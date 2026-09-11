//! Animated tail-light strip for the general `ShaderMaterial`.
//!
//! The pylons' language on a lamp — travelling bands, a scan sweep, fine
//! segment lines — drawn along the strip's local X. The bound prim is a UNIT
//! cube (x in [-0.5, 0.5]) with its size on `xformOp:scale`, so the pattern
//! always spans the whole bar however long it is authored.
//!
//! Two patterns, one shader:
//!   * DRIVING   — a steady rich-red bar with constant subtle life: soft bands
//!                 drifting out from the centre, a slow sweep end to end, a
//!                 faint breath. Never blinks, never goes dark.
//!   * REVERSING — the bar breaks into blocks that fill outward from the
//!                 centre in quick steps, a hot leading block, then reset.
//!                 The whole bar lifts in brightness.
//!
//! Which one shows is `drive_level`, WIRED to the rover's own `throttle` port
//! on the bound gprim (see `RearGlow` in `my_survey.usda`). The wire's
//! `lunco:factor`/`lunco:offset` map throttle -1..1 onto 0..1, so
//! 0 = full reverse, 0.5 = stopped, 1 = full forward. Reverse lamps follow the
//! selected direction, not wheel speed — the way a real car's do.
//!
//! Motion comes from `globals.time` only: no per-tick script, no hidden state.
//! Inputs are snake_case — the ShaderMaterial reflection binds the WGSL struct
//! field names.

#import bevy_pbr::{
    mesh_functions,
    forward_io::VertexOutput,
    mesh_view_bindings::globals,
}
#import lunco::noise::vnoise

//!@ui      color         color "Lamp red (HDR; keep G/B near 0 so it stays red)"
//!@default color         2.2,0.0,0.035
//!@ui      glow          0 8   "Emissive gain"
//!@default glow          1.4
//!@ui      base          0 1   "Steady floor while driving"
//!@default base          0.6
//!@ui      band_gain     0 2   "Drifting-band depth (driving)"
//!@default band_gain     0.22
//!@ui      band_count    0 12  "Bands per half-strip"
//!@default band_count    2.0
//!@ui      band_speed    0 4   "Band drift speed (outward)"
//!@default band_speed    0.35
//!@ui      sweep_gain    0 2   "Sweep contribution (driving)"
//!@default sweep_gain    0.3
//!@ui      sweep_speed   0 4   "Sweep speed"
//!@default sweep_speed   0.5
//!@ui      breathe       0 1   "Breathing depth"
//!@default breathe       0.08
//!@ui      segments      0 96  "LED segments along the strip"
//!@default segments      48.0
//!@ui      segment_gap   0 0.8 "Dark gap between LED segments"
//!@default segment_gap   0.2
//!@ui      rev_gain      0 3   "Brightness lift when reversing"
//!@default rev_gain      1.5
//!@ui      rev_steps     1 16  "Chase blocks per half-strip (reversing)"
//!@default rev_steps     6.0
//!@ui      rev_speed     0 4   "Chase cycles per second (reversing)"
//!@default rev_speed     1.1
//!@ui      rev_gap       0 0.6 "Dark gap between chase blocks"
//!@default rev_gap       0.16
//!@ui      hot_gain      0 2   "Hot leading block (reversing)"
//!@default hot_gain      0.7
//!@ui      flicker       0 1   "Noise flicker depth"
//!@default flicker       0.04
//!@ui      drive_level   0 1   "Throttle, driven (0 reverse / 0.5 stop / 1 forward)"
//!@default drive_level   0.5
struct Material {
    color:       vec3<f32>,
    glow:        f32,
    base:        f32,
    band_gain:   f32,
    band_count:  f32,
    band_speed:  f32,
    sweep_gain:  f32,
    sweep_speed: f32,
    breathe:     f32,
    segments:    f32,
    segment_gap: f32,
    rev_gain:    f32,
    rev_steps:   f32,
    rev_speed:   f32,
    rev_gap:     f32,
    hot_gain:    f32,
    flicker:     f32,
    drive_level: f32,
}

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> mat: Material;

const TAU: f32 = 6.28318531;

// Anti-aliased repeating cell mask: 1 inside each cell, 0 in the gap between.
// The edge is ONE pixel wide (analytic coverage from `fwidth`), and once the
// cells shrink below a couple of pixels the mask fades to its average instead
// of shimmering into moire at a distance.
fn cells(u: f32, gap: f32) -> f32 {
    let w = max(fwidth(u), 1e-5);
    let d = abs(fract(u) - 0.5);                   // 0 at cell centre .. 0.5 at edge
    let half_lit = 0.5 * (1.0 - clamp(gap, 0.0, 0.95));
    let m = clamp((half_lit - d) / w + 0.5, 0.0, 1.0);
    let far = clamp(w * 2.0 - 1.0, 0.0, 1.0);     // cells under ~2 px wide
    return mix(m, 1.0 - clamp(gap, 0.0, 0.95), far);
}

@fragment
fn fragment(input: VertexOutput) -> @location(0) vec4<f32> {
    let t = globals.time;

    let local_from_world = mesh_functions::get_local_from_world(input.instance_index);
    let p = (local_from_world * vec4<f32>(input.world_position.xyz, 1.0)).xyz;
    let sx = clamp(p.x + 0.5, 0.0, 1.0);          // 0..1 end to end
    let c = clamp(abs(p.x) * 2.0, 0.0, 1.0);      // 0 at centre .. 1 at either end

    // 0 while stopped or driving forward, 1 once throttle is clearly reversed.
    let rev = 1.0 - smoothstep(0.25, 0.45, mat.drive_level);

    // Fine LED texture, shared by both patterns.
    let led = cells(sx * max(mat.segments, 1.0), mat.segment_gap);

    // ── DRIVING: steady, with bands drifting outward and a slow sweep ──
    let bands = 0.5 + 0.5 * cos((c * mat.band_count - t * mat.band_speed) * TAU);
    let sweep_pos = abs(fract(t * mat.sweep_speed * 0.2) * 2.0 - 1.0);   // ping-pong 0..1
    let sweep = 1.0 - smoothstep(0.0, 0.14, abs(sx - sweep_pos));
    let breath = 1.0 + mat.breathe * sin(t * 1.3);
    let drive_field = (mat.base + mat.band_gain * bands + mat.sweep_gain * sweep) * breath;

    // ── REVERSING: blocks fill outward from the centre, hold, reset ──
    let steps = max(mat.rev_steps, 1.0);
    let block = floor(c * steps) / steps;          // this block's start, 0..1
    let fill = fract(t * mat.rev_speed) * 1.3;      // runs past 1 to hold the full bar
    let on = step(block, fill);
    let lead = on * (1.0 - smoothstep(0.0, 1.5 / steps, fill - block));
    let blocks = cells(c * steps, mat.rev_gap);
    let rev_field = (0.22 + on * 0.9 + mat.hot_gain * lead) * mix(1.0, blocks, 0.9) * mat.rev_gain;

    let nz = vnoise(vec3<f32>(sx * 10.0, p.y * 6.0, t * 2.5));
    let flick = 1.0 + mat.flicker * (nz - 0.5) * 2.0;

    let field = mix(drive_field, rev_field, rev) * led * flick;

    // Hot block: a touch of orange on top of the red, so it reads as a
    // brighter filament rather than a wash to white.
    let hot = vec3<f32>(mat.color.r, mat.color.r * 0.14, mat.color.r * 0.05)
        * mat.hot_gain * lead * rev * led;

    let emissive = mat.color * mat.glow * max(field, 0.0) + hot * mat.glow * 0.6;
    let alpha = clamp(field, 0.0, 1.0);
    return vec4<f32>(emissive, alpha);
}
