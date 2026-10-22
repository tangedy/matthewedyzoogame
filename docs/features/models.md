# Hero animal models

Block-built showpiece models for the rarest animals. Everything lives in `src/server/Services/AnimalBuilder.luau` (the `SPECS` table plus shared building blocks) and `src/shared/AnimalConfig.luau` (the roster). There is no new remote, saved data or UI. The models are still the procedural placeholders, so a modeler's template in `ServerStorage.AnimalTemplates` still replaces any of them.

## New species

| Key | Display name | Tier | Income/s | Hose tier | Spawn weight | Wash time × | Look |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `Griffon` | Griffon | Legendary | 90 | 3 | 1.5 | 2.3 | White eagle head with a hooked gold beak and crest, lion body, eagle forelegs with talons, lion paws behind, wings folded on the back with gold edges, tufted tail |
| `Phoenix` | Phoenix | Mythic | 280 | 4 | 0.5 | 2.2 | Two-legged crimson bird, gold beak and bib, glowing eyes, neon flame crest, raised V wings edged with neon flame feathers, five drooping flame tail feathers, fire particles |
| `Kitsune` | Kitsune | Mythic | 300 | 4 | 0.5 | 2.4 | White nine-tailed fox: red-lined ears, shrine-fox face markings, blue gem, glowing slit eyes, red rope collar with a gold bell, nine tails fanned behind with white tips and blue fox-fire wisps, two hovering fox-fire orbs |
| `Axolotl` | Axolotl | Mythic (Limited) | 400 | 1 | 0 | 1.2 | Pink, wide smiling head, six frilly glowing gill stalks, bead eyes, blush, paddle tail with a see-through fin, bubbles |
| `Dragon` | Dragon | Zoo God | 1200 | 5 | 0.12 | 4.2 | Crimson, gold belly plates, tilted neck, swept-back horns, open jaws glowing with fire, fire-breath and ember particles plus nostril smoke, membrane wings with finger spars, spines, tail ending in a spade |
| `Kaiju` | Kaiju | Secret | 5000 | 5 | 0.02 | 5.0 | Upright charcoal giant lizard: three columns of glowing cyan dorsal plates up the back and along the tail, glowing jaws with atomic breath, burning slit eyes, heavy brows, arms, huge thighs |

`Axolotl` has `Limited = true` and `SpawnWeight = 0`, so it never walks in. The monetization feature sells it (see the cross-feature contract).

**Assumption:** the request said "verity", which doesn't match any animal we know of. We built a **Phoenix** instead. If "verity" meant something else, add a new spec and roster entry; nothing else depends on the Phoenix key.

"Kaiju" is a generic giant atomic lizard and doesn't use any trademarked name.

## Upgraded species

- **Elephant** (Zoo God): rounded back and sagging belly, a royal blanket with gold trim and a jewel, round pillar legs with gold anklets, foot pads and toenails, a domed forehead, big two-layer ears, a trunk that curls forward at the tip, curved tusks, a gold headdress with a gem, and a tufted tail. Body length went from 8.5 to 6.8 so the whole animal fits a pen.
- **Giraffe** (Mythic): the neck now leans forward, there are irregular flush spots on the body and neck, a mane, sloping withers, a cream belly, round legs with knees, socks and hooves, a muzzle with nostrils, ossicones with dark tips, ears, lashes, a tongue and a tufted tail.
- **T-Rex** (Secret, key `TRex`, template `TRex`): drumstick thighs, clawed feet, tiny two-clawed arms, a big head with a sloped snout, a hinged open jaw with teeth, slit eyes, angry brows, stripes and scutes, and a heavy tail that sweeps round to one side.

## How the models stay compatible

- Root is still the PrimaryPart at the origin, on the ground, facing -Z. Body, Head, Neck and Legs are the only queryable and collidable parts. Every decoration goes through `decoration()` (CanQuery and CanCollide false) and is a direct child of the model, so grime tint and mutation recolour reach it.
- Mud patches still come only from Body, Neck and Head faces. Decorations are kept off the sides, the neck sides and the head sides. Wings rise up and out from the top edges or fold on top. Ears, gills and frills come off the rear corners of the head, and haunches are tucked under the body.
- Neon, eye, flame and plate parts are marked `NoGrime`.
- Particle emitters go through `flair()`, which caps `Rate` at 20. The real rates are 3 to 12.

## New spec fields

These are in `AnimalBuilder`'s `Spec` type. All of them are optional, and existing species don't use them.

| Field | What it does |
| --- | --- |
| `NeckTilt` | Radians the neck leans forward from its base. The head stays level on the tip. Neck patches follow the tilt. |
| `HeadPosition` | Places the head centre explicitly, overriding `HeadLift` and `HeadOnTop`. T-Rex and Kaiju use it. |
| `SkipRump` | Skips the rump patches. Use it when a tail, a tail fan or dorsal plates cover that face. Wash time is unchanged, because total dirt comes from `WashTimeMultiplier` and not from the patch count. |
| `CenterZ` | After decorating, slides every part along Z so the snout-to-tail extent is centred on the pivot. This keeps long animals inside the pen and their cache slot. |

Head attribute `HaloLift` (number) sets how high the Zoo God halo floats above the head (default 0.9). The Elephant sets 2.1 to clear its forehead dome, and the Dragon sets 1.5 to clear its horns.

Building blocks for future specs: `ball`, `rod` (axis Y), `disc` (axis Z), `wedge`, `triangle` (two mirrored wedges), `chain` (tapering, curving segments for tails, trunks, horns and tusks), `heroEyes`, `maw` (snout, jaw, teeth and nostrils), `claws`, `glow`, `flair`, `anchorAt` and `glowLight`.

## Tuning knobs

- Roster numbers (tier, income, spawn weight, hose tier, wash time) are in `src/shared/AnimalConfig.luau`.
- Shape, size and colours are in each species' `SPECS` entry in `AnimalBuilder.luau`. `PatchCell` sets how dense the mud is.
- Pen limits for the audit are `AUDIT_MAX_WIDTH` 9, `AUDIT_MAX_LENGTH` 11.5, `AUDIT_MAX_HEIGHT` 16 and `AUDIT_MAX_PARTS` 150. The emitter cap is `MAX_FLAIR_RATE` 20.

## Known limits

- Cache slots are 7 studs apart (`GameConfig.Cache.SlotSpacing`). The widest animals (Elephant with its ears, about 8.6 studs) overlap a neighbour's slot a little. This was already true before this change.
- `ShopController.unlocksText` counts every species at a tier, Limited ones included. Today it is only called for the next hose to buy (tier 2 and up), so the tier-1 Axolotl never shows up there. If it is ever called for tier 1, skipping `def.Limited` in it would keep the Axolotl out.
- None of this was checked in Studio while it was being built (it was verified statically). Run the checklist below.

## Check in Studio

Start a Play session, then run the audit in the server command bar:

```lua
require(game.ServerScriptService.Server.Services.AnimalBuilder).audit()
```

- [ ] The audit prints one line per species and returns `0` (no warnings). Every new model is within 9 wide, 11.5 long and 16 tall, has 150 parts or fewer and has at least 6 patches.
- [ ] To eyeball each model, force walk-ins (for example with a SpawnWeight hook or the dev tools) or build them in the command bar:
  ```lua
  local AB = require(game.ServerScriptService.Server.Services.AnimalBuilder)
  for i, k in {"Griffon","Phoenix","Kitsune","Axolotl","Dragon","Kaiju","Elephant","Giraffe","TRex"} do
  	local m = AB.build(k, { Rarity = "Mythic" }); m:PivotTo(CFrame.new(i * 14, 0, 40)); m.Parent = workspace
  end
  ```
- [ ] **Griffon**: the beak hooks downward, the front legs are yellow with talons and the back legs have paws. The wings lie on the back like a tent and don't hang over the body sides.
- [ ] **Phoenix**: stands on two gold legs. The wings rise in a V with glowing flame tips, and fire particles come off the wings, crest and tail. The flame tail droops behind. Mud patches show on the rump between the tail feathers.
- [ ] **Kitsune**: nine tails fan out behind the rump and none of them cross the body sides or top. Three tail tips and two orbs give off blue fox-fire, and the ears are triangles with red insides.
- [ ] **Axolotl**: pink, smiling, with three glowing gill stalks on each side of the head. The head is no wider than the body and mud shows on the rump around the tail. It never walks in by itself.
- [ ] **Dragon**: its jaws glow, and fire wisps and embers stream forward from the mouth. The wings rise from the shoulders and don't clip the neck. The tail curls beside the hind legs and ends in a spade, and the Zoo God halo floats above the horns.
- [ ] **Kaiju**: the cyan dorsal plates glow up the back and along the tail, with atomic breath from the jaws and sparks off the top plate. It reads as an upright giant.
- [ ] **Elephant**: the trunk curls, the tusks curve up, the ears sit behind the head and the halo sits above the forehead dome.
- [ ] **Giraffe**: the neck leans forward and its spots follow the neck. The head is level with its ossicones on top.
- [ ] **T-Rex**: the jaw is open with teeth showing, the arms are tiny and the tail sweeps to one side.
- [ ] Wash each new animal (give yourself the hose tier, or override the walk-in). Every mud patch is visible and can be sprayed, with none hidden behind a wing, tail or gill, and the wash completes. Do the Kaiju's and Giraffe's tall head and neck patches too.
- [ ] Put each new animal in a pen. It stays inside the pen walls and doesn't cover the collect pad or the gate post.
- [ ] Carry each new animal (E). The scaled-down copy above your head looks right and its particles don't swamp the screen.
- [ ] Gold, Diamond and Rainbow mutations recolour the bodies, while the neon parts (eyes, flames, plates, fox-fire) keep their colours. While dirty, the whole animal is tinted with mud except the neon parts.
- [ ] Other species (Chicken through Unicorn) look and wash exactly as before.
