package pixlsplat

import "core:math"
import "core:math/linalg"
import rl   "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// 3D drawing primitives for oriented surfels / blades.
// The pixel-art resolve pass lives in post.odin.

// Splat sizing, matching the original:
//   bake() samples surfels on a lattice of spacing h = 0.02, and each splat is
//   a Gaussian with sigma = 0.66 h drawn hard-edged out to maxStdDev = 1.5,
//   i.e. a disc of radius ~1.0 h. Discs must be about 2h across to overlap and
//   leave no gaps between lattice points; anything under ~1.41h across shows
//   the lattice as a raster grid.
// With crisp off the original draws soft Gaussians out to sqrt(8) sigma.
SURFEL_H       :: f32(0.02)
SPLAT_SIGMA    :: f32(0.66) * SURFEL_H
SPLAT_STD_DEV  :: f32(1.5)
SPLAT_STD_SOFT :: f32(2.8284271)                 // sqrt(8)
SPLAT_R        :: SPLAT_SIGMA * SPLAT_STD_DEV    // hard disc RADIUS in world units

// Radius to draw a splat at, given the radius it has in hard mode.
splat_radius :: proc(hard_radius: f32, soft: bool) -> f32 {
    return hard_radius * (SPLAT_STD_SOFT / SPLAT_STD_DEV) if soft else hard_radius
}

// Hard circular disc texture (white inside, transparent outside)
disc_hard_tex: rl.Texture2D
// Gaussian falloff: alpha = exp(-4 (r/R)^2), i.e. R sits at sqrt(8) sigma
disc_soft_tex: rl.Texture2D

splat_soft: bool   // which of the two textures draw_disc_frame uses

// Splats are written premultiplied (rgb*a, a) into a target that starts out
// transparent, so the post pass can tell solid splats from translucent light.
// Hard mode alpha-tests the disc texture; soft mode keeps its falloff.
splat_shader: rl.Shader
splat_loc_soft: i32

SPLAT_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float soft;
out vec4 finalColor;
void main() {
    vec4 t = texture(texture0, fragTexCoord);
    vec4 c = fragColor * colDiffuse;
    float a;
    if (soft > 0.5) {
        a = t.a * c.a;
    } else {
        if (t.a < 0.5) discard;   // raylib's default shader has no alpha test
        a = c.a;
    }
    finalColor = vec4(c.rgb * a, a);
}
`

init_splat_assets :: proc(size: i32 = 64) {
    hard := rl.GenImageColor(size, size, rl.BLANK)
    soft := rl.GenImageColor(size, size, rl.BLANK)
    defer rl.UnloadImage(hard)
    defer rl.UnloadImage(soft)

    cx, cy := f32(size)*0.5, f32(size)*0.5
    r := cx - 0.5                     // leave a tiny margin so bilinear doesn't leak

    for y in 0..<size {
        for x in 0..<size {
            dx := f32(x) + 0.5 - cx
            dy := f32(y) + 0.5 - cy
            d2 := dx*dx + dy*dy
            if d2 <= r*r {
                rl.ImageDrawPixel(&hard, x, y, rl.WHITE)
                k := d2 / (r*r)                       // (r/R)^2
                a := math.exp(-4 * k)
                rl.ImageDrawPixel(&soft, x, y, {255, 255, 255, u8(a * 255 + 0.5)})
            }
        }
    }

    disc_hard_tex = rl.LoadTextureFromImage(hard)
    rl.SetTextureFilter(disc_hard_tex, .POINT)   // keep the edge hard
    rl.SetTextureWrap(disc_hard_tex, .CLAMP)

    disc_soft_tex = rl.LoadTextureFromImage(soft)
    rl.SetTextureFilter(disc_soft_tex, .BILINEAR)
    rl.SetTextureWrap(disc_soft_tex, .CLAMP)

    splat_shader   = rl.LoadShaderFromMemory(nil, SPLAT_FS)
    splat_loc_soft = rl.GetShaderLocation(splat_shader, "soft")
}

unload_splat_assets :: proc() {
    rl.UnloadShader(splat_shader)
    rl.UnloadTexture(disc_hard_tex)
    rl.UnloadTexture(disc_soft_tex)
}

// Call before BeginShaderMode(splat_shader).
set_splat_mode :: proc(soft: bool) {
    splat_soft = soft
    v := f32(1 if soft else 0)
    rl.SetShaderValue(splat_shader, splat_loc_soft, &v, .FLOAT)
}

// A square spanned by `t` and `b` around `pos`, masked to a disc by the texture.
draw_disc_frame :: proc(pos, t, b: [3]f32, radius: f32, col: rl.Color, two_sided := true) {
    p0 := pos + (-t - b) * radius
    p1 := pos + ( t - b) * radius
    p2 := pos + ( t + b) * radius
    p3 := pos + (-t + b) * radius

    rlgl.SetTexture(splat_soft ? disc_soft_tex.id : disc_hard_tex.id)

    rlgl.Begin(rlgl.QUADS)
    rlgl.Color4ub(col.r, col.g, col.b, col.a)

    // Front
    rlgl.TexCoord2f(0, 0); rlgl.Vertex3f(p0.x, p0.y, p0.z)
    rlgl.TexCoord2f(1, 0); rlgl.Vertex3f(p1.x, p1.y, p1.z)
    rlgl.TexCoord2f(1, 1); rlgl.Vertex3f(p2.x, p2.y, p2.z)
    rlgl.TexCoord2f(0, 1); rlgl.Vertex3f(p3.x, p3.y, p3.z)

    if two_sided {
        // Back (so culling never hides it)
        rlgl.TexCoord2f(0, 0); rlgl.Vertex3f(p0.x, p0.y, p0.z)
        rlgl.TexCoord2f(0, 1); rlgl.Vertex3f(p3.x, p3.y, p3.z)
        rlgl.TexCoord2f(1, 1); rlgl.Vertex3f(p2.x, p2.y, p2.z)
        rlgl.TexCoord2f(1, 0); rlgl.Vertex3f(p1.x, p1.y, p1.z)
    }
    rlgl.End()

    rlgl.SetTexture(0)
}

// `radius` is the disc radius in world units.
draw_oriented_disc :: proc(pos, normal: [3]f32, radius: f32, col: rl.Color) {
    up := [3]f32{0, 1, 0}
    if abs(linalg.dot(normal, up)) > 0.93 {
        up = {1, 0, 0}
    }
    t := linalg.normalize(linalg.cross(up, normal))
    b := linalg.cross(normal, t)
    draw_disc_frame(pos, t, b, radius, col)
}

// Camera-facing disc for isotropic splats (halos). One winding only: a
// translucent splat must be blended once, not once per side.
draw_billboard_disc :: proc(pos, cam_right, cam_up: [3]f32, radius: f32, col: rl.Color) {
    draw_disc_frame(pos, cam_right, cam_up, radius, col, two_sided = false)
}

// Stretched hard ellipse: original free blades are one Gaussian each, drawn
// as a hard ellipse of radius 1.5 sigma (not a rectangle / triangle).
draw_oriented_ellipse :: proc(pos, axis_x, axis_y: [3]f32, rx, ry: f32, col: rl.Color, two_sided := true) {
    // axis_x/axis_y should be unit; corners of the ellipse bounding quad
    p0 := pos + (-axis_x)*rx + (-axis_y)*ry
    p1 := pos + ( axis_x)*rx + (-axis_y)*ry
    p2 := pos + ( axis_x)*rx + ( axis_y)*ry
    p3 := pos + (-axis_x)*rx + ( axis_y)*ry

    rlgl.SetTexture(splat_soft ? disc_soft_tex.id : disc_hard_tex.id)
    rlgl.Begin(rlgl.QUADS)
    rlgl.Color4ub(col.r, col.g, col.b, col.a)
    rlgl.TexCoord2f(0, 0); rlgl.Vertex3f(p0.x, p0.y, p0.z)
    rlgl.TexCoord2f(1, 0); rlgl.Vertex3f(p1.x, p1.y, p1.z)
    rlgl.TexCoord2f(1, 1); rlgl.Vertex3f(p2.x, p2.y, p2.z)
    rlgl.TexCoord2f(0, 1); rlgl.Vertex3f(p3.x, p3.y, p3.z)
    if two_sided {
        rlgl.TexCoord2f(0, 0); rlgl.Vertex3f(p0.x, p0.y, p0.z)
        rlgl.TexCoord2f(0, 1); rlgl.Vertex3f(p3.x, p3.y, p3.z)
        rlgl.TexCoord2f(1, 1); rlgl.Vertex3f(p2.x, p2.y, p2.z)
        rlgl.TexCoord2f(1, 0); rlgl.Vertex3f(p1.x, p1.y, p1.z)
    }
    rlgl.End()
    rlgl.SetTexture(0)
}

// Free-splat blade: hard ellipse along right/up with half-extents half_w/half_h.
// Matches original 1.5-sigma hard edge of a stretched Gaussian.
draw_oriented_blade :: proc(pos, right, up: [3]f32, half_w, half_h: f32, col: rl.Color) {
    ax := right
    if linalg.vector_length(ax) > 1e-6 do ax = linalg.normalize(ax)
    ay := up
    if linalg.vector_length(ay) > 1e-6 do ay = linalg.normalize(ay)
    draw_oriented_ellipse(pos, ax, ay, half_w, half_h, col, two_sided = true)
}

// Fog: fade colour toward a dark background between start and end distance.
// Matches shade.js: mix(col, vec3(0.03,0.035,0.05), 0.75 * smoothstep(fog.x, fog.y, dist))
FOG_START :: f32(3)
FOG_END   :: f32(6)
FOG_COL   :: [3]f32{0.03, 0.035, 0.05}

apply_fog_color :: proc(col: rl.Color, dist: f32, emissive := false) -> rl.Color {
    if emissive do return col
    t := math.clamp((dist - FOG_START) / (FOG_END - FOG_START), 0, 1)
    t = t * t * (3 - 2 * t) // smoothstep
    k := 0.75 * t
    r := f32(col.r)/255 * (1 - k) + FOG_COL[0] * k
    g := f32(col.g)/255 * (1 - k) + FOG_COL[1] * k
    b := f32(col.b)/255 * (1 - k) + FOG_COL[2] * k
    return {u8(math.clamp(r*255, 0, 255)), u8(math.clamp(g*255, 0, 255)), u8(math.clamp(b*255, 0, 255)), col.a}
}

