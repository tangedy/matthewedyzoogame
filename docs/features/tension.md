# Tension and clippable moments

Animals have moods and a patience meter while they're being washed. If patience runs out, the animal shakes: mud flies everywhere, part of the wash comes undone, and everyone nearby gets flung and splatted. Mythic and rarer animals also have a timer, and if it runs out they wander off unpaid.

## What it does

- **Moods**, per species (rarity default plus a per-species override):
  - **Calm** stands still.
  - **Ticklish** squirms every 1–2 s: a small wobble and twist driven by the server through `PivotTo` around the wash spot. It never leaves that spot.
  - **Grumpy** starts lunging once patience is below 40%. Each lunge picks the nearest player within 14 studs, shows a red **!** and rears back for 0.6 s, then strikes 1 stud toward that player and returns. Anyone touching the animal at the strike gets knocked back.
- **Patience** drains 1 per second while the wash runs.
  - Below 20%, the bar flashes and jitters and reads **DON'T LET IT SHAKE!**. The `PatienceLow` hook fires once per wash.
  - At 0 the animal **SHAKES**:
    - `CleaningService.redirty(jobId, ShakeRedirty)` makes some of the clean area muddy again.
    - A mud particle burst plays with a low mud sound, and splats are left on the ground.
    - Every living character within `ShakeRadius` is flung, owner or not. The server picks the velocity and tells each client through `TensionFling`. The client applies the velocity to its own character, sets PlatformStand to tumble it, plays the "uuhhh" sound, shows a full-screen mud splat and shakes the camera.
    - Players farther out, up to `CameraShakeRange` times the radius, only get a camera shake.
    - Patience then refills to 70%.
- **Wander-off** (Mythic, Zoo God and Secret by default): a countdown of 100–120 s starts when washing begins. If it reaches 0 before the wash finishes, the animal walks off down the lane and the wash is not paid (`BayService.abandonWash`). Only the owner gets a funny announcement. Limited (bought) animals never wander off.
- **Calm Treat**: `Hooks.on("CalmTreat", player, seconds)` freezes patience and the wander-off timer for that many seconds. The animal also stops squirming and lunging. Treats stack up to `MaxCalmSeconds`. The bar turns blue and reads **CALMED 12s**.
- **Grace**: there is no tension at all while `LifetimeAnimalsWashed < 3`, and never on a player's first animal of a session.
- **Cleanup**: state ends when:
  - `WashCompleted` fires. The pose is restored before the celebration hop.
  - The job is no longer active. This is checked every 0.25 s and covers bay release and abandons.
  - The animal model is gone.
  - The owner leaves.

  Everything runs from one Heartbeat loop, so no per-job threads are left behind.

### UI (TensionController)

- **Patience row** at top center, y 162, just under the wash card and the same 380 px width:
  - Mood pill (CALM green, TICKLISH pink, GRUMPY red).
  - An orange-to-red bar styled like the clean bar.
  - A **LEAVES 1:40** timer pill for wander-off animals, which flashes red under 15 s.
  - The row is hidden when you're not washing.
- **Centre pops**: **MUD SHAKE!**, **CALMED!**, **IT WANDERED OFF!**
- **Mud splat overlay**: brown blotches with flecks that pop in, drip and fade over about 3 s.

### Remotes

| Remote | Direction | Payload |
| --- | --- | --- |
| `TensionState` | server → owner | `{ JobId, Mood, Patience 0..1, Calm seconds, Wander seconds?, Event?, Ended? }` |
| `TensionFling` | server → flung player | `(velocity: Vector3, ragdollSeconds, splat: boolean)` |
| `TensionCameraShake` | server → nearby player | `(intensity, seconds)` |
| `TensionDev` | client → server | `"shake"` or `"wander"`. Only Studio and the place owner can use it, rate-limited to 1 per 0.3 s. |

Clients never decide patience, shakes or flings. The client clamps fling speed (250) and ragdoll time (3 s) as a sanity check.

### Hooks

- Listens: `WashStarted`, `WashCompleted`, `CalmTreat (player, seconds)`
- Fires: `PatienceLow (player, jobId, fraction)` once per wash when patience drops below `LowFraction`

### Core change

`src/server/Services/BayService.luau` gets `BayService.abandonWash(player): boolean`. It is additive: an `Abandoned` flag on the job, and a branch after the wash wait that walks the animal to the exit unpaid.

## Config knobs (`src/shared/FeatureConfig/TensionConfig.luau`)

| Knob | Meaning |
| --- | --- |
| `GraceWashes` | No tension until this many lifetime washes (3) |
| `RefillFraction` | Patience after a shake (0.7) |
| `LowFraction` | Warning and `PatienceLow` threshold (0.2) |
| `MaxCalmSeconds` | Cap on stacked Calm Treats |
| `ByRarity[tier]` | `Mood`, `PatienceSeconds`, `ShakeRedirty`, `ShakeRadius`, `Knockback`, `KnockUp`, `WanderOffSeconds` (0 = never) |
| `BySpecies[key]` | Any subset of the above, applied over the rarity default (e.g. Hippo has a 20-stud radius and huge knockback) |
| `Squirm.*` | Interval, duration and wobble size for Ticklish |
| `Lunge.*` | Patience threshold, cooldown, range, wind-up, strike, distance, hit distance, knockback |
| `Shake.*` | Wiggle, particles, puddles, ragdoll time, distance falloff, camera shake range and strength |
| `Sounds`, `MudColors`, `WanderOffLines` | Presentation |

Default patience: Common 40 s, Rare 34 s, Epic 28 s, Legendary 25 s, Mythic 22 s, Zoo God and Secret 26 s. A Pig washes in about 3 s, so patience only matters on big or rare animals, or when you dawdle.

## Check in Studio

Dev keys work in Studio only, or for the place owner: **K** empties the current animal's patience so it shakes now. **L** sets the wander-off timer to 5 s, on any animal. Both also start tension on the current wash during the grace period.

- [ ] Fresh profile: no patience bar for the first 3 washes or for the first animal after rejoining.
- [ ] After 3+ washes (second animal of the session): the patience row appears under the wash card with the right mood, and drains smoothly.
- [ ] The row hides when the wash completes, and the celebration hop starts from the normal spot (no offset pose).
- [ ] Ticklish animal (Epic or Legendary, e.g. Fox or Llama): squirms every 1–2 s and stays on the wash spot. Spraying still works while it squirms.
- [ ] Grumpy animal (e.g. Goat, or any Mythic) below 40%: a red **!** and rear-back, then a 1-stud lunge at the nearest player. Standing touching it flings you; standing back doesn't.
- [ ] Below 20%: the bar flashes red, jitters and reads **DON'T LET IT SHAKE!**, with one warning ping.
- [ ] Press **K**: wiggle, a mud burst, mud splats on the ground, and the clean % on the HUD drops. You tumble away, see the brown splat overlay drip and fade, hear "uuhhh", and the camera shakes. Patience refills to 70%.
- [ ] With 2+ players (Test > Clients and Servers): a second player inside the radius is flung and splatted too; one just outside gets only a camera shake.
- [ ] Mythic animal: the **LEAVES m:ss** pill counts down. Press **L** and wait 5 s: the animal walks off to the exit, no pay, the owner sees the funny announcement and **IT WANDERED OFF!**, and the next animal walks in normally.
- [ ] Calm Treat: in the server command bar, `require(game.ServerScriptService.Server.Services.Hooks).fire("CalmTreat", game.Players:GetPlayers()[1], 15)`. The bar turns blue with **CALMED 15s**, patience and the wander timer freeze, and the animal stops squirming and lunging.
- [ ] Leave mid-wash (or stop the client) during a shake or lunge: no errors in the server output, and the bay is released cleanly.
- [ ] Phone emulator: the row is readable and doesn't overlap the SPRAY button or the thumbstick.
