package pixlsplat

// Minimal GLB loader for <name>.rig.glb files produced by convert-model.mjs.
// Only nodes, skins (inverse bind matrices + joint indices), and animations
// are read — meshes and textures have already been stripped.
//
// Plays clips by sampling TRS channels, building local matrices, walking the
// node hierarchy for world matrices, then converting to bind-relative dual
// quaternions for skin_apply (see skin.odin / original rig.js).

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

// ---- public ----------------------------------------------------------------

Rig :: struct {
    bones:       []Dual_Quat,   // current pose, joint order
    poses:       []Bone_Pose,   // quat+pos for stand_on_ground
    rest_inv_q:  []quaternion128,
    rest_pos:    [][3]f32,      // bind position in model (recentred) space
    joint_nodes: []int,         // node index per joint
    nodes:       []Rig_Node,
    clips:       []Rig_Clip,
    clip_names:  []string,
    current:     int,           // index into clips, -1 = none
    time:        f32,
    ground_y:    f32,
    lift:        f32,
    center:      [3]f32,        // same recenter as the PSF
    unit:        f32,
}

Rig_Node :: struct {
    name:         string,
    translation:  [3]f32,
    rotation:     quaternion128,
    scale:        [3]f32,
    children:     []int,
    parent:       int,          // -1 root
    // animated overrides (reset each sample from bind, then channels write)
    t:            [3]f32,
    r:            quaternion128,
    s:            [3]f32,
    world:        matrix[4,4]f32,
}

Rig_Clip :: struct {
    name:     string,
    duration: f32,
    channels: [dynamic]Rig_Channel,
}

Rig_Channel :: struct {
    node:   int,
    path:   u8,          // 0=translation 1=rotation 2=scale
    times:  []f32,
    values: []f32,       // 3 or 4 floats per key
}

rig_destroy :: proc(rig: ^Rig) {
    delete(rig.bones)
    delete(rig.poses)
    delete(rig.rest_inv_q)
    delete(rig.rest_pos)
    delete(rig.joint_nodes)
    for &n in rig.nodes {
        delete(n.name)
        delete(n.children)
    }
    delete(rig.nodes)
    for &c in rig.clips {
        delete(c.name)
        for &ch in c.channels {
            delete(ch.times)
            delete(ch.values)
        }
        delete(c.channels)
    }
    delete(rig.clips)
    delete(rig.clip_names)
    rig^ = {}
}

load_rig :: proc(path: string, center: [3]f32, unit: f32) -> (rig: Rig, ok: bool) {
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil {
        fmt.eprintf("rig: cannot read %s\n", path)
        return {}, false
    }
    defer delete(data)
    if len(data) < 20 || string(data[0:4]) != "glTF" {
        fmt.eprintf("rig: not a GLB: %s\n", path)
        return {}, false
    }
    // GLB: 12-byte header, then JSON chunk, then BIN chunk
    version := (^u32)(&data[4])^
    if version != 2 {
        fmt.eprintf("rig: unsupported glTF version %d\n", version)
        return {}, false
    }
    off := 12
    json_data: []u8
    bin_data: []u8
    for off + 8 <= len(data) {
        clen := int((^u32)(&data[off])^)
        ctype := (^u32)(&data[off+4])^
        off += 8
        if off+clen > len(data) do break
        chunk := data[off:off+clen]
        off += clen
        if ctype == 0x4E4F534A do json_data = chunk // JSON
        if ctype == 0x004E4942 do bin_data = chunk // BIN
    }
    if json_data == nil {
        fmt.eprintf("rig: no JSON chunk in %s\n", path)
        return {}, false
    }

    // Parse with a loose JSON tree.
    root, jerr := json.parse(json_data, spec = .JSON, allocator = context.allocator)
    if jerr != nil {
        fmt.eprintf("rig: JSON parse failed: %v\n", jerr)
        return {}, false
    }
    defer json.destroy_value(root)
    obj, is_obj := root.(json.Object)
    if !is_obj {
        fmt.eprintf("rig: root is not an object\n")
        return {}, false
    }

    rig.center = center
    rig.unit = unit
    rig.current = -1
    rig.ground_y = 0

    // ---- nodes ----
    nodes_val, _ := obj["nodes"].(json.Array)
    rig.nodes = make([]Rig_Node, len(nodes_val))
    for nv, i in nodes_val {
        no, _ := nv.(json.Object)
        n := &rig.nodes[i]
        n.parent = -1
        n.scale = {1, 1, 1}
        n.rotation = linalg.QUATERNIONF32_IDENTITY
        if name, ok := no["name"].(json.String); ok {
            n.name = strings.clone(string(name))
        }
        if t, ok := no["translation"].(json.Array); ok && len(t) >= 3 {
            n.translation = {jf32(t[0]), jf32(t[1]), jf32(t[2])}
        }
        if r, ok := no["rotation"].(json.Array); ok && len(r) >= 4 {
            // glTF stores xyzw
            n.rotation = q_new(jf32(r[0]), jf32(r[1]), jf32(r[2]), jf32(r[3]))
        }
        if s, ok := no["scale"].(json.Array); ok && len(s) >= 3 {
            n.scale = {jf32(s[0]), jf32(s[1]), jf32(s[2])}
        }
        if ch, ok := no["children"].(json.Array); ok {
            n.children = make([]int, len(ch))
            for c, ci in ch do n.children[ci] = int(jf32(c))
        }
        n.t = n.translation
        n.r = n.rotation
        n.s = n.scale
    }
    // parent links
    for &n, i in rig.nodes {
        for c in n.children {
            if c >= 0 && c < len(rig.nodes) do rig.nodes[c].parent = i
        }
    }

    // ---- accessors / bufferViews helpers ----
    accessors, _ := obj["accessors"].(json.Array)
    buffer_views, _ := obj["bufferViews"].(json.Array)

    read_f32_accessor := proc(accessors: json.Array, buffer_views: json.Array, bin: []u8, index: int) -> []f32 {
        if index < 0 || index >= len(accessors) do return nil
        acc, _ := accessors[index].(json.Object)
        bv_i := int(jf32(acc["bufferView"]))
        count := int(jf32(acc["count"]))
        comp_type := int(jf32(acc["componentType"])) // 5126 = f32
        type_s, _ := acc["type"].(json.String)
        ncomp := 1
        switch string(type_s) {
        case "VEC3": ncomp = 3
        case "VEC4": ncomp = 4
        case "MAT4": ncomp = 16
        case "SCALAR": ncomp = 1
        }
        if comp_type != 5126 || count <= 0 do return nil
        bv, _ := buffer_views[bv_i].(json.Object)
        boff := int(jf32(bv["byteOffset"])) if "byteOffset" in bv else 0
        aoff := int(jf32(acc["byteOffset"])) if "byteOffset" in acc else 0
        start := boff + aoff
        need := count * ncomp * 4
        if start < 0 || start+need > len(bin) do return nil
        out := make([]f32, count * ncomp)
        mem.copy(raw_data(out), raw_data(bin[start:start+need]), need)
        return out
    }

    // ---- skin ----
    skins, _ := obj["skins"].(json.Array)
    if len(skins) == 0 {
        fmt.eprintf("rig: no skins in %s\n", path)
        return {}, false
    }
    skin, _ := skins[0].(json.Object)
    joints_a, _ := skin["joints"].(json.Array)
    rig.joint_nodes = make([]int, len(joints_a))
    for jv, ji in joints_a do rig.joint_nodes[ji] = int(jf32(jv))

    ibm_idx := int(jf32(skin["inverseBindMatrices"]))
    ibm := read_f32_accessor(accessors, buffer_views, bin_data, ibm_idx)
    defer delete(ibm)
    njoints := len(rig.joint_nodes)
    rig.rest_inv_q = make([]quaternion128, njoints)
    rig.rest_pos = make([][3]f32, njoints)
    rig.bones = make([]Dual_Quat, njoints)
    rig.poses = make([]Bone_Pose, njoints)

    // inverse bind → bind pose (invert), then recenter/scale like the PSF
    for i in 0..<njoints {
        m: matrix[4,4]f32
        if ibm != nil && (i+1)*16 <= len(ibm) {
            for r in 0..<4 do for c in 0..<4 {
                // glTF MAT4 is column-major
                m[c][r] = ibm[i*16 + c*4 + r]
            }
        } else {
            m = linalg.MATRIX4F32_IDENTITY
        }
        // bind = inverse(inverseBind)
        bind := linalg.matrix4_inverse(m)
        t, q, s := mat4_decompose(bind)
        _ = s
        // into model space: (p - center) * unit
        rig.rest_pos[i] = (t - center) * unit
        rig.rest_inv_q[i] = conj(q)
        rig.bones[i] = dq_identity()
        rig.poses[i] = Bone_Pose{q = linalg.QUATERNIONF32_IDENTITY, t = {}}
    }

    // ---- animations ----
    anims, _ := obj["animations"].(json.Array)
    rig.clips = make([]Rig_Clip, len(anims))
    rig.clip_names = make([]string, len(anims))
    for av, ai in anims {
        ao, _ := av.(json.Object)
        clip := &rig.clips[ai]
        if name, ok := ao["name"].(json.String); ok {
            clip.name = strings.clone(string(name))
        } else {
            clip.name = fmt.aprintf("clip_%d", ai)
        }
        rig.clip_names[ai] = clip.name
        ch_a, _ := ao["channels"].(json.Array)
        sm_a, _ := ao["samplers"].(json.Array)
        clip.channels = make([dynamic]Rig_Channel, 0, len(ch_a))
        for chv in ch_a {
            cho, _ := chv.(json.Object)
            samp_i := int(jf32(cho["sampler"]))
            tgt, _ := cho["target"].(json.Object)
            node_i := int(jf32(tgt["node"]))
            path_s, _ := tgt["path"].(json.String)
            path: u8
            switch string(path_s) {
            case "translation": path = 0
            case "rotation":    path = 1
            case "scale":       path = 2
            case: continue
            }
            if samp_i < 0 || samp_i >= len(sm_a) do continue
            sm, _ := sm_a[samp_i].(json.Object)
            in_acc := int(jf32(sm["input"]))
            out_acc := int(jf32(sm["output"]))
            times := read_f32_accessor(accessors, buffer_views, bin_data, in_acc)
            values := read_f32_accessor(accessors, buffer_views, bin_data, out_acc)
            if times == nil || values == nil {
                delete(times)
                delete(values)
                continue
            }
            ch := Rig_Channel{node = node_i, path = path, times = times, values = values}
            if len(times) > 0 do clip.duration = max(clip.duration, times[len(times)-1])
            append(&clip.channels, ch)
        }
    }

    // Prefer walk, else first clip.
    for i in 0..<len(rig.clips) {
        if rig.clips[i].name == "walk" {
            rig.current = i
            break
        }
    }
    if rig.current < 0 && len(rig.clips) > 0 do rig.current = 0

    fmt.printf("rig: %s → %d joints, %d clips", path, njoints, len(rig.clips))
    if rig.current >= 0 do fmt.printf(" (playing '%s')", rig.clips[rig.current].name)
    fmt.printf("\n")
    ok = true
    return
}

rig_play :: proc(rig: ^Rig, name: string) {
    for i in 0..<len(rig.clips) {
        if rig.clips[i].name == name {
            if rig.current != i {
                rig.current = i
                rig.time = 0
            }
            return
        }
    }
}

// Advance animation by dt seconds and rebuild bone dual-quats.
rig_update :: proc(rig: ^Rig, dt: f32) {
    if len(rig.nodes) == 0 do return

    // Reset nodes to bind TRS.
    for &n in rig.nodes {
        n.t = n.translation
        n.r = n.rotation
        n.s = n.scale
    }

    if rig.current >= 0 && rig.current < len(rig.clips) {
        clip := &rig.clips[rig.current]
        if clip.duration > 0 {
            rig.time = math.mod(rig.time + dt, clip.duration)
        }
        t := rig.time
        for &ch in clip.channels {
            if ch.node < 0 || ch.node >= len(rig.nodes) do continue
            sample_channel(&ch, t, &rig.nodes[ch.node])
        }
    }

    // Local matrices then hierarchy → world.
    // Find roots and DFS.
    for &n, i in rig.nodes {
        local := mat4_compose(n.t, n.r, n.s)
        if n.parent < 0 {
            n.world = local
        } else {
            n.world = linalg.mul(rig.nodes[n.parent].world, local)
        }
        // Parents come first only if nodes are ordered; glTF does not guarantee
        // that. Multi-pass: relax until stable (max depth ≤ node count).
        _ = i
    }
    // Multi-pass parent resolution (handles arbitrary order).
    for _ in 0..<len(rig.nodes) {
        changed := false
        for &n in rig.nodes {
            local := mat4_compose(n.t, n.r, n.s)
            if n.parent < 0 {
                if n.world != local {
                    n.world = local
                    changed = true
                }
            } else {
                w := linalg.mul(rig.nodes[n.parent].world, local)
                if n.world != w {
                    n.world = w
                    changed = true
                }
            }
        }
        if !changed do break
    }

    // Bind-relative dual quats (same math as rig.js).
    for ji in 0..<len(rig.joint_nodes) {
        ni := rig.joint_nodes[ji]
        if ni < 0 || ni >= len(rig.nodes) {
            rig.bones[ji] = dq_identity()
            rig.poses[ji] = Bone_Pose{q = linalg.QUATERNIONF32_IDENTITY, t = {}}
            continue
        }
        t, q, s := mat4_decompose(rig.nodes[ni].world)
        _ = s
        // R = worldQuat * restInvQuat
        R := q * rig.rest_inv_q[ji]
        // model-space world position
        p := (t - rig.center) * rig.unit
        // t = p - R * restPos
        rt := linalg.mul(R, rig.rest_pos[ji])
        tr := p - rt
        rig.bones[ji] = dq_from_quat_pos(R, tr)
        rig.poses[ji] = Bone_Pose{q = R, t = tr}
    }
}

// ---- internals -------------------------------------------------------------

jf32 :: proc(v: json.Value) -> f32 {
    #partial switch x in v {
    case json.Float: return f32(x)
    case json.Integer: return f32(x)
    }
    return 0
}

sample_channel :: proc(ch: ^Rig_Channel, t: f32, node: ^Rig_Node) {
    n := len(ch.times)
    if n == 0 do return
    if t <= ch.times[0] {
        apply_key(ch, 0, node)
        return
    }
    if t >= ch.times[n-1] {
        apply_key(ch, n-1, node)
        return
    }
    // Binary search key interval.
    lo, hi := 0, n-1
    for lo+1 < hi {
        mid := (lo + hi) / 2
        if ch.times[mid] <= t do lo = mid
        else do hi = mid
    }
    t0, t1 := ch.times[lo], ch.times[hi]
    u := (t - t0) / max(t1 - t0, 1e-8)
    switch ch.path {
    case 0: // translation VEC3
        a := [3]f32{ch.values[lo*3], ch.values[lo*3+1], ch.values[lo*3+2]}
        b := [3]f32{ch.values[hi*3], ch.values[hi*3+1], ch.values[hi*3+2]}
        node.t = a + (b - a) * u
    case 1: // rotation VEC4 xyzw, slerp
        a := q_new(ch.values[lo*4], ch.values[lo*4+1], ch.values[lo*4+2], ch.values[lo*4+3])
        b := q_new(ch.values[hi*4], ch.values[hi*4+1], ch.values[hi*4+2], ch.values[hi*4+3])
        node.r = quat_slerp(a, b, u)
    case 2: // scale VEC3
        a := [3]f32{ch.values[lo*3], ch.values[lo*3+1], ch.values[lo*3+2]}
        b := [3]f32{ch.values[hi*3], ch.values[hi*3+1], ch.values[hi*3+2]}
        node.s = a + (b - a) * u
    }
}

apply_key :: proc(ch: ^Rig_Channel, i: int, node: ^Rig_Node) {
    switch ch.path {
    case 0: node.t = {ch.values[i*3], ch.values[i*3+1], ch.values[i*3+2]}
    case 1: node.r = q_new(ch.values[i*4], ch.values[i*4+1], ch.values[i*4+2], ch.values[i*4+3])
    case 2: node.s = {ch.values[i*3], ch.values[i*3+1], ch.values[i*3+2]}
    }
}

quat_slerp :: proc(a, b: quaternion128, t: f32) -> quaternion128 {
    aa := a
    bb := b
    dot := aa.x*bb.x + aa.y*bb.y + aa.z*bb.z + aa.w*bb.w
    if dot < 0 {
        bb = q_scale(bb, -1)
        dot = -dot
    }
    if dot > 0.9995 {
        r := q_add(aa, q_scale(q_add(bb, q_scale(aa, -1)), t))
        return q_norm(r)
    }
    theta := math.acos(clamp(dot, -1, 1))
    s := math.sin(theta)
    wa := math.sin((1 - t) * theta) / s
    wb := math.sin(t * theta) / s
    return q_add(q_scale(aa, wa), q_scale(bb, wb))
}

mat4_compose :: proc(t: [3]f32, q: quaternion128, s: [3]f32) -> matrix[4,4]f32 {
    // Column-major: columns 0..2 are scaled rotated basis, column 3 is translation.
    R := linalg.matrix4_from_quaternion(q)
    // scale columns
    R[0] *= s.x
    R[1] *= s.y
    R[2] *= s.z
    R[3] = {t.x, t.y, t.z, 1}
    return R
}

mat4_decompose :: proc(m: matrix[4,4]f32) -> (t: [3]f32, q: quaternion128, s: [3]f32) {
    t = {m[3][0], m[3][1], m[3][2]}
    sx := linalg.vector_length([3]f32{m[0][0], m[0][1], m[0][2]})
    sy := linalg.vector_length([3]f32{m[1][0], m[1][1], m[1][2]})
    sz := linalg.vector_length([3]f32{m[2][0], m[2][1], m[2][2]})
    s = {max(sx, 1e-8), max(sy, 1e-8), max(sz, 1e-8)}
    R := m
    R[0] /= s.x
    R[1] /= s.y
    R[2] /= s.z
    q = quat_from_mat3(R)
    return
}

quat_from_mat3 :: proc(m: matrix[4,4]f32) -> quaternion128 {
    // Standard matrix → quaternion (column-major rotation in upper 3×3).
    tr := m[0][0] + m[1][1] + m[2][2]
    q: quaternion128
    if tr > 0 {
        s := math.sqrt(tr + 1) * 2
        q.w = 0.25 * s
        q.x = (m[1][2] - m[2][1]) / s
        q.y = (m[2][0] - m[0][2]) / s
        q.z = (m[0][1] - m[1][0]) / s
    } else if m[0][0] > m[1][1] && m[0][0] > m[2][2] {
        s := math.sqrt(1 + m[0][0] - m[1][1] - m[2][2]) * 2
        q.w = (m[1][2] - m[2][1]) / s
        q.x = 0.25 * s
        q.y = (m[0][1] + m[1][0]) / s
        q.z = (m[0][2] + m[2][0]) / s
    } else if m[1][1] > m[2][2] {
        s := math.sqrt(1 + m[1][1] - m[0][0] - m[2][2]) * 2
        q.w = (m[2][0] - m[0][2]) / s
        q.x = (m[0][1] + m[1][0]) / s
        q.y = 0.25 * s
        q.z = (m[1][2] + m[2][1]) / s
    } else {
        s := math.sqrt(1 + m[2][2] - m[0][0] - m[1][1]) * 2
        q.w = (m[0][1] - m[1][0]) / s
        q.x = (m[0][2] + m[2][0]) / s
        q.y = (m[1][2] + m[2][1]) / s
        q.z = 0.25 * s
    }
    n := q_len(q)
    if n > 1e-8 do q = q_scale(q, 1 / n)
    return q
}
