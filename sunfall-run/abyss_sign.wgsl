//! "To the Abyss" — a vintage Los Angeles neon arrow sign, for the general
//! `ShaderMaterial`. Bound to `AbyssSign/Board` in `my_survey.usda`.
//!
//! Everything on the sign is drawn here, on a plain arrow-shaped can:
//!   * "ABYSS" in red-pink tube lettering, "To the" in a cyan italic above it;
//!   * a violet neon tube following the arrow's outline;
//!   * a row of marquee bulbs round the edge, chasing toward the tip;
//!   * a small Googie sparkle, and one letter (the Y) that buzzes now and then
//!     like a failing tube.
//!
//! OPAQUE on purpose (no `lunco:surface:additive`): the painted can has to hide
//! the sun's far wall behind it. The glow of each tube is painted onto the can
//! round it, the way real neon lights its own backing.
//!
//! Reads MESH-LOCAL position in metres — the Board is authored in its own
//! coordinates, unscaled. The face is the XY plane, +Z the front, and the arrow
//! points to -X. The outline below must match the Board's `points`.
//! Animated from `globals.time` only.

#import bevy_pbr::{
    mesh_functions,
    forward_io::VertexOutput,
    mesh_view_bindings::globals,
}
#import lunco::noise::vnoise

//!@ui      abyss_color  color "ABYSS tubes (HDR; values >1 bloom)"
//!@default abyss_color  2.6,0.10,0.50
//!@ui      abyss_glow   0 8   "ABYSS brightness"
//!@default abyss_glow   3.0
//!@ui      script_color color "'To the' tubes"
//!@default script_color 0.10,1.80,2.40
//!@ui      script_glow  0 8   "'To the' brightness"
//!@default script_glow  2.6
//!@ui      border_color color "Outline tube"
//!@default border_color 1.10,0.30,2.60
//!@ui      border_glow  0 8   "Outline brightness"
//!@default border_glow  2.4
//!@ui      bulb_color   color "Marquee bulbs"
//!@default bulb_color   2.4,1.60,0.70
//!@ui      bulb_glow    0 8   "Bulb brightness"
//!@default bulb_glow    2.6
//!@ui      star_color   color "Sparkle"
//!@default star_color   2.6,1.90,0.40
//!@ui      star_glow    0 8   "Sparkle brightness"
//!@default star_glow    2.4
//!@ui      field_color  color "Can paint, inside the outline"
//!@default field_color  0.004,0.010,0.022
//!@ui      halo_gain    0 2   "How much the tubes light the can"
//!@default halo_gain    0.35
//!@ui      band_color   color "Can paint, outside the outline + sides"
//!@default band_color   0.040,0.004,0.012
//!@ui      halo_width   0.01 0.5 "Glow spread on the can (m)"
//!@default halo_width   0.07
//!@ui      core_gain    0 2   "White-hot tube centres"
//!@default core_gain    0.5
//!@ui      bulb_rest    0 1   "Bulb level between chases"
//!@default bulb_rest    0.12
//!@ui      chase_speed  0 6   "Chase waves per second"
//!@default chase_speed  1.6
//!@ui      buzz         0 1   "How hard the Y cuts out"
//!@default buzz         0.85
struct Material {
    abyss_color:  vec3<f32>,
    abyss_glow:   f32,
    script_color: vec3<f32>,
    script_glow:  f32,
    border_color: vec3<f32>,
    border_glow:  f32,
    bulb_color:   vec3<f32>,
    bulb_glow:    f32,
    star_color:   vec3<f32>,
    star_glow:    f32,
    field_color:  vec3<f32>,
    halo_gain:    f32,
    band_color:   vec3<f32>,
    halo_width:   f32,
    core_gain:    f32,
    bulb_rest:    f32,
    chase_speed:  f32,
    buzz:         f32,
}

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> mat: Material;

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318531;
const FAR: f32 = 1e3;

// ── The can. Same outline as the Board mesh, counter-clockwise from the tip.
const HALF_T: f32 = 0.11;      // half the can's thickness (Board z = +-0.11)
const BULB_IN: f32 = 0.11;     // bulb row, inset from the edge
const BORDER_IN: f32 = 0.25;   // outline tube, inset from the edge
const BULB_STEP: f32 = 0.20;   // bulb spacing along the row
const BULB_R: f32 = 0.038;
const BORDER_R: f32 = 0.024;

fn outline() -> array<vec2<f32>, 8> {
    return array<vec2<f32>, 8>(
        vec2<f32>(-2.70,  0.00),   // tip
        vec2<f32>(-1.30, -1.35),
        vec2<f32>(-1.30, -0.80),
        vec2<f32>( 2.50, -0.80),
        vec2<f32>( 2.05,  0.00),   // tail notch
        vec2<f32>( 2.50,  0.80),
        vec2<f32>(-1.30,  0.80),
        vec2<f32>(-1.30,  1.35),
    );
}

// The outline moved `depth` inward (mitred corners). Interior is on the left
// of each edge because the outline runs counter-clockwise.
fn inset(depth: f32) -> array<vec2<f32>, 8> {
    var v = outline();
    var o: array<vec2<f32>, 8>;
    for (var i = 0u; i < 8u; i++) {
        let prv = v[(i + 7u) % 8u];
        let cur = v[i];
        let nxt = v[(i + 1u) % 8u];
        let e1 = normalize(cur - prv);
        let e2 = normalize(nxt - cur);
        let n1 = vec2<f32>(-e1.y, e1.x);
        let n2 = vec2<f32>(-e2.y, e2.x);
        o[i] = cur + depth * (n1 + n2) / (1.0 + dot(n1, n2));
    }
    return o;
}

fn seg(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

// Circular arc: centre c, radius r, spanning `ac` +- `hw` radians.
fn arc(p: vec2<f32>, c: vec2<f32>, r: f32, ac: f32, hw: f32) -> f32 {
    let d = p - c;
    var da = atan2(d.y, d.x) - ac;
    da = da - TAU * floor((da + PI) / TAU);          // wrap to [-pi, pi)
    if abs(da) <= hw {
        return abs(length(d) - r);
    }
    let e0 = c + r * vec2<f32>(cos(ac - hw), sin(ac - hw));
    let e1 = c + r * vec2<f32>(cos(ac + hw), sin(ac + hw));
    return min(length(p - e0), length(p - e1));
}

fn rad(deg: f32) -> f32 { return deg * PI / 180.0; }

// ── Tube lettering. Font units: baseline y = 0, cap height 1; each glyph
//    starts at x = 0 and the caller offsets it.
fn g_A(q: vec2<f32>) -> f32 {
    return min(min(seg(q, vec2<f32>(0.0, 0.0), vec2<f32>(0.36, 1.0)),
                   seg(q, vec2<f32>(0.36, 1.0), vec2<f32>(0.72, 0.0))),
               seg(q, vec2<f32>(0.15, 0.38), vec2<f32>(0.57, 0.38)));
}
fn g_B(q: vec2<f32>) -> f32 {
    var d = seg(q, vec2<f32>(0.0, 0.0), vec2<f32>(0.0, 1.0));
    d = min(d, seg(q, vec2<f32>(0.0, 1.0), vec2<f32>(0.34, 1.0)));
    d = min(d, arc(q, vec2<f32>(0.34, 0.765), 0.235, 0.0, PI * 0.5));
    d = min(d, seg(q, vec2<f32>(0.0, 0.53), vec2<f32>(0.37, 0.53)));
    d = min(d, arc(q, vec2<f32>(0.37, 0.265), 0.265, 0.0, PI * 0.5));
    return min(d, seg(q, vec2<f32>(0.37, 0.0), vec2<f32>(0.0, 0.0)));
}
fn g_Y(q: vec2<f32>) -> f32 {
    return min(min(seg(q, vec2<f32>(0.0, 1.0), vec2<f32>(0.36, 0.48)),
                   seg(q, vec2<f32>(0.72, 1.0), vec2<f32>(0.36, 0.48))),
               seg(q, vec2<f32>(0.36, 0.48), vec2<f32>(0.36, 0.0)));
}
fn g_S(q: vec2<f32>) -> f32 {
    // Two point-symmetric bowls: the top one from 25 deg round the left to the
    // bottom, the lower one from the top round the right to -155 deg.
    return min(arc(q, vec2<f32>(0.28, 0.75), 0.25, rad(147.5), rad(122.5)),
               arc(q, vec2<f32>(0.28, 0.25), 0.25, rad(-32.5), rad(122.5)));
}
fn g_T(q: vec2<f32>) -> f32 {
    return min(seg(q, vec2<f32>(0.0, 1.0), vec2<f32>(0.62, 1.0)),
               seg(q, vec2<f32>(0.31, 1.0), vec2<f32>(0.31, 0.0)));
}
fn g_o(q: vec2<f32>) -> f32 {
    return abs(length(q - vec2<f32>(0.3, 0.3)) - 0.3);
}
fn g_t(q: vec2<f32>) -> f32 {
    return min(min(seg(q, vec2<f32>(0.12, 0.9), vec2<f32>(0.12, 0.18)),
                   arc(q, vec2<f32>(0.30, 0.18), 0.18, rad(250.0), rad(70.0))),
               seg(q, vec2<f32>(0.0, 0.6), vec2<f32>(0.38, 0.6)));
}
fn g_h(q: vec2<f32>) -> f32 {
    return min(min(seg(q, vec2<f32>(0.0, 1.0), vec2<f32>(0.0, 0.0)),
                   arc(q, vec2<f32>(0.27, 0.33), 0.27, rad(90.0), rad(90.0))),
               seg(q, vec2<f32>(0.54, 0.33), vec2<f32>(0.54, 0.0)));
}
fn g_e(q: vec2<f32>) -> f32 {
    return min(seg(q, vec2<f32>(0.02, 0.3), vec2<f32>(0.58, 0.3)),
               arc(q, vec2<f32>(0.3, 0.3), 0.29, rad(160.0), rad(160.0)));
}

// Text layout, in the sign's metres. Centred on the shaft.
const ABYSS_X0: f32 = -0.74;
const ABYSS_BASE: f32 = -0.47;
const ABYSS_H: f32 = 0.52;
const ABYSS_R: f32 = 0.030;
const SCRIPT_X0: f32 = -0.72;
const SCRIPT_BASE: f32 = 0.16;
const SCRIPT_H: f32 = 0.27;
const SCRIPT_R: f32 = 0.020;
const SCRIPT_SLANT: f32 = 0.18;
const STAR_AT: vec2<f32> = vec2<f32>(0.95, 0.30);
const STAR_R: f32 = 0.014;

// A neon tube at distance d (m) from its centre line: glass body, white-hot
// core, and the glow it throws on the can round it.
fn tube(d: f32, r: f32, px: f32, col: vec3<f32>, glow: f32) -> vec3<f32> {
    let body = clamp((r - d) / px + 0.5, 0.0, 1.0);
    let core = 1.0 - smoothstep(0.0, r, d);
    let halo = exp(-max(d - r, 0.0) / max(mat.halo_width, 0.01));
    return col * glow * body * (0.7 + 0.3 * core)
         + vec3<f32>(mat.core_gain * glow) * core * core * body
         + col * mat.halo_gain * halo * (1.0 - body);
}

@fragment
fn fragment(input: VertexOutput) -> @location(0) vec4<f32> {
    let t = globals.time;
    let local_from_world = mesh_functions::get_local_from_world(input.instance_index);
    let p = (local_from_world * vec4<f32>(input.world_position.xyz, 1.0)).xyz;
    // Metres per pixel, taken before any branching (derivatives need uniform
    // control flow). Every edge below is exactly one pixel wide.
    let px = max(length(fwidth(p)), 1e-5);

    // Sides of the can: painted return with a thin outline-coloured stripe, so
    // the silhouette still reads edge-on.
    if abs(p.z) < HALF_T - 0.004 {
        let d = abs(p.z);
        return vec4<f32>(mat.band_color + tube(d, 0.012, px, mat.border_color, mat.border_glow * 0.6), 1.0);
    }

    let q = p.xy;
    // Text is mirrored on the back face so it reads there too; the outline,
    // bulbs and arrow are the same shape from both sides.
    var u = q;
    if p.z < 0.0 {
        u.x = 2.0 * 0.30 - q.x;
    }

    var col = mat.band_color;

    // Inside the outline tube the can is a darker enamel.
    let rim = inset(BORDER_IN);
    var d_border = FAR;
    var inside = false;
    for (var i = 0u; i < 8u; i++) {
        let a = rim[i];
        let b = rim[(i + 1u) % 8u];
        d_border = min(d_border, seg(q, a, b));
        // Even-odd crossing test against the rim polygon.
        if ((a.y > q.y) != (b.y > q.y)) && (q.x < a.x + (q.y - a.y) * (b.x - a.x) / (b.y - a.y)) {
            inside = !inside;
        }
    }
    if inside {
        col = mat.field_color;
    }
    col += tube(d_border, BORDER_R, px, mat.border_color, mat.border_glow);

    // Marquee bulbs: evenly spaced along each edge of the bulb row, lit by a
    // wave that travels toward -X, the tip. Bulbs are placed by edge so every
    // corner gets one.
    let row = inset(BULB_IN);
    var d_bulb = FAR;
    var bulb_x = 0.0;
    for (var i = 0u; i < 8u; i++) {
        let a = row[i];
        let b = row[(i + 1u) % 8u];
        let len = length(b - a);
        let n = max(round(len / BULB_STEP), 1.0);
        let h = clamp(dot(q - a, b - a) / (len * len), 0.0, 1.0);
        let c = a + (b - a) * (round(h * n) / n);
        let dc = length(q - c);
        if dc < d_bulb {
            d_bulb = dc;
            bulb_x = c.x;
        }
    }
    let ph = fract(bulb_x / (3.0 * BULB_STEP) + t * mat.chase_speed);
    let on = smoothstep(0.0, 0.06, ph) * (1.0 - smoothstep(0.30, 0.40, ph));
    let lit = mix(mat.bulb_rest, 1.0, on);
    col += tube(d_bulb, BULB_R, px, mat.bulb_color, mat.bulb_glow * lit)
         * select(1.0, lit, d_bulb > BULB_R);

    // ABYSS. The Y is kept apart so it can buzz.
    let fa = (u - vec2<f32>(ABYSS_X0, ABYSS_BASE)) / ABYSS_H;
    var d_abyss = FAR;
    var d_y = FAR;
    if fa.x > -0.5 && fa.x < 4.5 && fa.y > -0.6 && fa.y < 1.6 {
        d_abyss = min(g_A(fa), g_B(fa - vec2<f32>(0.92, 0.0)));
        d_y = g_Y(fa - vec2<f32>(1.755, 0.0));
        d_abyss = min(d_abyss, min(g_S(fa - vec2<f32>(2.675, 0.0)), g_S(fa - vec2<f32>(3.435, 0.0))));
        d_abyss *= ABYSS_H;
        d_y *= ABYSS_H;
    }
    // A burst window every few seconds; inside it the tube chatters on and off.
    let burst = smoothstep(0.62, 0.66, vnoise(vec3<f32>(t * 0.45, 7.3, 1.1)));
    let chatter = step(0.5, vnoise(vec3<f32>(t * 14.0, 2.7, 5.9)));
    let y_on = 1.0 - mat.buzz * burst * chatter;
    let hum = 1.0 + 0.04 * (vnoise(vec3<f32>(t * 6.0, 0.0, 0.0)) - 0.5);
    col += tube(d_abyss, ABYSS_R, px, mat.abyss_color, mat.abyss_glow * hum);
    col += tube(d_y, ABYSS_R, px, mat.abyss_color, mat.abyss_glow * hum * y_on)
         + mat.abyss_color * 0.05 * clamp((ABYSS_R - d_y) / px + 0.5, 0.0, 1.0);

    // "To the", slanted.
    var fs = (u - vec2<f32>(SCRIPT_X0, SCRIPT_BASE)) / SCRIPT_H;
    fs.x -= SCRIPT_SLANT * fs.y;
    var d_script = FAR;
    if fs.x > -0.5 && fs.x < 3.8 && fs.y > -0.6 && fs.y < 1.6 {
        d_script = min(g_T(fs), g_o(fs - vec2<f32>(0.55, 0.0)));
        d_script = min(d_script, min(g_t(fs - vec2<f32>(1.50, 0.0)), g_h(fs - vec2<f32>(2.06, 0.0))));
        d_script = min(d_script, g_e(fs - vec2<f32>(2.70, 0.0))) * SCRIPT_H;
    }
    col += tube(d_script, SCRIPT_R, px, mat.script_color, mat.script_glow * hum);

    // Googie sparkle: a long cross and a short diagonal one, twinkling.
    let s = u - STAR_AT;
    let d_plus = min(seg(s, vec2<f32>(-0.14, 0.0), vec2<f32>(0.14, 0.0)), seg(s, vec2<f32>(0.0, -0.14), vec2<f32>(0.0, 0.14)));
    let d_x = min(seg(s, vec2<f32>(-0.06, -0.06), vec2<f32>(0.06, 0.06)), seg(s, vec2<f32>(-0.06, 0.06), vec2<f32>(0.06, -0.06)));
    let tw = 0.5 + 0.5 * sin(t * 2.3);
    col += tube(d_plus, STAR_R, px, mat.star_color, mat.star_glow * mix(0.35, 1.0, tw));
    col += tube(d_x, STAR_R, px, mat.star_color, mat.star_glow * mix(1.0, 0.35, tw));

    return vec4<f32>(col, 1.0);
}
