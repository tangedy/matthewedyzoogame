# Monetization

Robux developer products and game passes, from the shop button to the grant. The concept doc's rules apply: nothing pay-to-win in the "skip the game" sense, no shop prompt in a session's first 90 seconds, mostly repeatable consumables, plus limiteds and whale items.

## Files

| File | Role |
| --- | --- |
| `src/shared/FeatureConfig/MonetizationConfig.luau` | Products, passes, ids, Robux prices, boost strengths, offer rules, guardrails. Also the `ShopState` type the client draws from. |
| `src/server/Features/Monetization.luau` | `init()`: remotes, `ProcessReceipt`, game pass checks, shop requests, Hooks modifiers and listeners, contextual offers, background loop. |
| `src/server/Features/MonetizationState.luau` | `data.Extra.Monetization` (validated on read), per-session state, rate limits, test-mode decision, client payload. |
| `src/server/Features/MonetizationGrants.luau` | What each item does once paid: boosts, cash, limited animal delivery, VIP tag, Fire-Hose Rig unlock. |
| `src/server/Features/MonetizationStock.luau` | Global limited stock (DataStore, idempotent per PurchaseId). |
| `src/client/Features/MonetizationController.luau` | Client state, boost timers, offers, notices, cash-pack auto-open. |
| `src/client/Features/MonetizationShop.luau` | SHOP button and the tabbed shop panel (pure view). |

The helper modules have no `init`, so the feature autoloaders just require them.

## What's for sale

| Key | Type | Robux | Effect |
| --- | --- | --- | --- |
| `SuperSoapStarter` | Product, once per player | 5 | Same as Super Soap. The shop shows it in place of Super Soap until it has been used. While one intro prompt is open (or its receipt is still due) a second one is refused, so it can't be bought twice at the intro price. |
| `SuperSoap` | Product | 9 | 2x cleaning power for 10 minutes (Hooks `CleaningPower`). Time stacks up to 4 hours, counts down only while online, and is saved. |
| `CalmTreat` | Product | 15 | `Hooks.fire("CalmTreat", player, 60)`. The Tension feature freezes patience. Only sold while a wash is in progress (otherwise it would do nothing). |
| `AutoCollect2h` | Product | 49 | Pens collect themselves for 2 hours of play. Time stacks up to 8 hours. Its own green kiosk beside pen 1, labeled 2 HOURS. |
| `AutoCollectForever` | Game pass | 399 | Pens collect themselves forever. Its own gold kiosk beside the 2-hour one, labeled FOREVER. |
| `LuckySoap` | Product | 49 | The next 5 walk-ins: Legendary+ `SpawnWeight` x4, non-Normal `MutationWeight` x3. Stacks up to 50. A charge is used only by a walk-in that was actually rolled with the boost (counted on `WashStarted`). The fixed first animal of a session doesn't use one, and neither does a walk-in replaced by another feature's `NextAnimal` override (e.g. LiveOps' daily or Mud Storm animal). The Legendary+ part only matters once the hose can wash a Legendary species; the card says so. |
| `CashSmall` / `CashMedium` / `CashLarge` | Product | 25 / 75 / 199 | `max(Floor, income/s * 60 * Minutes)`, capped at `CapFraction` (15% / 30% / 50%) of the next hose's price, so a pack can never skip a tool tier. The shop shows the current amount. |
| `LimitedAxolotl` | Product, limited | 1000 | One Axolotl (`Species`/`Mutation` in config) into the cache. Global stock of 1000, never restocked. Shown as COMING SOON until `AnimalConfig.Animals.Axolotl` exists. |
| `VIPKeeper` | Game pass | 399 | Income x1.25 (Hooks `IncomeMultiplier`) and a gold "VIP" tag over the head. |
| `FireHoseRig` | Game pass | 1499 | Sets `data.ToolTier` to the top tier, then `EconomyService.sendTool` and `CleaningService.refreshHose`. |

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
- **Super Soap** (or the starter price, if unused): the server checks 8 s after `WashStarted` for an animal with `WashTimeMultiplier >= 2`. It offers if the wash is still under 50% clean and Super Soap isn't active.
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
- `SuperSoap.PowerMultiplier`, `.Seconds`, `.MaxSeconds`.
- `CalmTreatSeconds`.
- `LuckySoap.WalkIns`, `.MaxWalkIns`, `.MinRarityOrder`, `.SpawnWeightMultiplier`, `.MutationWeightMultiplier`.
- `VIP.IncomeMultiplier`, `.TagText`, `.TagColor`.
- `SoldOutCompensation`.
- `Offers.*`: quiet time, cooldown, per-session cap, auto-hide, Super Soap offer thresholds, cash auto-open cadence and cap.
- `ReceiptsKept`, `PendingDeliverySeconds`, `StockStoreName` / `StudioStockStoreName`, `StockRefreshSeconds`, `StockRecheckSeconds`, `BuyCooldown`, `StateCooldown`, `SimulateUnconfiguredLive`.

## Remotes

| Remote | Direction | Payload |
| --- | --- | --- |
| `MonetizationBuy` (event) | client to server | `key: string` |
| `GetMonetizationState` (function) | client to server | returns `ShopState` (rate-limited) |
| `MonetizationState` (event) | server to client | `ShopState` |
| `MonetizationStock` (event) | server to all | `key, remaining` |
| `MonetizationNotice` (event) | server to client | `text, ok` |
| `MonetizationOffer` (event) | server to client | `kind ("CalmTreat" or "SuperSoap"), productKey` |

## Cross-feature contract

- Fires `CalmTreat (player, seconds)`. Listens for `PatienceLow (player, jobId, fraction)`. Both are fine with Tension being absent.
- Sells `AnimalConfig.Animals.Axolotl` only if it exists (added by the Models feature).
- Owns `MarketplaceService.ProcessReceipt`. Only one handler can exist per game, so any other feature that sells developer products must go through this one.

## Coupling points (merge watch)

- The cash-pack auto-open also counts hose buys the core `ShopController` refuses locally. It finds them through ShopController's private UI: the ScreenGui `Shop`, its child `ShopPanel`, and button text starting with `Buy for`. This is best effort. If those names change, only the local-refusal path stops counting; the "Not enough cash" `PurchaseResult` listener keeps working. A cleaner fix for core: have ShopController fire a client BindableEvent (e.g. ReplicatedStorage `HosePurchaseRefused`) and listen to that instead.
- Lucky Soap's `NextAnimal` modifier is registered one frame after `init` so it runs after the overrides other features register in their own `init`. A feature that registers a `NextAnimal` modifier later than that would make an overridden walk-in use a charge.

## Check in Studio

- [ ] Play solo. A pink SHOP button sits under INDEX on the left. Tapping it pops open the panel with Boosts / Cash / Passes / Limited tabs and a TEST MODE line.
- [ ] Boosts: Super Soap shows 5 ROBUX at first. BUY grants it (notice "[TEST] Super Soap!") and a "SOAP 2X 9:59" pill appears right of INDEX. The card now shows 9 ROBUX. Buying again stacks the time.
- [ ] With Super Soap active, washing is visibly ~2x faster. Rejoin: the remaining time is kept (with Studio API access enabled).
- [ ] Lucky Soap: BUY, and the "LUCKY: 5 LEFT" pill appears. It counts down by one per walk-in after purchase. Rarer/mutated animals show up noticeably more often. With LiveOps merged, a daily/Mud Storm override walk-in doesn't use a charge.
- [ ] Calm Treat: BUY with no animal at the wash spot: refused with "Start washing an animal first!". BUY during a wash: if the Tension feature is merged, patience freezes for 60 s. Without it, only the notice shows.
- [ ] Cash: the cards show amounts, and each is at most 15% / 30% / 50% of the next hose price. BUY adds exactly that much cash.
- [ ] Limited: the Axolotl card shows COMING SOON until the Models branch adds `Axolotl` to AnimalConfig. Once it's there:
  - [ ] it shows "N / 1000 LEFT", and BUY puts an Axolotl in a free cache slot (plus an index toast);
  - [ ] with a full cache, the notice says it will join when a slot frees, and it appears a few seconds after you place or sell a cache animal.
- [ ] Passes: VIP Keeper adds a gold VIP tag over your head (it survives a respawn) and pen income is 25% higher. Fire-Hose Rig swaps in the top hose immediately, and the HUD hose label updates. Both cards then read OWNED.
- [ ] Offers stay silent for the first 90 s of a session. After that:
  - [ ] a big animal (e.g. Cow or Zebra) left mostly dirty for 8 s pops a Super Soap offer at the right middle. X dismisses it, and it auto-hides after 12 s;
  - [ ] with Tension merged, low patience pops the Calm Treat offer.
- [ ] After 90 s, tap the hose shop's Buy while short of cash 3 times. The SHOP opens on the Cash tab. It opens at most 3 times per session.
- [ ] Spamming BUY doesn't double-grant (rate limit). Firing `MonetizationBuy` with a junk key or a non-string from the command bar does nothing.
- [ ] Phone emulator (landscape and portrait): the SHOP button, panel tabs, BUY and X buttons are easy to tap, and nothing covers SPRAY or the thumbstick.
- [ ] Before publishing: put the real product and pass ids and prices in MonetizationConfig and confirm `SimulateUnconfiguredLive = false`.
