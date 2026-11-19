package pixlsplat

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

fract :: proc(x: f32) -> f32 {
    return x - math.floor(x)
}


// CPU-side particle motions matching particles.js MOTION table.
// Each particle keeps a stable seed r and a base pose; update mutates a
// transient draw pose (pos, alpha, scale).

Particle_Mode :: enum {
    Rise, Float, Blink, Twinkle, Drift, Leaf, Smoke, Beam, Fog, Shaft, Ray, Sway, Pulse,
}

Particle :: struct {
    mode:   Particle_Mode,
    base:   [3]f32,
    r:      [3]f32,   // stable random seed (0..1)
    color:  [4]u8,
    scale:  f32,      // base std dev, used when `sigma` is zero
    alpha0: f32,
    // Gaussian shape (world.js `put`): std dev along three local axes, and those
    // axes in world space. Zero sigma = isotropic `scale`; zero axes = identity.
    sigma:  [3]f32,
    axes:   [3][3]f32,
    // optional effect params
    center: [3]f32,   // beam / leaf column centre
    v:      [3]f32,   // x=radius or unused, y=height
    // transient
    pos:    [3]f32,
    alpha:  f32,
    scale_mul: f32,
    spin:   f32,      // rotation about Y (the lighthouse beam)
    alive:  bool,
}

Particle_System :: struct {
    items: [dynamic]Particle,
}

particle_system_make :: proc() -> Particle_System {
    return {items = make([dynamic]Particle)}
}

particle_system_destroy :: proc(ps: ^Particle_System) {
    delete(ps.items)
}

particle_add :: proc(ps: ^Particle_System, p: Particle) {
    p := p
    p.pos = p.base
    p.alpha = p.alpha0
    p.scale_mul = 1
    p.alive = true
    if p.sigma == ([3]f32{}) do p.sigma = {p.scale, p.scale, p.scale}
    if p.axes[0] == ([3]f32{}) && p.axes[1] == ([3]f32{}) {
        p.axes = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
    }
    append(&ps.items, p)
}

// World-space axes of a splat orientation (quaternion x, y, z, w). A zero
// quaternion means no rotation.
axes_from_quat :: proc(q: [4]f32) -> [3][3]f32 {
    if q == ([4]f32{}) do return {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
    r, u, n := quat_axes(q)
    return {r, u, n}
}

// One splat of a particle effect: position, std dev per axis, orientation.
// `r` is the stable random seed the motion uses; a particle and its halo share
// one so they move together.
particle_put :: proc(
    ps: ^Particle_System,
    mode: Particle_Mode,
    pos, sigma: [3]f32,
    rot: [4]f32,
    alpha: f32,
    color: [4]u8,
    center, v, r: [3]f32,
) {
    particle_add(ps, Particle{
        mode   = mode,
        base   = pos,
        r      = r,
        color  = color,
        scale  = sigma[0],
        alpha0 = alpha,
        center = center,
        v      = v,
        sigma  = sigma,
        axes   = axes_from_quat(rot),
    })
}

// Emit n particles of a mode in a box around center with given spread.
particle_emit_box :: proc(
    ps: ^Particle_System,
    mode: Particle_Mode,
    n: int,
    center, spread: [3]f32,
    colors: [][4]u8,
    scale: f32 = 0.02,
    alpha: f32 = 1,
    v: [3]f32 = {},
    seed: u32 = 1,
    pairs: bool = false, // if true, emit particle + faint halo twin
) {
    rng := mulberry32_new(seed)
    for i in 0..<n {
        r := [3]f32{mulberry32_next(&rng), mulberry32_next(&rng), mulberry32_next(&rng)}
        base := center + [3]f32{
            (r.x * 2 - 1) * spread.x,
            (r.y * 2 - 1) * spread.y,
            (r.z * 2 - 1) * spread.z,
        }
        col := colors[i % len(colors)]
        particle_add(ps, Particle{
            mode = mode, base = base, r = r, color = col,
            scale = scale, alpha0 = alpha, center = center, v = v,
        })
        if pairs {
            particle_add(ps, Particle{
                mode = mode, base = base, r = r, color = col,
                scale = scale * 2.2, alpha0 = alpha * 0.35, center = center, v = v,
            })
        }
    }
}

// Sun shafts: rows of long translucent splats along -SUN (scene-kit shafts).
Shaft_Beam :: struct {
    to:  [3]f32,
    len: f32,
    r:   f32,
}

shafts_emit :: proc(
    ps: ^Particle_System,
    beams: []Shaft_Beam,
    colors: [][4]u8,
    alpha: f32 = 0.3,
    n: int = 14,
    seed: u32 = 7,
) {
    rng := mulberry32_new(seed)
    dir := linalg.normalize([3]f32{-SUN.x, -SUN.y, -SUN.z})
    // horizontal across-beam axis
    side := linalg.normalize([3]f32{-dir.z, 0, dir.x})
    if linalg.vector_length(side) < 1e-4 do side = {1, 0, 0}
    for b, bi in beams {
        length := b.len if b.len > 0 else 2.2
        rr := b.r if b.r > 0 else 0.14
        for k in 0..<n {
            u := (f32(k) + 0.5) / f32(n)
            w := (mulberry32_next(&rng) - 0.5) * rr * 1.6
            t := length * (1 - u)
            thick := (rr * (0.3 + 0.4 * mulberry32_next(&rng))) / 1.5
            pos := b.to - dir * t + side * w
            col := colors[bi % len(colors)]
            a := alpha * (0.45 + 0.55 * u)
            // (thick, len/n*1.1, thick) along the beam, as in scene-kit.js shafts()
            ay := dir
            ax := linalg.normalize(linalg.cross(ay, [3]f32{0, 0, 1}))
            if linalg.vector_length(ax) < 1e-4 || math.is_nan(ax.x) do ax = {1, 0, 0}
            az := linalg.cross(ax, ay)
            particle_add(ps, Particle{
                mode = .Ray,
                base = pos,
                r = {mulberry32_next(&rng), mulberry32_next(&rng), mulberry32_next(&rng)},
                color = col,
                scale = thick,
                alpha0 = a,
                sigma = {thick, length / f32(n) * 1.1, thick},
                axes = {ax, ay, az},
            })
        }
    }
}

particle_update :: proc(ps: ^Particle_System, t: f32) {
    for &p in ps.items {
        r := p.r
        pos := p.base
        a: f32 = 1
        sm: f32 = 1
        spin: f32 = 0
        switch p.mode {
        case .Rise:
            k := fract(t * 0.22 * (0.6 + r.x) + r.y)
            pos.y += k * p.v.y
            pos.x += 0.07 * math.sin(k * 9 + r.z * 40) * k
            pos.z += 0.07 * math.cos(k * 7 + r.x * 40) * k
            sm = 1 - 0.6 * k
            a = sstep(0, 0.05, k) * (1 - sstep(0.55, 1, k))
        case .Float:
            pos += 0.07 * [3]f32{
                math.sin(t * 0.3 + r.x * 40),
                math.sin(t * 0.22 + r.y * 40),
                math.cos(t * 0.27 + r.z * 40),
            }
            a = 0.35 + 0.65 * sstep(0.2, 0.9, math.sin(t * (0.3 + r.z * 0.4) + r.x * 60) * 0.5 + 0.5)
        case .Blink:
            pos += 0.12 * [3]f32{
                math.sin(t * 0.5 + r.x * 40),
                0.6 * math.sin(t * 0.4 + r.y * 40),
                math.cos(t * 0.45 + r.z * 40),
            }
            a = sstep(0.55, 0.95, math.sin(t * (0.9 + r.z) + r.x * 60))
        case .Twinkle:
            a = sstep(0.6, 0.98, math.sin(t * (0.7 + r.z * 1.3) + r.x * 60))
        case .Drift:
            // wrap in x around radius v.x
            R := p.v.x if p.v.x > 0 else 1.3
            pos.x = fract((pos.x + t * 0.16 * (0.5 + r.x) + R) / (2 * R)) * (2 * R) - R
            pos.y += 0.03 * math.sin(t * 1.3 + r.y * 30)
            a = sstep(0, 0.25, R - abs(pos.x))
        case .Leaf:
            H := p.v.y if p.v.y > 0 else 1
            cy := p.center.y
            pos.y = cy + fract((pos.y - cy - t * 0.14 * (0.6 + r.x)) / H) * H
            pos.x += 0.13 * math.sin(t * 0.9 + r.y * 40 + pos.y * 3)
            pos.z += 0.11 * math.cos(t * 0.7 + r.z * 40 + pos.y * 2.5)
            a = sstep(0, 0.1, pos.y - cy) * (1 - sstep(H - 0.3, H, pos.y - cy))
        case .Smoke:
            k := fract(t * 0.09 * (0.6 + r.x) + r.y)
            pos.y += k * p.v.y
            pos.x += 0.12 * k * math.sin(k * 6 + r.z * 40) + 0.12 * k * k
            pos.z += 0.1 * k * math.cos(k * 5 + r.x * 40)
            sm = 1 + 3 * k
            a = sstep(0, 0.08, k) * (1 - sstep(0.3, 1, k)) * 0.6
        case .Beam:
            ang := t * 0.7
            cs, sn := math.cos(ang), math.sin(ang)
            d := pos - p.center
            pos = p.center + [3]f32{cs*d.x + sn*d.z, d.y, -sn*d.x + cs*d.z}
            spin = ang   // the bar turns with it
        case .Fog:
            pos.x += 0.25 * math.sin(t * 0.12 + r.x * 40)
            pos.z += 0.25 * math.cos(t * 0.1 + r.y * 40)
            pos.y += 0.04 * math.sin(t * 0.3 + r.z * 30)
            a = 0.55 + 0.45 * math.sin(t * 0.25 + r.z * 50)
        case .Shaft:
            pos.x += 0.08 * math.sin(t * 0.15 + r.x * 20)
            a = 0.5 + 0.5 * math.sin(t * 0.4 + r.y * 50)
        case .Ray:
            pos.x += 0.025 * math.sin(t * 0.21 + r.x * 6)
            pos.z += 0.02 * math.cos(t * 0.17 + r.x * 6)
            a = 0.8 + 0.2 * math.sin(t * 0.5 + r.y * 50)
        case .Sway:
            pos.x += 0.016 * math.sin(t * 1.6 + pos.x * 5 + pos.z * 3)
            pos.z += 0.011 * math.cos(t * 1.3 + pos.z * 4 - pos.x * 2)
        case .Pulse:
            sm = 0.93 + 0.07 * math.sin(t * 7 + r.x * 20)
        }
        p.pos = pos
        p.alpha = math.clamp(p.alpha0 * a, 0, 1)
        p.scale_mul = sm
        p.spin = spin
        p.alive = p.alpha > 0.02
    }
}

// Every particle is a 3D Gaussian: std dev `sigma` along its local axes. It is
// drawn the way a splat renderer does, as the ellipse its covariance projects to
// on the screen plane, so isotropic dots, flat mist discs, tall light shafts and
// the turning lighthouse beam all go through one path.
//   px_scale: render-target pixels per world unit at distance 1 (height / 2 tan(fov/2)).
//   Spark adds 0.3 px^2 to every splat's covariance so sub-pixel ones stay
//   visible; the same is done here.
particle_draw :: proc(
    ps: ^Particle_System,
    cam_right, cam_up, cam_pos: [3]f32,
    soft: bool,
    px_scale: f32 = 0,
) {
    k := SPLAT_STD_SOFT if soft else SPLAT_STD_DEV
    for p in ps.items {
        if !p.alive do continue
        dist := linalg.vector_length(p.pos - cam_pos)
        a := u8(math.clamp(p.alpha, 0, 1) * 255 + 0.5)
        col := apply_fog_color({p.color[0], p.color[1], p.color[2], a}, dist, emissive = true)

        sg   := p.sigma * p.scale_mul
        axes := p.axes
        if p.spin != 0 {
            cs, sn := math.cos(p.spin), math.sin(p.spin)
            for i in 0..<3 {
                x, z := axes[i].x, axes[i].z
                axes[i].x =  cs * x + sn * z
                axes[i].z = -sn * x + cs * z
            }
        }

        // covariance on the screen plane: sum of sigma_i^2 * (axis_i projected)^2
        cxx, cxy, cyy: f32
        for i in 0..<3 {
            u := linalg.dot(axes[i], cam_right) * sg[i]
            v := linalg.dot(axes[i], cam_up) * sg[i]
            cxx += u * u
            cxy += u * v
            cyy += v * v
        }
        if px_scale > 0 {
            ppu  := px_scale / max(dist, 1e-3)
            blur := 0.3 / (ppu * ppu)
            cxx += blur
            cyy += blur
        }
        tr   := cxx + cyy
        det  := cxx * cyy - cxy * cxy
        disc := math.sqrt(max(tr * tr * 0.25 - det, 0))
        l1   := tr * 0.5 + disc
        l2   := max(tr * 0.5 - disc, 1e-12)

        v1 := [2]f32{1, 0}
        if abs(cxy) > 1e-12 {
            v1 = {l1 - cyy, cxy}
            v1 /= math.hypot(v1[0], v1[1])
        } else if cyy > cxx {
            v1 = {0, 1}
        }
        e1 := cam_right * v1[0] + cam_up * v1[1]
        e2 := cam_right * -v1[1] + cam_up * v1[0]
        draw_oriented_ellipse(p.pos, e1, e2, k * math.sqrt(l1), k * math.sqrt(l2),
            {col.r, col.g, col.b, a}, two_sided = false)
    }
}
