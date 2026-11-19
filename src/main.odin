package pixlsplat

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import rl   "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

ART_W :: 640
ART_H :: 360

// One splat in the soft-mode draw order (Gaussians blend, so they must be
// drawn back to front).
Sort_Item :: struct {
    d:    f32,    // distance along the view direction
    i:    i32,
    free: bool,   // index into free.items instead of surfels
}

// The colour is already lit (bake() in island.odin), so it is drawn as is.
// Emissive surfels (the lantern) are boosted like the original's shader does.
draw_surfel :: proc(s: Surfel, soft: bool, dist: f32 = 0) {
    col := rl.Color{s.color[0], s.color[1], s.color[2], 255}
    if s.emissive {
        col = {
            u8(min(f32(s.color[0]) * 1.15, 255)),
            u8(min(f32(s.color[1]) * 1.15, 255)),
            u8(min(f32(s.color[2]) * 1.15, 255)),
            255,
        }
    } else {
        col = apply_fog_color(col, dist)
    }
    draw_oriented_disc(s.pos, s.normal, splat_radius(SPLAT_R, soft), col)
}

// Free splat draw. Sway blades are handled in the blade pass with optional sway.
draw_free :: proc(fs: Free_Splat, cam_right, cam_up: [3]f32, soft: bool, dist: f32 = 0) {
    switch fs.kind {
    case .Glow:
        // Three nested translucent discs (alphas 0.14/0.3/0.55), through haze/fog.
        a := u8(math.clamp(fs.alpha, 0, 1) * 255 + 0.5)
        r := fs.scale.x * (SPLAT_STD_SOFT if soft else SPLAT_STD_DEV)
        col := apply_fog_color({fs.color[0], fs.color[1], fs.color[2], a}, dist, emissive = true)
        // Keep glow alpha; fog only shifts RGB slightly for distant halos is skipped (emissive)
        draw_billboard_disc(fs.pos, cam_right, cam_up, r, {col.r, col.g, col.b, a})
    case .Lit, .Emissive:
        col := apply_fog_color(
            {fs.color[0], fs.color[1], fs.color[2], 255},
            dist,
            emissive = fs.kind == .Emissive,
        )
        draw_oriented_disc(fs.pos, fs.up, splat_radius(fs.scale.x * 2, soft), col)
    case .Litter:
        // Flat on ground: ellipse in the XZ plane (right × world-up cross ≈ forward)
        col := apply_fog_color({fs.color[0], fs.color[1], fs.color[2], 255}, dist)
        right := fs.right
        if linalg.vector_length(right) < 1e-5 do right = {1, 0, 0}
        // second axis along ground perpendicular to right
        fwd := linalg.normalize(linalg.cross({0, 1, 0}, right))
        if linalg.vector_length(fwd) < 1e-5 do fwd = {0, 0, 1}
        draw_oriented_ellipse(fs.pos, right, fwd, fs.scale.x, fs.scale.y, col)
    case .Sway:
        // drawn in the blade pass
    }
}

// Time-based sway offset matching particles.js sway mode.
sway_offset :: proc(p: [3]f32, t: f32) -> [3]f32 {
    return {
        0.016 * math.sin(t * 1.6 + p.x * 5.0 + p.z * 3.0),
        0,
        0.011 * math.cos(t * 1.3 + p.z * 4.0 - p.x * 2.0),
    }
}

// Simple blink firefly particle (hello scene).
Blink_Particle :: struct {
    base:  [3]f32,
    phase: f32,
    color: [4]u8,
}

draw_blink_particle :: proc(bp: Blink_Particle, t: f32, cam_right, cam_up: [3]f32, soft: bool, cam_pos: [3]f32) {
    // drift a little
    p := bp.base + [3]f32{
        0.08 * math.sin(t * 0.7 + bp.phase),
        0.05 * math.sin(t * 1.1 + bp.phase * 1.7),
        0.08 * math.cos(t * 0.55 + bp.phase * 0.9),
    }
    // blink envelope
    pulse := 0.5 + 0.5 * math.sin(t * 3.2 + bp.phase * 5)
    pulse = pulse * pulse
    if pulse < 0.08 do return
    a := u8(math.clamp(pulse, 0, 1) * 220)
    dist := linalg.vector_length(p - cam_pos)
    col := apply_fog_color({bp.color[0], bp.color[1], bp.color[2], a}, dist, emissive = true)
    r := 0.018 * (SPLAT_STD_SOFT if soft else SPLAT_STD_DEV)
    draw_billboard_disc(p, cam_right, cam_up, r, {col.r, col.g, col.b, a})
    // soft halo
    if pulse > 0.35 {
        ha := u8(f32(a) * 0.35)
        draw_billboard_disc(p, cam_right, cam_up, r * 2.4, {col.r, col.g, col.b, ha})
    }
}


main :: proc() {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    rl.InitWindow(1280, 720, "pixlsplat – Hello island")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    // Scene targets at 1x and 2x the art resolution (index = ss), and the
    // art-resolution target the post pass resolves into.
    scene_rt: [3]rl.RenderTexture2D
    for k in 1..=2 {
        scene_rt[k] = rl.LoadRenderTexture(ART_W * i32(k), ART_H * i32(k))
        rl.SetTextureFilter(scene_rt[k].texture, .POINT)
    }
    defer { for k in 1..=2 do rl.UnloadRenderTexture(scene_rt[k]) }

    art_rt := rl.LoadRenderTexture(ART_W, ART_H)
    defer rl.UnloadRenderTexture(art_rt)
    rl.SetTextureFilter(art_rt.texture, .POINT)

    init_splat_assets()
    defer unload_splat_assets()

    post: Post
    post_init(&post)
    defer post_unload(&post)
    post_set_palette(&post, PALETTE[:], GLOW_PALETTE[:], PALETTE[0])

    // Defaults match the original viewer: palette, hard pixels, 2x2
    // supersampling and outline on, dither off.
    cfg := Post_Settings{quant = true, crisp = true, outline = true, ss = 2, dither = 0}

    camera := rl.Camera3D{
        position   = {2.8, 1.7, 2.8},
        target     = {0, 0.25, 0},
        up         = {0, 1, 0},
        fovy       = 30,
        projection = .PERSPECTIVE,
    }

    fmt.println("Building scene…")
    surfels, free := build_hello()
    defer {
        delete(surfels)
        delete(free.items)
    }
    fmt.printf("Generated %d SDF surfels + %d free splats\n", len(surfels), len(free.items))

    // Fireflies: blink mode with halos (hello scene particles)
    blinks := make([dynamic]Blink_Particle)
    defer delete(blinks)
    {
        rng := mulberry32_new(99)
        cols := [2][4]u8{{255, 207, 90, 255}, {255, 241, 192, 255}}
        for i in 0..<18 {
            bx := (mulberry32_next(&rng) * 2 - 1) * 1.1
            by := 0.3 + (mulberry32_next(&rng) * 2 - 1) * 0.5
            bz := (mulberry32_next(&rng) * 2 - 1) * 1.1
            append(&blinks, Blink_Particle{
                base  = {bx, by, bz},
                phase = mulberry32_next(&rng) * math.TAU,
                color = cols[i & 1],
            })
        }
    }

    order: [dynamic]Sort_Item
    defer delete(order)

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

        // toggles, same letters as the original's panel
        if rl.IsKeyPressed(.Q) do cfg.quant   = !cfg.quant
        if rl.IsKeyPressed(.X) do cfg.crisp   = !cfg.crisp
        if rl.IsKeyPressed(.E) do cfg.outline = !cfg.outline
        if rl.IsKeyPressed(.S) do cfg.ss      = 3 - cfg.ss          // 1 <-> 2
        if rl.IsKeyPressed(.D) do cfg.dither  = 0 if cfg.dither >= 1 else cfg.dither + 0.5

        camera.position = {
            math.cos(yaw) * math.cos(pitch) * dist,
            math.sin(pitch) * dist + 0.4,
            math.sin(yaw) * math.cos(pitch) * dist,
        }
        camera.target = {0, 0.22, 0}

        fwd   := linalg.normalize(camera.target - camera.position)
        right := linalg.normalize(linalg.cross(fwd, camera.up))
        cup   := linalg.cross(right, fwd)
        soft  := !cfg.crisp

        // ---- pass 1: splats into a transparent, premultiplied target -----------
        set_splat_mode(soft)
        rt := scene_rt[cfg.ss]

        rl.BeginTextureMode(rt)
        rl.ClearBackground(rl.BLANK)
        rl.BeginMode3D(camera)
        rl.BeginShaderMode(splat_shader)
        rl.BeginBlendMode(.ALPHA_PREMULTIPLY)

        t := f32(rl.GetTime())

        // grass blades: hard ellipses; sway with time
        for fs in free.items {
            if fs.kind == .Sway {
                off := sway_offset(fs.pos, t)
                pos := fs.pos + off
                dist := linalg.vector_length(pos - camera.position)
                col := apply_fog_color({fs.color[0], fs.color[1], fs.color[2], 255}, dist)
                draw_oriented_blade(pos, fs.right, fs.up, fs.scale.x, fs.scale.y, col)
            }
        }

        if !soft {
            // hard pixels: opaque discs write depth, then translucent light is
            // blended over them without writing depth
            for s in surfels {
                dist := linalg.vector_length(s.pos - camera.position)
                draw_surfel(s, false, dist)
            }
            for fs in free.items {
                if fs.kind == .Lit || fs.kind == .Emissive || fs.kind == .Litter {
                    dist := linalg.vector_length(fs.pos - camera.position)
                    draw_free(fs, right, cup, false, dist)
                }
            }
            rlgl.DisableDepthMask()
            for fs in free.items {
                if fs.kind == .Glow {
                    dist := linalg.vector_length(fs.pos - camera.position)
                    draw_free(fs, right, cup, false, dist)
                }
            }
            for bp in blinks {
                draw_blink_particle(bp, t, right, cup, false, camera.position)
            }
            rlgl.EnableDepthMask()
        } else {
            // soft Gaussians: everything blends, so sort back to front
            clear(&order)
            for s, i in surfels {
                append(&order, Sort_Item{d = linalg.dot(s.pos - camera.position, fwd), i = i32(i)})
            }
            for fs, i in free.items {
                if fs.kind == .Sway do continue
                append(&order, Sort_Item{d = linalg.dot(fs.pos - camera.position, fwd), i = i32(i), free = true})
            }
            slice.sort_by(order[:], proc(a, b: Sort_Item) -> bool { return a.d > b.d })

            rlgl.DisableDepthMask()
            for it in order {
                if it.free {
                    fs := free.items[it.i]
                    dist := linalg.vector_length(fs.pos - camera.position)
                    draw_free(fs, right, cup, true, dist)
                } else {
                    s := surfels[it.i]
                    dist := linalg.vector_length(s.pos - camera.position)
                    draw_surfel(s, true, dist)
                }
            }
            for bp in blinks {
                draw_blink_particle(bp, t, right, cup, true, camera.position)
            }
            rlgl.EnableDepthMask()
        }

        rl.EndBlendMode()
        rl.EndShaderMode()
        rl.EndMode3D()
        rl.EndTextureMode()

        // ---- pass 2: resolve to pixel art on the GPU ---------------------------
        post_apply(&post, rt.texture, art_rt, ART_W, ART_H, cfg)

        rl.BeginDrawing()
        rl.ClearBackground(rl.BLACK)
        src := rl.Rectangle{0, 0, ART_W, -ART_H}   // render textures are upside down
        dst := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
        rl.DrawTexturePro(art_rt.texture, src, dst, {0, 0}, 0, rl.WHITE)

        rl.DrawText("Hello island", 10, 10, 20, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%d surfels + %d free | drag orbit, wheel zoom | %d fps",
            len(surfels), len(free.items), rl.GetFPS()), 10, 35, 18, {180,180,180,255})
        rl.DrawText(fmt.ctprintf("[Q] palette %s  [X] hard pixels %s  [S] supersample %dx%d  [E] outline %s  [D] dither %.1f",
            cfg.quant ? "on" : "off", cfg.crisp ? "on" : "off", cfg.ss, cfg.ss,
            cfg.outline ? "on" : "off", cfg.dither), 10, 58, 16, {180,180,180,255})
        rl.EndDrawing()
    }
}
