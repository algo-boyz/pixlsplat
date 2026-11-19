package pixlsplat

import "core:math"
import "core:math/linalg"

M_GRASS  :: 0
M_ROCK   :: 1
M_TRUNK  :: 2
M_LEAVES :: 3
M_POST   :: 4
M_LAMP   :: 5

// Exact palette from the original (no runtime conversion at global scope)
PALETTE := [12][4]u8{
    {10,  10,  24,  255}, // #0a0a18
    {23,  21,  44,  255}, // #17152c
    {43,  39,  64,  255}, // #2b2740
    {76,  74,  96,  255}, // #4c4a60
    {128, 126, 146, 255}, // #807e92
    {74,  42,  38,  255}, // #4a2a26
    {31,  74,  56,  255}, // #1f4a38
    {79,  154, 74,  255}, // #4f9a4a
    {168, 216, 96,  255}, // #a8d860
    {200, 55,  45,  255}, // #c8372d
    {255, 207, 90,  255}, // #ffcf5a
    {255, 241, 192, 255}, // #fff1c0
}

// Extra colours that only translucent light (halos, beams, smoke) may take.
// They are appended after PALETTE in the shader (paletteSize vs surfaceSize).
GLOW_PALETTE := [2][4]u8{
    {0x4e, 0x3f, 0x3a, 255}, // #4e3f3a
    {0x8a, 0x73, 0x56, 255}, // #8a7356
}

build_hello :: proc() -> (surfels: [dynamic]Surfel, free: Free_List) {
    c := make_ctx(1.3, 0.3, 42)
    defer delete(c.s.adds)

    island(&c, M_GRASS, M_ROCK, bump = 0.03)

    // Tree
    shape_add_cone(&c.s, {0, -0.05, 0}, {0.05, 0.75, 0}, 0.09, 0.05, M_TRUNK)

    blobs := [3][4]f32{
        { 0.05, 1.00,  0.00, 0.38},
        {-0.22, 0.85,  0.12, 0.28},
        { 0.28, 0.82, -0.10, 0.26},
    }
    // Original: displace(ellipsoid, -0.06*(vnoise3(*9)-0.5))
    // Approximate with amp=-0.06 on vnoise (center of the -0.06*(v-0.5) range is similar detail)
    for b in blobs {
        add_displaced_ellipsoid(
            &c.s,
            {b[0], b[1], b[2]},
            {b[3], b[3]*0.8, b[3]},
            -0.06,
            9,
            M_LEAVES,
            0.08,
        )
    }
    ctx_grow(&c, 1.45)

    // Lantern
    shape_add_cone(&c.s, {0.6, -0.03, 0.35}, {0.6, 0.50, 0.35}, 0.022, 0.016, M_POST)
    shape_add_box (&c.s, {0.6,  0.56, 0.35}, {0.05, 0.06, 0.05}, 0.01, M_LAMP)

    rocks(&c, M_ROCK, 5, 0.1)

    // Colours, as in the original paint(): the surface colour plus flags.
    // Lighting and palette snapping happen in bake().
    paint :: proc(mat: int, p, n: [3]f32) -> Paint {
        switch mat {
        case M_LAMP:
            return {c = hex_rgb(0xffcf5a), emissive = true}
        case M_POST:
            return {c = hex_rgb(0x2b2740)}
        case M_TRUNK:
            return {c = mul_rgb(hex_rgb(0x4a2a26), 0.85 + 0.3 * vnoise3(p.x*30, p.y*5, p.z*30))}
        case M_LEAVES:
            if vnoise3(p.x*12, p.y*12, p.z*12) > 0.55 {
                return {c = hex_rgb(0xa8d860), leaf = true}
            }
            return {c = hex_rgb(0x4f9a4a), leaf = true}
        case M_ROCK:
            return {c = mul_rgb(hex_rgb(0x807e92), 0.8 + 0.4 * vnoise3(p.x*8, p.y*10, p.z*8))}
        case: // grass
            if n.y < 0.5 {
                return {c = hex_rgb(0x4a2a26)}
            }
            t := sstep(0.3, 0.7, vnoise3(p.x*4, 2, p.z*4))
            return {c = mix_rgb(hex_rgb(0x1f4a38), hex_rgb(0x4f9a4a), t)}
        }
        return {c = {1, 1, 1}}
    }

    minp := [3]f32{-c.R - 0.6, -0.4 - c.R*1.1, -c.R - 0.6}
    maxp := [3]f32{ c.R + 0.6,  c.top + 0.1,     c.R + 0.6}
    surfels = sample_surface(c.s, minp, maxp, SURFEL_H)

    // Lantern: point light with its own visibility rays (see light.odin)
    lights := [?]Light{
        {pos = {0.6, 0.56, 0.35}, color = {1.0, 0.72, 0.32}, power = 1.0},
    }
    lighting := make_lighting(c.s, lights[:], PALETTE[:])
    defer delete_lighting(&lighting)
    bake(&c, surfels[:], paint, &lighting)

    // Free list owns its own RNG copy
    free = make_free(c.rnd)

    grass_cols := [][2][4]u8{
        {{31, 74, 56, 255}, {79, 154, 74, 255}},
        {{79, 154, 74, 255}, {168, 216, 96, 255}},
    }
    free_grass(&free, &c, 1500, grass_cols, r = 1.25)

    flower_cols := [][4]u8{
        {255, 241, 192, 255},
        {200,  55,  45, 255},
    }
    free_dots(&free, &c, 40, flower_cols)

    free_glow(&free, 0.6, 0.56, 0.35, 0.28, {255, 207, 90, 255})

    return
}