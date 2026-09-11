//! Pulsing holographic waypoint pylon for the general `ShaderMaterial`.
//!
//! The bound geometry is a handful of plain UNIT primitives (concentric
//! cylinders + a foot ring + a node sphere). None of them are meant to read as
//! the cylinder they are: this shader
//!   * cuts the tube into spiralling vertical BLADES (alpha 0 between them), so
//!     there is no closed cylinder silhouette;
//!   * masks what is left down to a rotating lattice, upward-travelling energy
//!     rings with white-hot edges, and a camera-facing fresnel rim;
//!   * dissolves both ends so no flat cap is ever visible.
//!
//! Animated from `globals.time` ONLY: no per-tick script, no hidden state,
//! identical on every machine that renders the same second. Unlit + emissive on
//! purpose — a hologram is a symbol, and on the Moon a lit surface facing away
//! from the sun renders pure black.
//!
//! Character (solid core vs. bladed cage vs. pure aura) comes entirely from the
//! `//!@` inputs, so ONE shader dresses every piece through three bound
//! materials. Inputs are snake_case — the ShaderMaterial reflection binds the
//! WGSL struct field names. Edit live (hot-reload) or via the Inspector.

#import bevy_pbr::{
    mesh_functions,
    forward_io::VertexOutput,
    mesh_view_bindings::{globals, view},
}
#import lunco::noise::vnoise

//!@ui      color         color  "Neon tint (HDR; values >1 bloom)"
//!@default color         0.0,1.75,2.15
//!@ui      glow          0 8    "Emissive gain"
//!@default glow          2.6
//!@ui      base_alpha    0 1    "Coverage where nothing is lit"
//!@default base_alpha    0.04
//!@ui      base_floor    0 1    "Emissive floor where nothing is lit"
//!@default base_floor    0.03
//!@ui      blades        0 10   "Vertical blade count (0 = closed tube)"
//!@default blades        5.0
//!@ui      blade_gap     0 0.9  "Fraction of each blade slot left empty"
//!@default blade_gap     0.46
//!@ui      blade_twist   0 3    "Blade spiral turns over the full height"
//!@default blade_twist   0.35
//!@ui      blade_soft    0 0.5  "Blade edge softness"
//!@default blade_soft    0.08
//!@ui      rim_gain      0 3    "Fresnel-rim contribution"
//!@default rim_gain      0.8
//!@ui      rim_power     0.5 6  "Fresnel falloff"
//!@default rim_power     2.2
//!@ui      ring_gain     0 3    "Travelling energy-ring contribution"
//!@default ring_gain     1.25
//!@ui      ring_count    0 24   "Rings stacked up the column"
//!@default ring_count    3.5
//!@ui      ring_speed    0 8    "Ring travel speed (upward)"
//!@default ring_speed    1.0
//!@ui      ring_sharp    1 40   "Ring band width (higher = thinner)"
//!@default ring_sharp    5.0
//!@ui      lattice_gain  0 3    "Rotating lattice contribution"
//!@default lattice_gain  0.8
//!@ui      lattice_cells 2 40   "Lattice cell count around the column"
//!@default lattice_cells 7.0
//!@ui      lattice_spin  0 4    "Lattice rotation speed"
//!@default lattice_spin  0.45
//!@ui      sweep_gain    0 3    "Vertical scan-sweep contribution"
//!@default sweep_gain    0.7
//!@ui      sweep_speed   0 6    "Scan-sweep speed"
//!@default sweep_speed   2.4
//!@ui      scanline      0 1    "Fine scanline depth"
//!@default scanline      0.2
//!@ui      glitch        0 1    "Occasional glitch-jump depth"
//!@default glitch        0.4
//!@ui      hot_edge      0 3    "White-hot flash on the brightest edges"
//!@default hot_edge      0.8
//!@ui      top_fade      0 0.95 "Fraction of the top that dissolves"
//!@default top_fade      0.34
//!@ui      bottom_fade   0 0.95 "Fraction of the bottom that dissolves"
//!@default bottom_fade   0.05
struct Material {
    color:         vec3<f32>,
    glow:          f32,
    base_alpha:    f32,
    base_floor:    f32,
    blades:        f32,
    blade_gap:     f32,
    blade_twist:   f32,
    blade_soft:    f32,
    rim_gain:      f32,
    rim_power:     f32,
    ring_gain:     f32,
    ring_count:    f32,
    ring_speed:    f32,
    ring_sharp:    f32,
    lattice_gain:  f32,
    lattice_cells: f32,
    lattice_spin:  f32,
    sweep_gain:    f32,
    sweep_speed:   f32,
    scanline:      f32,
    glitch:        f32,
    hot_edge:      f32,
    top_fade:      f32,
    bottom_fade:   f32,
}

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> mat: Material;

const TAU: f32 = 6.28318531;

// Distance to the nearest wall of a triangular (hex-ish) lattice.
fn lattice_edge(q: vec2<f32>) -> f32 {
    let f = fract(q) - vec2<f32>(0.5);
    let e1 = abs(f.x);
    let e2 = abs(f.x * 0.5 + f.y * 0.8660254);
    let e3 = abs(f.x * 0.5 - f.y * 0.8660254);
    return min(e1, min(e2, e3));
}

@fragment
fn fragment(input: VertexOutput) -> @location(0) vec4<f32> {
    let t = globals.time;

    // Position on the UNIT primitive (scale removed by local_from_world):
    // y in [-0.5, 0.5], so a = 0 at the base, 1 at the top.
    let local_from_world = mesh_functions::get_local_from_world(input.instance_index);
    let p = (local_from_world * vec4<f32>(input.world_position.xyz, 1.0)).xyz;
    let a = clamp(p.y + 0.5, 0.0, 1.0);
    let ang01 = atan2(p.z, p.x) / TAU + 0.5;

    // Camera-facing fresnel: bright at the silhouette, near-clear head-on.
    let nrm = normalize(input.world_normal);
    let vdir = normalize(view.world_position - input.world_position.xyz);
    let fres = pow(clamp(1.0 - abs(dot(nrm, vdir)), 0.0, 1.0), max(mat.rim_power, 0.5));

    // Glitch: mostly 0, occasionally snaps the pattern sideways and flashes.
    let gnz = vnoise(vec3<f32>(ang01 * 3.0, a * 5.0, t * 1.7));
    let gj = step(0.82, gnz) * mat.glitch;
    let a_g = a + gj * 0.05;
    let ang_g = ang01 + gj * 0.08;

    // Spiralling vertical blades: alpha goes to 0 between them, so the closed
    // cylinder silhouette is gone. blades < 0.5 => a solid piece (core/aura).
    var blade = 1.0;
    if mat.blades >= 0.5 {
        let bc = fract((ang_g + a_g * mat.blade_twist) * mat.blades);
        let d = abs(bc - 0.5) * 2.0;                       // 0 at blade centre .. 1 at gap
        let keep = 1.0 - clamp(mat.blade_gap, 0.0, 0.9);
        blade = 1.0 - smoothstep(keep - mat.blade_soft, keep + 1e-4, d);
    }

    // Rotating lattice wrapped around the surface.
    let lq = vec2<f32>(ang_g * mat.lattice_cells + t * mat.lattice_spin,
                       a_g * mat.lattice_cells * 2.2);
    let lattice = 1.0 - smoothstep(0.0, 0.11, lattice_edge(lq));

    // Upward-travelling energy rings, with a thin white-hot core line.
    let rp = a_g * mat.ring_count - t * mat.ring_speed;
    let ring_band = pow(0.5 + 0.5 * cos(rp * TAU), max(mat.ring_sharp, 1.0));
    let ring_line = pow(0.5 + 0.5 * cos(rp * TAU), 48.0);

    // Slow vertical scan sweep + fine scanlines.
    let sweep_pos = fract(t * mat.sweep_speed * 0.15);
    let sweep = 1.0 - smoothstep(0.0, 0.10, abs(a_g - sweep_pos));
    let scan = 1.0 - mat.scanline * (0.5 + 0.5 * sin(a_g * 200.0));

    // Dissolve both ends — no flat cap edge ever shows.
    let top = 1.0 - smoothstep(1.0 - clamp(mat.top_fade, 0.0, 0.95), 1.0, a);
    let bot = smoothstep(0.0, max(mat.bottom_fade, 1e-3), a);
    let ends = top * bot;

    let flick = 1.0 + gj * 1.6 + 0.06 * (gnz - 0.5);

    // One field drives BOTH emissive weight and coverage.
    let field = clamp(
        mat.rim_gain * fres
        + mat.ring_gain * ring_band
        + mat.lattice_gain * lattice
        + mat.sweep_gain * sweep,
        0.0, 1.0,
    );

    let lit = (mat.base_floor + field) * scan * flick * blade;
    var emissive = mat.color * mat.glow * lit;
    // White-hot flash on the sharpest edges (ring core line + lattice walls).
    emissive += vec3<f32>(1.0) * mat.hot_edge * mat.glow
        * max(ring_line, pow(lattice, 3.0)) * blade * ends * flick;

    let alpha = clamp((mat.base_alpha + field) * ends * scan * blade, 0.0, 1.0);

    return vec4<f32>(emissive, alpha);
}
