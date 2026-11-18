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

Prim_Kind :: enum { Sphere, Ellipsoid, Cone, Box, Func }

Prim :: struct {
    kind: Prim_Kind,
    mat:  int,
    k:    f32,
    f:    proc(p: [3]f32) -> f32,
    using data: struct #raw_union {
        sphere:    Sphere,
        ellipsoid: Ellipsoid,
        cone:      Cone,
        box:       Box,
    },
}

Shape :: struct {
    adds: [dynamic]Prim,
}

shape_new :: proc() -> Shape {
    return {adds = make([dynamic]Prim)}
}

shape_add_sphere :: proc(s: ^Shape, c: [3]f32, r: f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Sphere, mat = mat, k = k, sphere = {c, r}})
}
shape_add_ellipsoid :: proc(s: ^Shape, c: [3]f32, radii: [3]f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Ellipsoid, mat = mat, k = k, ellipsoid = {c, radii}})
}
shape_add_cone :: proc(s: ^Shape, a, b: [3]f32, r1, r2: f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Cone, mat = mat, k = k, cone = cone_make(a, b, r1, r2)})
}
shape_add_box :: proc(s: ^Shape, c: [3]f32, half: [3]f32, r: f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Box, mat = mat, k = k, box = {c, half, r}})
}
shape_add_func :: proc(s: ^Shape, f: proc(p: [3]f32) -> f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Func, mat = mat, k = k, f = f})
}

prim_dist :: proc(pr: Prim, p: [3]f32) -> f32 {
    switch pr.kind {
    case .Sphere:    return sphere_dist(pr.sphere, p)
    case .Ellipsoid: return ellipsoid_dist(pr.ellipsoid, p)
    case .Cone:      return cone_dist(pr.cone, p)
    case .Box:       return box_dist(pr.box, p)
    case .Func:      return pr.f(p)
    }
    return 1e9
}

smin :: proc(a, b, k: f32) -> f32 {
    if k <= 0 do return min(a, b)
    h := max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k * 0.25
}

shape_dist :: proc(s: Shape, p: [3]f32) -> f32 {
    d: f32 = 1e9
    for a in s.adds {
        d = smin(d, prim_dist(a, p), a.k)
    }
    return d
}

shape_mat :: proc(s: Shape, p: [3]f32) -> int {
    best: f32 = 1e9
    m := 0
    for a in s.adds {
        d := prim_dist(a, p)
        if d < best {
            best = d
            m = a.mat
        }
    }
    return m
}

Surfel :: struct {
    pos:    [3]f32,
    normal: [3]f32,
    color:  [4]u8,
    ao:     f32,
}

sample_surface :: proc(
    sh:    Shape,
    minp, maxp: [3]f32,
    h:     f32,
    paint: proc(mat: int, p, n: [3]f32, ao: f32) -> [4]u8,
) -> [dynamic]Surfel {
    out := make([dynamic]Surfel)
    e := h * 0.5

    grad :: proc(sh: Shape, p: [3]f32, e: f32) -> [3]f32 {
        return {
            shape_dist(sh, p + {e,0,0}) - shape_dist(sh, p - {e,0,0}),
            shape_dist(sh, p + {0,e,0}) - shape_dist(sh, p - {0,e,0}),
            shape_dist(sh, p + {0,0,e}) - shape_dist(sh, p - {0,0,e}),
        }
    }

    ao_steps := [3]f32{2, 5, 10}

    for z := minp.z; z < maxp.z; z += h {
        for y := minp.y; y < maxp.y; y += h {
            for x := minp.x; x < maxp.x; x += h {
                p := [3]f32{x, y, z}
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
                col := paint(mat, p, n, ao)
                append(&out, Surfel{pos = p, normal = n, color = col, ao = ao})
            }
        }
    }
    return out
}