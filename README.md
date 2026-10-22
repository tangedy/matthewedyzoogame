# Wash the Zoo

A Roblox washing-station game: an animal walks into your bay, you walk around it spraying off the mud, finishing pays coins, it leaves, the next one arrives.

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

- **Game Settings → Places → Max Players**: set it to `GameConfig.BayCount` (default 4). Extra players can still join, but they won't get a bay.
- **Game Settings → Security → Enable Studio Access to API Services**: turn this on, and publish the place, to test saving in Studio. Without it, loading fails and you play on a temporary profile that never saves (a red banner says so). Studio saves to its own store (`GameConfig.StudioDataStoreName`), so they never touch live data.
- Sounds use built-in `rbxasset://` placeholders. Swap in real asset IDs in `GameConfig.Sounds`.

## Checks

```bash
stylua src && selene src
```

## Layout

| Path | Becomes | Purpose |
| --- | --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` | `GameConfig`, `ToolConfig`, `AnimalConfig`, `Types`, `Remotes` |
| `src/server` | `ServerScriptService.Server` | `ServerBootstrap` + `Services/` |
| `src/client` | `StarterPlayerScripts.Client` | `ClientBootstrap` + `Controllers/` |

Server services:

- **WorldBuilder** builds the ground and wash bays.
- **AnimalBuilder** builds the placeholder block animals and their dirt patches.
- **DirtRenderer** handles how dirt looks. It's the only place to change when trying decals or texture masks.
- **AnimalService** handles selection, the walk in and out, celebration and disposal.
- **CleaningService** does the server-authoritative spray validation, keeps dirt state and progress, and signals completion.
- **BayService** handles bay ownership and the per-bay state machine `Empty → Arriving → Washing → Completing → Departing`.
- **PlayerDataService** loads, validates and saves profiles through DataStore. It uses a session lock, autosaves every 60 s, saves on leave and on shutdown, and never saves a profile whose load failed.
- **EconomyService** pays out completed washes and validates hose upgrade purchases.

Client controllers:

- **CleaningController** handles input, aiming, the spray beam, splash and sound, the mobile SPRAY button, the reticle and the remaining-dirt highlight.
- **ShopController** opens the hose shop from the upgrade station's prompt and sends purchase requests.
- **HUDController** shows coins, tool, animal, clean meter and reward, plus the instructions and the payout popup.

## Status

- **Milestones 1–2:** done and tested in Studio.
- **Milestone 3** (three animals, hose tiers, shop, saving): implemented, not yet tested in Studio. See [TESTING.md](TESTING.md).

The pig, sheep and cow are all in the spawn pool. The first animal each session is always the pig.

**Next, Milestone 4:** the multiplayer and mobile acceptance pass (bay ownership checks, remote abuse, multi-bay performance).
