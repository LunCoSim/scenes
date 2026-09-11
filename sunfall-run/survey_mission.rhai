// Sunfall Run — mission orchestration.
//
// Bound from my_survey.usda by `LunCoProgramAPI` on /Survey/Scenario/Mission.
// USD owns the scene; this script only SEQUENCES phases and ANNOUNCES them on
// the event bus. It drives nothing per tick — the marker Sensors own
// "arrived", and the cannons light THEMSELVES: their flame shader reads the
// rover's position over a USD wire (see Flame_Mat in holo_cannon.usda), so
// nothing here switches them.
//
// The run: four gates down a 200 m neon road, ending INSIDE the sun.
//
//   The rover does NOT drive itself on load — it stays put until a human
//   takes control.
//   1. Start gate      (z =   56.45, pylon pair 1) — reached at spawn,
//                      so it is not awaited.
//   2. Before cannons  (z =  -13.55)
//   3. Past cannons    (z =  -33.55). The cannons at z = -23.55 ignite as
//                      the rover passes z = +1.45, shoot out over 4 m, and
//                      burn until z = -29 (their own gate, wired from the
//                      rover's position) — nothing in this script.
//   4. The sun         (z = -170.0) — inside the disc. Run complete.
//
// Click the rover to take control: that possesses it, enables WASD, and brings
// up the speed widgets and autopilot options. The mission only listens for the
// waypoint events, so a hand-driven run scores exactly the same.
//
// NOTE: do NOT re-add `cmd("EngageAutopilot", ...)` here. Engaging it on load
// makes the rover drive off by itself the moment the scene opens, which also
// makes it far harder to click.

const ROVER = "/Survey/SurveyRover";


// Battery state of charge, printed at each gate so a run leaves an energy
// trace in the log (the rover root publishes `soc` since `power = "battery"`).
// Read-only and guarded: a failed read must never stop the mission.
fn log_power(label) {
    try {
        let soc = get(find(ROVER), "soc");
        print(`[power] ${label}: battery SoC = ${soc}`);
    } catch (err) {
        print(`[power] ${label}: SoC not readable (${err})`);
    }
}

// Translate each raw `waypoint.reached` arrival into an ordered milestone
// event the task tree below waits on. Ordering by name, not by arrival
// timing, is what keeps the sequence deterministic.
fn on_event(me, evt) {
    if evt.name == "battery_drained" {
        print("[power] battery drained");
        notify_kind("Rover battery drained", "warn");
        return;
    }
    let rover = find(ROVER);
    if evt.name != "waypoint.reached" || evt.source != rover { return; }
    let index = waypoint_event_index(evt);
    if index == () { return; }
    let milestones = [
        "waypoint_1_reached",
        "waypoint_2_reached",
        "waypoint_3_reached",
        "waypoint_4_reached",
    ];
    if index < milestones.len() {
        emit(milestones[index]);
        log_power(milestones[index]);
    }
}

fn task(me) {
    seq([
        wait(0.5),                                   // let the scene settle
        once(|m| {
            // NO camera command here. The mission does not touch the viewport:
            // the authored `Avatar` camera in `my_survey.usda` already frames
            // the parked rover, and a `follow()` here re-claimed the viewport
            // at load, which is what caused the view to jump on start.
            cmd("ControlAnimation", #{ playing: true, looping: true, seek_secs: 0.0 });

            // Start with NOTHING selected. The transform gizmo is attached to
            // whatever is selected, and a leftover selection puts gizmo handles
            // over the rover so a click lands on the gizmo instead of the
            // vehicle.
            cmd("SelectEntity", #{ entity_id: 0 });
            // And make sure the clock is running, so the rover responds.
            cmd("SetTimeTransport", #{ playing: true, rate: 1.0 });
        }),


        // NO `wait_for("waypoint_1_reached")` HERE, deliberately.
        //
        // The rover SPAWNS on gate 1, so its Sensor fires during load — about
        // two seconds before this task tree runs its first step. `wait_for`
        // only catches events emitted after it starts waiting, so waiting on
        // gate 1 blocks the sequence permanently: gates 2, 3 and 4 then fly
        // past unheard and the cannons never open. Gate 1 is the start LINE,
        // announced above, not a milestone to wait for.
        // The cannons need no step here: they ignite 25 m before the gate
        // and go out at Waypoint3's trigger, by their own gate.
        // Deliberately NO toast — announcing the fire gave the surprise away.
        wait_for("waypoint_2_reached"),
        wait_for("waypoint_3_reached"),

        wait_for("waypoint_4_reached"),
        once(|m| {
            clear_patrol(find(ROVER));           // brake + drop the route
            emit("survey_complete");
        }),
    ])
}
