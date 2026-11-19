package pixlsplat

// Window-relative art resolution and scene framing.
// Port of the sizing and camera logic of src/viewer/viewer.js:
//   - the pixel-art grid follows the window (N screen pixels per art pixel), so
//     a window that is not 16:9 no longer stretches the picture;
//   - the camera target, distance and fog come from the world's metadata
//     (R, top, bottom, elev), not from constants;
//   - the camera drifts around the scene until the user takes over.

import "core:math"
import rl "vendor:raylib"

PIXEL_SIZE_SCENE :: 4   // screen px per art px: scenes (default - 1, min 2)
PIXEL_SIZE_MODEL :: 5   // creature scenes
PIXEL_SIZE_MIN   :: 1
PIXEL_SIZE_MAX   :: 12

ORBIT_MIN_DIST :: f32(0.6)
ORBIT_MAX_DIST :: f32(14)

// What the camera needs to frame a world.
View :: struct {
    R:         f32,   // island radius
    top:       f32,   // highest point above the world's y = 0
    bottom:    f32,   // lowest point
    elev:      f32,   // camera height / horizontal distance when idle
    ground_y:  f32,   // where a model's feet sit (islands are placed at -size.y/2)
    height:    f32,   // model height (0 for stand-alone scenes)
    is_scene:  bool,  // stand-alone scene vs model on an island
    dither:    f32,   // scene's preferred dither, < 0 = keep the current setting
}

view := View{R = 1.3, top = 1.45, bottom = -1.5, elev = 0.22, dither = -1, is_scene = true}

view_default_pixel :: proc() -> i32 {
    return PIXEL_SIZE_SCENE if view.is_scene else PIXEL_SIZE_MODEL
}

// Orbit target (y) and the radius that has to fit on screen.
view_frame :: proc() -> (target_y, radius: f32) {
    low  := view.ground_y + view.bottom * 0.8
    high := view.ground_y + max(view.height, view.top) + 0.1
    if view.is_scene {
        low  = view.bottom * 0.8
        high = view.top + 0.1
    }
    target_y = (low + high) * 0.5
    radius = max(view.R * (1.12 if view.is_scene else 1.3), (high - low) * 0.5) * 1.03
    return
}

// Distance at which `radius` fits a vertical field of view of `fovy` degrees on a
// window of this aspect ratio (portrait windows pull back).
view_fit_distance :: proc(radius, fovy, aspect: f32) -> f32 {
    d := radius / math.tan(fovy * math.RAD_PER_DEG * 0.5) * 1.12
    return d * max(1, 0.9 / aspect)
}

// The idle orbit. t: seconds. Returns spherical camera coordinates around the target.
view_idle_orbit :: proc(t: f32, fit: f32) -> (yaw, pitch, dist: f32) {
    speed: f32 = 0.17 if view.is_scene else 0.25
    a := t * speed + 0.6
    horiz := fit * (1 + 0.04 * math.sin(t * 0.31))        // slow breathing zoom
    elev  := view.elev + 0.03 * math.sin(t * 0.23)
    // position = (sin a, elev, cos a) * horiz  ->  yaw = pi/2 - a
    yaw   = math.PI * 0.5 - a
    pitch = math.atan(elev)
    dist  = horiz * math.sqrt(1 + elev * elev)
    return
}

// Fog distances relative to how far away the whole scene is (shade.js setFog).
view_set_fog :: proc(cam_dist, radius: f32) {
    fog_start = cam_dist + radius * 0.1
    fog_end   = cam_dist + radius * 1.8
}

// Art-resolution size for a window.
view_art_size :: proc(win_w, win_h, pixel: i32) -> (w, h: i32) {
    p := max(1, pixel)
    return max(1, (win_w + p / 2) / p), max(1, (win_h + p / 2) / p)
}

// Render targets: the scene at 1x and 2x the art resolution (index = ss) and the
// art-resolution target the post pass resolves into.
Targets :: struct {
    scene: [3]rl.RenderTexture2D,
    art:   rl.RenderTexture2D,
    w, h:  i32,
}

targets_destroy :: proc(t: ^Targets) {
    if t.w == 0 do return
    for k in 1..=2 do rl.UnloadRenderTexture(t.scene[k])
    rl.UnloadRenderTexture(t.art)
    t.w, t.h = 0, 0
}

targets_resize :: proc(t: ^Targets, w, h: i32) {
    if t.w == w && t.h == h do return
    targets_destroy(t)
    for k in 1..=2 {
        t.scene[k] = rl.LoadRenderTexture(w * i32(k), h * i32(k))
        rl.SetTextureFilter(t.scene[k].texture, .POINT)
    }
    t.art = rl.LoadRenderTexture(w, h)
    rl.SetTextureFilter(t.art.texture, .POINT)
    t.w, t.h = w, h
}
