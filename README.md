# Wash The Farm Animals

A Roblox washing-station game (working title was Wash the Zoo): an animal walks into your bay, you walk around it scrubbing and spraying off the mud, finishing pays coins, and it joins your farm.

Design sources: `Wash the Zoo — Implementation Design Document.csv` (takes priority) and `Wash the Zoo Game Concept.csv`.

## Setup

Tools are pinned in `rokit.toml` (Rojo, Selene, StyLua, luau-lsp).

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in this folder.
2. In Roblox Studio, install the Rojo plugin (Plugins → Manage Plugins, or `rojo plugin install`).
3. Open a new **Baseplate** place in Studio.
4. Run `rojo serve` here, then click **Connect** in the Studio Rojo plugin.
5. Press **Play**.

Or build a standalone place file: `rojo build -o WashTheZoo.rbxl`.

Everything (map, bays, placeholder animals, UI) is created by scripts at runtime, so no models or assets need to be imported.

### Studio settings to change

- **Game Settings → Places → Max Players**: set it to `GameConfig.BayCount` (default 4). If more players join, they wait in a queue and get the next bay that frees up.
- **Game Settings → Security → Enable Studio Access to API Services**: turn this on, and publish the place, to test saving in Studio. Without it, loading fails and you play on a temporary profile that never saves (a red banner says so). Studio saves to its own store (`GameConfig.StudioDataStoreName`), so they never touch live data.
- Sounds use built-in `rbxasset://` placeholders. Swap in real asset IDs in `GameConfig.Sounds`.

## Checks

```bash
stylua src && selene src
```

## Layout

| Path | Becomes | Purpose |
| --- | --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` | `GameConfig`, `ToolConfig`, `AnimalConfig`, `RarityConfig`, `MutationConfig`, `UIStyle`, `Types`, `Remotes` |
| `src/server` | `ServerScriptService.Server` | `ServerBootstrap` + `Services/` |
| `src/client` | `StarterPlayerScripts.Client` | `ClientBootstrap` + `Controllers/` |

Server services:

- **EnvironmentBuilder** builds the cozy world (lighting, grass, the dirt road, fences, trees, flower beds, hay, barn, pond, welcome plaza and clouds), kept clear of every bay slot.
- **HoseBuilder** builds the cleaning tool for each tier (Sponge, Scrub Brush, Garden Hose, Power Washer, Foam Cannon, Fire Hose) as a real backpack Tool that stays equipped.
- **StationProps** parks each tier's gear at the wash station (bucket, brush caddy, hose reel, pressure-washer cart, foam cart, fire truck) and runs a hose line from it to the tool from tier 3 up.
- **WorldBuilder** builds the ground, wash bays, and each bay's zoo pens and expansion stand.
- **AnimalBuilder** builds animals: real models from `ServerStorage.AnimalTemplates` when present (see the contract at the top of the file), otherwise block placeholders. It also applies the rarity looks.
- **DirtRenderer** handles how dirt looks. It's the only place to change when trying decals or texture masks.
- **AnimalService** handles selection, the walk in and out, celebration and disposal.
- **CleaningService** does the server-authoritative spray validation, keeps dirt state and progress, and signals completion.
- **BayService** handles bay ownership and the per-bay state machine `Empty → Arriving → Washing → Completing → Departing`.
- **PlayerDataService** loads, validates and saves profiles through DataStore. It uses a session lock, autosaves every 60 s, saves on leave and on shutdown, and never saves a profile whose load failed.
- **EconomyService** pays out completed washes, validates hose upgrade purchases, and handles coin spending and grants.
- **ZooService** runs the Steal a Brainrot-style zoo:
  - Washed animals wait in the cache.
  - You carry an animal to a pen to place it or swap it.
  - You can sell animals from the cache or from a pen.
  - Penned animals earn cash per second into a collect pad.
  - It also handles zoo expansion and index discoveries.

Client controllers:

- **CleaningController** handles input, aiming, the spray beam, splash and sound, the mobile SPRAY button, the reticle and the remaining-dirt highlight.
- **OnboardingController** shows the first-wash "Wash me!" marker and the "you can afford an upgrade" hint.
- **ShopController** opens the hose shop from the upgrade station's prompt and sends purchase requests.
- **ZooController** shows what you're carrying and the "cache full" hint, puts other players' prompts out of reach, and animates rainbow labels.
- **PenCashController** animates the cash counter above each pen pad: it bobs, glows, counts up with a bounce, and pops a floating "+$X" with sparkles.
- **IndexController** shows the Index button and panel (species × mutation) and new-discovery toasts.
- **HUDController** shows coins, tool, animal, clean meter and reward, plus the instructions and the payout popup.

## Feature systems (big-push branch)

These plug in through `src/server/Services/Hooks.luau` and the Features folders. See [docs/features/README.md](docs/features/README.md) for how. Each one has its own doc with config settings and a Studio checklist:

- [Hero models](docs/features/models.md):
  - new species: Griffon, Phoenix, Kitsune, Dragon, Kaiju and the Limited Axolotl
  - rebuilt Elephant, Giraffe and T-Rex
  - `AnimalBuilder.audit()` to check every model fits a pen
- [Tension](docs/features/tension.md):
  - moods and a patience meter
  - shakes that bring mud back and fling nearby players
  - a mud splat on screen and camera shake
  - wander-off timer for Mythic and rarer animals
  - dev keys: K shakes the animal, L skips the wander-off timer to 5 s
- [Live ops](docs/features/liveops.md):
  - Daily Dirty Animal and the scheduled Mud Storm (dev key M toggles it)
  - offline earnings with a welcome-back popup
  - zoo stars, leaderstats and the plaza leaderboard
  - onboarding analytics
- [Monetization](docs/features/monetization.md):
  - products: Super Soap, Calm Treat, Lucky Soap and cash packs
  - game passes: VIP and the Fire-Hose Rig early unlock
  - Limited Axolotl with a global stock
  - purchase handling that never grants twice
  - the shop and contextual offers
  - Studio test mode: purchases are simulated through the real grant code

## Status

- **Milestones 1–2:** done and tested in Studio.
- **Milestone 3** (three animals, hose tiers, shop, saving): shop and purchases verified in a Studio playtest. Saving still needs a published place to test.
- **Milestone 4** (multiplayer and mobile): server hardening verified in a solo playtest. A real 2-player test and a phone test are still needed.
- **Milestone 5** (presentation): mud splatters, a muddy-to-clean body tint, mud bursts, soap foam, a "Squeaky clean!" banner, onboarding markers, a shop hint and shorter downtime. Verified in a Studio playtest, except the markers, which still need checking by eye.

See [TESTING.md](TESTING.md). Everything in the implementation design doc is now built. Real animal art and real sound assets are the remaining production work: the code takes them through `AnimalBuilder` (the model contract) and `GameConfig.Sounds`.

Developer keys (Studio and place owner only): **C** cleans the current animal, **G** grants coins.

**Zoo loop (Steal a Brainrot style)**, which replaces roadmap Phases A–B:

- **Bays:** a bay is built only while a player owns it, so there are no empty lanes.
- **Cache:** every washed animal walks into the bay's 3-slot cache. Pick one up with E and it rides above your head. Take it to a pen and use the gate prompt: an empty pen gets **Place**, an occupied pen gets **Swap**, which sells the old animal. Hold F at the cache to sell an animal instead.
- **Full cache:** while the cache is full, no new animal walks in.
- **Income:** penned animals earn cash per second onto the green pad in front of their pen. Step on the pad to collect it.
- **Rarity:** each of the 22 species has a fixed tier: Common, Rare, Epic, Legendary, Mythic, Zoo God or Secret. Better hoses (5 tiers) unlock rarer tiers.
- **Mutations:** every walk-in rolls Normal, Gold (×1.25), Diamond (×1.5) or Rainbow (×10).
- **Index:** 22 species × 4 mutations = 88 entries.
- **UI:** Steal a Brainrot-style chunky outlined text, rarity colours (an animated rainbow for Zoo God), and $ cash with K/M/B suffixes.

**Next:** Phase C (moods and patience) and the remaining roadmap phases.
