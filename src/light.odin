package pixlsplat

// Baked lighting for scenes (port of src/authoring/light.js).
//
// A scene does not move, so its light is worked out once, at build time, for
// every surfel, and the surfel stores the final palette colour:
//
//   - sun shadows: march from the surfel towards the sun through the scene's
//     signed distance field; a soft shadow from how close the ray passes
//   - sky ambient: 0.48 (facing down) .. 0.62 (facing up), scaled by AO
//   - lamp light with shadows: fires and lanterns light what they can see
//   - light through leaves: foliage is lit from both sides and only half
//     shadowed, so a canopy glows instead of turning into a dark ball
//   - cool shadows, warm light: the hue shifts with how lit the surface is
//   - colour ramps: the lit colour is matched to the palette in OKLab with a
//     penalty for leaving the surface's own hue (make_ramps / ramps_pick)

import "core:math"
import "core:math/linalg"

// Same direction as the original's key light: normalize(0.45, 0.8, 0.4).
SUN :: [3]f32{0.4494386, 0.7990019, 0.3995009}

LIGHT_AMB_LOW  :: f32(0.48)
LIGHT_AMB_HIGH :: f32(0.62)
LIGHT_SUN      :: f32(0.7)
LIGHT_LAMP     :: f32(1.0)

Light :: struct {
    pos:   [3]f32,
    color: [3]f32,
    power: f32,
}

// ---- colour ----------------------------------------------------------------

// 0xRRGGBB -> 0..1 floats, like rgb("#rrggbb") in the original
hex_rgb :: proc(h: u32) -> [3]f32 {
    return {f32((h >> 16) & 255) / 255, f32((h >> 8) & 255) / 255, f32(h & 255) / 255}
}

rgbf :: proc(c: [4]u8) -> [3]f32 {
    return {f32(c[0]) / 255, f32(c[1]) / 255, f32(c[2]) / 255}
}

to_u8 :: proc(v: f32) -> u8 {
    return u8(math.clamp(v * 255 + 0.5, 0, 255))
}

to_lin :: proc(c: f32) -> f32 {
    if c <= 0.04045 do return c / 12.92
    return math.pow((c + 0.055) / 1.055, 2.4)
}

oklab :: proc(c: [3]f32) -> [3]f32 {
    r := to_lin(max(0, c[0]))
    g := to_lin(max(0, c[1]))
    b := to_lin(max(0, c[2]))
    third: f32 = 1.0 / 3.0
    l := math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, third)
    m := math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, third)
    s := math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, third)
    return {
        0.2104542553 * l + 0.793617785  * m - 0.0040720468 * s,
        1.9779984951 * l - 2.428592205  * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.808675766  * s,
    }
}

// hue as a direction in the a/b plane, shrunk towards 0 for greys so that
// greys and slightly tinted darks count as the same family
hue_dir :: proc(lab: [3]f32) -> [2]f32 {
    c := math.hypot(lab[1], lab[2])
    k := 1 / (c + 0.035)
    return {lab[1] * k, lab[2] * k}
}

Ramps :: struct {
    cols:         [][3]f32,
    labs:         [][3]f32,
    dirs:         [][2]f32,
    hue_penalty:  f32,
}

// palette: the first entry is the background and is never picked
make_ramps :: proc(palette: [][4]u8, hue_penalty: f32 = 0.12) -> Ramps {
    n := max(len(palette) - 1, 0)
    r := Ramps{
        cols        = make([][3]f32, n),
        labs        = make([][3]f32, n),
        dirs        = make([][2]f32, n),
        hue_penalty = hue_penalty,
    }
    for i in 0..<n {
        r.cols[i] = rgbf(palette[i + 1])
        r.labs[i] = oklab(r.cols[i])
        r.dirs[i] = hue_dir(r.labs[i])
    }
    return r
}

delete_ramps :: proc(r: ^Ramps) {
    delete(r.cols)
    delete(r.labs)
    delete(r.dirs)
}

// target: the lit colour wanted · base: the surface's own colour · pull: 0..1,
// how much a coloured lamp may drag it into another hue (1 = no hue penalty)
ramps_pick :: proc(r: Ramps, target, base: [3]f32, pull: f32 = 0) -> [3]f32 {
    // the hue only binds a colourful surface, and binds less in deep shadow:
    // white and grey shade into whatever cool grey fits, darks may go navy
    t   := oklab(target)
    bl  := oklab(base)
    hb  := hue_dir(bl)
    sat := sstep(0.025, 0.07, math.hypot(bl[1], bl[2]))
    lit := sstep(0.06, 0.3, t[0])
    pen := r.hue_penalty * (1 - pull) * sat * lit

    best := 0
    bd: f32 = 1e30
    for i in 0..<len(r.labs) {
        lab := r.labs[i]
        dl := t[0] - lab[0]
        da := t[1] - lab[1]
        db := t[2] - lab[2]
        hx := r.dirs[i][0] - hb[0]
        hy := r.dirs[i][1] - hb[1]
        c2 := lab[1] * lab[1] + lab[2] * lab[2] // a grey surface stays out of strong colours
        d  := 1.4 * dl * dl + da * da + db * db + pen * (hx * hx + hy * hy) + 8 * (1 - sat) * c2
        if d < bd {
            bd = d
            best = i
        }
    }
    return r.cols[best]
}

// ---- light -----------------------------------------------------------------

// `sh` is a copy of the finished scene shape (the header only: do not add to
// the original afterwards). `lights` must outlive the Lighting.
Lighting :: struct {
    sh:     Shape,
    lights: []Light,
    ramps:  Ramps,
}

make_lighting :: proc(sh: Shape, lights: []Light, palette: [][4]u8) -> Lighting {
    return {sh = sh, lights = lights, ramps = make_ramps(palette)}
}

delete_lighting :: proc(l: ^Lighting) {
    delete_ramps(&l.ramps)
}

// soft shadow: 1 = in full sun, 0 = fully shadowed
sun_vis :: proc(l: ^Lighting, p, n: [3]f32, max_t: f32 = 4) -> f32 {
    t: f32 = 0.03
    vis: f32 = 1
    o := p + n * 0.025
    for i := 0; i < 48 && t < max_t; i += 1 {
        h := shape_dist(l.sh, o + SUN * t)
        if h < 0.002 do return 0
        vis = min(vis, (10 * h) / t)
        t += min(max(h, 0.012), 0.35)
    }
    return math.clamp(vis, 0, 1)
}

// can a lamp at `lp` see this point? (hard-ish, with a little softness)
lamp_vis :: proc(l: ^Lighting, p, n, lp: [3]f32, dist: f32) -> f32 {
    dir := (lp - p) / dist
    o   := p + n * 0.025
    t: f32 = 0.03
    vis: f32 = 1
    for i := 0; i < 32 && t < dist - 0.12; i += 1 {
        h := shape_dist(l.sh, o + dir * t)
        if h < 0.002 do return 0.1
        vis = min(vis, (6 * h) / t)
        t += max(h, 0.012)
    }
    return 0.1 + 0.9 * math.clamp(vis, 0, 1)
}

// base: the surface colour (0..1) · p, n: position and normal · ao: 0..1
// occlusion from the sampler · leaf: foliage, lit through
// Returns the final palette colour.
light_shade :: proc(l: ^Lighting, base, p, n: [3]f32, ao: f32, leaf: bool) -> [3]f32 {
    ndl := linalg.dot(n, SUN)
    if leaf do ndl = 0.45 + 0.55 * abs(ndl) // light comes through
    sun := max(ndl, 0)
    if sun > 0 {
        v: f32
        if leaf {
            v = sun_vis(l, p, SUN)
            sun *= 0.35 + 0.65 * v
        } else {
            v = sun_vis(l, p, n)
            sun *= v
        }
    }
    sky := LIGHT_AMB_LOW + (LIGHT_AMB_HIGH - LIGHT_AMB_LOW) * (n.y * 0.5 + 0.5)
    k   := sky * (0.55 + 0.45 * ao) + LIGHT_SUN * sun

    // lamps: warm light that can recolour what is right next to them
    lamp: [3]f32
    for lt in l.lights {
        to := lt.pos - p
        d  := linalg.vector_length(to)
        if d > 1.6 || d < 1e-4 do continue
        facing := linalg.dot(n, to) / d
        w := ((max(facing, 0) * 0.85 + 0.15) / (1 + d * d * 9)) * lt.power * LIGHT_LAMP
        if w < 0.01 do continue
        if facing > -0.1 {
            w *= lamp_vis(l, p, n, lt.pos, d)
        } else {
            w *= 0.3
        }
        lamp += lt.color * w
    }

    // cool shadows, warm light: shift the hue with how lit the surface is
    lit  := min(1, sun / 0.5)
    tint := [3]f32{0.86 + 0.18 * lit, 0.92 + 0.08 * lit, 1.1 - 0.17 * lit}
    target: [3]f32
    for i in 0..<3 {
        target[i] = base[i] * k * tint[i] + lamp[i] * (base[i] * 0.85 + 0.1)
    }
    lamp_lum := 0.3 * lamp[0] + 0.59 * lamp[1] + 0.11 * lamp[2]
    pull     := math.clamp((lamp_lum - 0.12) / 0.5, 0, 1)
    return ramps_pick(l.ramps, target, base, pull)
}
