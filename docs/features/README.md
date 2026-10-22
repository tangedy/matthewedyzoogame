# Feature modules

New systems plug into the game without editing core services, so several can be built at the same time and merged cleanly.

## Where things go

| What | Where |
| --- | --- |
| Server logic | `src/server/Features/<Name>.luau`. A ModuleScript returning a table with `init()`. ServerBootstrap requires every module in that folder and calls `init()` once the core services are up. |
| Client logic and UI | `src/client/Features/<Name>Controller.luau`. Returns a table with `init(initial: Types.InitialState)`. ClientBootstrap starts these after the core controllers. |
| Tuning values | `src/shared/FeatureConfig/<Name>Config.luau`. Do **not** edit `GameConfig`. |
| Docs and test checklist | `docs/features/<name>.md`. Do **not** edit `README.md` or `TESTING.md`. |

## How features hook in

- **Hooks** (`src/server/Services/Hooks.luau`): `Hooks.on(event, fn)` for events the core fires, and `Hooks.modify(name, fn)` to change values like cleaning power, spawn weights, walk-in overrides, wash reward and income. The full list is at the top of the file.
- **Remotes:** call `Remotes.event("MyFeatureThing")` on the server and the remote is created on demand, so you don't edit the lists in `Remotes.luau`. Create it in your feature's `init()` so it exists before clients ask for it.
- **Saved data:** use `data.Extra.<YourFeatureKey>` (from `PlayerDataService.get(player)`). Validate what you read: it may be missing or malformed. Only plain JSON-safe values are saved. Call `PlayerDataService.markDirty(player)` after changes. Final writes in a `PlayerLeaving` listener (before any yield) make it into the leave-save.
- **Core helper APIs:**
  - `CleaningService.getActiveJob(player)` and `CleaningService.redirty(jobId, fraction)`
  - `ZooService.addToPads(player, amount)`, `ZooService.totalIncome(player)`, `ZooService.income(species, mutation)`
  - `EconomyService.addCoins(player, amount)` and `EconomyService.spend(player, amount)`
- **UI:** use `UIStyle` (chunky outlined text, rarity and mutation labels, `formatMoney`, `border`). Each controller builds its own ScreenGui and never edits `HUDController`. `UIPlatform` scales that ScreenGui and maps actions; see [Cross-platform UI](../ui-platform.md). Set attribute `UIPlatformExclude` on viewport-space guis (reticles, full-screen effects).

## Rules that still apply

- The server is authoritative: never trust client-sent amounts, prices, odds or results.
- Values live in config, not scattered through code.
- Run `stylua src && selene src` and `rojo build` before finishing.
