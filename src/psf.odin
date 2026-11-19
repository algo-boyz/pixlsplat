package pixlsplat

// PSF1 model loader — format written by cobanov/pixelart-gaussiansplat
// tools/convert-model.mjs.
//
//   header  40 bytes
//     "PSF1" (4) | count u32 | spacing f32 | bbox 6×f32 | flags u32
//     flags bit0 = has skin weights
//   count × 3 f32   position
//   count × 4 i8    normal xyz (×127) + flags (1=emissive, 2=two-sided)
//   count × 4 u8    colour rgba
//   if skinned:
//     count × 4 u8  joint indices
//     count × 4 u8  joint weights (0–255)
//
// The model is recentred and scaled so its longest side is 2 units, matching
// the original viewer (src/viewer/model.js).
//
// Skin weights are retained on Psf_Model for a follow-up dual-quaternion
// skinning pass (port of src/viewer/rig.js). Static display works today.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"

Psf_Model :: struct {
    surfels:  [dynamic]Surfel,
    joints:   [][4]u8,   // nil when not skinned; parallel to surfels
    weights:  [][4]u8,   // nil when not skinned
    spacing:  f32,       // surfel lattice spacing in viewer units
    skinned:  bool,
    center:   [3]f32,    // original centre (before recenter)
    unit:     f32,       // scale applied (longest side → 2)
    size:     [3]f32,    // extents after scale
}

load_psf :: proc(path: string) -> (model: Psf_Model, ok: bool) {
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil || len(data) < 40 {
        fmt.eprintf("psf: cannot read %s\n", path)
        return {}, false
    }
    defer delete(data)

    if string(data[0:4]) != "PSF1" {
        fmt.eprintf("psf: bad magic in %s (want PSF1)\n", path)
        return {}, false
    }

    count   := int((^u32)(&data[4])^)
    spacing := (^f32)(&data[8])^
    bb0 := (^f32)(&data[12])^
    bb1 := (^f32)(&data[16])^
    bb2 := (^f32)(&data[20])^
    bb3 := (^f32)(&data[24])^
    bb4 := (^f32)(&data[28])^
    bb5 := (^f32)(&data[32])^
    flags   := (^u32)(&data[36])^
    skinned := (flags & 1) != 0

    base := 40
    need := base + count*12 + count*4 + count*4
    if skinned do need += count*4 + count*4
    if need > len(data) {
        fmt.eprintf("psf: truncated %s (need %d have %d)\n", path, need, len(data))
        return {}, false
    }

    pos  := (cast([^]f32)raw_data(data[base:]))[:count*3]
    nor  := (cast([^]i8)raw_data(data[base + count*12:]))[:count*4]
    rgba := data[base + count*16:][:count*4]

    center := [3]f32{
        (bb0 + bb3) * 0.5,
        (bb1 + bb4) * 0.5,
        (bb2 + bb5) * 0.5,
    }
    extent := [3]f32{bb3 - bb0, bb4 - bb1, bb5 - bb2}
    longest := max(extent[0], max(extent[1], extent[2]))
    if longest < 1e-6 do longest = 1
    unit := 2.0 / longest
    h := spacing * unit

    model.surfels = make([dynamic]Surfel, 0, count)
    model.spacing = h
    model.skinned = skinned
    model.center  = center
    model.unit    = unit
    model.size    = extent * unit

    for i in 0..<count {
        p := [3]f32{
            (pos[i*3]   - center[0]) * unit,
            (pos[i*3+1] - center[1]) * unit,
            (pos[i*3+2] - center[2]) * unit,
        }
        nx := f32(nor[i*4])   / 127
        ny := f32(nor[i*4+1]) / 127
        nz := f32(nor[i*4+2]) / 127
        nrm := [3]f32{nx, ny, nz}
        if linalg.vector_length(nrm) > 1e-5 do nrm = linalg.normalize(nrm)
        fl := nor[i*4+3]
        append(&model.surfels, Surfel{
            pos      = p,
            normal   = nrm,
            color    = {rgba[i*4], rgba[i*4+1], rgba[i*4+2], 255},
            ao       = 1,
            mat      = 0,
            emissive = (fl & 1) != 0,
        })
    }

    if skinned {
        jbase := base + count*20
        jidx  := data[jbase:][:count*4]
        jw    := data[jbase + count*4:][:count*4]
        model.joints  = make([][4]u8, count)
        model.weights = make([][4]u8, count)
        for i in 0..<count {
            model.joints[i]  = {jidx[i*4], jidx[i*4+1], jidx[i*4+2], jidx[i*4+3]}
            model.weights[i] = {jw[i*4],   jw[i*4+1],   jw[i*4+2],   jw[i*4+3]}
        }
    }

    ok = true
    fmt.printf("psf: %s → %d surfels, spacing %.4f, skinned=%v, size (%.2f %.2f %.2f)\n",
        path, count, h, skinned, model.size[0], model.size[1], model.size[2])
    return
}

psf_model_destroy :: proc(m: ^Psf_Model) {
    delete(m.surfels)
    if m.joints  != nil do delete(m.joints)
    if m.weights != nil do delete(m.weights)
    m^ = {}
}

// Simple lambertian + ambient shade for unbaked model surfels.
// light_dir should point *toward* the light. Mutates colours in place.
// Matches the spirit of the original shade.js modifier (ambient + one key).
shade_model_surfels :: proc(
    surfels: []Surfel,
    light_dir: [3]f32,
    light_strength: f32 = 0.55,
    ambient: f32 = 0.35,
) {
    ld := light_dir
    if linalg.vector_length(ld) > 1e-5 do ld = linalg.normalize(ld)
    for &s in surfels {
        if s.emissive do continue
        ndl := max(0, linalg.dot(s.normal, ld))
        k := ambient + light_strength * ndl
        k = math.clamp(k, 0, 1.4)
        s.color = {
            u8(math.clamp(f32(s.color[0]) * k, 0, 255)),
            u8(math.clamp(f32(s.color[1]) * k, 0, 255)),
            u8(math.clamp(f32(s.color[2]) * k, 0, 255)),
            255,
        }
    }
}
