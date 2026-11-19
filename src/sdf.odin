package pixlsplat

import "core:math"
import "core:math/linalg"

Sphere :: struct { c: [3]f32, r: f32 }
sphere_dist :: proc(s: Sphere, p: [3]f32) -> f32 {
    return linalg.vector_length(p - s.c) - s.r
}

Ellipsoid :: struct { c: [3]f32, radii: [3]f32 }
ellipsoid_dist :: proc(e: Ellipsoid, p: [3]f32) -> f32 {
    q  := (p - e.c) / e.radii
    k0 := linalg.vector_length(q)
    k1 := linalg.vector_length(q / e.radii)
    if k1 < 1e-6 do return -min(e.radii.x, e.radii.y, e.radii.z)
    return (k0 * (k0 - 1)) / k1
}

Cone :: struct {
    a, b:   [3]f32,
    r1, r2: f32,
    ba:     [3]f32,
    baba:   f32,
}
cone_make :: proc(a, b: [3]f32, r1, r2: f32) -> Cone {
    ba := b - a
    return {a = a, b = b, r1 = r1, r2 = r2, ba = ba, baba = linalg.dot(ba, ba)}
}
cone_dist :: proc(c: Cone, p: [3]f32) -> f32 {
    pa := p - c.a
    t  := math.clamp(linalg.dot(pa, c.ba) / c.baba, 0, 1)
    return linalg.vector_length(pa - c.ba * t) - (c.r1 + (c.r2 - c.r1) * t)
}

Box :: struct { c: [3]f32, half: [3]f32, r: f32 }
box_dist :: proc(b: Box, p: [3]f32) -> f32 {
    q := linalg.abs(p - b.c) - b.half + b.r
    return linalg.vector_length(linalg.max(q, 0)) + min(max(q.x, max(q.y, q.z)), 0) - b.r
}

// Upright capped cylinder (centre, radius, half-height, corner radius).
Cyl :: struct { c: [3]f32, radius, half_h, r: f32 }
cyl_dist :: proc(cy: Cyl, p: [3]f32) -> f32 {
    dx := math.hypot(p.x - cy.c.x, p.z - cy.c.z) - cy.radius + cy.r
    dy := abs(p.y - cy.c.y) - cy.half_h + cy.r
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - cy.r
}

Prim_Kind :: enum { Sphere, Ellipsoid, Cone, Box, Cyl, Func }

// ---- displacement (port of JS displace(shape, fn)) -------------------------
// The JS authoring code wraps a primitive in a closure that adds a function of
// the position to its distance. Odin has no closures, so the few displacement
// patterns the scenes use are data: any Prim can carry one, and prim_dist adds
// it after the base distance. No global slots, no limit on how many.
Disp_Mode :: enum u8 {
    None,
    Noise,       // sum of up to two terms: amp * (vnoise3(p * freq) - bias)
    Radial_Cos,  // amp * cos(atan2(z - cz, x - cx) * n) * sstep(y1, y0, p.y): ribbed tent
    Axial_Sin,   // amp * sin(p.y * freq): ringed trunk
}

Displace :: struct {
    mode:   Disp_Mode,
    amp:    [2]f32,
    freq:   [2]f32,
    bias:   [2]f32,
    centre: [2]f32,   // Radial_Cos: x, z of the axis
    n:      f32,      // Radial_Cos: number of ribs
    y0, y1: f32,      // Radial_Cos: sstep(y0, y1, p.y) fades the ribs along the height
}

// amp * (vnoise3(p * freq) - bias). bias 0.5 centres the noise on the surface,
// 0 only pushes it one way (floating rocks, boulders).
disp_noise :: proc(amp, freq: f32, bias: f32 = 0) -> Displace {
    return {mode = .Noise, amp = {amp, 0}, freq = {freq, 0}, bias = {bias, 0}}
}

// Two noise octaves, as in the lighthouse rock:
//   -0.11 * (vnoise3(4p) - 0.5) - 0.035 * vnoise3(11p)
disp_noise2 :: proc(amp1, freq1, bias1, amp2, freq2, bias2: f32) -> Displace {
    return {mode = .Noise, amp = {amp1, amp2}, freq = {freq1, freq2}, bias = {bias1, bias2}}
}

// amp * cos(atan2(z - cz, x - cx) * n) * sstep(y_hi, y_lo, p.y)
disp_radial_cos :: proc(cx, cz, amp, n, y_hi, y_lo: f32) -> Displace {
    return {mode = .Radial_Cos, amp = {amp, 0}, centre = {cx, cz}, n = n, y0 = y_hi, y1 = y_lo}
}

disp_axial_sin :: proc(amp, freq: f32) -> Displace {
    return {mode = .Axial_Sin, amp = {amp, 0}, freq = {freq, 0}}
}

displace_eval :: proc(d: Displace, p: [3]f32) -> f32 {
    switch d.mode {
    case .None:
        return 0
    case .Noise:
        v := d.amp[0] * (vnoise3(p.x * d.freq[0], p.y * d.freq[0], p.z * d.freq[0]) - d.bias[0])
        if d.amp[1] != 0 {
            v += d.amp[1] * (vnoise3(p.x * d.freq[1], p.y * d.freq[1], p.z * d.freq[1]) - d.bias[1])
        }
        return v
    case .Radial_Cos:
        a := math.atan2(p.z - d.centre[1], p.x - d.centre[0])
        return d.amp[0] * math.cos(a * d.n) * sstep(d.y0, d.y1, p.y)
    case .Axial_Sin:
        return d.amp[0] * math.sin(p.y * d.freq[0])
    }
    return 0
}

Prim :: struct {
    kind:   Prim_Kind,
    disp:   Displace,
    mat:    int,
    k:      f32,
    is_sub: bool,
    bound:  [4]f32, // cx,cy,cz,r — r<=0 means unbound
    f:      proc(p: [3]f32) -> f32,
    using data: struct #raw_union {
        sphere:    Sphere,
        ellipsoid: Ellipsoid,
        cone:      Cone,
        box:       Box,
        cyl:       Cyl,
    },
}

Shape :: struct {
    adds:          [dynamic]Prim,
    current_bound: [4]f32, // r<=0 = clear
}

shape_new :: proc() -> Shape {
    return {adds = make([dynamic]Prim), current_bound = {0, 0, 0, -1}}
}

shape_bound :: proc(s: ^Shape, cx, cy, cz, r: f32) {
    s.current_bound = {cx, cy, cz, r}
}
shape_bound_clear :: proc(s: ^Shape) {
    s.current_bound = {0, 0, 0, -1}
}

_push_prim :: proc(s: ^Shape, pr: Prim) {
    pr := pr
    pr.bound = s.current_bound
    append(&s.adds, pr)
}

shape_add_sphere :: proc(s: ^Shape, c: [3]f32, r: f32, mat: int, k: f32 = 0) {
    _push_prim(s, Prim{kind = .Sphere, mat = mat, k = k, sphere = {c, r}})
}
shape_add_ellipsoid :: proc(s: ^Shape, c: [3]f32, radii: [3]f32, mat: int, k: f32 = 0) {
    _push_prim(s, Prim{kind = .Ellipsoid, mat = mat, k = k, ellipsoid = {c, radii}})
}
shape_add_cone :: proc(s: ^Shape, a, b: [3]f32, r1, r2: f32, mat: int, k: f32 = 0) {
    _push_prim(s, Prim{kind = .Cone, mat = mat, k = k, cone = cone_make(a, b, r1, r2)})
}
shape_add_box :: proc(s: ^Shape, c: [3]f32, half: [3]f32, r: f32, mat: int, k: f32 = 0) {
    _push_prim(s, Prim{kind = .Box, mat = mat, k = k, box = {c, half, r}})
}
shape_add_func :: proc(s: ^Shape, f: proc(p: [3]f32) -> f32, mat: int, k: f32 = 0) {
    _push_prim(s, Prim{kind = .Func, mat = mat, k = k, f = f})
}

shape_add_cyl :: proc(s: ^Shape, c: [3]f32, radius, half_h, r: f32, mat: int, k: f32 = 0) {
    _push_prim(s, Prim{kind = .Cyl, mat = mat, k = k, cyl = {c, radius, half_h, r}})
}

shape_sub_sphere :: proc(s: ^Shape, c: [3]f32, r: f32, mat: int) {
    _push_prim(s, Prim{kind = .Sphere, mat = mat, is_sub = true, sphere = {c, r}})
}
shape_sub_ellipsoid :: proc(s: ^Shape, c: [3]f32, radii: [3]f32, mat: int) {
    _push_prim(s, Prim{kind = .Ellipsoid, mat = mat, is_sub = true, ellipsoid = {c, radii}})
}
shape_sub_func :: proc(s: ^Shape, f: proc(p: [3]f32) -> f32, mat: int) {
    _push_prim(s, Prim{kind = .Func, mat = mat, is_sub = true, f = f})
}

prim_dist :: proc(pr: Prim, p: [3]f32) -> f32 {
    d: f32 = 1e9
    switch pr.kind {
    case .Sphere:    d = sphere_dist(pr.sphere, p)
    case .Ellipsoid: d = ellipsoid_dist(pr.ellipsoid, p)
    case .Cone:      d = cone_dist(pr.cone, p)
    case .Box:       d = box_dist(pr.box, p)
    case .Cyl:       d = cyl_dist(pr.cyl, p)
    case .Func:      d = pr.f(p)
    }
    if pr.disp.mode != .None do d += displace_eval(pr.disp, p)
    return d
}

// Displace the primitive added last: shape_add_cone(...); shape_displace(&s, disp_axial_sin(...)).
shape_displace :: proc(s: ^Shape, d: Displace) {
    assert(len(s.adds) > 0)
    s.adds[len(s.adds) - 1].disp = d
}

far_bound :: proc(b: [4]f32, p: [3]f32) -> f32 {
    return linalg.vector_length(p - [3]f32{b[0], b[1], b[2]}) - b[3]
}

smin :: proc(a, b, k: f32) -> f32 {
    if k <= 0 do return min(a, b)
    h := max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k * 0.25
}

shape_dist :: proc(s: Shape, p: [3]f32) -> f32 {
    d: f32 = 1e9
    for a in s.adds {
        if a.is_sub do continue
        if a.bound[3] > 0 && far_bound(a.bound, p) > d + a.k do continue
        d = smin(d, prim_dist(a, p), a.k)
    }
    for u in s.adds {
        if !u.is_sub do continue
        if u.bound[3] > 0 && far_bound(u.bound, p) > 0.05 do continue
        sd := -prim_dist(u, p)
        if sd > d do d = sd
    }
    return d
}

shape_mat :: proc(s: Shape, p: [3]f32) -> int {
    best: f32 = 1e9
    m := 0
    for a in s.adds {
        if a.is_sub do continue
        if a.bound[3] > 0 && far_bound(a.bound, p) > best do continue
        d := prim_dist(a, p)
        if d < best {
            best = d
            m = a.mat
        }
    }
    for u in s.adds {
        if !u.is_sub do continue
        if u.bound[3] > 0 && far_bound(u.bound, p) > 0.05 do continue
        if -prim_dist(u, p) > best - 1e-3 do return u.mat
    }
    return m
}

Surfel :: struct {
    pos:      [3]f32,
    normal:   [3]f32,
    color:    [4]u8,   // filled in by bake(): the final, lit palette colour
    ao:       f32,
    mat:      int,
    emissive: bool,    // set by bake(): drawn unlit and slightly boosted
}

// Samples the surface into surfels (position, normal, ao, material).
// Colours are assigned afterwards by bake() (island.odin).
sample_surface :: proc(
    sh:    Shape,
    minp, maxp: [3]f32,
    h:     f32,
) -> [dynamic]Surfel {
    out := make([dynamic]Surfel)
    e := h * 0.5
    B :: 4
    bh := f32(B) * h

    grad :: proc(sh: Shape, p: [3]f32, e: f32) -> [3]f32 {
        return {
            shape_dist(sh, p + {e,0,0}) - shape_dist(sh, p - {e,0,0}),
            shape_dist(sh, p + {0,e,0}) - shape_dist(sh, p - {0,e,0}),
            shape_dist(sh, p + {0,0,e}) - shape_dist(sh, p - {0,0,e}),
        }
    }

    ao_steps := [3]f32{2, 5, 10}

    // Hierarchical grid: skip whole BxBxB blocks that are clearly empty.
    for bz := minp.z; bz < maxp.z; bz += bh {
        for by := minp.y; by < maxp.y; by += bh {
            for bx := minp.x; bx < maxp.x; bx += bh {
                mid := [3]f32{bx + bh*0.5, by + bh*0.5, bz + bh*0.5}
                if abs(shape_dist(sh, mid)) > bh * 1.6 do continue

                for k in 0..<B {
                    for j in 0..<B {
                        for i in 0..<B {
                            p := [3]f32{
                                bx + (f32(i) + 0.5) * h,
                                by + (f32(j) + 0.5) * h,
                                bz + (f32(k) + 0.5) * h,
                            }
                            d := shape_dist(sh, p)
                            if abs(d) > h * 1.2 do continue

                            g  := grad(sh, p, e)
                            gl := linalg.vector_length(g) / (2 * e)
                            if gl < 1e-5 do continue
                            if abs(d) / gl > h * 0.6 do continue

                            for _ in 0..<2 {
                                s := d / (gl * gl) / (2 * e)
                                p -= g * s
                                d  = shape_dist(sh, p)
                                g  = grad(sh, p, e)
                                gl = linalg.vector_length(g) / (2 * e)
                                if gl < 1e-5 do break
                            }

                            n := linalg.normalize(g)

                            occ: f32 = 0
                            for s in ao_steps {
                                dd := shape_dist(sh, p + n * (s * h))
                                occ += max(0, 1 - dd / (s * h))
                            }
                            ao := max(0, 1 - occ / 2.2)

                            mat := shape_mat(sh, p)
                            append(&out, Surfel{pos = p, normal = n, color = {255, 255, 255, 255}, ao = ao, mat = mat})
                        }
                    }
                }
            }
        }
    }
    return out
}