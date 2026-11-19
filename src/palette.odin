package pixlsplat

// A palette for a model (or island) that did not ship one: k-means over the
// surface colours at the brightness levels the lighting produces.
// Port of src/viewer/palette.js from cobanov/pixelart-gaussiansplat.

import "core:slice"

// The viewer's clear colour (BACKGROUND in viewer.js). It must be the first
// palette entry so solid pixels never snap to it.
VIEWER_BACKGROUND :: [4]u8{0x07, 0x08, 0x0c, 255}

// Number of palette colours for a model and for the island it stands on.
MODEL_PALETTE_COLOURS  :: 28
ISLAND_PALETTE_COLOURS :: 10

// Per-model brightness, from public/models/models.json ("light=1.3" for the
// four creatures, default 1 otherwise).
model_exposure :: proc(name: string) -> f32 {
    switch name {
    case "minotaur", "toad", "vulture", "hyena": return 1.3
    }
    return 1.0
}

// colors: albedo of every surfel · k: palette size · exposure: light multiplier
// lit: colour of a point light in the scene, so lit tones get entries too.
extract_palette :: proc(
    colors: [][4]u8,
    k: int,
    exposure: f32 = 1,
    lit: [3]f32 = {},
    has_lit := false,
) -> [dynamic][4]u8 {
    out := make([dynamic][4]u8)
    count := len(colors)
    if count == 0 || k <= 0 do return out

    samples := make([dynamic][3]f32, 0, (count / max(1, count / 9000) + 1) * 5)
    defer delete(samples)

    step := max(1, count / 9000)
    levels := [4]f32{MODEL_AMBIENT_LOW, 0.55, 0.85, MODEL_AMBIENT_HIGH + MODEL_DIFFUSE}
    for i := 0; i < count; i += step {
        c := [3]f32{f32(colors[i][0]) / 255, f32(colors[i][1]) / 255, f32(colors[i][2]) / 255}
        for lv in levels {
            append(&samples, [3]f32{
                min(1, c[0] * lv * exposure),
                min(1, c[1] * lv * exposure),
                min(1, c[2] * lv * exposure),
            })
        }
        if has_lit && i % (step * 3) == 0 {
            s: [3]f32
            for ch in 0..<3 {
                s[ch] = min(1, c[ch] * 0.7 * exposure + (c[ch] * 0.85 + 0.1) * lit[ch] * 0.45)
            }
            append(&samples, s)
        }
    }
    if len(samples) == 0 do return out

    slice.sort_by(samples[:], proc(a, b: [3]f32) -> bool {
        return a[0] + a[1] * 2 + a[2] < b[0] + b[1] * 2 + b[2]
    })

    n := len(samples)
    centres := make([][3]f32, k)
    defer delete(centres)
    for i in 0..<k {
        centres[i] = samples[min(n - 1, int((f32(i) + 0.5) / f32(k) * f32(n)))]
    }

    sums   := make([][3]f32, k)
    counts := make([]int, k)
    defer delete(sums)
    defer delete(counts)
    for _ in 0..<10 {
        for i in 0..<k {
            sums[i]   = {}
            counts[i] = 0
        }
        for s in samples {
            best := 0
            best_d: f32 = 1e9
            for c, ci in centres {
                dx, dy, dz := s[0] - c[0], s[1] - c[1], s[2] - c[2]
                d := dx * dx + dy * dy + dz * dz
                if d < best_d {
                    best_d = d
                    best = ci
                }
            }
            sums[best]   += s
            counts[best] += 1
        }
        for i in 0..<k {
            if counts[i] > 0 do centres[i] = sums[i] / f32(counts[i])
        }
    }

    for c in centres {
        append(&out, [4]u8{to_u8(c[0]), to_u8(c[1]), to_u8(c[2]), 255})
    }
    return out
}

// The palette viewer.js builds for a model scene: the clear colour first, the
// particle colours, then k-means colours for the model and for its island
// (the island has its own small budget so it never takes colours from the model).
// Fog, shaft and ray particles are translucent light and do not add colours.
model_scene_palette :: proc(
    particles: ^Particle_System,
    model_cols, island_cols: [][4]u8,
    exposure: f32,
    lit: [3]f32,
    has_lit: bool,
) -> [dynamic][4]u8 {
    pal := make([dynamic][4]u8)
    append(&pal, VIEWER_BACKGROUND)
    for p in particles.items {
        #partial switch p.mode {
        case .Fog, .Shaft, .Ray: continue
        }
        append(&pal, [4]u8{p.color[0], p.color[1], p.color[2], 255})
    }
    m := extract_palette(model_cols, MODEL_PALETTE_COLOURS, exposure, lit, has_lit)
    defer delete(m)
    for c in m do append(&pal, c)
    if len(island_cols) > 0 {
        isl := extract_palette(island_cols, ISLAND_PALETTE_COLOURS, 1, lit, has_lit)
        defer delete(isl)
        for c in isl do append(&pal, c)
    }
    return pal
}
