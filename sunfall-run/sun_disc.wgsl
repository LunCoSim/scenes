//! 80s synthwave "sun disc" for the general `ShaderMaterial`.
//!
//! The bound geometry is a plain sphere, sunk so most of it sits above the
//! ground plane (y=0) — a real sphere, not a billboard, so it reads
//! correctly from any angle and can be raised to show any fraction above
//! the horizon via its own xformOp:translate.
//!
//! Look: a vertical sunset gradient, cut by horizontal TRANSPARENT bands that
//! ripple upward. The bands are densest right at the horizon, widening and
//! fading on the way up and gone before the crown (`band_gap_grow` shapes that
//! falloff), each with a thin hot rim so it reads as a slit rather than a hole.
//!
//! The disc must be drawn ADDITIVELY (`lunco:surface:additive = true` on the
//! prim) for the bands to be transparent: additive blending means driving the
//! emissive to zero inside a band leaves whatever was already in the frame, so
//! the sky shows through. Under an opaque pipeline the bands would come out
//! black instead of clear.
//!
//! Unlit + emissive, animated from `globals.time` via `band_speed`.

#import bevy_pbr::{
    mesh_functions,
    forward_io::VertexOutput,
    mesh_view_bindings::{globals, view},
}

//!@ui      top_color     color  "Colour at the disc's crown (HDR)"
//!@default top_color     2.3,0.15,0.02
//!@ui      bottom_color  color  "Colour at the horizon line (HDR)"
//!@default bottom_color  2.9,0.55,0.03
//!@ui      glow          0 8    "Emissive gain"
//!@default glow          2.2
//!@ui      rim_gain      0 3    "Fresnel-rim contribution (glow past the silhouette)"
//!@default rim_gain      1.4
//!@ui      rim_power     0.5 6  "Fresnel falloff"
//!@default rim_power     2.6
//!@ui      line_color    color  "Accent-line neon tint (HDR)"
//!@default line_color    2.6,0.08,0.45
//!@ui      line_glow     0 8    "Accent-line emissive gain"
//!@default line_glow     3.4
//!@ui      band_count    0 24   "Accent lines packed into the band zone (before fade-out thins them)"
//!@default band_count    9.0
//!@ui      band_zone     0.05 1 "Fraction of the disc's height (from the horizon up) the lines can occupy"
//!@default band_zone     0.7
//!@ui      band_width    0.005 0.4 "Line thickness as a fraction of its slot (thin!)"
//!@default band_width    0.07
//!@ui      band_soft     0 0.1  "Line edge softness"
//!@default band_soft     0.01
//!@ui      band_gap_grow 0 4    "How much the gaps thin out and fade going up from the horizon"
//!@default band_gap_grow 1.4
//!@ui      band_speed    -2 2   "Ripple speed — positive scrolls the gaps UP the disc"
//!@default band_speed    0.06
//!@ui      gap_strength  0 1    "How transparent the gaps cut — 1 is fully see-through"
//!@default gap_strength  1.0
//!@ui      grad_start    0 0.9  "Latitude where the gradient starts — set to the horizon cut so the FULL ramp is visible"
//!@default grad_start    0.45
//!@ui      inside_gain   0 1    "Emissive scale on the INWARD-facing side, seen when the camera is inside the sphere"
//!@default inside_gain   0.28
//!@ui      grad_end      0.05 1 "Latitude where the ramp REACHES top_color — above this the disc is flat top_color"
//!@default grad_end      1.0
struct Material {
    top_color:     vec3<f32>,
    bottom_color:  vec3<f32>,
    glow:          f32,
    rim_gain:      f32,
    rim_power:     f32,
    line_color:    vec3<f32>,
    line_glow:     f32,
    band_count:    f32,
    band_zone:     f32,
    band_width:    f32,
    band_soft:     f32,
    band_gap_grow: f32,
    band_speed:    f32,
    gap_strength:  f32,
    grad_start:    f32,
    inside_gain:   f32,
    grad_end:      f32,
}

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> mat: Material;

@fragment
fn fragment(input: VertexOutput, @builtin(front_facing) is_front: bool) -> @location(0) vec4<f32> {
    // This sphere is authored with a real `radius` attribute (not a unit
    // mesh driven by xformOp:scale), so `get_local_from_world` only undoes
    // translate/rotate — p.y is in real metres, not [-1, 1]. Normalize by
    // the point's own distance from centre (≈ radius, since p sits on the
    // sphere surface) instead of assuming a fixed range: p.y/|p| is the
    // sphere's own cosine-of-latitude, in [-1, 1] regardless of radius or
    // how far the sphere is raised out of the ground.
    // a = 0 at the sphere's own equator, 1 at its crown.
    let local_from_world = mesh_functions::get_local_from_world(input.instance_index);
    let p = (local_from_world * vec4<f32>(input.world_position.xyz, 1.0)).xyz;
    let lat = p.y / max(length(p), 1e-4);
    let a = clamp((lat + 1.0) * 0.5, 0.0, 1.0);

    // The shell is `doubleSided` so the rover can drive INSIDE it. On this
    // build's additive pass that is not free: rendering the front faces and
    // the back faces separately shows they tile the disc EXACTLY ONCE between
    // them — so the pass does depth-test, and it keeps the FARTHER fragment,
    // not the nearer one. The result is that from outside you are looking at
    // the far wall's inner surface across almost the whole disc, dimmed by
    // `inside_gain`, while the correctly-lit outer surface facing you is
    // thrown away. (The one place the near wall won was a small ellipse at the
    // bottom, where the far wall dips under the opaque ground and loses to it.)
    // That is what turns the disc into a hollow beehive with a bowl in its
    // underside from any raised or offset camera: the "bands" you see there
    // are the inside of the back of the sphere, not sky through the cuts.
    // Head-on it hides, because a horizontal ray enters and leaves at the same
    // latitude, so the far wall is cut wherever the near wall is.
    // Fix: drop the far wall whenever the camera is OUTSIDE the shell, which
    // lets the near, properly-lit surface through and lets the cut bands show
    // real sky. Keep it when the camera is inside — that inner surface is the
    // only thing there is to see from in there. `cam` is the eye in the
    // sphere's own local frame, so comparing its distance from the centre
    // against this fragment's (which sits on the surface, i.e. the radius) is
    // the inside/outside test at any radius or position.
    let cam = (local_from_world * vec4<f32>(view.world_position, 1.0)).xyz;
    let camera_inside = length(cam) < length(p);
    if !is_front && !camera_inside {
        discard;
    }

    // Sunset gradient. The sphere is sunk so the horizon cuts it near its own
    // equator, which means a plain mix over the full latitude wastes the whole
    // bottom half of the ramp below ground and the visible disc reads as one
    // flat tint. Remap so `grad_start` (the horizon cut) is the bottom colour
    // and the crown is the top colour — the entire ramp lands where it shows.
    // The ramp runs between two latitudes rather than from `grad_start` to the
    // crown: `grad_end` is where it finishes, and everything above that is flat
    // `top_color`. Setting it to the sphere's middle keeps the upper half a
    // solid yellow and confines the red-orange fade to the lower half.
    let t = clamp((a - mat.grad_start) / max(mat.grad_end - mat.grad_start, 1e-3), 0.0, 1.0);
    let base = mix(mat.bottom_color, mat.top_color, t);

    // Camera-facing fresnel: bright at the silhouette, near-clear head-on —
    // a soft glow halo past the disc's own edge.
    let nrm = normalize(input.world_normal);
    let vdir = normalize(view.world_position - input.world_position.xyz);
    let fres = pow(clamp(1.0 - abs(dot(nrm, vdir)), 0.0, 1.0), max(mat.rim_power, 0.5));

    // Thin neon accent lines, additive on top of the gradient. Warped so
    // slots are narrow (high frequency) right at the horizon and widen
    // going up (band_gap_grow > 0) — the opposite curve from a plain evenly
    // ruled ladder — plus a brightness envelope that fades them to nothing
    // before reaching the top of the zone, so they thin out AND dim out
    // rather than stopping abruptly.
    // The band axis is WORLD up — perpendicular to the ground plane — so every
    // ring lies in a plane parallel to the grid. It is deliberately NOT the
    // camera's up vector: the chase camera is pitched down, so using it tilted
    // the whole stack of rings toward the viewer and the stripes came out
    // skewed. World up keeps them level no matter where the camera looks.
    // The prim carries no rotation, so local axes are world axes here.
    let up_ws = vec3<f32>(0.0, 1.0, 0.0);
    let band_h = dot(p, up_ws) / max(length(p), 1e-4);
    let a_band = clamp((band_h + 1.0) * 0.5, 0.0, 1.0);

    let zone = clamp(mat.band_zone, 1e-3, 1.0);
    let az = clamp(a_band / zone, 0.0, 1.0);
    let warped = 1.0 - pow(1.0 - az, 1.0 + max(mat.band_gap_grow, 0.0));
    let slots = max(mat.band_count, 1.0);
    // Scrolling the slot phase with time is what makes the bands ripple; a
    // positive `band_speed` walks the pattern toward the crown.
    let cell = fract(warped * slots - globals.time * mat.band_speed);
    let d = abs(cell - 0.5) * 2.0;
    let half_w = clamp(mat.band_width, 0.0, 1.0);

    // `gap` is 1 INSIDE a band. The disc is drawn additively, so scaling the
    // emissive to zero there leaves only whatever is already in the frame —
    // the sky reads straight through the gap. `edge` is the thin hot rim just
    // inside each cut, which keeps the bands from looking like flat holes.
    let gap = 1.0 - smoothstep(half_w - mat.band_soft, half_w + mat.band_soft, d);
    let gap_inner = 1.0 - smoothstep(half_w - mat.band_soft * 4.0, half_w - mat.band_soft * 2.0, d);
    let edge = clamp(gap - gap_inner, 0.0, 1.0);
    let envelope = 1.0 - smoothstep(0.45, 1.0, az);
    var cut = 0.0;
    var rim_line = 0.0;
    if a_band < zone {
        cut = gap * envelope * clamp(mat.gap_strength, 0.0, 1.0);
        rim_line = edge * envelope;
    }

    // Seen from INSIDE the shell (doubleSided), the camera faces the crown of
    // the gradient across the whole screen, and at the exterior's intensity it
    // clips to flat cream. Scale the inward-facing side down so the interior
    // stays readable without touching the look from outside.
    let face_gain = select(mat.inside_gain, 1.0, is_front);
    let lit = (base * mat.glow + base * mat.rim_gain * fres) * face_gain;
    let emissive = lit * (1.0 - cut) + mat.line_color * mat.line_glow * rim_line * face_gain;
    return vec4<f32>(emissive, 1.0);
}
