package pixlsplat

// Dual-quaternion skinning for PSF models (port of src/viewer/rig.js + Spark).
//
// Each bone is a rigid transform (R, t) relative to the bind pose. As a dual
// quaternion: real = R, dual = ½ t R. A point is skinned as the weighted blend
// of bone dual-quats applied to the rest position; normals use the rotation only.

import "core:math"
import "core:math/linalg"
import "core:slice"

// Dual quaternion: real (rotation) + dual (translation encoded).
Dual_Quat :: struct {
    r: quaternion128, // rotation
    d: quaternion128, // 0.5 * t * r
}

q_new :: proc(x, y, z, w: f32) -> quaternion128 {
    q: quaternion128
    q.x = x; q.y = y; q.z = z; q.w = w
    return q
}

q_scale :: proc(q: quaternion128, s: f32) -> quaternion128 {
    out: quaternion128
    out.x = q.x * s; out.y = q.y * s; out.z = q.z * s; out.w = q.w * s
    return out
}

q_add :: proc(a, b: quaternion128) -> quaternion128 {
    out: quaternion128
    out.x = a.x + b.x; out.y = a.y + b.y; out.z = a.z + b.z; out.w = a.w + b.w
    return out
}

q_len :: proc(q: quaternion128) -> f32 {
    return math.sqrt(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w)
}

q_norm :: proc(q: quaternion128) -> quaternion128 {
    n := q_len(q)
    if n < 1e-8 do return linalg.QUATERNIONF32_IDENTITY
    return q_scale(q, 1 / n)
}

dq_identity :: proc() -> Dual_Quat {
    return Dual_Quat{r = linalg.QUATERNIONF32_IDENTITY, d = q_new(0, 0, 0, 0)}
}

// Build dual quat from rotation quaternion + translation vector.
dq_from_quat_pos :: proc(q: quaternion128, t: [3]f32) -> Dual_Quat {
    // dual = 0.5 * (0,t) * q
    tq := q_new(t.x, t.y, t.z, 0)
    return Dual_Quat{r = q, d = q_scale(tq * q, 0.5)}
}

// Apply dual quat to a point: p' = R p + t
dq_transform_point :: proc(dq: Dual_Quat, p: [3]f32) -> [3]f32 {
    // t = 2 * dual * conjugate(real), taking xyz
    conj_r := conj(dq.r)
    tq := q_scale(dq.d * conj_r, 2)
    t := [3]f32{tq.x, tq.y, tq.z}
    rp := linalg.mul(dq.r, p)
    return rp + t
}

// Apply rotation part only (for normals).
dq_rotate :: proc(dq: Dual_Quat, v: [3]f32) -> [3]f32 {
    return linalg.mul(dq.r, v)
}

// Weighted blend of dual quats (short-arc: flip sign if dot(real) < 0).
dq_blend4 :: proc(dqs: [4]Dual_Quat, w: [4]f32) -> Dual_Quat {
    out: Dual_Quat
    total: f32
    ref := dqs[0].r
    for i in 0..<4 {
        if w[i] <= 0 do continue
        q := dqs[i]
        // same hemisphere as first non-zero weight
        if linalg.dot(q.r, ref) < 0 {
            q.r = q_scale(q.r, -1)
            q.d = q_scale(q.d, -1)
        }
        out.r = q_add(out.r, q_scale(q.r, w[i]))
        out.d = q_add(out.d, q_scale(q.d, w[i]))
        total += w[i]
    }
    if total < 1e-8 do return dq_identity()
    n := q_len(out.r)
    if n < 1e-8 do return dq_identity()
    inv := 1 / n
    out.r = q_scale(out.r, inv)
    out.d = q_scale(out.d, inv)
    return out
}

// Bone pose used by stand_on_ground (compact: quat + translation).
Bone_Pose :: struct {
    q: quaternion128,
    t: [3]f32,
}

// Skin all model surfels from rest positions into the scene slice.
// bones: dual quats, one per joint index referenced by model.joints.
// scene_slice: the portion of the global surfel array that holds this model.
skin_apply :: proc(
    model: ^Psf_Model,
    bones: []Dual_Quat,
    scene_slice: []Surfel,
) {
    assert(len(scene_slice) == len(model.rest_pos))
    if !model.skinned || model.joints == nil {
        for i in 0..<len(scene_slice) {
            scene_slice[i].pos = model.rest_pos[i]
            scene_slice[i].normal = model.rest_nrm[i]
        }
        return
    }
    for i in 0..<len(scene_slice) {
        j := model.joints[i]
        ww := model.weights[i]
        w := [4]f32{f32(ww[0])/255, f32(ww[1])/255, f32(ww[2])/255, f32(ww[3])/255}
        dqs: [4]Dual_Quat
        for k in 0..<4 {
            bi := int(j[k])
            if bi >= 0 && bi < len(bones) do dqs[k] = bones[bi]
            else do dqs[k] = dq_identity()
        }
        dq := dq_blend4(dqs, w)
        scene_slice[i].pos = dq_transform_point(dq, model.rest_pos[i])
        n := dq_rotate(dq, model.rest_nrm[i])
        if linalg.vector_length(n) > 1e-5 do n = linalg.normalize(n)
        scene_slice[i].normal = n
    }
}

// 2nd-percentile foot height → lift so the pose sits on ground_y.
// Matches standOnGround in rig.js: lift immediately when sinking, ease when rising.
stand_on_ground :: proc(
    model: ^Psf_Model,
    poses: []Bone_Pose,
    ground_y: f32,
    dt: f32,
    lift: ^f32,
    scene_slice: []Surfel,
) {
    n := len(model.rest_pos)
    if n == 0 do return
    // Sparse sample (≤6000) like the original.
    stride := max(1, (n + 5999) / 6000)
    ys := make([dynamic]f32, 0, (n + stride - 1) / stride)
    defer delete(ys)

    skinned := model.skinned && model.joints != nil && len(poses) > 0
    for i := 0; i < n; i += stride {
        p := model.rest_pos[i]
        h: f32
        if skinned {
            j := model.joints[i]
            ww := model.weights[i]
            for k in 0..<4 {
                w := f32(ww[k]) / 255
                if w <= 0 do continue
                bi := int(j[k])
                if bi < 0 || bi >= len(poses) do continue
                pose := poses[bi]
                // y row of R·p + t  (same formula as rig.js)
                qx, qy, qz, qw := pose.q.x, pose.q.y, pose.q.z, pose.q.w
                hy := (2*(qx*qy + qw*qz))*p.x + (1 - 2*(qx*qx + qz*qz))*p.y + (2*(qy*qz - qw*qx))*p.z + pose.t.y
                h += w * hy
            }
        } else {
            h = p.y
        }
        append(&ys, h)
    }
    slice.sort(ys[:])
    foot := ys[min(len(ys)-1, len(ys)*2/100)] // 2nd percentile
    want := ground_y - (foot - 0.012)
    if want > lift^ {
        lift^ = want
    } else {
        lift^ += (want - lift^) * min(1, dt * 2.5)
    }
    // Apply lift to the already-skinned scene positions.
    for i in 0..<len(scene_slice) {
        scene_slice[i].pos.y += lift^
    }
}
