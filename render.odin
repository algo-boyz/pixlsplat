package pixlsplat

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

draw_oriented_disc :: proc(pos, normal: [3]f32, size: f32, col: rl.Color) {
    up := [3]f32{0, 1, 0}
    if abs(linalg.dot(normal, up)) > 0.93 {
        up = {1, 0, 0}
    }
    t := linalg.normalize(linalg.cross(up, normal))
    b := linalg.cross(normal, t)

    half := size * 0.52
    p0 := pos + (-t - b) * half
    p1 := pos + ( t - b) * half
    p2 := pos + ( t + b) * half
    p3 := pos + (-t + b) * half

    rl.DrawTriangle3D(p0, p1, p2, col)
    rl.DrawTriangle3D(p0, p2, p3, col)
}

draw_oriented_blade :: proc(pos, right, up: [3]f32, half_w, half_h: f32, col: rl.Color) {
    p0 := pos + (-right)*half_w + (-up)*half_h
    p1 := pos + ( right)*half_w + (-up)*half_h
    p2 := pos + ( right)*half_w + ( up)*half_h
    p3 := pos + (-right)*half_w + ( up)*half_h
    rl.DrawTriangle3D(p0, p1, p2, col)
    rl.DrawTriangle3D(p0, p2, p3, col)
}

nearest_palette :: proc(c: [4]u8) -> [4]u8 {
    best := PALETTE[0]
    best_d: f32 = 1e9
    for p in PALETTE {
        dr := f32(c[0]) - f32(p[0])
        dg := f32(c[1]) - f32(p[1])
        db := f32(c[2]) - f32(p[2])
        d  := dr*dr + dg*dg + db*db
        if d < best_d {
            best_d = d
            best = p
        }
    }
    return best
}

apply_palette_and_outline :: proc(img: ^rl.Image) {
    w, h := int(img.width), int(img.height)
    bg := PALETTE[0]

    for y in 0..<h {
        for x in 0..<w {
            c := rl.GetImageColor(img^, i32(x), i32(y))
            if c.a < 8 do continue
            q := nearest_palette({c.r, c.g, c.b, 255})
            rl.ImageDrawPixel(img, i32(x), i32(y), {q[0], q[1], q[2], 255})
        }
    }

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
                    u8(max(0, i32(c.r) - 38)),
                    u8(max(0, i32(c.g) - 38)),
                    u8(max(0, i32(c.b) - 32)),
                    255,
                }
                q := nearest_palette(dark)
                rl.ImageDrawPixel(img, i32(x), i32(y), {q[0], q[1], q[2], 255})
            }
        }
    }
}