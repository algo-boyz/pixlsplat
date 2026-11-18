package pixlsplat

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// 3D drawing primitives for oriented surfels / blades.
// Pixel-art quantise + outline live in post.odin.

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

    // Both windings so back-face culling cannot hide a surfel
    rl.DrawTriangle3D(p0, p1, p2, col)
    rl.DrawTriangle3D(p0, p2, p3, col)
    rl.DrawTriangle3D(p0, p2, p1, col)
    rl.DrawTriangle3D(p0, p3, p2, col)
}

draw_oriented_blade :: proc(pos, right, up: [3]f32, half_w, half_h: f32, col: rl.Color) {
    p0 := pos + (-right)*half_w + (-up)*half_h
    p1 := pos + ( right)*half_w + (-up)*half_h
    p2 := pos + ( right)*half_w + ( up)*half_h
    p3 := pos + (-right)*half_w + ( up)*half_h
    rl.DrawTriangle3D(p0, p1, p2, col)
    rl.DrawTriangle3D(p0, p2, p3, col)
    rl.DrawTriangle3D(p0, p2, p1, col)
    rl.DrawTriangle3D(p0, p3, p2, col)
}