package pixlsplat

import "core:math"
import "core:math/linalg"

// Shared scene props ported from island.js / scene-kit.js.

tufts :: proc(c: ^Ctx, mat: int, n: int, hgt: f32 = 0.2) {
    for i in 0..<n {
        a := mulberry32_next(&c.rnd) * math.TAU
        x, z, _ := ctx_place(c, a, 0.12 + mulberry32_next(&c.rnd)*0.6, false)
        y := ctx_height(c, x, z)
        shape_bound(&c.s, x, y + hgt/2, z, hgt)
        for k in 0..<6 {
            aa := mulberry32_next(&c.rnd) * math.TAU
            l  := 0.03 + mulberry32_next(&c.rnd)*0.05
            h  := hgt * (0.55 + mulberry32_next(&c.rnd)*0.6)
            shape_add_cone(&c.s,
                {x, y - 0.02, z},
                {x + math.cos(aa)*l, y + h, z + math.sin(aa)*l},
                0.009, 0.002, mat)
        }
    }
    shape_bound_clear(&c.s)
}

bones :: proc(c: ^Ctx, mat: int, n: int) {
    for i in 0..<n {
        a := mulberry32_next(&c.rnd) * math.TAU
        x, z, _ := ctx_place(c, a, 0.12 + mulberry32_next(&c.rnd)*0.5, false)
        y := ctx_height(c, x, z) + 0.02
        aa := mulberry32_next(&c.rnd) * math.TAU
        l  := 0.14 + mulberry32_next(&c.rnd)*0.12
        b  := [3]f32{x + math.cos(aa)*l, y + 0.01, z + math.sin(aa)*l}
        shape_bound(&c.s, x, y, z, l + 0.06)
        shape_add_cone(&c.s, {x, y, z}, b, 0.013, 0.011, mat)
        shape_add_sphere(&c.s, {x, y, z}, 0.024, mat, 0.012)
        shape_add_sphere(&c.s, b, 0.022, mat, 0.012)
    }
    shape_bound_clear(&c.s)
}

urn :: proc(c: ^Ctx, mat: int, x, z: f32, k: f32 = 1) {
    y := ctx_height(c, x, z)
    prof := [6]f32{0.05, 0.1, 0.11, 0.07, 0.045, 0.06}
    shape_bound(&c.s, x, y + 0.14*k, z, 0.22*k)
    for i in 0..<5 {
        shape_add_cone(&c.s,
            {x, y + f32(i)*0.055*k, z},
            {x, y + f32(i+1)*0.055*k, z},
            prof[i]*k, prof[i+1]*k, mat)
    }
    shape_bound_clear(&c.s)
}

// Bowl fire with subtractive rim (uses shape_sub_ellipsoid).
fire_bowl :: proc(
    c: ^Ctx,
    m_metal, m_flame: int,
    x, z, hgt: f32,
    lights: ^[dynamic]Light,
    embers: ^[dynamic][3]f32,
    power: f32 = 1.2,
) {
    y := ctx_height(c, x, z)
    shape_bound(&c.s, x, y + hgt/2, z, hgt/2 + 0.25)
    for k in 0..<3 {
        shape_add_cone(&c.s,
            {x + math.cos(f32(k)*2.09)*0.09, y - 0.01, z + math.sin(f32(k)*2.09)*0.09},
            {x, y + hgt - 0.04, z},
            0.014, 0.014, m_metal)
    }
    shape_add_ellipsoid(&c.s, {x, y + hgt, z}, {0.12, 0.05, 0.12}, m_metal)
    shape_sub_ellipsoid(&c.s, {x, y + hgt + 0.045, z}, {0.1, 0.045, 0.1}, m_metal)
    shape_add_sphere(&c.s, {x, y + hgt + 0.05, z}, 0.065, m_flame)
    shape_add_sphere(&c.s, {x + 0.012, y + hgt + 0.12, z}, 0.045, m_flame, 0.02)
    shape_add_sphere(&c.s, {x, y + hgt + 0.185, z + 0.012}, 0.024, m_flame, 0.02)
    shape_bound_clear(&c.s)
    append(lights, Light{pos = {x, y + hgt + 0.14, z}, color = {1.0, 0.52, 0.18}, power = power})
    append(embers, [3]f32{x, y + hgt + 0.12, z})
    ctx_grow(c, y + hgt + 0.3)
}

banner :: proc(c: ^Ctx, m_pole, m_cloth: int, x, z: f32, hgt: f32 = 1.5) {
    y := ctx_height(c, x, z)
    shape_bound(&c.s, x, y + hgt/2, z, hgt/2 + 0.3)
    shape_add_cone(&c.s, {x, y - 0.03, z}, {x, y + hgt, z}, 0.02, 0.014, m_pole)
    shape_add_sphere(&c.s, {x, y + hgt + 0.02, z}, 0.03, m_pole)
    shape_add_box(&c.s, {x + 0.15, y + hgt - 0.2, z}, {0.14, 0.17, 0.012}, 0.008, m_cloth)
    shape_add_box(&c.s, {x + 0.2, y + hgt - 0.44, z}, {0.07, 0.08, 0.012}, 0.008, m_cloth)
    shape_bound_clear(&c.s)
    ctx_grow(c, y + hgt + 0.1)
}

// Caller owns the returned tips slice (delete when done).
dead_tree :: proc(c: ^Ctx, mat: int, x, z, hgt: f32, lean: f32 = 0.2) -> [dynamic][3]f32 {
    y := ctx_height(c, x, z)
    a := mulberry32_next(&c.rnd) * math.TAU
    shape_bound(&c.s, x, y + hgt/2, z, hgt * 0.8)
    p := [3]f32{x, y - 0.04, z}
    pts := make([dynamic][3]f32)
    append(&pts, p)
    for k in 1..=4 {
        q := [3]f32{
            x + math.cos(a + f32(k)*0.9) * lean * f32(k) * 0.3,
            y + (hgt * f32(k)) / 4,
            z + math.sin(a + f32(k)*0.9) * lean * f32(k) * 0.3,
        }
        r1 := 0.085 * (1.25 - f32(k)*0.2) * hgt
        r2 := 0.085 * (1.05 - f32(k)*0.2) * hgt
        shape_add_cone(&c.s, p, q, r1, r2, mat, 0.02)
        p = q
        append(&pts, p)
    }
    for k in 0..<5 {
        shape_add_cone(&c.s,
            {x, y + 0.08, z},
            {x + math.cos(f32(k)*1.26 + a)*0.2*hgt, y - 0.04, z + math.sin(f32(k)*1.26 + a)*0.2*hgt},
            0.045*hgt, 0.015, mat, 0.03)
    }
    tips := make([dynamic][3]f32)
    for k in 0..<5 {
        from := pts[2 + (k % 3)]
        da := a + f32(k)*1.4
        len := (0.28 + mulberry32_next(&c.rnd)*0.25) * hgt
        mid := [3]f32{
            from.x + math.cos(da)*len*0.6,
            from.y + len*0.35,
            from.z + math.sin(da)*len*0.6,
        }
        tip := [3]f32{
            from.x + math.cos(da + 0.4)*len,
            from.y + len*0.85,
            from.z + math.sin(da + 0.4)*len,
        }
        shape_add_cone(&c.s, from, mid, 0.03*hgt, 0.018*hgt, mat, 0.015)
        shape_add_cone(&c.s, mid, tip, 0.018*hgt, 0.005, mat, 0.01)
        append(&tips, mid)
        append(&tips, tip)
    }
    shape_bound_clear(&c.s)
    ctx_grow(c, y + hgt*1.25)
    delete(pts)
    return tips
}

// Skull + rib arches. Uses sub for eye sockets.
ribcage :: proc(c: ^Ctx, mat, m_dark: int, a: f32, k: f32 = 1) {
    x, z, _ := ctx_place(c, a, 0.45*k)
    rx, rz := math.cos(a), math.sin(a)
    tx, tz := -rz, rx
    y := ctx_height(c, x, z)
    shape_bound(&c.s, x, y + 0.4*k, z, 1.0*k)
    spine :: proc(x, z, y, tx, tz, t, kk: f32) -> [3]f32 {
        return {x + tx*t, y + 0.1*kk, z + tz*t}
    }
    shape_add_cone(&c.s, spine(x,z,y,tx,tz,-0.55*k,k), spine(x,z,y,tx,tz,0.5*k,k), 0.045*k, 0.03*k, mat)
    for i in 0..<6 {
        p := spine(x,z,y,tx,tz, (-0.42 + f32(i)*0.16)*k, k)
        hgt := (0.75 - abs(f32(i) - 2.2)*0.07) * k
        for sd in ([2]f32{-1, 1}) {
            q1 := [3]f32{p.x + rx*sd*0.3*k, p.y + hgt*0.5, p.z + rz*sd*0.3*k}
            q2 := [3]f32{p.x + rx*sd*0.2*k, p.y + hgt, p.z + rz*sd*0.2*k}
            shape_add_cone(&c.s, p, q1, 0.03*k, 0.024*k, mat)
            shape_add_cone(&c.s, q1, q2, 0.024*k, 0.01*k, mat, 0.02)
        }
    }
    h := spine(x,z,y,tx,tz,-0.72*k,k)
    nose := spine(x,z,y,tx,tz,-0.95*k,k)
    shape_add_sphere(&c.s, {h.x, h.y + 0.07*k, h.z}, 0.15*k, mat)
    shape_add_sphere(&c.s, {nose.x, nose.y + 0.02, nose.z}, 0.095*k, mat, 0.08)
    for sd in ([2]f32{-1, 1}) {
        shape_sub_sphere(&c.s, {
            h.x + rx*sd*0.1*k - tx*0.09*k,
            h.y + 0.1*k,
            h.z + rz*sd*0.1*k - tz*0.09*k,
        }, 0.045*k, m_dark)
        shape_add_cone(&c.s,
            {h.x + rx*sd*0.1*k, h.y + 0.16*k, h.z + rz*sd*0.1*k},
            {h.x + rx*sd*0.3*k, h.y + 0.42*k, h.z + rz*sd*0.3*k},
            0.035*k, 0.006, mat)
    }
    shape_bound_clear(&c.s)
    ctx_grow(c, y + 0.9*k)
}

campfire :: proc(
    c: ^Ctx,
    m_rock, m_dark, m_flame: int,
    x, z: f32,
    lights: ^[dynamic]Light,
    embers: ^[dynamic][3]f32,
    power: f32 = 1.5,
) {
    y := ctx_height(c, x, z)
    shape_bound(&c.s, x, y + 0.12, z, 0.4)
    for k in 0..<9 {
        shape_add_sphere(&c.s,
            {x + math.cos(f32(k)*0.698)*0.17, y + 0.02, z + math.sin(f32(k)*0.698)*0.17},
            0.045, m_rock)
    }
    for k in 0..<4 {
        shape_add_cone(&c.s,
            {x + math.cos(f32(k)*1.57)*0.14, y + 0.02, z + math.sin(f32(k)*1.57)*0.14},
            {x, y + 0.15, z},
            0.028, 0.022, m_dark)
    }
    shape_add_sphere(&c.s, {x, y + 0.13, z}, 0.07, m_flame)
    shape_add_sphere(&c.s, {x + 0.012, y + 0.21, z}, 0.05, m_flame, 0.02)
    shape_add_sphere(&c.s, {x, y + 0.29, z + 0.012}, 0.026, m_flame, 0.02)
    shape_bound_clear(&c.s)
    append(lights, Light{pos = {x, y + 0.32, z}, color = {1.0, 0.55, 0.2}, power = power})
    append(embers, [3]f32{x, y + 0.25, z})
}

// Materials expected: stone, glow, roof
stone_lantern :: proc(
    c: ^Ctx,
    m_stone, m_glow, m_roof: int,
    x, z: f32,
    lights: ^[dynamic]Light,
    free: ^Free_List,
) {
    y := ctx_height(c, x, z)
    shape_bound(&c.s, x, y + 0.3, z, 0.45)
    shape_add_cyl(&c.s, {x, y + 0.03, z}, 0.1, 0.03, 0.01, m_stone)
    shape_add_cyl(&c.s, {x, y + 0.2, z}, 0.035, 0.15, 0.008, m_stone)
    shape_add_box(&c.s, {x, y + 0.37, z}, {0.085, 0.02, 0.085}, 0.006, m_stone)
    shape_add_box(&c.s, {x, y + 0.45, z}, {0.058, 0.06, 0.058}, 0.006, m_glow)
    for dx in ([2]f32{1, -1}) {
        for dz in ([2]f32{1, -1}) {
            shape_add_box(&c.s, {x + dx*0.058, y + 0.45, z + dz*0.058}, {0.012, 0.062, 0.012}, 0.003, m_stone)
        }
    }
    roofs := [3][3]f32{{0.13, 0.02, 0.53}, {0.095, 0.02, 0.565}, {0.055, 0.02, 0.6}}
    for r in roofs {
        shape_add_box(&c.s, {x, y + r[2], z}, {r[0], r[1], r[0]}, 0.008, m_roof)
    }
    shape_add_sphere(&c.s, {x, y + 0.64, z}, 0.025, m_roof)
    shape_bound_clear(&c.s)
    append(lights, Light{pos = {x, y + 0.45, z}, color = {1.0, 0.72, 0.32}, power = 0.95})
    free_glow(free, x, y + 0.45, z, 0.26, {255, 207, 90, 255})
    ctx_grow(c, y + 0.75)
}
