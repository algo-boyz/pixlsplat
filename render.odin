package pixlsplat

import "core:math"
import "core:math/linalg"
import rl   "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// 3D drawing primitives for oriented surfels / blades.
// Pixel-art quantise + outline live in post.odin.

// Splat sizing, matching the original:
//   bake() samples surfels on a lattice of spacing h = 0.02, and each splat is
//   a Gaussian with sigma = 0.66 h drawn hard-edged out to maxStdDev = 1.5,
//   i.e. a disc of radius ~1.0 h. Discs must be about 2h across to overlap and
//   leave no gaps between lattice points; anything under ~1.41h across shows
//   the lattice as a raster grid.
SURFEL_H       :: f32(0.02)
SPLAT_SIGMA    :: f32(0.66) * SURFEL_H
SPLAT_STD_DEV  :: f32(1.5)
SPLAT_R        :: SPLAT_SIGMA * SPLAT_STD_DEV   // disc RADIUS in world units

// Hard circular disc texture (white inside, transparent outside)
disc_tex: rl.Texture2D

// raylib's default fragment shader has no alpha test, so the transparent
// corners of a disc quad would still write depth and punch holes in the discs
// behind/next to it. This shader discards them.
disc_shader: rl.Shader

DISC_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
out vec4 finalColor;
void main() {
    vec4 t = texture(texture0, fragTexCoord);
    if (t.a < 0.5) discard;
    finalColor = vec4((fragColor * colDiffuse).rgb, 1.0);
}
`

init_disc_texture :: proc(size: i32 = 64) {
    img := rl.GenImageColor(size, size, rl.BLANK)
    defer rl.UnloadImage(img)

    cx, cy := f32(size)*0.5, f32(size)*0.5
    r := cx - 0.5                     // leave a tiny margin so bilinear doesn't leak

    for y in 0..<size {
        for x in 0..<size {
            dx := f32(x) + 0.5 - cx
            dy := f32(y) + 0.5 - cy
            if dx*dx + dy*dy <= r*r {
                rl.ImageDrawPixel(&img, x, y, rl.WHITE)
            }
        }
    }

    disc_tex = rl.LoadTextureFromImage(img)
    rl.SetTextureFilter(disc_tex, .POINT)   // keep the edge hard
    rl.SetTextureWrap(disc_tex, .CLAMP)

    disc_shader = rl.LoadShaderFromMemory(nil, DISC_FS)
}

unload_disc_texture :: proc() {
    rl.UnloadShader(disc_shader)
    rl.UnloadTexture(disc_tex)
}

// `radius` is the disc radius in world units.
draw_oriented_disc :: proc(pos, normal: [3]f32, radius: f32, col: rl.Color) {
    // Build the same oriented frame as before
    up := [3]f32{0, 1, 0}
    if abs(linalg.dot(normal, up)) > 0.93 {
        up = {1, 0, 0}
    }
    t := linalg.normalize(linalg.cross(up, normal))
    b := linalg.cross(normal, t)

    half := radius              // the quad spans [-radius, radius]; the texture masks it to a circle

    // Four corners of the oriented square that will be masked by the circle
    p0 := pos + (-t - b) * half
    p1 := pos + ( t - b) * half
    p2 := pos + ( t + b) * half
    p3 := pos + (-t + b) * half

    // Draw as textured quad (both windings so culling never hides it)
    rlgl.SetTexture(disc_tex.id)

    rlgl.Begin(rlgl.QUADS)
    rlgl.Color4ub(col.r, col.g, col.b, col.a)

    // Front
    rlgl.TexCoord2f(0, 0); rlgl.Vertex3f(p0.x, p0.y, p0.z)
    rlgl.TexCoord2f(1, 0); rlgl.Vertex3f(p1.x, p1.y, p1.z)
    rlgl.TexCoord2f(1, 1); rlgl.Vertex3f(p2.x, p2.y, p2.z)
    rlgl.TexCoord2f(0, 1); rlgl.Vertex3f(p3.x, p3.y, p3.z)

    // Back
    rlgl.TexCoord2f(0, 0); rlgl.Vertex3f(p0.x, p0.y, p0.z)
    rlgl.TexCoord2f(0, 1); rlgl.Vertex3f(p3.x, p3.y, p3.z)
    rlgl.TexCoord2f(1, 1); rlgl.Vertex3f(p2.x, p2.y, p2.z)
    rlgl.TexCoord2f(1, 0); rlgl.Vertex3f(p1.x, p1.y, p1.z)
    rlgl.End()

    rlgl.SetTexture(0)
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