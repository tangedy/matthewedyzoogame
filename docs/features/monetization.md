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
| `src/client/Features/MonetizationController.luau` | Client state, boost timers, offers, notices, cash-pack auto-open. |
| `src/client/Features/MonetizationShop.luau` | SHOP button and the tabbed shop panel (pure view). |

The helper modules have no `init`, so the feature autoloaders just require them.

## Going live (real Robux)

Every product and pass ships with id 0, which live servers treat as "Not on sale yet" (only the place owner gets a simulated purchase). To take real Robux:

1. Creator Dashboard > Open Cloud > API Keys: make a key with `developer-product:read` and `developer-product:write`, limited to this experience.
2. From the repo root, with the experience's **Universe** id (not the place id):
   ```
   $env:ROBLOX_API_KEY = "<key>"
   powershell -ExecutionPolicy Bypass -File tools/create-products.ps1 -UniverseId <id> -DryRun
   powershell -ExecutionPolicy Bypass -File tools/create-products.ps1 -UniverseId <id>
   ```
   It creates the 23 developer products (reusing any that already exist by name) and writes their ids into `src/shared/FeatureConfig/MonetizationIds.luau`.
3. Make the VIP Keeper game pass (399) by hand under Monetization > Passes and paste its id into `MonetizationIds.Passes.VIPKeeper`.
4. Publish. Roblox charges the price set on the product; keep `Robux` in `MonetizationConfig` matching so the shop shows the right number. A re-run of the script never changes the price of a product that already exists: change it on the Creator Dashboard.
5. Game Settings > Security: **Enable Studio Access to API Services** must be on (receipts save through DataStores).

`MonetizationConfig` reads the ids from `MonetizationIds`; nothing else needs editing.

## What's for sale

| Key | Type | Robux | Effect |
| --- | --- | --- | --- |
| `CalmTreat` | Product | 15 | `Hooks.fire("CalmTreat", player, 60)`. The Tension feature freezes patience. Only sold while a wash is in progress (otherwise it would do nothing). |
| `AutoCollect2h` | Product | 49 | Pens collect themselves for 30 minutes of play. Time stacks up to 2 hours. Sold at the blue ROBUX SHOP booth on the plaza. |
| `SpeedBoost` | Product | 19 | 2x walk speed for 10 minutes. Stacks up to 4 hours. |
| `CashSmall` / `CashMedium` / `CashLarge` | Product | 25 / 75 / 149 | `max(Floor, income/s * 60 * Minutes)` with Minutes 5 / 20 / 60, capped at `CapFraction` (10% / 35% / 75%) of the next hose's price, so a pack can never skip a tool tier. Bigger packs are better value per Robux. The shop shows the current amount. |
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
- **Cash tab auto-open:** every 3rd failed hose purchase, at most 3 times a session. A failure is either:
  - a "Not enough cash" PurchaseResult from the server, or
  - a tap on the hose shop's "Buy for" button while short of cash. The hose shop refuses that locally without asking the server.

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
- `Offers.*`: quiet time, cooldown, per-session cap, auto-hide, cash auto-open cadence and cap.
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

## Coupling points (merge watch)

- The cash-pack auto-open also counts hose buys the core `ShopController` refuses locally. It finds them through ShopController's private UI: the ScreenGui `Shop`, its child `ShopPanel`, and button text starting with `Buy for`. This is best effort. If those names change, only the local-refusal path stops counting; the "Not enough cash" `PurchaseResult` listener keeps working. A cleaner fix for core: have ShopController fire a client BindableEvent (e.g. ReplicatedStorage `HosePurchaseRefused`) and listen to that instead.

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
- [ ] After 90 s, tap the hose shop's Buy while short of cash 3 times. The SHOP opens on the Cash tab. It opens at most 3 times per session.
- [ ] Spamming BUY doesn't double-grant (rate limit). Firing `MonetizationBuy` with a junk key or a non-string from the command bar does nothing.
- [ ] Phone emulator (landscape and portrait): the SHOP button, panel tabs, BUY and X buttons are easy to tap, and nothing covers SPRAY or the thumbstick.
- [ ] Before publishing: put the real product and pass ids and prices in MonetizationConfig and confirm `SimulateUnconfiguredLive = false`.
