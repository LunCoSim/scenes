//! Cosmic sunset sky — a fullscreen camera-background shader, same render
//! contract as the shipped `starfield.wgsl` (see that file for why: this is
//! the dedicated skybox pipeline, not a regular mesh `ShaderMaterial` — no
//! mesh, no world position, the ray is reconstructed from the camera's own
//! clip-space matrices). Bind it to an `Xform` with
//! `lunco:surface:skybox = true`, exactly like `StarfieldSky`.
//!
//! Four layers, painted in order:
//!   1. A vertical gradient — blue at the zenith, hot pink at the horizon.
//!   2. A sun-anchored glow: the sky floods pink around the sun's own
//!      direction, which is what sells the sunset (a flat vertical gradient
//!      cannot, because it has no azimuth term).
//!   3. A jagged distant-mountain ridge wrapped around the full horizon
//!      (ridged fbm on the azimuth angle, so it never repeats or tiles),
//!      with a gaussian NOTCH cut at the sun's azimuth so the sun sits in an
//!      opening instead of colliding with the silhouette.
//!   4. Sparse pinprick stars plus scattered parallel star trails, both kept
//!      above the ridge line. The trails run in toward the sun.
//!
//! `sun_azimuth` / `sun_elevation` must be pointed at wherever the scene's
//! sun sphere actually is — they are what anchors layers 2 and 3.

#import bevy_core_pipeline::fullscreen_vertex_shader::FullscreenVertexOutput
#import bevy_pbr::utils::coords_to_viewport_uv
#import bevy_render::view::View
#import lunco::noise::fbm

@group(0) @binding(0) var<uniform> view: View;

//!@ui      zenith_color      color "Colour straight up (HDR)"
//!@default zenith_color      0.05,0.07,0.30
//!@ui      horizon_color     color "Colour at the horizon"
//!@default horizon_color     0.85,0.13,0.42
//!@ui      mountain_color    color "Distant mountain silhouette colour"
//!@default mountain_color    0.06,0.03,0.13
//!@ui      sun_glow_color    color "Colour of the sky glow around the sun (HDR)"
//!@default sun_glow_color    2.0,0.30,0.75
//!@ui      streak_color      color "Star-trail colour (HDR)"
//!@default streak_color      1.6,1.2,2.0
//!@ui      edge_color        color "Neon glow along the ridge line itself (HDR)"
//!@default edge_color        2.0,0.15,1.0
//!@ui      horizon_falloff   0.15 2  "Gradient curve — lower keeps pink closer to the horizon"
//!@default horizon_falloff   0.55
//!@ui      mountain_height   0 0.5   "Average mountain height (sine of elevation angle)"
//!@default mountain_height   0.05
//!@ui      mountain_relief   0 0.3   "How tall the peaks are"
//!@default mountain_relief   0.035
//!@ui      mountain_freq     0.5 20  "Mountain silhouette detail frequency"
//!@default mountain_freq     3.0
//!@ui      mountain_soft     0.001 0.05 "Silhouette edge softness"
//!@default mountain_soft     0.006
//!@ui      mountain_sharp    0 1     "Blend to ridged noise — 1 is craggy peaks, 0 is rolling hills"
//!@default mountain_sharp    0.85
//!@ui      notch_width       0 1.5   "Angular half-width of the gap cut for the sun (radians)"
//!@default notch_width       0.30
//!@ui      notch_depth       0 0.5   "How deep the sun's gap cuts into the ridge"
//!@default notch_depth       0.10
//!@ui      sun_azimuth       -180 180 "Sun azimuth in degrees — atan2(z, x) of the sun prim"
//!@default sun_azimuth       -90.0
//!@ui      sun_elevation     -10 60  "Sun elevation in degrees above the horizon"
//!@default sun_elevation     4.0
//!@ui      sun_glow_focus    1 200   "Tightness of the pink glow — higher hugs the sun"
//!@default sun_glow_focus    14.0
//!@ui      sun_glow_gain     0 4     "Strength of the pink glow"
//!@default sun_glow_gain     1.1
//!@ui      star_density      0 0.02  "Fraction of sky cells that sparkle"
//!@default star_density      0.003
//!@ui      star_brightness   0 8     "Star brightness (HDR)"
//!@default star_brightness   2.0
//!@ui      streak_density    0 0.5   "Fraction of trail slots that carry a streak"
//!@default streak_density    0.06
//!@ui      streak_length     0.02 1  "Length of each trail (radians of arc)"
//!@default streak_length     0.34
//!@ui      streak_brightness 0 6     "Star-trail brightness (HDR)"
//!@default streak_brightness 1.5
//!@ui      streak_sectors    16 512  "How many angular slots around the sun can carry a trail"
//!@default streak_sectors    220.0
//!@ui      streak_width      0.0002 0.02 "Trail half-width, radians (constant along its length)"
//!@default streak_width      0.00045
//!@ui      edge_gain         0 6     "Brightness of the ridge-line glow"
//!@default edge_gain         1.0
//!@ui      edge_width        0.0005 0.05 "Thickness of the ridge-line glow"
//!@default edge_width        0.004
struct Material {
    zenith_color:      vec3<f32>,
    horizon_color:     vec3<f32>,
    mountain_color:    vec3<f32>,
    sun_glow_color:    vec3<f32>,
    streak_color:      vec3<f32>,
    edge_color:        vec3<f32>,
    horizon_falloff:   f32,
    mountain_height:   f32,
    mountain_relief:   f32,
    mountain_freq:     f32,
    mountain_soft:     f32,
    mountain_sharp:    f32,
    notch_width:       f32,
    notch_depth:       f32,
    sun_azimuth:       f32,
    sun_elevation:     f32,
    sun_glow_focus:    f32,
    sun_glow_gain:     f32,
    star_density:      f32,
    star_brightness:   f32,
    streak_density:    f32,
    streak_length:     f32,
    streak_brightness: f32,
    streak_sectors:    f32,
    streak_width:      f32,
    edge_gain:         f32,
    edge_width:        f32,
}

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> mat: Material;

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Shortest signed angular difference, wrapped into [-pi, pi] — so a notch at
// azimuth +175 deg still reaches a pixel at -175 deg.
fn ang_delta(a: f32, b: f32) -> f32 {
    let d = a - b;
    return d - 6.28318530718 * round(d / 6.28318530718);
}

@fragment
fn fragment(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    // Reconstruct the view ray the same way the shipped starfield sky does —
    // this is the documented, correct way to get a direction in this
    // background pipeline (no mesh, no world position to read).
    let viewport_uv = coords_to_viewport_uv(in.position.xy, view.viewport);
    let view_position_homogeneous = view.view_from_clip * vec4(
        viewport_uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0),
        1.0,
        1.0,
    );
    let view_ray_direction =
        view_position_homogeneous.xyz / view_position_homogeneous.w;
    let dir = normalize((view.world_from_view * vec4(view_ray_direction, 0.0)).xyz);

    let elev = clamp(dir.y, -1.0, 1.0);
    let up = clamp(elev, 0.0, 1.0);

    // 1. Vertical gradient — pink at the horizon, blue overhead.
    var col = mix(mat.horizon_color, mat.zenith_color, pow(up, max(mat.horizon_falloff, 0.05)));

    // 2. Sun-anchored glow. Without this the sky has no azimuth term at all
    //    and reads as a flat gradient rather than a sunset.
    let sun_az = radians(mat.sun_azimuth);
    let sun_el = radians(mat.sun_elevation);
    let sun_dir = vec3<f32>(cos(sun_az) * cos(sun_el), sin(sun_el), sin(sun_az) * cos(sun_el));
    let sun_cos = clamp(dot(dir, sun_dir), 0.0, 1.0);
    let sun_glow = pow(sun_cos, max(mat.sun_glow_focus, 1.0));
    col += mat.sun_glow_color * mat.sun_glow_gain * sun_glow;

    // 3. Distant mountain ridge. Ridged noise (1 - |2n-1|) gives craggy peaks
    //    instead of the rolling humps plain fbm produces; `mountain_sharp`
    //    blends between the two. A second, higher-frequency octave adds the
    //    smaller broken detail along each flank.
    let theta = atan2(dir.z, dir.x);

    // Ridged multifractal — the standard construction for a mountain profile,
    // and the reason the old plain fbm read as rolling hills. Each octave is
    // folded (1 - |2n-1|) so its maximum becomes a sharp crest instead of a
    // smooth hump, squared to tighten that crest, then multiplied by a weight
    // carried down from the octave above. That weighting is the important
    // part: fine detail only appears where the coarse octave was already high,
    // so ridges get broken rocky flanks while valleys stay clean — which is
    // what makes a range look eroded rather than wavy.
    var sum = 0.0;
    var amp = 0.5;
    var w = 1.0;
    var f = mat.mountain_freq;
    for (var i = 0; i < 5; i = i + 1) {
        let n = fbm(vec3<f32>(cos(theta) * f, sin(theta) * f, f * 0.137), 1, 0.5);
        var r = 1.0 - abs(n * 2.0 - 1.0);
        r = r * r * w;
        w = clamp(r * 2.2, 0.0, 1.0);
        sum = sum + r * amp;
        amp = amp * 0.55;
        f = f * 2.13;
    }
    let crags = clamp(sum * 1.45, 0.0, 1.0);

    // Smooth profile kept so `mountain_sharp` still dials hills <-> crags.
    let hills = fbm(vec3<f32>(cos(theta) * mat.mountain_freq, sin(theta) * mat.mountain_freq, 0.0), 3, 0.5);
    let shaped = mix(hills, crags, clamp(mat.mountain_sharp, 0.0, 1.0));

    // `mountain_height` is now the valley floor and `mountain_relief` the rise
    // to the summits, rather than a mean with noise swinging either side of it.
    var ridge = mat.mountain_height + mat.mountain_relief * shaped;

    // Gap for the sun: a gaussian notch centred on the sun's azimuth, so the
    // ridge dips away and the sun sits in an opening rather than behind rock.
    let dtheta = ang_delta(theta, sun_az);
    let notch = exp(-pow(dtheta / max(mat.notch_width, 1e-3), 2.0));
    ridge -= mat.notch_depth * notch;

    let mountain_mask = 1.0 - smoothstep(ridge, ridge + mat.mountain_soft, elev);
    col = mix(col, mat.mountain_color, mountain_mask);

    // Neon rim riding the ridge line. A gaussian centred ON the silhouette
    // boundary, so it glows a little to each side of it and traces every peak
    // and notch — including the gap cut for the sun. Added after the mountain
    // fill so the body can sit at pure black and only the outline lights up.
    let d_edge = (elev - ridge) / max(mat.edge_width, 1e-4);
    col += mat.edge_color * mat.edge_gain * exp(-d_edge * d_edge);

    // 4a. Star trails running IN toward the sun, as in the reference. Exactly
    //     ONE streak per angular sector, placed at a hashed radius: the first
    //     radial attempt also cut cells along the radius, so several collinear
    //     cells could fire at once and the trails came out as bundled
    //     "whiskers". Thickness is measured perpendicular (r * dBearing), so a
    //     trail keeps a constant width instead of fanning out with distance.
    let elev_ang = asin(clamp(dir.y, -1.0, 1.0));
    let to_sun = vec2<f32>(ang_delta(theta, sun_az), elev_ang - radians(mat.sun_elevation));
    let r = length(to_sun);
    let bearing = atan2(to_sun.y, to_sun.x);
    let sectors = max(mat.streak_sectors, 8.0);
    let sfrac = (bearing / 6.28318530718 + 0.5) * sectors;
    let sector = floor(sfrac);
    let on = step(1.0 - mat.streak_density, hash21(vec2<f32>(sector, 13.0)));
    // Inner radius. 0.20 rad (~11.5 deg) left a bare ring around the sun
    // sphere; 0.14 lets some trails start nearer it. The outer reach is held
    // roughly where it was by trimming the span to match.
    let r0 = 0.14 + hash21(vec2<f32>(sector, 3.0)) * 1.16;
    let len = max(mat.streak_length, 0.02) * (0.6 + 0.8 * hash21(vec2<f32>(sector, 29.0)));
    let along = (r - r0) / len;
    let inside = step(0.0, along) * step(along, 1.0);
    let taper = smoothstep(0.0, 0.18, along) * (1.0 - smoothstep(0.45, 1.0, along));
    let across = abs(fract(sfrac) - 0.5) * (6.28318530718 / sectors) * r;
    // Edge antialiased in SCREEN space, not as a fixed fraction of the width.
    // The original ramp (0.85w -> w) was a constant 15% of the trail, so the
    // two knobs fought: widen it and the trail is an airbrushed stroke, shrink
    // the width to sharpen it and the edge goes sub-pixel and stair-steps.
    // Deriving the ramp from `fwidth` decouples them — the edge stays put at
    // one pixel however thin the trail gets, so `streak_width` is free to go
    // genuinely thin. This is analytic pixel coverage, a ONE pixel transition;
    // a smoothstep over +/-aa spread it over two and still read as haze.
    // Clamp is load-bearing: `fract` jumps at the sector seam and `fwidth`
    // spikes there, which would otherwise resolve to ~0.5 coverage and draw a
    // ghost line down every seam.
    let aa = clamp(fwidth(across), 1e-7, mat.streak_width);
    let thin = clamp((mat.streak_width - across) / aa + 0.5, 0.0, 1.0);
    let streak = on * inside * taper * thin;

    // 4b. Sparse pinprick stars — small, crisp, hashed per view direction.
    let cell = floor(dir.xz * 600.0 + dir.y * 600.0);
    let starf = hash21(cell);
    let star = step(1.0 - mat.star_density, starf);

    // Both star layers are clipped to the sky above the (notched) ridge.
    let above_ridge = step(ridge + 0.008, elev);
    col += vec3<f32>(1.0) * mat.star_brightness * star * above_ridge;
    col += mat.streak_color * mat.streak_brightness * streak * above_ridge;

    return vec4<f32>(col, 1.0);
}
