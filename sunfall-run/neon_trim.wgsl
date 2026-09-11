//! Neon trim for the general `ShaderMaterial` — emissive piping, light bars,
//! wheel-hub halos, gate beams, billboard struts.
//!
//! Unlit + additive: a steady neon glow, a slow breathing pulse, an OPTIONAL
//! bright dash travelling along the piece's local X, and a camera-facing
//! fresnel edge. Animated from `globals.time` only — no per-tick script.
//!
//! Character comes from the `//!@` inputs, so one shader dresses every strip.
//! Inputs are snake_case — the ShaderMaterial reflection binds the WGSL struct
//! field names. Edit live (hot-reload) or via the Inspector.

#import bevy_pbr::{
    mesh_functions,
    forward_io::VertexOutput,
    mesh_view_bindings::{globals, view},
}
#import lunco::noise::vnoise

//!@ui      color       color "Neon tint (HDR; values >1 bloom)"
//!@default color       0.0,1.9,2.2
//!@ui      glow        0 10  "Emissive gain"
//!@default glow        3.0
//!@ui      base        0 1   "Steady emissive floor"
//!@default base        0.6
//!@ui      pulse       0 1   "Breathing-pulse depth"
//!@default pulse       0.3
//!@ui      pulse_speed 0 8   "Breathing-pulse speed"
//!@default pulse_speed 2.0
//!@ui      flow        0 1   "Travelling-dash depth (along local X)"
//!@default flow        0.0
//!@ui      flow_speed  0 8   "Dash speed"
//!@default flow_speed  2.5
//!@ui      flow_count  0 24  "Dashes along the strip"
//!@default flow_count  3.0
//!@ui      rim_gain    0 3   "Fresnel-edge boost"
//!@default rim_gain    0.6
//!@ui      rim_power   0.5 6 "Fresnel falloff"
//!@default rim_power   2.5
//!@ui      flicker     0 1   "Noise flicker depth"
//!@default flicker     0.06
//!@ui      alpha_gain  0 2   "Overall coverage"
//!@default alpha_gain  1.0
//!@ui      flow_color  color "Dash colour (used as far as flow_mix says)"
//!@default flow_color  1.0,1.0,1.0
//!@ui      flow_mix    0 1   "0 = dashes in the body colour, 1 = in flow_color"
//!@default flow_mix    0.0
//!@ui      span        0.1 8 "Local-X length the dashes run over (1 = unit prim)"
//!@default span        1.0
struct Material {
    color:       vec3<f32>,
    glow:        f32,
    base:        f32,
    pulse:       f32,
    pulse_speed: f32,
    flow:        f32,
    flow_speed:  f32,
    flow_count:  f32,
    rim_gain:    f32,
    rim_power:   f32,
    flicker:     f32,
    alpha_gain:  f32,
    flow_color:  vec3<f32>,
    flow_mix:    f32,
    span:        f32,
}

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> mat: Material;

const TAU: f32 = 6.28318531;

@fragment
fn fragment(input: VertexOutput) -> @location(0) vec4<f32> {
    let t = globals.time;

    let local_from_world = mesh_functions::get_local_from_world(input.instance_index);
    let p = (local_from_world * vec4<f32>(input.world_position.xyz, 1.0)).xyz;
    // 0..1 along local X. `span` is the piece's local-X length: 1 for a unit
    // prim sized by xformOp:scale, the real width for a Mesh authored in its
    // parent's coordinates (else the dashes only run across its middle metre).
    let sx = clamp(p.x / max(mat.span, 0.1) + 0.5, 0.0, 1.0);

    let nrm = normalize(input.world_normal);
    let vdir = normalize(view.world_position - input.world_position.xyz);
    let rim = pow(clamp(1.0 - abs(dot(nrm, vdir)), 0.0, 1.0), max(mat.rim_power, 0.5));

    let breathe = 1.0 + mat.pulse * 0.5 * sin(t * mat.pulse_speed);
    let dash = mat.flow * pow(0.5 + 0.5 * cos((sx * mat.flow_count - t * mat.flow_speed) * TAU), 6.0);
    let nz = vnoise(vec3<f32>(sx * 8.0, p.y * 8.0, t * 3.0));
    let flick = 1.0 + mat.flicker * (nz - 0.5) * 2.0;

    // Body and dash are lit separately so a dash can carry its own tint
    // (flow_mix 0 reproduces the single-colour look exactly).
    let body = max((mat.base + mat.rim_gain * rim) * breathe * flick, 0.0);
    let dash_e = max(dash * breathe * flick, 0.0);
    let dash_col = mix(mat.color, mat.flow_color, clamp(mat.flow_mix, 0.0, 1.0));
    let emissive = (mat.color * body + dash_col * dash_e) * mat.glow;
    let alpha = clamp((mat.base * 0.5 + dash + mat.rim_gain * rim) * mat.alpha_gain, 0.0, 1.0);
    return vec4<f32>(emissive, alpha);
}
