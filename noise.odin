package pixlsplat

import "core:math"

Mulberry32 :: struct { state: u32 }

mulberry32_new :: proc(seed: u32) -> Mulberry32 {
    return {state = seed}
}

mulberry32_next :: proc(r: ^Mulberry32) -> f32 {
    r.state += 0x6d2b79f5
    t := r.state
    t = (t ~ (t >> 15)) * (t | 1)
    t ~= t + (t ~ (t >> 7)) * (t | 61)
    return f32((t ~ (t >> 14))) / 4294967296.0
}

hash3 :: proc(x, y, z: i32) -> f32 {
    h := u32(x) * 374761393 + u32(y) * 668265263 + u32(z) * 2147483647
    h = (h ~ (h >> 13)) * 1274126177
    h ~= h >> 16
    return f32(h) / 4294967296.0
}

smoothstep01 :: proc(t: f32) -> f32 {
    return t * t * (3 - 2 * t)
}

vnoise3 :: proc(x, y, z: f32) -> f32 {
    xi := i32(math.floor(x))
    yi := i32(math.floor(y))
    zi := i32(math.floor(z))
    xf := smoothstep01(x - f32(xi))
    yf := smoothstep01(y - f32(yi))
    zf := smoothstep01(z - f32(zi))

    c :: proc(dx, dy, dz, xi, yi, zi: i32) -> f32 {
        return hash3(xi + dx, yi + dy, zi + dz)
    }
    lerp :: proc(a, b, t: f32) -> f32 { return a + (b - a) * t }

    return lerp(
        lerp(lerp(c(0,0,0,xi,yi,zi), c(1,0,0,xi,yi,zi), xf),
             lerp(c(0,1,0,xi,yi,zi), c(1,1,0,xi,yi,zi), xf), yf),
        lerp(lerp(c(0,0,1,xi,yi,zi), c(1,0,1,xi,yi,zi), xf),
             lerp(c(0,1,1,xi,yi,zi), c(1,1,1,xi,yi,zi), xf), yf),
        zf,
    )
}

sstep :: proc(a, b, x: f32) -> f32 {
    t := math.clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}

mul_rgb :: proc(c: [3]f32, k: f32) -> [3]f32 {
    return {c.x * k, c.y * k, c.z * k}
}

mix_rgb :: proc(a, b: [3]f32, t: f32) -> [3]f32 {
    return {
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t,
    }
}