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
    free: bool,   // index into free_items instead of surfels
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

// Blink/fireflies: see particles.odin (Particle_Mode.Blink)


main :: proc() {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    rl.InitWindow(1280, 720, "pixlsplat")
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

    // Scene sources: pre-baked .dio under assets/models/, procedural hello,
    // or converted .psf models (static for now; skin weights loaded when present).
    // Keys 1–5: dio / hello · 6–9: psf creatures
    Scene_Kind :: enum { Hello_Build, Dio, Psf }
    scene_name := "shrine"
    scene_kind := Scene_Kind.Dio

    surfels: [dynamic]Surfel
    free_items: [dynamic]Free_Splat
    particles: Particle_System
    particles = particle_system_make()
    defer {
        delete(surfels)
        delete(free_items)
        particle_system_destroy(&particles)
    }

    load_scene :: proc(
        name: string,
        kind: Scene_Kind,
        surfels: ^[dynamic]Surfel,
        free_items: ^[dynamic]Free_Splat,
        particles: ^Particle_System,
        post: ^Post,
    ) {
        clear(surfels)
        clear(free_items)
        particle_system_destroy(particles)
        particles^ = particle_system_make()

        if kind == .Dio {
            path := fmt.tprintf("assets/models/%s.dio", name)
            world, ok := load_dio(path)
            if ok {
                for s in world.surfels do append(surfels, s)
                for f in world.free do append(free_items, f)
                // steal particle system
                particles^ = world.particles
                world.particles = {}
                if len(world.palette) > 0 {
                    glow := world.glow_pal[:] if len(world.glow_pal) > 0 else [][4]u8{}
                    post_set_palette(post, world.palette[:], glow, world.background)
                }
                dio_world_destroy(&world)
                fmt.printf("Loaded %s (%d surfels + %d free)\n", path, len(surfels^), len(free_items^))
                return
            }
            fmt.eprintf("Failed to load %s — falling back to hello build\n", path)
        } else if kind == .Psf {
            path := fmt.tprintf("assets/models/%s.psf", name)
            model, ok := load_psf(path)
            if ok {
                skinned := model.skinned
                for s in model.surfels do append(surfels, s)
                // Derive a small palette from the model colours so the pixel
                // pass has something to vote with. Background stays dark.
                pal := make([dynamic][4]u8)
                defer delete(pal)
                append(&pal, [4]u8{12, 14, 18, 255}) // near-black bg
                // sample every Nth surfel into the palette (cheap stand-in for k-means)
                step := max(1, len(model.surfels) / 24)
                for i := 0; i < len(model.surfels); i += step {
                    append(&pal, model.surfels[i].color)
                }
                post_set_palette(post, pal[:], {}, pal[0])
                // Apply a one-shot directional light so unbaked albedo still
                // has form under the hard-pixel pass.
                shade_model_surfels(surfels[:], {0.45, 0.8, 0.35}, 0.55, 0.35)
                psf_model_destroy(&model)
                fmt.printf("Loaded %s (%d surfels, skinned=%v)\n", path, len(surfels^), skinned)
                // Note: joint/weight arrays were destroyed with the temporary
                // Psf_Model. For live dual-quaternion skinning, keep the model
                // alive and update bone dual-quats each frame (see rig.js).
                return
            }
            fmt.eprintf("Failed to load %s — falling back to hello build\n", path)
        }
        // Procedural hello
        s, free := build_hello()
        for x in s do append(surfels, x)
        delete(s)
        for f in free_items do append(free_items, f)
        // TODO:
        // delete(free_items)
        // Error: No procedures or ambiguous call for procedure group 'delete' that match with the given arguments 
        // Given argument types: 
        // • ^[dynamic]Free_Splat 
        particle_emit_box(
            particles, .Blink, 18,
            center = {0, 0.3, 0}, spread = {1.1, 0.5, 1.1},
            colors = {{255, 207, 90, 255}, {255, 241, 192, 255}},
            scale = 0.018, alpha = 1, seed = 99, pairs = true,
        )
        shafts_emit(
            particles,
            beams = {
                {to = {0.2, 0.0, 0.1}, len = 2.4, r = 0.12},
                {to = {-0.3, 0.05, 0.35}, len = 2.0, r = 0.1},
            },
            colors = {{0x8a, 0x73, 0x56, 255}, {0x4e, 0x3f, 0x3a, 255}},
            alpha = 0.28, n = 12, seed = 11,
        )
        post_set_palette(post, PALETTE[:], GLOW_PALETTE[:], PALETTE[0])
        fmt.printf("Built hello (%d surfels + %d free)\n", len(surfels^), len(free_items^))
    }

    load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)

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
        // Scene switch: 1 hello (build) · 2 shrine · 3 lighthouse · 4 caravan · 5 hello.dio
        if rl.IsKeyPressed(.ONE) {
            scene_name, scene_kind = "hello", .Hello_Build
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }
        if rl.IsKeyPressed(.TWO) {
            scene_name, scene_kind = "shrine", .Dio
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }
        if rl.IsKeyPressed(.THREE) {
            scene_name, scene_kind = "lighthouse", .Dio
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }
        if rl.IsKeyPressed(.FOUR) {
            scene_name, scene_kind = "caravan", .Dio
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }
        if rl.IsKeyPressed(.FIVE) {
            scene_name, scene_kind = "hello", .Dio
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }

        // PSF models (static view; skin weights present in file but not animated yet)
        if rl.IsKeyPressed(.SIX) {
            scene_name, scene_kind = "minotaur", .Psf
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }
        if rl.IsKeyPressed(.SEVEN) {
            scene_name, scene_kind = "hyena", .Psf
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }
        if rl.IsKeyPressed(.EIGHT) {
            scene_name, scene_kind = "toad", .Psf
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }
        if rl.IsKeyPressed(.NINE) {
            scene_name, scene_kind = "dragon_shield", .Psf
            load_scene(scene_name, scene_kind, &surfels, &free_items, &particles, &post)
        }

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
        for fs in free_items {
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
            for fs in free_items {
                if fs.kind == .Lit || fs.kind == .Emissive || fs.kind == .Litter {
                    dist := linalg.vector_length(fs.pos - camera.position)
                    draw_free(fs, right, cup, false, dist)
                }
            }
            rlgl.DisableDepthMask()
            for fs in free_items {
                if fs.kind == .Glow {
                    dist := linalg.vector_length(fs.pos - camera.position)
                    draw_free(fs, right, cup, false, dist)
                }
            }
            particle_update(&particles, t)
            particle_draw(&particles, right, cup, camera.position, false)
            rlgl.EnableDepthMask()
        } else {
            // soft Gaussians: everything blends, so sort back to front
            clear(&order)
            for s, i in surfels {
                append(&order, Sort_Item{d = linalg.dot(s.pos - camera.position, fwd), i = i32(i)})
            }
            for fs, i in free_items {
                if fs.kind == .Sway do continue
                append(&order, Sort_Item{d = linalg.dot(fs.pos - camera.position, fwd), i = i32(i), free = true})
            }
            slice.sort_by(order[:], proc(a, b: Sort_Item) -> bool { return a.d > b.d })

            rlgl.DisableDepthMask()
            for it in order {
                if it.free {
                    fs := free_items[it.i]
                    dist := linalg.vector_length(fs.pos - camera.position)
                    draw_free(fs, right, cup, true, dist)
                } else {
                    s := surfels[it.i]
                    dist := linalg.vector_length(s.pos - camera.position)
                    draw_surfel(s, true, dist)
                }
            }
            particle_update(&particles, t)
            particle_draw(&particles, right, cup, camera.position, true)
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

        rl.DrawText(fmt.ctprintf("%s", scene_name), 10, 10, 20, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%d surfels + %d free | drag orbit, wheel zoom | %d fps",
            len(surfels), len(free_items), rl.GetFPS()), 10, 35, 18, {180,180,180,255})
        rl.DrawText(fmt.ctprintf("[Q] palette %s  [X] hard %s  [S] ss %dx%d  [E] outline %s  [D] dither %.1f",
            cfg.quant ? "on" : "off", cfg.crisp ? "on" : "off", cfg.ss, cfg.ss,
            cfg.outline ? "on" : "off", cfg.dither), 10, 58, 16, {180,180,180,255})
        rl.DrawText("[1] hello build  [2] shrine  [3] lighthouse  [4] caravan  [5] hello.dio", 10, 78, 16, {160,160,160,255})
        rl.EndDrawing()
    }
}
