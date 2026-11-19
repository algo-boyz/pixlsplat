package pixlsplat

import "core:math"
import "core:math/linalg"

Free_Kind :: enum { Lit, Emissive, Sway, Glow, Litter }

Free_Splat :: struct {
    pos:   [3]f32,
    scale: [3]f32,
    right, up: [3]f32,
    color: [4]u8,
    kind:  Free_Kind,
    alpha: f32,
}

Free_List :: struct {
    items: [dynamic]Free_Splat,
    rnd:   Mulberry32,          // owned copy, no dangling pointer
}

make_free :: proc(rnd: Mulberry32) -> Free_List {
    return {
        items = make([dynamic]Free_Splat),
        rnd   = rnd,
    }
}

// shade.js upNormal path multiplies free blade/litter albedo by 0.74.
LEAF_UP_FACTOR :: f32(0.74)

_dim_u8 :: proc(c: [4]u8, k: f32) -> [4]u8 {
    return {
        u8(math.clamp(f32(c[0]) * k, 0, 255)),
        u8(math.clamp(f32(c[1]) * k, 0, 255)),
        u8(math.clamp(f32(c[2]) * k, 0, 255)),
        c[3],
    }
}

free_blade :: proc(f: ^Free_List, x, y, z, h, w: f32, dark, light: [4]u8) {
    a    := mulberry32_next(&f.rnd) * math.TAU
    lean := 0.15 + mulberry32_next(&f.rnd) * 0.3
    dir  := linalg.normalize([3]f32{math.cos(a)*lean, 1, math.sin(a)*lean})

    right := linalg.normalize(linalg.cross(dir, {0,0,1}))
    if linalg.vector_length(right) < 0.1 {
        right = linalg.normalize(linalg.cross(dir, {1,0,0}))
    }

    // Lit as if facing up (leaf:true / upNormal), then darkened
    dk := _dim_u8(dark, LEAF_UP_FACTOR)
    lt := _dim_u8(light, LEAF_UP_FACTOR)

    append(&f.items, Free_Splat{
        pos   = {x + dir.x*h*0.25, y + h*0.25, z + dir.z*h*0.25},
        // scale: half-extents of the hard ellipse (1.5-sigma of stretched Gaussian)
        scale = {w, h*0.3, w},
        right = right,
        up    = dir,
        color = dk,
        kind  = .Sway,
        alpha = 1,
    })
    append(&f.items, Free_Splat{
        pos   = {x + dir.x*h*0.7, y + h*0.68, z + dir.z*h*0.7},
        scale = {w*0.8, h*0.3, w*0.8},
        right = right,
        up    = dir,
        color = lt,
        kind  = .Sway,
        alpha = 1,
    })
}

// Now takes the context explicitly so we never store a pointer
free_grass :: proc(
    f: ^Free_List,
    c: ^Ctx,
    n: int,
    colors: [][2][4]u8,
    r: f32 = 1.25,
) {
    for i, tries := 0, 0; i < n && tries < n * 60; tries += 1 {
        a  := mulberry32_next(&f.rnd) * math.TAU
        rr := math.sqrt(mulberry32_next(&f.rnd)) * r
        x  := math.cos(a) * rr
        z  := math.sin(a) * rr
        y  := ctx_height(c, x, z)

        if shape_dist(c.s, {x, y + 0.06, z}) < 0.035 {
            continue
        }

        pair := colors[int(mulberry32_next(&f.rnd) * f32(len(colors))) % len(colors)]
        h := 0.08 + mulberry32_next(&f.rnd) * 0.12
        free_blade(f, x, y - 0.01, z, h, 0.011, pair[0], pair[1])
        i += 1
    }
}

free_dots :: proc(
    f: ^Free_List,
    c: ^Ctx,
    n: int,
    colors: [][4]u8,
    y_range: [2]f32 = {0.12, 0.22},
    size: f32 = 0.016,
    r: f32 = 1.2,
) {
    for i, tries := 0, 0; i < n && tries < n * 60; tries += 1 {
        a  := mulberry32_next(&f.rnd) * math.TAU
        rr := math.sqrt(mulberry32_next(&f.rnd)) * r
        x  := math.cos(a) * rr
        z  := math.sin(a) * rr
        y0 := ctx_height(c, x, z)
        if shape_dist(c.s, {x, y0 + 0.06, z}) < 0.035 {
            continue
        }
        y := y0 + y_range[0] + mulberry32_next(&f.rnd) * (y_range[1] - y_range[0])
        col := colors[int(mulberry32_next(&f.rnd) * f32(len(colors))) % len(colors)]
        append(&f.items, Free_Splat{
            pos   = {x, y, z},
            scale = {size, size, size},
            right = {1,0,0},
            up    = {0,1,0},
            color = col,
            kind  = .Lit,
            alpha = 1,
        })
        i += 1
    }
}


// Flat leaves / petals on the ground (original free.litter).
free_litter :: proc(
    f: ^Free_List,
    c: ^Ctx,
    n: int,
    colors: [][4]u8,
    size: f32 = 0.022,
    r: f32 = 1.2,
) {
    for i, tries := 0, 0; i < n && tries < n * 60; tries += 1 {
        a  := mulberry32_next(&f.rnd) * math.TAU
        rr := math.sqrt(mulberry32_next(&f.rnd)) * r
        x  := math.cos(a) * rr
        z  := math.sin(a) * rr
        y  := ctx_height(c, x, z)
        if shape_dist(c.s, {x, y + 0.06, z}) < 0.03 {
            continue
        }
        col := _dim_u8(colors[int(mulberry32_next(&f.rnd) * f32(len(colors))) % len(colors)], LEAF_UP_FACTOR)
        // Thin axis up: lying flat. scale = (size, size*0.7, 0.004) in original.
        append(&f.items, Free_Splat{
            pos   = {x, y + 0.012, z},
            scale = {size, size * 0.7, 0.004},
            right = {1, 0, 0},
            up    = {0, 0, 1}, // thin axis is local Z after FLAT quat; we draw in XZ plane
            color = col,
            kind  = .Litter,
            alpha = 1,
        })
        i += 1
    }
}

free_glow :: proc(f: ^Free_List, x, y, z, radius: f32, col: [4]u8) {
    // same rings as scene-kit.js: [scale factor, alpha], widest and faintest first
    rings := [3][2]f32{{1.0, 0.14}, {0.62, 0.30}, {0.32, 0.55}}
    for pair in rings {
        k, a := pair[0], pair[1]
        append(&f.items, Free_Splat{
            pos   = {x, y, z},
            scale = {radius*k, radius*k, radius*k},
            right = {1,0,0},
            up    = {0,1,0},
            color = col,
            kind  = .Glow,
            alpha = a,
        })
    }
}