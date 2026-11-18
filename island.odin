package pixlsplat

import "core:math"
import "core:math/linalg"

Ctx :: struct {
    s:      Shape,
    R:      f32,
    r_flat: f32,
    rnd:    Mulberry32,
    top:    f32,
    seed:   f32,
    top_y:  f32,
    bump:   f32,
    rise:   f32,
}

// Used only while building (single-threaded)
_island_ctx: ^Ctx

make_ctx :: proc(R, r_flat: f32, seed: u32 = 42) -> Ctx {
    return Ctx{
        s      = shape_new(),
        R      = R,
        r_flat = r_flat,
        rnd    = mulberry32_new(seed),
        top    = 0.3,
        seed   = f32(seed) * 0.01,
        top_y  = 0,
        bump   = 0.03,
        rise   = 0,
    }
}

ctx_grow :: proc(c: ^Ctx, y: f32) {
    c.top = max(c.top, y)
}

ctx_height :: proc(c: ^Ctx, x, z: f32) -> f32 {
    r := math.hypot(x, z)
    e := sstep(c.r_flat, c.r_flat + 0.3, r)
    return c.top_y +
        e * (c.bump * (vnoise3(x*5 + c.seed, 1, z*5) - 0.5) * 2 +
             c.rise * sstep(c.r_flat + 0.1, c.R, r) * vnoise3(x*1.4 + c.seed, 7, z*1.4))
}

island_under_dist :: proc(p: [3]f32) -> f32 {
    c := _island_ctx
    base := Ellipsoid{{0, c.top_y - 0.12, 0}, {0.92*c.R, 0.78*c.R, 0.92*c.R}}
    d := ellipsoid_dist(base, p)
    d -= 0.09 * (vnoise3(p.x*4 + c.seed, p.y*4, p.z*4) - 0.5) * 2
    d -= 0.04 * vnoise3(p.x*11, p.y*11, p.z*11)
    return max(d, p.y - c.top_y + 0.12)
}

// Heightfield slab top — matches original JS island top SDF.
island_top_dist :: proc(p: [3]f32) -> f32 {
    c := _island_ctx
    hh: f32 = 0.16
    r  := math.hypot(p.x, p.z)
    outline := c.R * (1 + 0.08 * (vnoise3(p.x * 1.7 + c.seed, 3, p.z * 1.7) - 0.5))
    dx := r - outline + 0.07
    hy := ctx_height(c, p.x, p.z)
    dy := abs(p.y - hy + hh) - hh + 0.07
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - 0.07
}

island :: proc(c: ^Ctx, m_top, m_under: int, bump: f32 = 0.03, rise: f32 = 0, top_y: f32 = 0) {
    c.top_y = top_y
    c.bump  = bump
    c.rise  = rise
    _island_ctx = transmute(^Ctx)(rawptr(c))

    R := c.R

    // Top grass disc (visual stand-in for the full height-field slab)
    shape_add_func(&c.s, island_top_dist, m_top, 0)
    // Underside with noise
    shape_add_func(&c.s, island_under_dist, m_under, 0.09)

    // Hanging spikes
    for i in 0..<8 {
        a  := mulberry32_next(&c.rnd) * math.TAU
        rr := math.sqrt(mulberry32_next(&c.rnd)) * 0.62 * R
        x  := math.cos(a) * rr
        z  := math.sin(a) * rr
        y0 := top_y - 0.12 - 0.78*R * math.sqrt(max(0, 1 - (rr/(0.92*R))*(rr/(0.92*R))))
        len := (0.2 + mulberry32_next(&c.rnd)*0.5) * R * 0.6
        tip := [3]f32{
            x + (mulberry32_next(&c.rnd)-0.5)*0.15,
            y0 - len,
            z + (mulberry32_next(&c.rnd)-0.5)*0.15,
        }
        shape_add_cone(&c.s, {x, y0+0.25, z}, tip, 0.16, 0.012, m_under, 0.08)
    }

    // Floating rocks
    for i in 0..<6 {
        a  := mulberry32_next(&c.rnd) * math.TAU
        rr := R + 0.18 + mulberry32_next(&c.rnd)*0.35
        x  := math.cos(a) * rr
        z  := math.sin(a) * rr
        y  := top_y - 0.75 + mulberry32_next(&c.rnd)*0.9
        q  := 0.05 + mulberry32_next(&c.rnd)*0.09
        shape_add_ellipsoid(&c.s, {x, y, z}, {q*1.2, q*0.85, q}, m_under)
    }
}

rocks :: proc(c: ^Ctx, mat: int, n: int, size: f32 = 0.1) {
    for i in 0..<n {
        a  := mulberry32_next(&c.rnd) * math.TAU
        rr := 0.35 + mulberry32_next(&c.rnd) * 0.5
        x  := math.cos(a) * rr * c.R * 0.85
        z  := math.sin(a) * rr * c.R * 0.85
        r  := size * (0.5 + mulberry32_next(&c.rnd))
        y  := ctx_height(c, x, z)
        shape_add_ellipsoid(&c.s, {x, y + r*0.25, z}, {r*1.3, r*0.8, r}, mat, 0.02)
    }
}