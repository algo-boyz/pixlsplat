package pixlsplat

// Pixel-art post pass (mirrors src/render/post.js in the original).
//
//   1. Quantise each art pixel to the scene palette.
//   2. Ordered Bayer dither between the two nearest colours so gradients
//      break into speckles instead of flat blobs.
//   3. Darken outline pixels that sit next to the background.

import rl "vendor:raylib"

// Tunables
POST_DITHER: f32 = 0.65   // 0 = pure nearest, 1 = full Bayer mix
POST_OUTLINE_R: i32 = 38
POST_OUTLINE_G: i32 = 38
POST_OUTLINE_B: i32 = 32

// Luminance-weighted distance (same weights as original post.js)
palette_dist :: proc(c: [3]f32, p: [4]u8) -> f32 {
    e := [3]f32{c[0] - f32(p[0]), c[1] - f32(p[1]), c[2] - f32(p[2])}
    w := [3]f32{e[0] * 0.30, e[1] * 0.59, e[2] * 0.11}
    return (w[0]*w[0] + w[1]*w[1] + w[2]*w[2]) + 0.25 * (e[0]*e[0] + e[1]*e[1] + e[2]*e[2])
}

nearest_palette :: proc(c: [4]u8) -> [4]u8 {
    cf := [3]f32{f32(c[0]), f32(c[1]), f32(c[2])}
    best := PALETTE[0]
    best_d: f32 = 1e9
    for p in PALETTE {
        d := palette_dist(cf, p)
        if d < best_d {
            best_d = d
            best = p
        }
    }
    return best
}

// Two nearest palette colours + blend factor along best→second (0 = pure best)
two_nearest :: proc(c: [3]f32) -> (a, b: [4]u8, t: f32) {
    best, second := PALETTE[0], PALETTE[0]
    bd, sd: f32 = 1e9, 1e9
    for p in PALETTE {
        d := palette_dist(c, p)
        if d < bd {
            second, sd = best, bd
            best, bd = p, d
        } else if d < sd {
            second, sd = p, d
        }
    }
    denom := bd + sd
    t = 0
    if denom > 1e-6 do t = bd / denom
    return best, second, t
}

// 4×4 Bayer thresholds in (0, 1) — same matrix as original post.js
bayer4 :: proc(x, y: int) -> f32 {
    m := [16]f32{
        0,  8,  2, 10,
        12, 4, 14,  6,
        3, 11,  1,  9,
        15, 7, 13,  5,
    }
    i := (x & 3) + (y & 3) * 4
    return (m[i] + 0.5) / 16.0
}

// Full post: palette quantise (+ dither) then outline.
// Mutates `img` in place. Call after reading the low-res render target.
post_apply :: proc(img: ^rl.Image) {
    w, h := int(img.width), int(img.height)
    bg := PALETTE[0]

    // --- quantise + ordered dither ------------------------------------------
    for y in 0..<h {
        for x in 0..<w {
            c := rl.GetImageColor(img^, i32(x), i32(y))
            if c.a < 8 do continue
            cf := [3]f32{f32(c.r), f32(c.g), f32(c.b)}
            a, b, t := two_nearest(cf)
            q := a
            if POST_DITHER > 0 && t * POST_DITHER > bayer4(x, y) {
                q = b
            }
            rl.ImageDrawPixel(img, i32(x), i32(y), {q[0], q[1], q[2], 255})
        }
    }

    // --- outline ------------------------------------------------------------
    copy := rl.ImageCopy(img^)
    defer rl.UnloadImage(copy)

    for y in 1..<h-1 {
        for x in 1..<w-1 {
            c := rl.GetImageColor(copy, i32(x), i32(y))
            if c.r == bg[0] && c.g == bg[1] do continue

            n0 := rl.GetImageColor(copy, i32(x),   i32(y-1))
            n1 := rl.GetImageColor(copy, i32(x),   i32(y+1))
            n2 := rl.GetImageColor(copy, i32(x-1), i32(y))
            n3 := rl.GetImageColor(copy, i32(x+1), i32(y))

            edge := (n0.r == bg[0] && n0.g == bg[1]) ||
                    (n1.r == bg[0] && n1.g == bg[1]) ||
                    (n2.r == bg[0] && n2.g == bg[1]) ||
                    (n3.r == bg[0] && n3.g == bg[1])

            if edge {
                dark := [4]u8{
                    u8(max(0, i32(c.r) - POST_OUTLINE_R)),
                    u8(max(0, i32(c.g) - POST_OUTLINE_G)),
                    u8(max(0, i32(c.b) - POST_OUTLINE_B)),
                    255,
                }
                q := nearest_palette(dark)
                rl.ImageDrawPixel(img, i32(x), i32(y), {q[0], q[1], q[2], 255})
            }
        }
    }
}