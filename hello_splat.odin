package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// SDF primitives (parameter structs + explicit dist procedures)
// ---------------------------------------------------------------------------

Sphere :: struct {
    c: [3]f32,
    r: f32,
}
sphere_dist :: proc(s: Sphere, p: [3]f32) -> f32 {
    return linalg.vector_length(p - s.c) - s.r
}

Ellipsoid :: struct {
    c:     [3]f32,
    radii: [3]f32,
}
ellipsoid_dist :: proc(e: Ellipsoid, p: [3]f32) -> f32 {
    q  := (p - e.c) / e.radii
    k0 := linalg.vector_length(q)
    k1 := linalg.vector_length(q / e.radii)
    if k1 < 1e-6 do return -min(e.radii.x, e.radii.y, e.radii.z)
    return (k0 * (k0 - 1)) / k1
}

// Tapered capsule (called "cone" in the original)
Cone :: struct {
    a, b:     [3]f32,
    r1, r2:   f32,
    ba:       [3]f32, // precomputed
    baba:     f32,
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

Box :: struct {
    c:    [3]f32,
    half: [3]f32,
    r:    f32,
}
box_dist :: proc(b: Box, p: [3]f32) -> f32 {
    q := linalg.abs(p - b.c) - b.half + b.r
    return linalg.vector_length(linalg.max(q, 0)) + min(max(q.x, max(q.y, q.z)), 0) - b.r
}

// ---------------------------------------------------------------------------
// Shape builder (tagged union of primitives)
// ---------------------------------------------------------------------------

Prim_Kind :: enum {
    Sphere,
    Ellipsoid,
    Cone,
    Box,
}

Prim :: struct {
    kind: Prim_Kind,
    mat:  int,
    k:    f32, // blend radius
    using data: struct #raw_union {
        sphere:    Sphere,
        ellipsoid: Ellipsoid,
        cone:      Cone,
        box:       Box,
    },
}

Shape :: struct {
    adds: [dynamic]Prim,
}

shape_new :: proc() -> Shape {
    return Shape{adds = make([dynamic]Prim)}
}

shape_add_sphere :: proc(s: ^Shape, c: [3]f32, r: f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Sphere, mat = mat, k = k, sphere = {c, r}})
}
shape_add_ellipsoid :: proc(s: ^Shape, c: [3]f32, radii: [3]f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Ellipsoid, mat = mat, k = k, ellipsoid = {c, radii}})
}
shape_add_cone :: proc(s: ^Shape, a, b: [3]f32, r1, r2: f32, mat: int, k: f32 = 0) {
    append(&s.adds, Prim{kind = .Cone, mat = mat, k = k, cone = cone_make(a, b, r1, r2)})
}
shape_add_box :: proc(s: ^Shape, c: [3]f32, half: [3]f32, r: f32, mat: int, k: f32 = 0) {
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
    for a in s.adds {
        d = smin(d, prim_dist(a, p), a.k)
    }
    return d
}

shape_mat :: proc(s: Shape, p: [3]f32) -> int {
    best: f32 = 1e9
    m := 0
    for a in s.adds {
        d := prim_dist(a, p)
        if d < best {
            best = d
            m = a.mat
        }
    }
    return m
}

// ---------------------------------------------------------------------------
// Surface sampling
// ---------------------------------------------------------------------------

Surfel :: struct {
    pos:    [3]f32,
    normal: [3]f32,
    color:  rl.Color,
}

sample_surface :: proc(sh: Shape, minp, maxp: [3]f32, h: f32, paint: proc(mat: int, p, n: [3]f32) -> rl.Color) -> [dynamic]Surfel {
    out := make([dynamic]Surfel)
    e := h * 0.5

    grad :: proc(sh: Shape, p: [3]f32, e: f32) -> [3]f32 {
        return {
            shape_dist(sh, p + {e, 0, 0}) - shape_dist(sh, p - {e, 0, 0}),
            shape_dist(sh, p + {0, e, 0}) - shape_dist(sh, p - {0, e, 0}),
            shape_dist(sh, p + {0, 0, e}) - shape_dist(sh, p - {0, 0, e}),
        }
    }

    for z := minp.z; z < maxp.z; z += h {
        for y := minp.y; y < maxp.y; y += h {
            for x := minp.x; x < maxp.x; x += h {
                p := [3]f32{x, y, z}
                d := shape_dist(sh, p)
                if abs(d) > h * 1.2 do continue

                g := grad(sh, p, e)
                gl := linalg.vector_length(g) / (2 * e)
                if gl < 1e-6 do continue
                if abs(d) / gl > h * 0.6 do continue

                // Newton steps onto the surface
                for _ in 0 ..< 2 {
                    s := d / (gl * gl) / (2 * e)
                    p -= g * s
                    d = shape_dist(sh, p)
                    g = grad(sh, p, e)
                    gl = linalg.vector_length(g) / (2 * e)
                    if gl < 1e-6 do break
                }

                n := g * (1 / (gl * 2 * e))
                mat := shape_mat(sh, p)
                col := paint(mat, p, n)
                append(&out, Surfel{pos = p, normal = n, color = col})
            }
        }
    }
    return out
}

// ---------------------------------------------------------------------------
// Hello scene
// ---------------------------------------------------------------------------

build_hello :: proc() -> [dynamic]Surfel {
    s := shape_new()
    defer delete(s.adds)

    M_GRASS  :: 0
    M_ROCK   :: 1
    M_TRUNK  :: 2
    M_LEAVES :: 3
    M_POST   :: 4
    M_LAMP   :: 5

    // Floating island
    shape_add_box(&s, {0, -0.02, 0}, {1.3, 0.04, 1.3}, 0.08, M_GRASS)
    shape_add_box(&s, {0, -0.25, 0}, {1.15, 0.25, 1.15}, 0.15, M_ROCK, 0.1)

    // Trunk
    shape_add_cone(&s, {0, -0.05, 0}, {0.05, 0.75, 0}, 0.09, 0.05, M_TRUNK)

    // Leafy blobs (no displacement noise for simplicity in this version)
    blobs := [3][4]f32{
        { 0.05, 1.00,  0.00, 0.38},
        {-0.22, 0.85,  0.12, 0.28},
        { 0.28, 0.82, -0.10, 0.26},
    }
    for blob in blobs {
        shape_add_ellipsoid(&s,
            {blob[0], blob[1], blob[2]},
            {blob[3], blob[3]*0.8, blob[3]},
            M_LEAVES, 0.08)
    }

    // Lantern
    shape_add_cone(&s, {0.6, -0.03, 0.35}, {0.6, 0.5, 0.35}, 0.022, 0.016, M_POST)
    shape_add_box(&s, {0.6, 0.56, 0.35}, {0.05, 0.06, 0.05}, 0.01, M_LAMP)

    // Rocks
    for i in 0 ..< 5 {
        rx := f32(i) * 0.4 - 0.8
        rz := math.sin(f32(i) * 2.1) * 0.9
        r  := 0.08 + f32(i % 3) * 0.03
        shape_add_sphere(&s, {rx, -0.02, rz}, r, M_ROCK)
    }

    paint :: proc(mat: int, p, n: [3]f32) -> rl.Color {
        switch mat {
        case M_LAMP:   return {255, 207,  90, 255}
        case M_POST:   return { 43,  39,  64, 255}
        case M_TRUNK:  return { 74,  42,  38, 255}
        case M_LEAVES:
            if math.sin(p.x*12 + p.y*12 + p.z*12) > 0.3 {
                return {168, 216, 96, 255}
            }
            return {79, 154, 74, 255}
        case M_ROCK:   return {128, 126, 146, 255}
        case: // grass
            if n.y < 0.4 {
                return {74, 42, 38, 255}
            }
            return {31, 74, 56, 255}
        }
        return rl.WHITE
    }

    minp := [3]f32{-1.5, -0.6, -1.5}
    maxp := [3]f32{ 1.5,  1.6,  1.5}
    return sample_surface(s, minp, maxp, 0.045, paint)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

main :: proc() {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    rl.InitWindow(1280, 720, "Pixel-art Surfels – Hello Island (Odin + Raylib)")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    ART_W, ART_H :: 320, 180
    target := rl.LoadRenderTexture(ART_W, ART_H)
    defer rl.UnloadRenderTexture(target)
    rl.SetTextureFilter(target.texture, .POINT)

    white_img := rl.GenImageColor(4, 4, rl.WHITE)
    white_tex := rl.LoadTextureFromImage(white_img)
    rl.UnloadImage(white_img)
    defer rl.UnloadTexture(white_tex)

    camera := rl.Camera3D{
        position   = {2.5, 1.8, 2.5},
        target     = {0, 0.4, 0},
        up         = {0, 1, 0},
        fovy       = 45,
        projection = .PERSPECTIVE,
    }

    fmt.println("Building scene (SDF sampling)…")
    surfels := build_hello()
    defer delete(surfels)
    fmt.printf("Generated %d surfels\n", len(surfels))

    yaw, pitch: f32 = 0.8, 0.4
    dist: f32 = 3.5
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
            pitch  = math.clamp(pitch + (m.y - last_mouse.y) * 0.005, -1.2, 1.2)
            last_mouse = m
        }

        wheel := rl.GetMouseWheelMove()
        dist = math.clamp(dist - wheel * 0.25, 1.5, 8)

        camera.position = {
            math.cos(yaw) * math.cos(pitch) * dist,
            math.sin(pitch) * dist + 0.5,
            math.sin(yaw) * math.cos(pitch) * dist,
        }
        camera.target = {0, 0.35, 0}

        // Low-res pass
        rl.BeginTextureMode(target)
        rl.ClearBackground({10, 10, 24, 255})
        rl.BeginMode3D(camera)

        sun := linalg.normalize([3]f32{0.45, 0.85, 0.25})

        for s in surfels {
            ndotl := max(linalg.dot(s.normal, sun), 0.18)
            col := s.color
            col.r = u8(f32(col.r) * ndotl)
            col.g = u8(f32(col.g) * ndotl)
            col.b = u8(f32(col.b) * ndotl)

            rl.DrawBillboardPro(
                camera,
                white_tex,
                {0, 0, 4, 4},
                s.pos,
                {0, 1, 0},
                {0.055, 0.055},
                {0, 0},
                0,
                col,
            )
        }

        rl.EndMode3D()
        rl.EndTextureMode()

        // Upscale
        rl.BeginDrawing()
        rl.ClearBackground(rl.BLACK)

        src := rl.Rectangle{0, 0, f32(ART_W), -f32(ART_H)}
        dst := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
        rl.DrawTexturePro(target.texture, src, dst, {0, 0}, 0, rl.WHITE)

        rl.DrawText("Hello island – Odin + Raylib (simplified pixel-art surfels)", 10, 10, 20, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%d surfels | drag orbit, wheel zoom", len(surfels)), 10, 35, 18, rl.GRAY)
        rl.EndDrawing()
    }
}