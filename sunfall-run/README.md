# Sunfall Run 

A neon road runs across a flat lunar site, lined with holographic palm pylons,
and ends *inside* a sunken synthwave sun. You drive a Cybertruck-styled rover
down it. 

## Open it

You need [LunCoSim](https://github.com/LunCoSim/lunco-sim) installed. Download
or clone this folder, then in LunCoSim choose **File → Open Folder/Twin** and pick either
the folder itself. The folder is a Twin: its
`twin.toml` names `my_survey.usda` as the scene to open.

To start LunCoSim straight into the scene from a terminal, pass the scene
file to `--scene`:

```sh
luncosim --scene path/to/sunfall-run/my_survey.usda
```

`luncosim` is the LunCoSim executable; where it lives depends on how you
installed LunCoSim on your system.

The rover waits until you take it. **Click it** to take control, then drive
with **WASD**. Clicking it also brings up its autopilot options, which follow
the same route (`survey_patrol.btxml`) if you would rather watch.

## The course

One straight road, three stages:

1. **Start** — the rover sits at the first pair of palms (`z ≈ +60`).
2. **The flame** — two cannons midway along (`z = -23.55`) light as you
   approach and fire over the road until you are past them.
3. **The sun** — the road runs into the sun disc; the finish is at its centre
   (`z = -170`). The rover brakes to a stop and the run is complete. Just
   past the finish, inside the sun, a vintage neon arrow sign reading
   "To the ABYSS" points on toward the edge of the world.

Behind the scenes there are four checkpoints (`Waypoint1`–`4` in
`my_survey.usda`): the start, one just before the cannons, one just after,
and the sun. The mission shows no on-screen messages — the flame is meant to
be a surprise. Each checkpoint is logged with the rover's battery charge, e.g.
`[power] waypoint_2_reached: battery SoC = …`, and a warning appears if the
battery runs flat. The battery is charged by the solar panel on the roof.

## The files

This folder is a **portable Twin**. Its own files are referenced as
`twin://my-survey/<file>` — `my-survey` is the `name` in `twin.toml`, so the
folder itself can be called anything. Only parts that ship with LunCoSim
are referenced as `lunco://`.

| File | Role |
|---|---|
| `twin.toml` | The Twin's name and the scene it opens by default. |
| `my_survey.usda` | The scene: ground, lunar gravity, sky, sun, road, 20 palm pylons, 2 flame cannons, the "To the ABYSS" sign, 4 checkpoints, the rover and its Cybertruck bodywork, and the mission. |
| `cybertruck.usda` | The rover: a copy of LunCoSim's `skid_rover.usda` — chassis, drivetrain, battery, solar panel, sensors — with its headlights removed. |
| `holo_pylon_waypoint.usda` | One palm pylon: trunk, frond crown and materials. |
| `holo_cannon.usda` | One flame cannon: plinth, column, barrel, flame beam and a muzzle glow. |
| `holo_pylon.wgsl` | The neon shader on the pylons, fronds and cannon hardware. |
| `flame_beam.wgsl` | The cannon flame: LunCoSim's `plume.wgsl` with an added `beam_opacity` input. |
| `cosmic_sky.wgsl` | The sky: ridgeline, stars and star trails. |
| `sun_disc.wgsl` | The synthwave sun and its see-through bands. |
| `abyss_sign.wgsl` | The "To the ABYSS" sign: neon lettering, outline tube, chasing marquee bulbs and a flickering letter. |
| `neon_grid.wgsl` | The road grid. |
| `neon_trim.wgsl` | The rover's neon trim. |
| `tail_light.wgsl` | The rover's animated rear light bar — steady red while driving, a stepped fill while reversing. |
| `survey_mission.rhai` | The mission: waits for the four checkpoints, logs battery charge at each, stops the rover at the finish. |
| `survey_patrol.btxml` | The autopilot route: drive to each checkpoint in order. |

## Changing it

- **Checkpoints.** A checkpoint lives in three places, and all three must
  agree: its `Waypoint` prim in `my_survey.usda`, its `drive_to` line in
  `survey_patrol.btxml`, and the `milestones` list in `survey_mission.rhai`.
- **When the cannons fire.** No script switches them: each cannon's flame is
  wired to the rover's position in `my_survey.usda` and burns only while the
  rover is near. The window is `gate_ahead`, `gate_behind` and `gate_ramp` in
  `Flame_Mat` in `holo_cannon.usda`. Don't change flame or light values from a
  script at run time (`SetUsdAttribute`, `SetObjectProperty`) — that rebuilds
  the whole scene.
- **Checking your edits.** `luncosim --validate survey_mission.rhai
  survey_patrol.btxml` checks the script and route for syntax. It can't check
  the `.usda` files (they report `has no composing Twin root` there, which is
  expected); open the scene and read the log instead.

## A warning you can ignore

```
[environment] 1 co-sim model(s) want a local Earth direction, but
`EarthDirectionWorld` is degenerate …
```

The rover's Earth-tracking antenna is looking for an Earth this scene doesn't
have. The antenna holds its position; nothing else is affected.

