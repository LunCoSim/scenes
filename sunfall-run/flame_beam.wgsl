//! flame_beam.wgsl — twin-local copy of `lunco://shaders/plume.wgsl`.
//! ONE change: `beam_opacity` multiplies the returned alpha (see below).
//! Kept in sync by hand; diff against the shipped shader after an update.
//! Engine-exhaust plume for the general `ShaderMaterial`.
//!
//! The bound `Cone` is a FIXED BOUNDING VOLUME, authored at the plume's
//! full-throttle extent and never transformed again. Everything the plume does —
//! how far it reaches, how wide it blooms, how it shimmers — happens inside that
//! volume, here, from `throttle`.
//!
//! `throttle` is driven per-instance through `float inputs:throttle.connect` on
//! the bound gprim, straight off the vessel's own `throttle` output. The plume is
//! therefore a CONSEQUENCE of the engine's commanded state, on the same tick and
//! by the same number the vessel published.
//!
//! ## Why this shades the authored cone surface
//!
//! The cone is a fixed, full-throttle envelope. An earlier implementation
//! ray-marched a shorter cone inside it, but that made visibility depend on a
//! view-ray entry point and the renderer's front/back-face convention. In the
//! simulator that could leave a real, non-zero engine command with no visible
//! pixels. The reusable presentation contract is simpler and more reliable: the
//! authored cone is the exhaust surface, and throttle masks it from the nozzle
//! outward while also changing its radiance and width response. This is not a
//! simulation shortcut — it is a stable visualisation of the same commanded
//! actuator state, with no scene-specific code or per-tick script.
//!
//! ## The shape, and where its numbers come from
//!
//! In mesh-local space the cone is `radius 1, height 1`: apex at `y = +0.5`, base
//! at `y = -0.5`, and its radius at height `y` is `0.5 - y`. The prim's authored
//! 180° flip puts the apex DOWNSTREAM, so with `a = y + 0.5` running 0 at the
//! nozzle end to 1 at the tip, the bounding surface is `r = 1 - a`.
//!
//! The current plume is the visible part of the authored cone up to `a <= len`,
//! with a brightness and width response derived from
//!
//!     response = throttle ^ throttle_exponent
//!     len = response                         (normalised to the authored volume)
//!     wid = width_idle + (1 - width_idle) * response
//!
//! The exponent is a visual response control, not a second engine command. It
//! keeps a low but real valve opening visible without making zero throttle glow.
//! Both values are FRACTIONS of the authored volume, which is what keeps the
//! per-instance sizing in USD — the outer shroud and the inner core differ only
//! in their prim's scale, and this file has no opinion about either.
//!
//! ## Flicker
//!
//! A steady plume reads as a decal. The shimmer is procedural value noise
//! (`lunco::noise`) advected along the plume axis by `globals.time`, so it is a
//! function of position and time evaluated per fragment — no state, no per-tick
//! script, and identical on every machine that renders the same second.
//!
//! It modulates DOWNWARD only (`1 - depth * …`). That is deliberate: the authored
//! cone is the full-throttle bound and the photometry model derives the plume's
//! light from that same bound, so a flicker that could overshoot would put light
//! outside the volume that emits it.
//!
//! ## The light is not in here
//!
//! Emissive geometry in a forward renderer illuminates nothing, so the plume's
//! `PointLight` is a separate prim driven from `LunCo.Propulsion.PlumePhotometry`.
//! Its colour is authored on that light (`inputs:color`) and must be kept as the
//! chroma of `core_color` below; its luminance parameter must be kept as
//! `core_color`'s Rec.709 luma. A shader parameter is deliberately not readable as
//! a connection source — that is what stops a render value feeding back into the
//! simulation — so this coupling is authored, not wired.
//!
//! Dynamic, self-describing parameters: the engine reflects the `Material`
//! struct (field names → offsets) and the `//!@` annotations straight out of
//! this file. Edit live (hot-reload) or via the Inspector / `SetObjectProperty`.

#import bevy_pbr::{
    mesh_functions,
    forward_io::VertexOutput,
    mesh_view_bindings::globals,
}
#import lunco::pbr_lit::lit
#import lunco::noise::vnoise

//!@ui      core_color    color "Axial colour (hot core)"
//!@default core_color    6.0,3.5,0.9
//!@ui      throttle      0 1   "Throttle (driven by the engine)"
//!@default throttle      0.0
//!@ui      throttle_exponent 0.1 1 "Visual length response to throttle"
//!@default throttle_exponent 0.35
//!@ui      edge_color    color "Flank colour (cooler outer gas)"
//!@default edge_color    3.0,1.0,0.12
//!@ui      width_idle    0 1   "Half-width fraction at zero throttle"
//!@default width_idle    0.28
//!@ui      flicker       0 1   "Flicker depth; 0 = steady"
//!@default flicker       1.0
//!@ui      flicker_speed 0 20  "Flicker advection speed along the axis"
//!@default flicker_speed 6.0
//!@ui      flicker_scale 0 40  "Flicker cell count across the plume"
//!@default flicker_scale 7.0
//!@ui      density       0 40  "Emission / extinction gain per unit local depth"
//!@default density       9.0
//!@ui      steps         4 64  "Ray-march samples through the volume"
//!@default steps         24
//!@ui      beam_opacity  0 1   "Coverage multiplier: 1 = solid plume, ~0.2 = headlight shaft"
//!@default beam_opacity  1.0
//!@ui      ring_gain     0 4   "Running-light band strength (0 = smooth beam)"
//!@default ring_gain     0.0
//!@ui      ring_count    0 24  "Bands along the beam"
//!@default ring_count    8.0
//!@ui      ring_speed    -20 20 "Band travel speed; negative runs back down"
//!@default ring_speed    3.0
//!@ui      ring_sharp    1 32  "Band tightness"
//!@default ring_sharp    4.0
//!@ui      spiral_turns  0 12  "Twist: how many turns a band makes around the beam"
//!@default spiral_turns  0.0
//!@ui      gated         0 1   "1 = burn only while the rover is in the window below"
//!@default gated         0.0
//!@ui      rover_level   0 1   "Rover road position, DRIVEN (z = level * 400 - 200)"
//!@default rover_level   0.0
//!@ui      gate_ahead    0 100 "Ignites when the rover is this far BEFORE the cannon (m)"
//!@default gate_ahead    14.55
//!@ui      gate_behind   0 100 "Goes out once the rover is this far PAST the cannon (m)"
//!@default gate_behind   5.45
//!@ui      gate_ramp     0 20  "Ignition: the beam shoots out over this much rover travel (m)"
//!@default gate_ramp     0.0
//!@ui      nozzle_at_apex 0 1  "1 = nozzle at the cone's APEX (flipped mount): length grows from there"
//!@default nozzle_at_apex 0.0
const TAU: f32 = 6.28318531;

struct Material {
    core_color:    vec3<f32>,
    throttle:      f32,
    throttle_exponent: f32,
    edge_color:    vec3<f32>,
    width_idle:    f32,
    flicker:       f32,
    flicker_speed: f32,
    flicker_scale: f32,
    density:       f32,
    steps:         f32,
    beam_opacity:  f32,
    ring_gain:     f32,
    ring_count:    f32,
    ring_speed:    f32,
    ring_sharp:    f32,
    spiral_turns:  f32,
    gated:         f32,
    rover_level:   f32,
    gate_ahead:    f32,
    gate_behind:   f32,
    gate_ramp:     f32,
    nozzle_at_apex: f32,
}

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> mat: Material;

@fragment
fn fragment(input: VertexOutput) -> @location(0) vec4<f32> {
    var t = clamp(mat.throttle, 0.0, 1.0);

    // THE GATE (twin addition). The cannon burns only while the rover is in a
    // window around it, read from the rover's own position — wired on the
    // bound cone to the rover body's `position_z` port, scaled onto 0..1 on
    // the wire. The window is RELATIVE to this cone's own world z, so the
    // asset works wherever it stands; the road runs toward -z, so "before the
    // cannon" is the +z side. Being a wire from physics, it is dark from the
    // very first frame: no script has to catch the beam while the stage is
    // still streaming in (which is what flashed it on at load).
    if (mat.gated > 0.5) {
        let cannon_z = mesh_functions::get_world_from_local(input.instance_index)[3].z;
        let rover_z = mat.rover_level * 400.0 - 200.0;
        let d = rover_z - cannon_z;              // > 0: rover not yet at the cannon
        // Ignition ramps over `gate_ramp` metres of approach, so the beam
        // SHOOTS out of the barrel (length follows throttle) rather than
        // popping in whole; it goes out at once behind the rover.
        let ignite = clamp((mat.gate_ahead - d) / max(mat.gate_ramp, 1e-3), 0.0, 1.0);
        t = t * ignite * step(-mat.gate_behind, d);
    }

    // A dead engine emits NOTHING — not a residual glow. The photometry model
    // gates its light to exactly zero at zero throttle for the same reason, and
    // the two must agree or a coasting shot picks up a plume with no light or a
    // light with no plume.
    if (t <= 0.0) {
        return vec4<f32>(0.0);
    }

    // Thrust and visible plume length are different observables. A low valve
    // opening still produces a hot, camera-readable jet; the authored exponent
    // makes that perceptual mapping explicit and editable while zero throttle
    // remains exactly dark. The photometry model continues to use raw throttle.
    let visual_throttle = pow(t, clamp(mat.throttle_exponent, 0.1, 1.0));
    let len = max(visual_throttle, 1e-3);
    let wid = mat.width_idle + (1.0 - mat.width_idle) * visual_throttle;

    // The rasteriser gives us a point on the fixed authored cone. Use the mesh
    // transform rather than world-space assumptions: the same material works
    // for a vessel nozzle, a side RCS jet, or a nozzle on a nested USD instance.
    let local_from_world = mesh_functions::get_local_from_world(input.instance_index);
    let p = (local_from_world * vec4<f32>(input.world_position.xyz, 1.0)).xyz;
    let a = clamp(p.y + 0.5, 0.0, 1.0);
    let axial = 1.0 - a;

    // Mask the fixed cone into a short, readable jet. The small fade band keeps
    // the tip from popping as throttle changes, while a full-throttle command
    // still fills the complete authored envelope.
    // Length is measured FROM THE NOZZLE. The shipped plume has its nozzle at
    // the cone's base (a = 0); a cone mounted the other way round — the
    // cannons, apex at the muzzle so the jet flares out over the road — sets
    // `nozzle_at_apex`, or a growing flame would start in the air and reach
    // back to the barrel.
    let from_nozzle = select(a, 1.0 - a, mat.nozzle_at_apex > 0.5);
    var cutoff = 1.0;
    if len < 0.999 {
        cutoff = 1.0 - smoothstep(len, min(len + 0.12, 1.0), from_nozzle);
    }
    if cutoff <= 0.0 {
        return vec4<f32>(0.0);
    }

    // Turbulence is advected downstream. It changes the edge/core balance and
    // radiance, so the engine flame visibly changes over time without any Rhai
    // tick work or hidden state.
    let n = vnoise(vec3<f32>(
        p.x * mat.flicker_scale,
        p.z * mat.flicker_scale,
        a * mat.flicker_scale + globals.time * mat.flicker_speed
    ));
    let shimmer = 1.0 - clamp(mat.flicker, 0.0, 1.0) * 0.45 * (1.0 - n);
    // Keep the temperature structure visible in the envelope itself. The inner
    // core cone adds the hottest layer, but the outer volume must still read as
    // a flame when transparent-surface ordering places that layer behind it.
    // Cone-local x/z are radius-normalised by the authored unit cone.
    let radial = clamp(length(vec2<f32>(p.x, p.z)), 0.0, 1.0);
    let centre_hot = 1.0 - smoothstep(0.12, 0.78, radial);

    // ── RUNNING LIGHTS ────────────────────────────────────────────────────
    // The same idea as the pylons' upward-travelling rings in
    // `holo_pylon.wgsl`, wrapped onto the plume axis. `a` runs along the beam
    // and `ang01` around it, so mixing them by `spiral_turns` turns flat rings
    // into a helix that climbs as it travels. `ring_gain = 0` leaves the beam
    // exactly as the shipped plume draws it.
    let ang01 = atan2(p.z, p.x) / TAU + 0.5;
    let band_phase = (a * mat.ring_count + ang01 * mat.spiral_turns)
                   - globals.time * mat.ring_speed;
    let band = pow(0.5 + 0.5 * cos(band_phase * TAU), max(mat.ring_sharp, 1.0));
    let bands = 1.0 + mat.ring_gain * band;
    let core_mix = clamp(0.32 + 0.52 * centre_hot + 0.1 * axial + 0.06 * shimmer, 0.0, 1.0);
    let tint = mix(mat.edge_color, mat.core_color, core_mix);
    let width_response = 0.35 + 0.65 * wid;
    let radiance = (0.8 + 1.5 * cutoff) * shimmer * width_response;
    // COVERAGE IS A KNOB HERE — this is the only change from the shipped
    // `plume.wgsl`. Upstream, alpha is `cutoff * (0.55 + 0.35 * shimmer)`,
    // which floors coverage around 0.55 wherever the plume exists, so the jet
    // always reads as a solid object no matter how the other inputs are set.
    // `density` cannot help: it scales the EMISSIVE only and never touches
    // alpha. Multiplying by `beam_opacity` lets the same volume be drawn as a
    // headlight shaft you can see straight through.
    let alpha = clamp(cutoff * (0.55 + 0.35 * shimmer) * mat.beam_opacity
                      * (1.0 + 0.55 * mat.ring_gain * band), 0.0, 1.0);
    let emissive = tint * mat.density * radiance * bands;

    // The gprim's authored sub-1 `displayOpacity` selects Bevy's translucent
    // pipeline, so return both radiance and coverage. Alpha is not an opaque
    // cutout here: it weights the emitted RGB while the blend keeps the terrain
    // and vehicle behind the exhaust visible. The physical light remains a
    // separate SphereLight driven by Modelica photometry.
    return vec4<f32>(emissive, alpha);
}
