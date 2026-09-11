# LunCoSim Scenes

Open scenes for [LunCoSim](https://github.com/LunCoSim/lunco-sim) that are
**not bundled with the simulator**: missions, twins, test courses, visual
experiments and community builds. Anyone can use them, learn from them, and
contribute their own.

Each scene is a self-contained folder. Clone the repository, open a folder in
LunCoSim, and drive.

## Scenes

| Scene | What it is |
|---|---|
| [`sunfall-run/`](sunfall-run/) | A 200 m neon road across a lunar site, lined with holographic palms and flame cannons, ending inside a synthwave sun. Drive a Cybertruck-styled rover down it. |

## Open a scene

You need LunCoSim installed.

1. Clone this repository:

   ```sh
   git clone https://github.com/LunCoSim/scenes.git
   ```

2. Open the scene's folder in LunCoSim. Every folder here contains a
   `twin.toml`, so the app opens it as a **Twin** and loads its default
   scene.

   You can also pass a scene file directly on the command line. Pass the
   `.usda` file, not the folder:

   ```sh
   /Applications/LunCoSim.app/Contents/MacOS/luncosim \
       --scene /path/to/scenes/sunfall-run/my_survey.usda
   ```

Each scene's own `README.md` explains its controls and what to look for.

## How a scene folder works

Every scene is a **portable Twin**: a folder that carries everything it needs
except the parts that ship with LunCoSim.

```
sunfall-run/
├── twin.toml          # name, version, description, default scene
├── README.md          # what it is, how to play it, what each file does
├── my_survey.usda     # the scene
├── *.usda             # its own props and vehicles
├── *.wgsl             # its own shaders
└── *.rhai / *.btxml   # its own mission scripts and behaviours
```

A minimal `twin.toml`:

```toml
name = "my-survey"
version = "0.1.0"
description = "One line saying what the scene is."

[usd]
default_scene = "my_survey.usda"
```

References inside the scene use two schemes:

- `twin://<name>/<file>` for the scene's own files. `<name>` is the `name`
  in `twin.toml`, so the folder can be renamed without breaking anything.
- `lunco://<path>` for assets that ship with LunCoSim, such as vehicles,
  shaders and celestial data.

Never use absolute paths. They only work on the machine that wrote them.

## Contribute a scene

1. **Build it in LunCoSim.** To turn your open documents into a Twin, run
   `CreateTwin` from the command palette (⌘P / Ctrl+P). It writes
   `twin.toml`, saves your documents into the folder, and marks the first
   scene as the default.
2. **Keep it portable.** Reference your own files with `twin://` and the
   app's with `lunco://`. If you change an app asset, copy it into your
   folder under a new name, the way `sunfall-run/cybertruck.usda` is a
   modified copy of LunCoSim's skid rover, and say so in your README.
3. **Check you can license it.** See [Licensing your
   contribution](#licensing-your-contribution) below. Everything in your
   folder must be yours to give away, or declared in a `CREDITS.md`.
4. **Validate it.** This checks parsing only. It opens no window and loads
   no scene:

   ```sh
   luncosim --validate my_scene.usda *.usda *.rhai *.wgsl *.btxml
   ```

   It must report `OK` for every file. Fix warnings too. The most common one
   is a missing `metersPerUnit = 1` on the stage: LunCo scenes are in metres,
   while OpenUSD defaults to centimetres.
5. **Write a README** in your folder covering:
   - what the scene is
   - how to open and control it
   - what happens during a run
   - a table of the files and what each does
   - the LunCoSim version you tested with (the app prints it at startup,
     e.g. `0.6.0-nightly.76.1`)
6. **Open a pull request.** It should add your folder and one row to the
   Scenes table above.

### Keep scenes light

- Commit sources only, never recordings, renders, logs or caches.
- Reuse `lunco://` assets instead of copying them.
- Keep textures and meshes to the size the scene needs.

### Things that catch people out

- **Scripts attach through `LunCoProgramAPI`.** Author a
  `Scope` with `prepend apiSchemas = ["LunCoProgramAPI"]` and
  `uniform asset info:sourceAsset = @twin://<name>/<script>.rhai@`. The older
  `def LunCoProgram` prim type is no longer supported.
- **One generic program per owner.** If a vehicle asset already carries a
  script, for example LunCoSim's descent lander, put your mission script on a
  separate prim. Otherwise neither script attaches.
- **Scenes that record start recording as soon as they load**, and they
  overwrite the output folder. Don't publish a scene with an active recording
  script. Deactivate it with `over "Recorder" ( active = false ) {}`, or ship
  a separate recording variant.

## Relationship to LunCoSim

Scenes here are independent of the simulator's release cycle. A scene can
depend on assets from a given LunCoSim version; the scene's README says
which version it was tested with. Good scenes may later be adopted into
LunCoSim itself.

Bugs in the simulator belong in
[LunCoSim/lunco-sim](https://github.com/LunCoSim/lunco-sim). Problems with a
scene in this repository belong here.

## License

Everything in this repository is released under the [Apache License
2.0](LICENSE) — the same license as LunCoSim itself. That covers scene
sources, shaders, scripts and preview images alike.

A scene may use different terms for its own contents by placing a `LICENSE`
file in its folder, which then governs that folder. Use this if you want, for
example, CC BY 4.0 for artwork. Without one, the repository license applies.

### Licensing your contribution

Opening a pull request submits your scene under this license (Apache 2.0,
Section 5) — nothing to sign. So everything in your folder must be yours to
give away, or licensed to allow it and listed in a `CREDITS.md` with its
source. Nothing from asset stores, games, films or brand sites.

We can't verify where a file came from. If something here infringes your
rights, open an issue and we'll take it down.
