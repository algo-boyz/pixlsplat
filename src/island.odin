package pixlsplat

import "core:math"
import "core:math/linalg"

Ctx :: struct {
    s:      Shape,
    R:      f32,
    r_flat: f32,
    rnd:    Mulberry32,
    top:    f32,
    seed:   f32,       // island noise seed = rnd()*50 (matches original)
    top_y:  f32,
    bump:   f32,
    rise:   f32,
    ripple: f32,
    rough:  f32,
    clear:  proc(a: f32, tall: bool) -> f32, // optional; nil => R-0.16
}

// Used only while building (single-threaded)
_island_ctx: ^Ctx

hash_scene_name :: proc(name: string) -> u32 {
    h: u32 = 2166136261
    for b in transmute([]u8)name {
        h ~= u32(b)
        h *= 16777619
    }
    if h == 0 do h = 42
    return h
}

make_ctx :: proc(R, r_flat: f32, seed: u32 = 42, clear: proc(a: f32, tall: bool) -> f32 = nil) -> Ctx {
    return Ctx{
        s      = shape_new(),
        R      = R,
        r_flat = r_flat,
        rnd    = mulberry32_new(seed),
        top    = 0.3,
        seed   = 0, // set inside island() via rnd()*50
        top_y  = 0,
        bump   = 0.03,
        rise   = 0,
        ripple = 0,
        rough  = 0.09,
        clear  = clear,
    }
}

// Spot beyond creature reach in direction a. Returns x,z,r.
ctx_place :: proc(c: ^Ctx, a: f32, extra: f32 = 0.2, tall: bool = true) -> (x, z, r: f32) {
    clear_r: f32 = c.R - 0.16
    if c.clear != nil do clear_r = c.clear(a, tall)
    r = min(c.R - 0.16, clear_r + extra)
    x = math.cos(a) * r
    z = math.sin(a) * r
    return
}


ctx_grow :: proc(c: ^Ctx, y: f32) {
    c.top = max(c.top, y)
}


// A displaced ellipsoid (JS displace(ellipsoid, amp * vnoise3(p * freq))).
// amp * (vnoise3(p * freq) - bias); see disp_noise in sdf.odin.
add_displaced_ellipsoid :: proc(
    s: ^Shape,
    c: [3]f32,
    radii: [3]f32,
    amp, freq: f32,
    mat: int,
    k: f32 = 0,
    bias: f32 = 0,
) {
    shape_add_ellipsoid(s, c, radii, mat, k)
    shape_displace(s, disp_noise(amp, freq, bias))
}

ctx_height :: proc(c: ^Ctx, x, z: f32) -> f32 {
    r := math.hypot(x, z)
    e := sstep(c.r_flat, c.r_flat + 0.3, r)
    h := c.top_y +
        e * (c.bump * (vnoise3(x*5 + c.seed, 1, z*5) - 0.5) * 2 +
             c.rise * sstep(c.r_flat + 0.1, c.R, r) * vnoise3(x*1.4 + c.seed, 7, z*1.4))
    if c.ripple != 0 {
        h += c.ripple * (0.3 + 0.7 * e) * math.sin(x * 30 + 4 * vnoise3(x * 2.5, 2, z * 2.5) + z * 7)
    }
    return h
}

island_under_dist :: proc(p: [3]f32) -> f32 {
    c := _island_ctx
    base := Ellipsoid{{0, c.top_y - 0.12, 0}, {0.92*c.R, 0.78*c.R, 0.92*c.R}}
    d := ellipsoid_dist(base, p)
    d -= c.rough * (vnoise3(p.x*4 + c.seed, p.y*4, p.z*4) - 0.5) * 2
    d -= 0.04 * vnoise3(p.x*11, p.y*11, p.z*11)
    return max(d, p.y - c.top_y + 0.12)
}

// Heightfield slab top — matches original JS island top SDF.
island_top_dist :: proc(p: [3]f32) -> f32 {
    c := _island_ctx
    hh: f32 = 0.16
    r  := math.hypot(p.x, p.z)
    a  := math.atan2(p.z, p.x)
    outline := c.R * (1 + 0.16 * (vnoise3(math.cos(a)*1.7 + c.seed, math.sin(a)*1.7 + c.seed, 3) - 0.5))
    dx := r - outline + 0.07
    hy := ctx_height(c, p.x, p.z)
    dy := abs(p.y - hy + hh) - hh + 0.07
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - 0.07
}

island :: proc(c: ^Ctx, m_top, m_under: int, bump: f32 = 0.03, rise: f32 = 0, ripple: f32 = 0, rough: f32 = 0.09, top_y: f32 = 0) {
    // Match original: seed = rnd()*50 first so the rest of the stream aligns.
    c.seed  = mulberry32_next(&c.rnd) * 50
    c.top_y = top_y
    c.bump  = bump
    c.rise  = rise
    c.ripple = ripple
    c.rough  = rough
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
        shape_bound(&c.s, x, y, z, q * 2)
        // displace(ellipsoid, -0.03 * vnoise3(*12))
        add_displaced_ellipsoid(&c.s, {x, y, z}, {q*1.2, q*0.85, q}, -0.03, 12, m_under, 0)
    }
    shape_bound_clear(&c.s)
}

rocks :: proc(c: ^Ctx, mat: int, n: int, size: f32 = 0.1) {
    for i in 0..<n {
        a  := mulberry32_next(&c.rnd) * math.TAU
        x, z, _ := ctx_place(c, a, 0.1 + mulberry32_next(&c.rnd)*0.7, false)
        r  := size * (0.5 + mulberry32_next(&c.rnd))
        y  := ctx_height(c, x, z)
        shape_bound(&c.s, x, y, z, r * 1.8)
        add_displaced_ellipsoid(&c.s, {x, y + r*0.25, z}, {r*1.3, r*0.8, r}, -0.3*r, 11, mat, 0.02)
    }
    shape_bound_clear(&c.s)
}
// What a material's paint callback returns for one surfel.
//   c:        the surface colour, 0..1
//   emissive: drawn unlit (lamps, flames); skips all lighting in bake()
//   leaf:     foliage, lit from both sides and only half shadowed
Paint :: struct {
    c:        [3]f32,
    emissive: bool,
    leaf:     bool,
}

Paint_Proc :: #type proc(mat: int, p, n: [3]f32) -> Paint

// Turns sampled surfels into painted, lit ones (port of bake() in island.js).
//   lighting:   from make_lighting (light.odin): bakes sun, shadows, sky and
//               lamps into each surfel's final palette colour. Without it the
//               colour is just darkened by AO.
//   depth_shade: darker towards the underside of the island
bake :: proc(c: ^Ctx, surfels: []Surfel, paint: Paint_Proc, lighting: ^Lighting = nil, depth_shade := true) {
    for &s in surfels {
        pt := paint(s.mat, s.pos, s.normal)
        k  := pt.c
        s.emissive = pt.emissive
        if !pt.emissive {
            if lighting == nil {
                k = mul_rgb(k, 0.5 + 0.5 * s.ao)
            }
            // darker towards the bottom of the island
            if depth_shade && s.pos.y < -0.2 {
                k = mul_rgb(k, 1 - 0.45 * sstep(-0.2, -c.R, s.pos.y))
            }
            if lighting != nil {
                k = light_shade(lighting, k, s.pos, s.normal, s.ao, pt.leaf)
            }
        }
        s.color = {to_u8(k[0]), to_u8(k[1]), to_u8(k[2]), 255}
    }
}
