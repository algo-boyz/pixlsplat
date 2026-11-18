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
draw_surfel :: proc(s: Surfel, soft: bool) {
    col := rl.Color{s.color[0], s.color[1], s.color[2], 255}
    if s.emissive {
        col = {
            u8(min(f32(s.color[0]) * 1.15, 255)),
            u8(min(f32(s.color[1]) * 1.15, 255)),
            u8(min(f32(s.color[2]) * 1.15, 255)),
            255,
        }
    }
    draw_oriented_disc(s.pos, s.normal, splat_radius(SPLAT_R, soft), col)
}

// Everything except Sway blades, which are drawn as opaque triangles.
draw_free :: proc(fs: Free_Splat, cam_right, cam_up: [3]f32, soft: bool) {
    switch fs.kind {
    case .Glow:
        // translucent halo: alpha is the splat's opacity, sigma is its scale
        a := u8(math.clamp(fs.alpha, 0, 1) * 255 + 0.5)
        r := fs.scale.x * (SPLAT_STD_SOFT if soft else SPLAT_STD_DEV)
        draw_billboard_disc(fs.pos, cam_right, cam_up, r, {fs.color[0], fs.color[1], fs.color[2], a})
    case .Lit, .Emissive:
        draw_oriented_disc(fs.pos, fs.up, splat_radius(fs.scale.x * 2, soft),
            {fs.color[0], fs.color[1], fs.color[2], 255})
    case .Sway:
        // drawn in the blade pass
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

        // grass blades: opaque triangles in both modes
        for fs in free.items {
            if fs.kind == .Sway {
                draw_oriented_blade(fs.pos, fs.right, fs.up, fs.scale.x, fs.scale.y,
                    {fs.color[0], fs.color[1], fs.color[2], 255})
            }
        }

        if !soft {
            // hard pixels: opaque discs write depth, then translucent light is
            // blended over them without writing depth
            for s in surfels do draw_surfel(s, false)
            for fs in free.items {
                if fs.kind == .Lit || fs.kind == .Emissive do draw_free(fs, right, cup, false)
            }
            rlgl.DisableDepthMask()
            for fs in free.items {
                if fs.kind == .Glow do draw_free(fs, right, cup, false)
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
                    draw_free(free.items[it.i], right, cup, true)
                } else {
                    draw_surfel(surfels[it.i], true)
                }
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
