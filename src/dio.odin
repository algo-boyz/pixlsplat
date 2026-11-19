package pixlsplat

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"

// .dio world format (PSD1), see tools/lib/files.mjs / viewer/world.js:
//   magic "PSD1" | u32 json_len | json meta (padded to 4)
//   count × f32×3  positions
//   count × i8×4   normals xyz (*127) + emissive flag
//   count × u8×4   colour rgb (+ pad)
//   free  × f32×10 position, scale, quaternion
//   free  × u8×4   rgb + (kind:2 | opacity:6)

Dio_Meta_Light :: struct {
    pos:   [3]f32,
    color: [3]f32,
    power: f32,
}

Dio_Meta_Particle :: struct {
    mode:    string,
    n:       int,
    halo:    bool,
    still:   bool,
    alpha:   f32,
    colors:  []string,
    center:  [3]f32,
    spread:  [3]f32,
    height:  f32,
    origins: [][3]f32,
    points:  [][3]f32,
    // shafts explicit splats: [x,y,z,sx,sy,sz,alpha, qx,qy,qz,qw?]
    splats:  [][]f32,
}

Dio_Meta :: struct {
    count:      int,
    free:       int,
    h:          f32,
    R:          f32,
    top:        f32,
    bottom:     f32,
    baked:      bool,
    scene:      bool,
    elev:       f32,
    dither:     f32,   // -1 when the scene does not set one (see load_dio)
    palette:    []string,
    glowPalette: []string `json:"glowPalette"`,
    background: string,
    lights:     []Dio_Meta_Light,
    particles:  []Dio_Meta_Particle,
}

Dio_World :: struct {
    meta:     Dio_Meta,
    surfels:  [dynamic]Surfel,
    free:     [dynamic]Free_Splat,
    particles: Particle_System,
    palette:  [dynamic][4]u8,
    glow_pal: [dynamic][4]u8,
    background: [4]u8,
}

hex_to_u8 :: proc(hex: string) -> [4]u8 {
    h := hex
    if len(h) > 0 && h[0] == '#' do h = h[1:]
    if len(h) < 6 do return {0, 0, 0, 255}
    parse :: proc(s: string) -> u8 {
        v: u32
        for c in transmute([]u8)s {
            v <<= 4
            switch c {
            case '0'..='9': v |= u32(c - '0')
            case 'a'..='f': v |= u32(c - 'a' + 10)
            case 'A'..='F': v |= u32(c - 'A' + 10)
            }
        }
        return u8(v)
    }
    return {parse(h[0:2]), parse(h[2:4]), parse(h[4:6]), 255}
}

// Quaternion (x,y,z,w) → right and up axes for an oriented splat whose thin
// axis is local +Z (matches Spark / original free splat packing).
quat_axes :: proc(q: [4]f32) -> (right, up, normal: [3]f32) {
    x, y, z, w := q[0], q[1], q[2], q[3]
    // columns of rotation matrix for unit quat
    right = {
        1 - 2*(y*y + z*z),
        2*(x*y + w*z),
        2*(x*z - w*y),
    }
    up = {
        2*(x*y - w*z),
        1 - 2*(x*x + z*z),
        2*(y*z + w*x),
    }
    normal = {
        2*(x*z + w*y),
        2*(y*z - w*x),
        1 - 2*(x*x + y*y),
    }
    // free splat thin axis is local Z → normal; scale uses (sx,sy,sz)
    return right, up, normal
}

load_dio :: proc(path: string, ground_y: f32 = 0) -> (world: Dio_World, ok: bool) {
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil || len(data) < 8 {
        fmt.eprintf("dio: cannot read %s\n", path)
        return {}, false
    }
    defer delete(data)

    if string(data[0:4]) != "PSD1" {
        fmt.eprintf("dio: bad magic in %s\n", path)
        return {}, false
    }
    json_len := int((^u32)(&data[4])^)
    if 8+json_len > len(data) do return {}, false

    meta: Dio_Meta
    meta.dither = -1
    if jerr := json.unmarshal(data[8:8+json_len], &meta); jerr != nil {
        fmt.eprintf("dio: json parse failed: %v\n", jerr)
        return {}, false
    }
    world.meta = meta

    n := meta.count
    n_free := meta.free
    off := 8 + json_len
    need := off + n*20 + n_free*40 + n_free*4
    if need > len(data) {
        fmt.eprintf("dio: truncated file (need %d have %d)\n", need, len(data))
        return {}, false
    }

    pos := (cast([^]f32)raw_data(data[off:]))[:n*3]
    nor := (cast([^]i8)raw_data(data[off+n*12:]))[:n*4]
    rgba := data[off+n*16:][:n*4]
    free_geom := (cast([^]f32)raw_data(data[off+n*20:]))[:n_free*10]
    free_rgba := data[off+n*20+n_free*40:][:n_free*4]

    world.surfels = make([dynamic]Surfel, 0, n)
    for i in 0..<n {
        p := [3]f32{pos[i*3], pos[i*3+1] + ground_y, pos[i*3+2]}
        nx := f32(nor[i*4]) / 127
        ny := f32(nor[i*4+1]) / 127
        nz := f32(nor[i*4+2]) / 127
        nrm := [3]f32{nx, ny, nz}
        if linalg.vector_length(nrm) > 1e-5 do nrm = linalg.normalize(nrm)
        append(&world.surfels, Surfel{
            pos = p,
            normal = nrm,
            color = {rgba[i*4], rgba[i*4+1], rgba[i*4+2], 255},
            emissive = nor[i*4+3] != 0,
        })
    }

    world.free = make([dynamic]Free_Splat, 0, n_free)
    for i in 0..<n_free {
        base := i * 10
        posf := [3]f32{free_geom[base], free_geom[base+1] + ground_y, free_geom[base+2]}
        scale := [3]f32{free_geom[base+3], free_geom[base+4], free_geom[base+5]}
        quat := [4]f32{free_geom[base+6], free_geom[base+7], free_geom[base+8], free_geom[base+9]}
        right, up, _ := quat_axes(quat)
        packed := free_rgba[i*4+3]
        kind_i := int(packed & 3)
        opacity := f32(packed >> 2) / 63.0
        kind: Free_Kind
        switch kind_i {
        case 0: kind = .Lit
        case 1: kind = .Emissive
        case 2: kind = .Sway
        case 3: kind = .Glow
        }
        append(&world.free, Free_Splat{
            pos = posf,
            scale = scale,
            right = right,
            up = up,
            color = {free_rgba[i*4], free_rgba[i*4+1], free_rgba[i*4+2], 255},
            kind = kind,
            alpha = kind == .Glow ? opacity : 1,
        })
    }

    // palette
    for h in meta.palette do append(&world.palette, hex_to_u8(h))
    for h in meta.glowPalette do append(&world.glow_pal, hex_to_u8(h))
    if meta.background != "" {
        world.background = hex_to_u8(meta.background)
    } else if len(world.palette) > 0 {
        world.background = world.palette[0]
    }

    // particles from meta (port of the particle block in viewer/world.js)
    world.particles = particle_system_make()
    lcg: u32 = 99                   // world.js's rnd(): same seed and generator
    seeds := mulberry32_new(1234)   // stable per-particle motion seeds
    top := meta.top
    for ps in meta.particles {
        mode := particle_mode_from_string("twinkle" if ps.still else ps.mode)
        cols := make([dynamic][4]u8)
        defer delete(cols)
        for h in ps.colors do append(&cols, hex_to_u8(h))
        if len(cols) == 0 do append(&cols, [4]u8{255, 255, 255, 255})
        pick :: proc(cols: [][4]u8, lcg: ^u32) -> [4]u8 {
            return cols[int(lcg_next(lcg) * f32(len(cols))) % len(cols)]
        }

        c      := ps.center
        alpha  := ps.alpha if ps.alpha > 0 else 0.95
        vy     := ps.spread[1] if ps.spread != ([3]f32{}) else (ps.height if ps.height > 0 else 0.6)
        centre := [3]f32{c[0], c[1] + ground_y, c[2]}      // what the motion orbits
        v      := [3]f32{meta.R, vy, 0}
        ident  := [4]f32{}
        tilt   := [4]f32{0, 0, math.sin(f32(-0.15)), math.cos(f32(-0.15))}   // Euler z = -0.3

        // explicit shapes, relative to the centre (lighthouse beam, shrine rays)
        if len(ps.splats) > 0 {
            for b in ps.splats {
                if len(b) < 7 do continue
                rot := ident
                if len(b) >= 11 do rot = {b[7], b[8], b[9], b[10]}
                r := [3]f32{mulberry32_next(&seeds), mulberry32_next(&seeds), mulberry32_next(&seeds)}
                particle_put(
                    &world.particles, mode,
                    {c[0] + b[0], c[1] + b[1] + ground_y, c[2] + b[2]},
                    {b[3], b[4], b[5]}, rot, b[6], pick(cols[:], &lcg), centre, v, r,
                )
            }
            continue
        }

        // where the particles start
        spots := make([dynamic][3]f32)
        defer delete(spots)
        if len(ps.points) > 0 {
            for p in ps.points do append(&spots, p)
        } else if len(ps.origins) > 0 {
            for o in ps.origins {
                for _ in 0..<ps.n do append(&spots, o)
            }
        } else {
            for _ in 0..<ps.n {
                if ps.spread != ([3]f32{}) {
                    x := c[0] + (lcg_next(&lcg) - 0.5) * 2 * ps.spread[0]
                    y := c[1] + lcg_next(&lcg) * ps.spread[1]
                    z := c[2] + (lcg_next(&lcg) - 0.5) * 2 * ps.spread[2]
                    append(&spots, [3]f32{x, y, z})
                } else {
                    ang := lcg_next(&lcg) * 6.28
                    rad := math.sqrt(lcg_next(&lcg)) * meta.R * (0.7 if mode == .Shaft else 1)
                    y: f32
                    #partial switch mode {
                    case .Fog:   y = 0.05 + lcg_next(&lcg) * 0.22
                    case .Shaft: y = top * 0.55
                    case:        y = 0.06 + lcg_next(&lcg) * (top + 0.3)
                    }
                    append(&spots, [3]f32{math.cos(ang) * rad, y, math.sin(ang) * rad})
                }
            }
        }

        for o in spots {
            pos := [3]f32{o[0], o[1] + ground_y, o[2]}
            r   := [3]f32{mulberry32_next(&seeds), mulberry32_next(&seeds), mulberry32_next(&seeds)}
            #partial switch mode {
            case .Fog:    // low mist: big, flat, faint
                sx := 0.3 + lcg_next(&lcg) * 0.25
                sz := 0.3 + lcg_next(&lcg) * 0.25
                particle_put(&world.particles, mode, pos, {sx, 0.035, sz}, ident, alpha, pick(cols[:], &lcg), centre, v, r)
            case .Shaft:  // tall, slightly tilted light
                sx := 0.07 + lcg_next(&lcg) * 0.06
                sz := 0.07 + lcg_next(&lcg) * 0.06
                particle_put(&world.particles, mode, pos, {sx, top * 0.75, sz}, tilt, alpha, pick(cols[:], &lcg), centre, v, r)
            case:
                k: f32
                #partial switch mode {
                case .Smoke: k = meta.h * 0.9
                case .Leaf:  k = meta.h * 0.5
                case:        k = meta.h * (0.28 + lcg_next(&lcg) * 0.14)
                }
                sy := k * 0.6 if mode == .Leaf else k
                particle_put(&world.particles, mode, pos, {k, sy, k}, ident, alpha, pick(cols[:], &lcg), centre, v, r)
                if ps.halo {
                    particle_put(&world.particles, mode, pos, {k * 5.5, k * 5.5, k * 5.5}, ident, 0.18, pick(cols[:], &lcg), centre, v, r)
                }
            }
        }
    }

    ok = true
    return
}

particle_mode_from_string :: proc(s: string) -> Particle_Mode {
    switch s {
    case "rise": return .Rise
    case "float": return .Float
    case "blink": return .Blink
    case "twinkle": return .Twinkle
    case "drift": return .Drift
    case "leaf": return .Leaf
    case "smoke": return .Smoke
    case "beam": return .Beam
    case "fog": return .Fog
    case "shaft": return .Shaft
    case "ray": return .Ray
    case "sway": return .Sway
    case "pulse": return .Pulse
    }
    return .Float
}

dio_world_destroy :: proc(w: ^Dio_World) {
    delete(w.surfels)
    delete(w.free)
    particle_system_destroy(&w.particles)
    delete(w.palette)
    delete(w.glow_pal)
}

// world.js's rnd(): a 32-bit LCG in [0, 1).
lcg_next :: proc(seed: ^u32) -> f32 {
    seed^ = seed^ * 1664525 + 1013904223
    return f32(f64(seed^) / 4294967296.0)
}
