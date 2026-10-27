# Monetization

Robux developer products and game passes, from the shop button to the grant. The concept doc's rules apply: nothing pay-to-win in the "skip the game" sense, no shop prompt in a session's first 90 seconds, mostly repeatable consumables, plus limiteds and whale items.

## Files

| File | Role |
| --- | --- |
| `src/shared/FeatureConfig/MonetizationIds.luau` | The real product and pass ids, by key (written by `tools/create-products.ps1`). |
| `src/shared/FeatureConfig/MonetizationConfig.luau` | Products, passes, Robux prices, boost strengths, offer rules, guardrails. Also the `ShopState` type the client draws from. |
| `src/server/Features/Monetization.luau` | `init()`: remotes, `ProcessReceipt`, game pass checks, shop requests, Hooks modifiers and listeners, contextual offers, background loop. |
| `src/server/Features/MonetizationState.luau` | `data.Extra.Monetization` (validated on read), per-session state, rate limits, test-mode decision, client payload. |
| `src/server/Features/MonetizationGrants.luau` | What each item does once paid: boosts, cash, limited animal delivery, VIP tag, Fire-Hose Rig unlock. |
| `src/server/Features/MonetizationStock.luau` | Global limited stock (DataStore, idempotent per PurchaseId). |
| `src/client/Features/MonetizationController.luau` | Client state, boost timers, offers, notices, kiosk buys. |
| `src/server/Features/FavoritePrompt.luau` / `src/client/Features/FavoritePrompt.luau` | After the first Legendary-or-rarer wash (once ever, `data.Extra.FavoritePrompted`), Roblox's favourite dialog opens 3 s later. |
| `src/client/Features/MonetizationShop.luau` | SHOP button and the tabbed shop panel (pure view). |
| `src/client/Features/MonetizationQuickBuy.luau` | The one-tap quick-buy buttons on the right (`MonetizationConfig.QuickBuy`, pure view). |

The helper modules have no `init`, so the feature autoloaders just require them.

## Going live (real Robux)

Every product and pass ships with id 0, which live servers treat as "Not on sale yet" (only the place owner gets a simulated purchase). To take real Robux:

1. Creator Dashboard > Open Cloud > API Keys: make a key with `developer-product:read`, `developer-product:write`, `game-pass:read` and `game-pass:write`, limited to this experience.
2. From the repo root, with the experience's **Universe** id (not the place id):
   ```
   $env:ROBLOX_API_KEY = "<key>"
   powershell -ExecutionPolicy Bypass -File tools/create-products.ps1 -UniverseId <id> -DryRun
   powershell -ExecutionPolicy Bypass -File tools/create-products.ps1 -UniverseId <id>
   ```
   It creates the 23 developer products and the game passes (2x Cash Forever 3, VIP Keeper 399), reusing any that already exist by name, and writes their ids into `src/shared/FeatureConfig/MonetizationIds.luau`. Passes are put on sale, so they show on the experience's Store page.
3. Give each game pass an icon under Monetization > Passes (the script makes them without one).
4. Publish. Roblox charges the price set on the product; keep `Robux` in `MonetizationConfig` matching so the shop shows the right number. A plain re-run never changes a product that already exists; add `-Update` to push the script's names, prices and descriptions onto existing products (and put them on sale).
5. Game Settings > Security: **Enable Studio Access to API Services** must be on (receipts save through DataStores).

`MonetizationConfig` reads the ids from `MonetizationIds`; nothing else needs editing.

## What's for sale

| Key | Type | Robux | Effect |
| --- | --- | --- | --- |
| `CalmTreat` | Product | 15 | `Hooks.fire("CalmTreat", player, 60)`. The Tension feature freezes patience. Only sold while a wash is in progress (otherwise it would do nothing). |
| `AutoCollect2h` | Product | 49 | Pens collect themselves for 30 minutes of play. Time stacks up to 2 hours. Also sold at its own kiosk in the Robux row. |
| `SpeedBoost` | Product | 16 | 2x walk speed for 10 minutes. Stacks up to 4 hours. |
| `CashSmall` / `CashMedium` / `CashLarge` | Product | 7 / 75 / 149 | `max(Floor, income/s * 60 * Minutes)` with Minutes 1 / 20 / 60, capped at `CapFraction` (3% / 35% / 75%) of the next hose's price, so a pack can never skip a tool tier. Bigger packs are better value per Robux. The shop shows the current amount. |
| `CleanNow`, `CleanNow1`–`CleanNow4` | Product, hidden | 39 / 79 / 149 / 249 / 399 | Washes an animal the hose can't, priced by how many rarity steps it is above the hose. Offered on the "too dirty" prompt. |
| `HoseTier2`–`HoseTier5` | Product, hidden | 19 / 29 / 99 / 249 | Exactly the next hose (Scrub Brush, Garden Hose, Power Washer, Foam Cannon). Never a skip. The Foam Cannon costs more than Vault of Cash so the cash packs stay worth buying. |
| `TruckAnimal` | Product, hidden | 199 | The animal on the Delivery Truck (DeliveryTruck feature). |
| `OfflineDouble` | Product, hidden | 25 | Welcome-back only: doubles the offline payout already on the pads. |
| `LimitedAxolotl` | Product, limited | 1000 | One Axolotl (`Species`/`Mutation` in config) into the cache. Global stock of 1000, never restocked. Shown as COMING SOON until `AnimalConfig.Animals.Axolotl` exists. |
| `VIPKeeper` | Game pass | 399 | Income x1.25 (Hooks `IncomeMultiplier`) and a gold "VIP" tag over the head. |

## How purchases work

- **Shop request:** the client sends `MonetizationBuy(key)` and nothing else. The server rate-limits it (`BuyCooldown`), checks that the key is real, and checks: still loading, once-only product already used, pass already owned, limited unavailable or sold out. Then it either prompts the real purchase (`PromptProductPurchase` / `PromptGamePassPurchase`) or simulates it (see Test mode).
- **ProcessReceipt** (`processPurchase`, the single grant path):
  - Returns NotProcessedYet if the player isn't in the server, their profile isn't loaded, or they're on a temporary profile that won't save. Roblox retries later.
  - A PurchaseId already in `data.Extra.Monetization.Receipts` returns PurchaseGranted without granting again. The last `ReceiptsKept` (100) ids are kept.
  - A per-PurchaseId lock stops two concurrent calls for the same receipt.
  - Once granted, the PurchaseId is recorded, `PlayerDataService.saveNow` is called, and only then does it return PurchaseGranted.
- **Limited stock:** checked before prompting and claimed again at receipt time with `UpdateAsync` on a global record `{ Sold, Claims = { [PurchaseId] = true } }`. A retried receipt finds its own claim and never takes a second unit.
  - Sold out at receipt time: the player gets `max(Floor, min(Minutes of income, CapFraction of the next hose))` cash from `SoldOutCompensation` and a message, since Robux can't be refunded. The floor is never capped away.
  - A shop request treats a known stock of 0 as final (never restocked) and re-reads an unknown stock at most every `StockRecheckSeconds`, so spamming BUY can't drain the GetAsync budget.
  - DataStore error: the receipt stays unprocessed and is retried.
- **Delivering the animal:** the server builds the model first. Then it calls `ZooService.addToCache`, pivots the model to the returned slot, and calls `ZooService.adoptIntoCache` (plus an index discovery).
  - If there's no room, the animal is queued in `data.Extra.Monetization.PendingAnimals`. The queue retries every `PendingDeliverySeconds` (3 s).
  - With one free slot, it delivers only while the bay is `Empty`/`CacheFull`. Otherwise the washed animal already walking in could lose its slot, because the bay checks for room once, before the walk-in.
- **Game passes:** ownership comes from three places:
  - `UserOwnsGamePassAsync` on `PlayerLoaded` (pcall, cached for the session),
  - `PromptGamePassPurchaseFinished`,
  - the saved flag `data.Extra.Monetization.Passes` (set whenever this game grants a real pass, or a simulated one in Studio, so it also covers API outages).

## Offers

None of these show in a session's first `Offers.QuietSeconds` (90). The server and the client both check this.

- **Calm Treat:** when the Tension feature fires `PatienceLow` for the player.
- Each kind has a `CooldownSeconds` (240) cooldown, with `MaxPerSession` (6) in total. The popup sits at the right middle (clear of SPRAY), has an X, and hides itself after 12 s.
- **The shop panel never opens by itself.** Only the SHOP button and the plaza booth open it, and the booth needs a 0.3 s hold so walking past or a stray tap doesn't.

## Quick buy

2x Cash Forever (`MonetizationConfig.QuickBuyWide`) is a wide button the invite box's size, straight above it, and hides once owned. Under it, a square icon button column down the right side (above the 2x Cash button on desktop, under the invite box on touch) (`MonetizationConfig.QuickBuy`: 2x Speed for 16), each with a Robux price chip under it. One tap sends `MonetizationBuy(key)`, so Roblox's purchase dialog is the only confirm. The caption shows the time left on a running boost, or what a cash pack pays right now.

- On touch they make a row under the invite box. A column ran into WASH on a landscape phone.
- On desktop they make a column that grows up from just above the invite box.
- Hidden for the first `Offers.QuietSeconds` and while an offer popup is up. They sit in their own ScreenGui under every menu.

Shop icons (cards, tabs, prices, rail buttons) come from `src/client/UI/Icons.luau`. They're drawn from rounded frames, with no emoji and no uploaded images.

## Kiosks

`WorldBuilder.KIOSKS` lines four single-item stands up with the ROBUX SHOP booth, two on each side of it, all facing the plaza like one storefront. Each has a blue sign board with the item and its price. Holding a kiosk's `RobuxKioskPrompt` (0.3 s, 6-stud reach) sends its `ProductKey` attribute through `MonetizationBuy`, so Roblox's own purchase dialog still asks to confirm.

From the road end of the row: `SpeedBoost`, `CashMedium`, the ROBUX SHOP booth, `AutoCollect2h`, `VIPKeeper`.

Everything else is only in the shop panel.

## Test mode

- **In Studio,** every purchase is simulated through `processPurchase` (purchase id `SIM-<guid>`), or `grantPass` for passes. These are the same functions real receipts use.
- **In a live server,** only items with id 0 are simulated, and only for the place owner, unless `SimulateUnconfiguredLive` is on. Never turn that on in a shipped game, because it would hand out free items. Real ids never simulate.
  - A simulated limited there takes a unit from a per-server test counter, never the real global stock.
  - A simulated pass there lasts only for the session; it isn't saved, so it can't outlive the switch to real ids.
- The shop shows a TEST MODE line when purchases are simulated, and grant messages are prefixed `[TEST]`.
- Without Studio DataStore access, limited stock falls back to an in-memory counter. Temporary (unsaved) profiles can still receive simulated grants.

## Config knobs (MonetizationConfig)

- `Products[*]`: `Id`, `Robux` (display only, so keep it in sync with the website price), `DisplayName`, `Description`, `Tab`, `Order`, `Color`. Also `Minutes`/`Floor`/`CapFraction` for cash packs and `Species`/`Mutation`/`Stock` for limiteds.
- `Passes[*]`: `Id`, `Robux`, text.
- `CalmTreatSeconds`.
- `VIP.IncomeMultiplier`, `.TagText`, `.TagColor`.
- `SoldOutCompensation`.
- `Offers.*`: quiet time, cooldown, per-session cap, auto-hide.
- `ReceiptsKept`, `PendingDeliverySeconds`, `StockStoreName` / `StudioStockStoreName`, `StockRefreshSeconds`, `StockRecheckSeconds`, `BuyCooldown`, `StateCooldown`, `SimulateUnconfiguredLive`.

## Remotes

| Remote | Direction | Payload |
| --- | --- | --- |
| `MonetizationBuy` (event) | client to server | `key: string` |
| `GetMonetizationState` (function) | client to server | returns `ShopState` (rate-limited) |
| `MonetizationState` (event) | server to client | `ShopState` |
| `MonetizationStock` (event) | server to all | `key, remaining` |
| `MonetizationNotice` (event) | server to client | `text, ok` |
| `MonetizationOffer` (event) | server to client | `kind ("CalmTreat"), productKey` |

## Cross-feature contract

- Fires `CalmTreat (player, seconds)`. Listens for `PatienceLow (player, jobId, fraction)`. Both are fine with Tension being absent.
- Sells `AnimalConfig.Animals.Axolotl` only if it exists (added by the Models feature).
- Owns `MarketplaceService.ProcessReceipt`. Only one handler can exist per game, so any other feature that sells developer products must go through this one.

## Check in Studio

- [ ] Play solo. A pink SHOP button sits under INDEX on the left. Tapping it pops open the panel with Boosts / Cash / Passes / Limited tabs and a TEST MODE line.
- [ ] Calm Treat: BUY with no animal at the wash spot: refused with "Start washing an animal first!". BUY during a wash: if the Tension feature is merged, patience freezes for 60 s. Without it, only the notice shows.
- [ ] Cash: the cards show amounts, and each is at most 15% / 30% / 50% of the next hose price. BUY adds exactly that much cash.
- [ ] Limited: the Axolotl card shows COMING SOON until the Models branch adds `Axolotl` to AnimalConfig. Once it's there:
  - [ ] it shows "N / 1000 LEFT", and BUY puts an Axolotl in a free cache slot (plus an index toast);
  - [ ] with a full cache, the notice says it will join when a slot frees, and it appears a few seconds after you place or sell a cache animal.
- [ ] Passes: VIP Keeper adds a gold VIP tag over your head (it survives a respawn) and pen income is 25% higher. Fire-Hose Rig swaps in the top hose immediately, and the HUD hose label updates. Both cards then read OWNED.
- [ ] Offers stay silent for the first 90 s of a session. After that:
  - [ ] with Tension merged, low patience pops the Calm Treat offer.
- [ ] Tap the hose shop's Buy while short of cash many times: the SHOP panel never opens by itself.
- [ ] Each plot has the four kiosks (Speed, Auto-Collect, Bag of Cash, VIP) in one row with the ROBUX SHOP booth, all facing the plaza; holding one buys that item (simulated in Studio).
- [ ] In a published test server, wash a Legendary: about 3 s later Roblox asks to favourite the game. It never asks again.
- [ ] Spamming BUY doesn't double-grant (rate limit). Firing `MonetizationBuy` with a junk key or a non-string from the command bar does nothing.
- [ ] Phone emulator (landscape and portrait): the SHOP button, panel tabs, BUY and X buttons are easy to tap, and nothing covers SPRAY or the thumbstick.
- [ ] Before publishing: put the real product and pass ids and prices in MonetizationConfig and confirm `SimulateUnconfiguredLive = false`.
