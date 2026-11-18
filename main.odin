package pixlsplat

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

SPLAT_R: f32 = 0.028

main :: proc() {
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
    rl.InitWindow(1280, 720, "pixlsplat – Hello island")
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
    surfels, free := build_hello()
    defer {
        delete(surfels)
        delete(free.items)
    }
    fmt.printf("Generated %d SDF surfels + %d free splats\n", len(surfels), len(free.items))

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

        rl.BeginTextureMode(target)
        rl.ClearBackground({PALETTE[0][0], PALETTE[0][1], PALETTE[0][2], 255})
        rl.BeginMode3D(camera)

        sun := linalg.normalize([3]f32{0.55, 0.75, 0.35})

        for s in surfels {
            ndotl := math.clamp(linalg.dot(s.normal, sun), 0.25, 1.0)
            col := s.color
            col[0] = u8(f32(col[0]) * ndotl)
            col[1] = u8(f32(col[1]) * ndotl)
            col[2] = u8(f32(col[2]) * ndotl)
            draw_oriented_disc(s.pos, s.normal, SPLAT_R, {col[0], col[1], col[2], 255})
        }

        for fs in free.items {
            col := fs.color
            if fs.kind == .Glow {
                if fs.scale.x > 0.18 do continue   // drop any leftover large ring
                col[0] = u8(min(255, i32(col[0]) + 20))
                col[1] = u8(min(255, i32(col[1]) + 15))
                draw_oriented_disc(fs.pos, fs.up, fs.scale.x * 0.9, {col[0], col[1], col[2], 255})
            } else if fs.kind == .Sway {
                draw_oriented_blade(fs.pos, fs.right, fs.up, fs.scale.x, fs.scale.y, {col[0],col[1],col[2],255})
            } else {
                draw_oriented_disc(fs.pos, fs.up, fs.scale.x * 2, {col[0],col[1],col[2],255})
            }
        }

        rl.EndMode3D()
        rl.EndTextureMode()

        img := rl.LoadImageFromTexture(target.texture)
        rl.ImageFlipVertical(&img)
        
        // apply_palette_and_outline(&img)
        post_apply(&img)

        rl.UpdateTexture(target.texture, img.data)
        rl.UnloadImage(img)

        rl.BeginDrawing()
        rl.ClearBackground(rl.BLACK)
        src := rl.Rectangle{0, 0, f32(ART_W), f32(ART_H)}
        dst := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
        rl.DrawTexturePro(target.texture, src, dst, {0, 0}, 0, rl.WHITE)

        rl.DrawText("Hello island (closer to original SDF)", 10, 10, 20, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%d surfels + %d free | drag orbit, wheel zoom",
            len(surfels), len(free.items)), 10, 35, 18, {180,180,180,255})
        rl.EndDrawing()
    }
}