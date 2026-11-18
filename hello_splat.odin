package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// SDF primitives
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
    return Cone{a = a, b = b, r1 = r1, r2 = r2, ba = ba, baba = linalg.dot(ba, ba)}
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

// Shape builder

Prim_Kind :: enum { Sphere, Ellipsoid, Cone, Box }

Prim :: struct {
    kind: Prim_Kind,
    mat:  int,
    k:    f32,
    using data: struct #raw_union {
        sphere:    Sphere,
        ellipsoid: Ellipsoid,
        cone:      Cone,
        box:       Box,
    },
}

Shape :: struct { adds: [dynamic]Prim }

shape_new :: proc() -> Shape { return Shape{adds = make([dynamic]Prim)} }

shape_add_sphere    :: proc(s: ^Shape, c: [3]f32, r: f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Sphere, mat = mat, k = k, sphere = {c, r}})
}
shape_add_ellipsoid :: proc(s: ^Shape, c: [3]f32, radii: [3]f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Ellipsoid, mat = mat, k = k, ellipsoid = {c, radii}})
}
shape_add_cone      :: proc(s: ^Shape, a, b: [3]f32, r1, r2: f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Cone, mat = mat, k = k, cone = cone_make(a, b, r1, r2)})
}
shape_add_box       :: proc(s: ^Shape, c: [3]f32, half: [3]f32, r: f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Box, mat = mat, k = k, box = {c, half, r}})
}

prim_dist :: proc(pr: Prim, p: [3]f32) -> f32 {
    switch pr.kind {
    case .Sphere:    return sphere_dist(pr.sphere, p)
    case .Ellipsoid: return ellipsoid_dist(pr.ellipsoid, p)
    case .Cone:      return cone_dist(pr.cone, p)
    case .Box:       return box_dist(pr.box, p)
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
    for a in s.adds do d = smin(d, prim_dist(a, p), a.k)
    return d
}

shape_mat :: proc(s: Shape, p: [3]f32) -> int {
    best: f32 = 1e9
    m := 0
    for a in s.adds {
        d := prim_dist(a, p)
        if d < best { best = d; m = a.mat }
    }
    return m
}

// Surface sampling

Surfel :: struct {
    pos:    [3]f32,
    normal: [3]f32,
    color:  rl.Color,
}

sample_surface :: proc(sh: Shape, minp, maxp: [3]f32, h: f32, paint: proc(mat: int, p, n: [3]f32) -> rl.Color) -> [dynamic]Surfel {
    out := make([dynamic]Surfel)
    e := h * 0.45

    grad :: proc(sh: Shape, p: [3]f32, e: f32) -> [3]f32 {
        return {
            shape_dist(sh, p + {e,0,0}) - shape_dist(sh, p - {e,0,0}),
            shape_dist(sh, p + {0,e,0}) - shape_dist(sh, p - {0,e,0}),
            shape_dist(sh, p + {0,0,e}) - shape_dist(sh, p - {0,0,e}),
        }
    }

    for z := minp.z; z < maxp.z; z += h {
        for y := minp.y; y < maxp.y; y += h {
            for x := minp.x; x < maxp.x; x += h {
                p := [3]f32{x, y, z}
                d := shape_dist(sh, p)
                if abs(d) > h * 1.15 do continue

                g  := grad(sh, p, e)
                gl := linalg.vector_length(g) / (2 * e)
                if gl < 1e-5 do continue
                if abs(d) / gl > h * 0.55 do continue

                // Newton onto surface
                for _ in 0..<3 {
                    s := d / (gl*gl) / (2*e)
                    p -= g * s
                    d  = shape_dist(sh, p)
                    g  = grad(sh, p, e)
                    gl = linalg.vector_length(g) / (2 * e)
                    if gl < 1e-5 do break
                }

                n := linalg.normalize(g)          // outward normal
                mat := shape_mat(sh, p)
                col := paint(mat, p, n)
                append(&out, Surfel{pos = p, normal = n, color = col})
            }
        }
    }
    return out
}

// Better island (closer to original proportions)

build_hello :: proc() -> [dynamic]Surfel {
    s := shape_new()
    defer delete(s.adds)

    M_GRASS  :: 0
    M_ROCK   :: 1
    M_TRUNK  :: 2
    M_LEAVES :: 3
    M_POST   :: 4
    M_LAMP   :: 5

    R      :: 1.25          // island radius
    rFlat  :: 0.35          // flat centre radius
    topY   :: 0.0

    // 1. Grass top – rounded slab that follows a simple height field
    //    (this is the key piece we were missing)
    // ------------------------------------------------------------------
    // We approximate the original custom SDF with a flattened ellipsoid
    // that is slightly larger than the rock body, then we will let the
    // rock cut into it via blending.

    // Main grass disc (slightly domed)
    shape_add_ellipsoid(&s, {0, topY + 0.02, 0}, {R*1.02, 0.085, R*1.02}, M_GRASS, 0.0)

    // Soft lip / rim so the edge is not razor thin
    shape_add_ellipsoid(&s, {0, topY - 0.01, 0}, {R*0.98, 0.12, R*0.98}, M_GRASS, 0.08)

    // 2. Rock body – cut ellipsoid (the classic floating-island look)
    // ------------------------------------------------------------------
    // The original does:
    //   max( ellipsoid(...), y - topY + 0.12 )
    // We approximate it with a large ellipsoid placed lower + strong blend.
    shape_add_ellipsoid(&s, {0, topY - 0.28, 0}, {R*0.95, 0.55, R*0.95}, M_ROCK, 0.14)

    // 3. Tree
    // ------------------------------------------------------------------
    shape_add_cone(&s, {0.0, 0.05, 0.0}, {0.03, 0.82, 0.0}, 0.078, 0.042, M_TRUNK)

    blobs := [3][4]f32{
        { 0.02, 1.08,  0.00, 0.40},
        {-0.25, 0.93,  0.14, 0.30},
        { 0.27, 0.91, -0.12, 0.28},
    }
    for b in blobs {
        shape_add_ellipsoid(&s,
            {b[0], b[1], b[2]},
            {b[3], b[3]*0.80, b[3]},
            M_LEAVES, 0.09)
    }

    // 4. Lantern
    // ------------------------------------------------------------------
    shape_add_cone(&s, {0.55, 0.04, 0.42}, {0.55, 0.55, 0.42}, 0.017, 0.013, M_POST)
    shape_add_box (&s, {0.55, 0.60, 0.42}, {0.042, 0.048, 0.042}, 0.010, M_LAMP)

    // 5. Small rocks on the grass
    // ------------------------------------------------------------------
    for i in 0..<8 {
        a  := f32(i) * 0.85 + 0.4
        rr := 0.45 + 0.4 * math.sin(f32(i)*1.6)
        rx := math.cos(a) * rr
        rz := math.sin(a) * rr
        size := 0.05 + f32(i % 3) * 0.02
        shape_add_sphere(&s, {rx, 0.07, rz}, size, M_ROCK)
    }

    // Paint (kept close to original palette)
    // ------------------------------------------------------------------
    paint :: proc(mat: int, p, n: [3]f32) -> rl.Color {
        switch mat {
        case M_LAMP:   return {255, 210,  95, 255}
        case M_POST:   return { 48,  44,  70, 255}
        case M_TRUNK:  return { 82,  48,  42, 255}
        case M_LEAVES:
            if math.sin(p.x*11 + p.y*11 + p.z*11) > 0.22 {
                return {175, 220, 105, 255}
            }
            return { 85, 160,  80, 255}
        case M_ROCK:
            if n.y < -0.15 {
                return {100,  98, 120, 255}   // underside darker
            }
            return {128, 126, 146, 255}
        case: // grass
            if n.y < 0.30 {
                return { 68,  46,  38, 255}   // edge / cliff
            }
            return { 40,  92,  62, 255}
        }
        return rl.WHITE
    }

    // Sampling volume
    minp := [3]f32{-1.55, -1.05, -1.55}
    maxp := [3]f32{ 1.55,  1.55,  1.55}
    return sample_surface(s, minp, maxp, 0.027, paint)
}

// Oriented disc
// ---------------------------------------------------------------------------

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

// Palette + mild outline
// ---------------------------------------------------------------------------

PALETTE := [12]rl.Color{
    {10, 10, 24, 255},   // 0 background
    {23, 21, 44, 255},
    {43, 39, 64, 255},
    {76, 74, 96, 255},
    {128,126,146, 255},
    {74, 42, 38, 255},
    {31, 74, 56, 255},
    {79,154, 74, 255},
    {168,216, 96, 255},
    {200, 55, 45, 255},
    {255,207, 90, 255},
    {255,241,192, 255},
}

nearest_palette :: proc(c: rl.Color) -> rl.Color {
    best := PALETTE[0]
    best_d: f32 = 1e9
    for p in PALETTE {
        dr := f32(c.r) - f32(p.r)
        dg := f32(c.g) - f32(p.g)
        db := f32(c.b) - f32(p.b)
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

    // quantize
    for y in 0..<h {
        for x in 0..<w {
            c := rl.GetImageColor(img^, i32(x), i32(y))
            if c.a < 8 do continue
            rl.ImageDrawPixel(img, i32(x), i32(y), nearest_palette(c))
        }
    }

    // mild outline
    copy := rl.ImageCopy(img^)
    defer rl.UnloadImage(copy)

    for y in 1..<h-1 {
        for x in 1..<w-1 {
            c := rl.GetImageColor(copy, i32(x), i32(y))
            if c.r == bg.r && c.g == bg.g do continue

            n0 := rl.GetImageColor(copy, i32(x),   i32(y-1))
            n1 := rl.GetImageColor(copy, i32(x),   i32(y+1))
            n2 := rl.GetImageColor(copy, i32(x-1), i32(y))
            n3 := rl.GetImageColor(copy, i32(x+1), i32(y))

            edge := (n0.r == bg.r && n0.g == bg.g) ||
                    (n1.r == bg.r && n1.g == bg.g) ||
                    (n2.r == bg.r && n2.g == bg.g) ||
                    (n3.r == bg.r && n3.g == bg.g)

            if edge {
                dark := rl.Color{
                    u8(max(0, i32(c.r) - 38)),
                    u8(max(0, i32(c.g) - 38)),
                    u8(max(0, i32(c.b) - 32)),
                    255,
                }
                rl.ImageDrawPixel(img, i32(x), i32(y), nearest_palette(dark))
            }
        }
    }
}

main :: proc() {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    rl.InitWindow(1280, 720, "Pixel-art Surfels – Hello Island")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    ART_W, ART_H :: 320, 180
    target := rl.LoadRenderTexture(ART_W, ART_H)
    defer rl.UnloadRenderTexture(target)
    rl.SetTextureFilter(target.texture, .POINT)

    camera := rl.Camera3D{
        position   = {2.8, 1.7, 2.8},
        target     = {0, 0.25, 0},
        up         = {0, 1, 0},
        fovy       = 40,
        projection = .PERSPECTIVE,
    }

    fmt.println("Building scene…")
    surfels := build_hello()
    defer delete(surfels)
    fmt.printf("Generated %d surfels\n", len(surfels))

    yaw, pitch: f32 = 0.9, 0.32
    dist: f32 = 3.8
    dragging := false
    last_mouse: rl.Vector2

    for !rl.WindowShouldClose() {
        if rl.IsMouseButtonPressed(.LEFT) {
            dragging = true
            last_mouse = rl.GetMousePosition()
        }
        if rl.IsMouseButtonReleased(.LEFT) do dragging = false

        if dragging {
            m := rl.GetMousePosition()
            yaw   += (m.x - last_mouse.x) * 0.005
            pitch  = math.clamp(pitch + (m.y - last_mouse.y) * 0.005, -1.1, 1.1)
            last_mouse = m
        }

        wheel := rl.GetMouseWheelMove()
        dist = math.clamp(dist - wheel * 0.2, 1.8, 9)

        camera.position = {
            math.cos(yaw) * math.cos(pitch) * dist,
            math.sin(pitch) * dist + 0.4,
            math.sin(yaw) * math.cos(pitch) * dist,
        }
        camera.target = {0, 0.22, 0}

        // Low-res 3D
        rl.BeginTextureMode(target)
        rl.ClearBackground(PALETTE[0])
        rl.BeginMode3D(camera)

        sun := linalg.normalize([3]f32{0.55, 0.75, 0.35})

        for s in surfels {
            ndotl := math.clamp(linalg.dot(s.normal, sun), 0.25, 1.0)
            col := s.color
            col.r = u8(f32(col.r) * ndotl)
            col.g = u8(f32(col.g) * ndotl)
            col.b = u8(f32(col.b) * ndotl)

            draw_oriented_disc(s.pos, s.normal, 0.046, col)
        }

        rl.EndMode3D()
        rl.EndTextureMode()

        // Post-process (palette + outline)
        img := rl.LoadImageFromTexture(target.texture)
        // Raylib render textures come flipped; flip once so the image is upright
        rl.ImageFlipVertical(&img)
        apply_palette_and_outline(&img)
        rl.UpdateTexture(target.texture, img.data)
        rl.UnloadImage(img)

        // Upscale (now the texture is upright, so use positive height)
        rl.BeginDrawing()
        rl.ClearBackground(rl.BLACK)

        src := rl.Rectangle{0, 0, f32(ART_W), f32(ART_H)}   // positive height
        dst := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
        rl.DrawTexturePro(target.texture, src, dst, {0, 0}, 0, rl.WHITE)

        rl.DrawText("Hello island", 10, 10, 20, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%d surfels | drag orbit, wheel zoom", len(surfels)), 10, 35, 18, {180,180,180,255})
        rl.EndDrawing()
    }
}