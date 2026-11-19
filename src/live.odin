package pixlsplat

// Live point lights and per-frame shading of world surfels.
// Port of setLights() and the world paths of shadeFx() in src/render/shade.js.
//
//   baked scenes (caravan, lighthouse, shrine, hello): the surfel colour already
//     holds sun, shadows and lamps (see light.odin). Only a little live lamp
//     light is added on top, so the flame flickers.
//   creature islands (not baked): the .dio holds albedo. The island is lit every
//     frame like the model: ambient + key light + view term, cel bands, cool
//     shadows / warm light, and the same lamps.
//
// The world's colours as loaded are kept in `live.base`, so every frame starts
// from them instead of accumulating light.

import "core:math"
import "core:math/linalg"

MAX_LIVE_LIGHTS :: 4

// Beyond this distance a lamp adds under 1% (1/(1+12 d^2) at d = 2), so the
// per-surfel loop skips it. The original shader has no cut-off.
LIVE_LIGHT_RANGE :: f32(2.0)

// Island cel bands (the model's "bands" uniform is shared with the world).
WORLD_BANDS :: 5

Live_Light :: struct {
    pos:   [3]f32,
    color: [3]f32,   // colour x power x flicker
}

Live :: struct {
    sources: [dynamic]Dio_Meta_Light,    // the world's lights, y already shifted by ground_y
    lights:  [MAX_LIVE_LIGHTS]Live_Light, // this frame's, flickering
    count:   int,
    base:    [dynamic][4]u8,             // world surfel colours as loaded
    world_n: int,                        // surfels[0:world_n] belong to the world
    baked:   bool,
}

live: Live

live_begin :: proc() {
    clear(&live.sources)
    clear(&live.base)
    live.world_n = 0
    live.count   = 0
    live.baked   = false
}

live_destroy :: proc() {
    delete(live.sources)
    delete(live.base)
}

// Remember the world's colours (call once its surfels are in the draw list).
live_capture :: proc(world_surfels: []Surfel, baked: bool) {
    clear(&live.base)
    for s in world_surfels do append(&live.base, s.color)
    live.world_n = len(world_surfels)
    live.baked   = baked
}

// Take a loaded .dio's lights and colours. ground_y: where its y = 0 was placed.
live_add_world :: proc(world: ^Dio_World, world_surfels: []Surfel, ground_y: f32) {
    for l in world.meta.lights {
        ll := l
        ll.pos.y += ground_y
        append(&live.sources, ll)
    }
    live_capture(world_surfels, world.meta.baked)
}

// Flicker like flames (setLights in shade.js).
live_update :: proc(t: f32) {
    n := min(len(live.sources), MAX_LIVE_LIGHTS)
    for k in 0..<n {
        l  := live.sources[k]
        fk := f32(k)
        flicker := l.power * (0.86 + 0.1 * math.sin(t * 11 + fk * 2) + 0.06 * math.sin(t * 23.7 + fk))
        live.lights[k] = {pos = l.pos, color = l.color * flicker}
    }
    live.count = n
}

// Light a lamp adds to an unbaked surface (pointLight in shade.js), in 0..255.
point_light_add :: proc(l: Live_Light, p, n: [3]f32, albedo: [4]u8) -> [3]f32 {
    to := l.pos - p
    d  := linalg.vector_length(to)
    if d < 1e-5 do return {}
    w := (max(linalg.dot(n, to / d), 0) * 0.85 + 0.15) / (1 + d * d * 9)
    return {
        (f32(albedo[0]) / 255 * 0.85 + 0.1) * l.color[0] * w * 255,
        (f32(albedo[1]) / 255 * 0.85 + 0.1) * l.color[1] * w * 255,
        (f32(albedo[2]) / 255 * 0.85 + 0.1) * l.color[2] * w * 255,
    }
}

// An unbaked world surface (creature island), same lighting as the model but
// without back-face handling. Returns 0..255.
lit_world_color :: proc(albedo: [4]u8, p, n, cam_pos: [3]f32) -> [3]f32 {
    ndl := linalg.dot(n, SUN)
    facing: f32 = 0
    to_cam := cam_pos - p
    if dist := linalg.vector_length(to_cam); dist > 1e-5 {
        facing = linalg.dot(n, to_cam / dist)
    }
    hemi  := n.y * 0.5 + 0.5
    light := MODEL_AMBIENT_LOW + (MODEL_AMBIENT_HIGH - MODEL_AMBIENT_LOW) * hemi
    light += MODEL_DIFFUSE * max(ndl, 0) + 0.22 * max(facing, 0)
    bf := f32(WORLD_BANDS)
    light = (math.floor(light * bf) + 0.5) / bf

    tint := [3]f32{0.92, 0.95, 1.05} if ndl < 0 else [3]f32{1.04, 1.0, 0.95}
    col := [3]f32{
        f32(albedo[0]) * light * tint[0],
        f32(albedo[1]) * light * tint[1],
        f32(albedo[2]) * light * tint[2],
    }
    for k in 0..<live.count {
        col += point_light_add(live.lights[k], p, n, albedo)
    }
    return col
}

// Re-colour the world's surfels for this frame. `surfels` is the world part of
// the draw list. Emissive surfels keep their colour (draw_surfel boosts them).
live_shade_world :: proc(surfels: []Surfel, cam_pos: [3]f32) {
    n := min(live.world_n, len(surfels), len(live.base))
    for i in 0..<n {
        s    := &surfels[i]
        base := live.base[i]
        if s.emissive {
            s.color = base
            continue
        }
        col: [3]f32
        if live.baked {
            col = {f32(base[0]), f32(base[1]), f32(base[2])}
            lamp: [3]f32
            for k in 0..<live.count {
                lt := live.lights[k]
                to := lt.pos - s.pos
                d  := linalg.vector_length(to)
                if d > LIVE_LIGHT_RANGE || d < 1e-5 do continue
                w := (max(linalg.dot(s.normal, to / d), 0) * 0.8 + 0.2) / (1 + d * d * 12)
                lamp += lt.color * w
            }
            col += col * 0.4 * lamp
        } else {
            col = lit_world_color(base, s.pos, s.normal, cam_pos)
        }
        s.color = {
            u8(math.clamp(col[0], 0, 255)),
            u8(math.clamp(col[1], 0, 255)),
            u8(math.clamp(col[2], 0, 255)),
            255,
        }
    }
}
