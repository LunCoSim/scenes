//! Neon floor grid over lunar regolith, for the general `ShaderMaterial`.
//! Bind it to a large flat ground gprim: a warm-grey regolith base (fBm grain +
//! broad mottling, self-lit at a moonlit level) with a glowing cyan grid keyed
//! to WORLD XZ on top, so the grid stays put as things drive over it.
//! Anti-aliased with `fwidth`, a soft distance fade, and a slow pulse ring
//! travelling out from the origin. Opaque. Animated from `globals.time` only.
//!
//! LOCAL LIGHTS ONLY. The floor takes the scene's point and spot lights —
//! the rover's fog lamps, its under-glow and rear wash, the cannons' muzzle
//! flashes — as a diffuse pool on the regolith, and deliberately NOT the sun
//! or the ambient dome: those would lift the whole floor out of the near-black
//! Tron look it is tuned for. It walks Bevy's own clustered light list with
//! the engine's falloff and cone maths (`bevy_pbr::lighting::point_light` /
//! `spot_light`, Bevy 0.19), diffuse term only.
//!
//! Two treatments, on purpose:
//!   * POINT lights are physical — irradiance x exposure x `light_albedo`.
//!   * SPOT lights (in this scene: only the fog lamps) draw their pool at a
//!     brightness set HERE, `spot_gain`, from the lamp's own position, aim,
//!     cone, falloff and colour — but not its absolute power. The engine's
//!     USD-to-lumens scale and the camera EV are not documented, and at a
//!     physical 60 klm the pool landed invisibly faint. A stylised floor
//!     gets a stylised pool; `spot_gain` 0 turns it off.
//!
//! Inputs are snake_case — the ShaderMaterial reflection binds the WGSL struct
//! field names.

#import bevy_pbr::{
    forward_io::VertexOutput,
    mesh_view_bindings::{globals, view, clustered_lights},
    mesh_view_types::POINT_LIGHT_FLAGS_SPOT_LIGHT_Y_NEGATIVE,
    clustered_forward,
}
#import lunco::noise::{vnoise, fbm}

//!@ui      line_color  color "Grid-line neon (HDR; values >1 bloom)"
//!@default line_color  0.0,1.7,2.1
//!@ui      regolith    color "Regolith base albedo"
//!@default regolith    0.17,0.155,0.135
//!@ui      cell        0.2 20  "Grid spacing (m)"
//!@default cell        3.0
//!@ui      line_width  0.004 0.2 "Line half-width (fraction of a cell)"
//!@default line_width  0.02
//!@ui      glow        0 8    "Grid-line emissive gain"
//!@default glow        2.8
//!@ui      major_every 0 12   "Every Nth line is brighter (0 = off)"
//!@default major_every 5.0
//!@ui      grain       0 1    "Regolith grain depth"
//!@default grain       0.55
//!@ui      fade_dist   10 400 "Distance where the grid fades out (m)"
//!@default fade_dist   85.0
//!@ui      pulse_speed 0 6    "Outward pulse-ring speed"
//!@default pulse_speed 1.3
//!@ui      spine_color      color "Colour of the single highlighted centre-line spine (HDR)"
//!@default spine_color      2.6,1.3,0.05
//!@ui      spine_x          -200 200 "World X of the highlighted spine line (the road's centreline)"
//!@default spine_x          0.0
//!@ui      spine_half_width 0.02 2   "Spine half-width in metres"
//!@default spine_half_width 0.12
//!@ui      spine_glow       0 8     "Spine emissive gain — steady, no pulse (unlike the rest of the grid)"
//!@default spine_glow       3.2
//!@ui      light_albedo     0 2     "How strongly the floor takes local lights (0 = unlit)"
//!@default light_albedo     0.0
//!@ui      spot_gain        0 20    "Spot-light pool brightness (1 m in front of the lamp, facing it)"
//!@default spot_gain        0.0
struct Material {
    line_color:       vec3<f32>,
    cell:             f32,
    regolith:         vec3<f32>,
    line_width:       f32,
    glow:             f32,
    major_every:      f32,
    grain:            f32,
    fade_dist:        f32,
    pulse_speed:      f32,
    spine_color:      vec3<f32>,
    spine_x:          f32,
    spine_half_width: f32,
    spine_glow:       f32,
    light_albedo:     f32,
    spot_gain:        f32,
}

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> mat: Material;

// Anti-aliased line at every integer of `c`.
fn grid_axis(c: f32, half_w: f32) -> f32 {
    let d = abs(fract(c + 0.5) - 0.5);
    let w = half_w + fwidth(c);
    return 1.0 - smoothstep(0.0, w, d);
}

const PI: f32 = 3.14159265;

// Light landing on this fragment from every point/spot light in its cluster.
// Mirrors bevy_pbr's point_light()/spot_light(): the same inverse-square with
// smooth range cut-off, and the same packed spot direction and cone ramp.
//   .point — physical: exposure-adjusted irradiance / pi, times albedo later.
//   .spot  — stylised: unit-brightness colour x the geometric falloff, so a
//            spot's pool is exactly `spot_gain` at 1 m in front of the lamp.
struct LocalLight {
    point: vec3<f32>,
    spot:  vec3<f32>,
}

fn local_lights(world_pos: vec4<f32>, frag_xy: vec2<f32>, n: vec3<f32>) -> LocalLight {
    let is_ortho = view.clip_from_view[3].w == 1.0;
    let view_z = dot(vec4<f32>(
        view.view_from_world[0].z,
        view.view_from_world[1].z,
        view.view_from_world[2].z,
        view.view_from_world[3].z
    ), world_pos);
    let cluster = clustered_forward::view_fragment_cluster_index(frag_xy, view_z, is_ortho);
    let ranges = clustered_forward::unpack_clusterable_object_index_ranges(cluster);

    var out: LocalLight;
    out.point = vec3<f32>(0.0);
    out.spot = vec3<f32>(0.0);
    for (var i: u32 = ranges.first_point_light_index_offset;
            i < ranges.first_reflection_probe_index_offset;
            i = i + 1u) {
        let id = clustered_forward::get_clusterable_object_id(i);
        let light = &clustered_lights.data[id];
        let to_light = (*light).position_radius.xyz - world_pos.xyz;
        let d2 = max(dot(to_light, to_light), 1e-4);
        let l = to_light * inverseSqrt(d2);
        let ndotl = saturate(dot(n, l));
        let f = d2 * (*light).color_inverse_square_range.w;
        let fall = saturate(1.0 - f * f);
        let shape = fall * fall / d2 * ndotl;
        let rgb = (*light).color_inverse_square_range.rgb;
        if i >= ranges.first_spot_light_index_offset {
            var sd = vec3<f32>((*light).light_custom_data.x, 0.0, (*light).light_custom_data.y);
            sd.y = sqrt(max(0.0, 1.0 - sd.x * sd.x - sd.z * sd.z));
            if ((*light).flags & POINT_LIGHT_FLAGS_SPOT_LIGHT_Y_NEGATIVE) != 0u {
                sd.y = -sd.y;
            }
            let cone = saturate(dot(-sd, l) * (*light).light_custom_data.z + (*light).light_custom_data.w);
            let tint = rgb / max(max(rgb.r, max(rgb.g, rgb.b)), 1e-6);
            out.spot += tint * (shape * cone * cone);
        } else {
            out.point += rgb * shape;
        }
    }
    out.point = out.point * (view.exposure / PI);
    return out;
}

@fragment
fn fragment(input: VertexOutput) -> @location(0) vec4<f32> {
    let t = globals.time;
    let wp3 = input.world_position.xyz;
    let wp = wp3.xz;

    // Regolith base: fine grain + broad mottling, warm grey.
    let fine = fbm(wp3 * 0.6, 4, 0.5);
    let mottle = fbm(wp3 * 0.05, 3, 0.5);
    let shade = clamp(0.5 + mat.grain * (fine - 0.4) + 0.5 * (mottle - 0.5), 0.15, 1.15);
    var col = mat.regolith * shade;

    // Local lights land on the regolith, grain and all. Skipped entirely when
    // both gains are 0 so an unlit floor pays nothing for the light walk.
    if mat.light_albedo > 0.0 || mat.spot_gain > 0.0 {
        // Face the normal up whichever way the plane was wound — every light
        // that matters here is above the floor.
        let nn = normalize(input.world_normal);
        let n_up = select(-nn, nn, nn.y >= 0.0);
        let lamp = local_lights(input.world_position, input.position.xy, n_up);
        col += (lamp.point * mat.light_albedo + lamp.spot * mat.spot_gain) * shade;
    }

    // Cyan neon grid on top.
    let g = wp / max(mat.cell, 0.05);
    var line = max(grid_axis(g.x, mat.line_width), grid_axis(g.y, mat.line_width));
    if mat.major_every >= 1.0 {
        let gm = g / mat.major_every;
        let major = max(grid_axis(gm.x, mat.line_width * 0.6), grid_axis(gm.y, mat.line_width * 0.6));
        line = max(line, major * 1.8);
    }
    let d = length(wp);
    let fade = 1.0 - smoothstep(mat.fade_dist * 0.35, mat.fade_dist, d);
    let ring = 0.6 + 0.4 * sin(d * 0.2 - t * mat.pulse_speed);
    col += mat.line_color * mat.glow * (clamp(line, 0.0, 2.0) * fade * ring);

    // Single highlighted centreline spine — the road's own lane line, a
    // steady glow with no pulse, independent of the periodic cyan grid.
    let spine_d = abs(wp.x - mat.spine_x);
    let spine_w = mat.spine_half_width + fwidth(wp.x);
    let spine = 1.0 - smoothstep(0.0, spine_w, spine_d);
    col += mat.spine_color * mat.spine_glow * spine;

    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
