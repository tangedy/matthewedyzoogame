# QA report: online/multiplayer integration (2026-10-24)

Build: `main` at 97725af (6-stall + 4-barn layout, MaxPens 14, recoloured shopkeepers).

## How it was tested

- Studio MCP against an unpublished place (PlaceId 0), Rojo-synced (line counts matched the repo).
- Solo Studio playtests: the server took Bay8 (west) in one run and Bay1 (east) in another, so both plot sides were checked live.
- Pure logic (`PlayerDataService.sanitize`) was unit-tested in Edit mode against crafted old saves.
- Everything else was reviewed in code, marked **(review)** below.

### Limits that shaped the run

- The MCP can only start a **solo** playtest, not Test > Clients and Servers.
- The place is **unpublished**, so DataStores and ProfileService fall back to a temporary profile.
- Scripted and synthetic key presses do not trigger ProximityPrompts in the MCP playtest, so prompt-driven flows (buy barn, place, swap, sell, collect) were verified in code, not by clicking.
- Each MCP `require` gets its own module copy, so live service tables cannot be inspected.

## Lint

| Check | Result |
| --- | --- |
| `stylua --check src` | PASS (clean) |
| `selene src` | 0 errors, **2 warnings, exit code 1**, so the README's `stylua src && selene src` chain reports failure. `OnboardingController.luau:60` has an unused `washing`, and `ZooService.luau:1615` shadows `data`. |

## Summary

| Area | Tests run | Pass | Fail | Untested |
| --- | --- | --- | --- | --- |
| 1. Online integration | 9 | 7 | 1 | 1 |
| 2. Systems | 12 | 11 | 1 | 0 |
| 3. Friends (Social, FriendLuck) | 6 | 5 | 1 (low) | live friend join |
| 4. Saves | 9 | 6 | 2 (1 fixed) | 1 |
| 5. Base visibility | 9 | 8 | 0 | 1 |
| 6. Leaderboard | 6 | 2 | 4 | 0 |

## 1. Online integration

| Test | Expected | Actual | Result |
| --- | --- | --- | --- |
| Join and get a bay (live, solo) | Random free plot built, sign set, spawn on plaza | Bay8 and Bay1 built and assigned, `OwnerUserId` set | PASS |
| Leave, then release (review) | Thread cancelled, line cleared, unpaid wash dropped, model destroyed, slot freed | `BayService.release` does all of this, then calls `ZooService.detach` | PASS |
| Full server queue (review) | Ninth player queued and given the next free bay | `waiting` list, served FIFO on release | PASS |
| Full server config | Max Players = BayCount (8) | Place Max Players is **30**; README still says BayCount 4. Up to 22 players would sit with no bay at the map origin. | FAIL (config) |
| Server-authoritative wash (review, plus prior fuzz) | Server-side raycast, rate cap, pays once | `CleaningService`: rate cap, `MaxAcceptedStep`, `Active` lock before `OnComplete` | PASS |
| Co-op helpers (review) | Helpers speed up the wash but cannot finish it; payout goes to the owner only | Helper leaves `FinishReserve`; `awardWash` is called for the owner only | PASS |
| Cross-player prompts, pads, expand (review) | Non-owner cannot act | Every `Triggered` handler checks `who == player`, pads check the owner's character, and the client sets reach to 0 on other bays | PASS |
| Remote spam (live) | No double charge or progress | 300 `PurchaseToolUpgrade` plus 300 fake `CleaningIntent` in one frame: no change, no errors | PASS |
| 2–8 real clients join, leave, rejoin | — | Not possible through the MCP | UNTESTED |

## 2. Systems

| Test | Result |
| --- | --- |
| Economy: prices, spend and grant validation, non-yielding upgrade (review) | PASS |
| Hose shop spam (live) | PASS |
| ZooService place, swap, sell, collect (review): ownership, Paid confirm token, pad debounce, cap | PASS |
| Expansion ladder (live): stand at UnlockSpot1, "SMALL BARN $25K", ghost pens 7/8, pens 9–14 hidden | PASS |
| Expansion progression (review): `nextExpansion`, ghost range, stand moves to `UnlockSpot{n}`, hidden at max | PASS |
| LiveOps check-in (review): day marked before the yielding grant, server clock only | PASS |
| Offline earnings (review): server `LastSeen`, clamp, future or garbage timestamps pay 0 | PASS |
| Mud Storm and Tension dev commands (review): `isDeveloper` gate plus cooldown | PASS |
| Monetization receipts (review): idempotent by `PurchaseId`; a temporary profile returns NotProcessedYet; save after grant | PASS |
| Monetization live config: every product and pass `Id = 0`. Studio always simulates, so no real or test prompt path exists; live non-owners get "Not on sale yet". | FAIL (release blocker) |
| Remote fuzz (live): about 3,500 calls with NaN, inf, huge vectors, 5 KB strings, nested tables, Instances | PASS (0 server errors, cash unchanged) |
| Dev remotes on live servers (review): Studio or `CreatorId` only | PASS |

## 3. Friends

| Test | Result |
| --- | --- |
| FriendLuck pair check (review): `IsFriendsWith` in a pcall; a failure counts as not friends; leaving recounts the remaining players | PASS |
| SpawnWeight hook applied (review): `AnimalService.lua:117` | PASS |
| Friend joins or leaves mid-session (review): `publish` runs on both sides; nil-safe if either leaves during the web call | PASS |
| Flex tiers update (review): PlaySeconds accrue every 15 s and on leave; tier from washes or time | PASS |
| Pets cap and cleanup (review) | PASS |
| `Social.luau:352`: `accrue` runs `applyCosmetic` every 15 s, which destroys and rebuilds the trail and hose glow for every player. Particles reset visibly and instances churn over replication. | FAIL (low) |
| Live friend and non-friend accounts | UNTESTED. Studio test players cannot be friends, and the rules forbid real accounts. |

## 4. Saves

| Test | Expected | Actual | Result |
| --- | --- | --- | --- |
| Failed load never saves (live) | Temporary profile, banner, no write | API off: `Status = Failed`, red banner, ProfileService skipped | PASS |
| **Migration: old ZooSize 24, 17, 22 with animals in pens 15–24** | No animal loss | **Lost 10, 3 and 5 animals respectively, plus their pad cash** | **FAIL, fixed** |
| Migration: road-cage animals (pens 25–28, `Extra.RoadCages`) | Kept | **4 of 7 deleted** | **FAIL, fixed** |
| Migration: raw overflow over 8 | Kept or compensated | Extras deleted | **FAIL, fixed** |
| ZooSize clamp: 24, 22, 17 become 14; 10 stays 10; 19 becomes 22 then 14; junk becomes 6 | Nearest valid step | As expected | PASS |
| Barn tier kept from purchases (see bug 2) | The barn the player bought | Fixed: `BarnTier` is saved (v10); old 10/14/17/19–24 map to Small/Medium/Large/Gargantuan | FAIL, fixed |
| Sanitize run twice (live Edit test) | Stable | Second pass changes nothing | PASS |
| Save on leave and shutdown (review) | `PlayerLeaving` hook before `Release`, plus BindToClose | Correct ordering | PASS |
| Session lock: same account on two servers | Second server ForceLoads, first marks `Locked` and stops saving | Correct by code (`ListenToRelease`); not run live | UNTESTED (needs a published place) |
| 60 s autosave | — | ProfileService's own autosave; not observable without API access | UNTESTED |

## 5. Base visibility

| Test | Result |
| --- | --- |
| Pen layout, both sides (live): east x+, west x−, pens 1–6 Standard stalls, 7–10 Medium, 11–12 Giant, 13–14 Gargantuan; left and right of the walkway; no overlaps; all inside the 440 plot depth | PASS |
| Ghost and locked pens replicate to the client (live): ghost T = 0.72, no collision, pad hidden, prompts off | PASS |
| Unlock stand on UnlockSpot1 with the price label (live, client) | PASS |
| Shopkeepers, server and client, both booths, both sides (live): skin face and moustache, cream shirt, brown trousers, booth-coloured apron, cap, no BodyColors left, screenshot confirmed | PASS |
| Collect pads hidden until revealed, then shown (live) | PASS |
| Visitors cannot interact (review): client sets reach to 0 and the server re-checks the owner | PASS |
| Bay cleanup on leave, fresh bay for a new owner (review): model destroyed and rebuilt from scratch per assignment | PASS |
| Billboards (sign, income) replicate (review; `MaxDistance` 160) | PASS |
| A second client watching (pens, animals, pad amounts) | UNTESTED (single client) |

## 6. Leaderboard (`LiveOps/Leaderboard.luau`)

| Test | Result |
| --- | --- |
| Sorts by income, descending (review, line 252) | PASS |
| Ties broken by UserId, so the order is stable (review) | PASS |
| Persists across servers | **FAIL: not implemented.** There is no DataStore or OrderedDataStore; the board ranks only players in this server. |
| OrderedDataStore failure and rate-limit handling | **FAIL: not applicable**, there are no store calls |
| Shows names of players who have left | **FAIL: they disappear** as soon as they leave |
| Values update | PASS for the in-server board and leaderstats (polling loop) |

## Fix applied (separate from the findings)

**`src/server/Services/PlayerDataService.luau`, migration animal loss**

- **What it does now:** an animal whose saved pen this layout no longer has (pen > ZooSize, a removed road cage, or a duplicate pen) is collected as *displaced* instead of `continue`d away.
- **Where displaced animals go:** they fill free pens 1..ZooSize first, then the overflow line. Their uncollected pad cash is paid into Coins.
- **Overflow cap:** overflow past `MAX_OVERFLOW` (8) is now **sold at its sell value** (newest unpaid first) instead of dropped. Robux (`Paid`) animals are always kept.

Re-test results (Edit-mode harness on the synced source):

| Save | Before the fix | After the fix |
| --- | --- | --- |
| ZooSize 24, 24 animals | 10 lost | 14 penned, 8 overflow, 2 sold for $300 plus $1,000 pad cash |
| ZooSize 17, 17 animals | 3 lost | 14 penned, 3 overflow |
| ZooSize 24 with cages 25–28 | 4 lost | all 7 penned |
| ZooSize 22, pens 15–22 | 5 lost | all 5 penned |
| All-Paid 24 | 10 lost | 14 penned, 10 overflow (Paid never sold) |

Also re-checked: no duplicate pens or ids, a second pass changes nothing, stylua clean, selene unchanged (same 2 pre-existing warnings), and a playtest loads with no errors.

## Bugs, ranked

1. **[High, fixed] Old saves lose animals on load.** `PlayerDataService.luau`, sanitize animal loop (was lines 421–429).
   - Repro: a save with `SchemaVersion 9, ZooSize 24` and animals in pens 1–24 (or 25–28 with `Extra.RoadCages.Open`) loads with only pens 1–14.
2. **[High, fixed] The save kept the pen count, not the barn bought**, so a layout change re-read old pen counts as different barns.
   - Old 10 (Small barn) read as the new Medium barn; old 14 (Medium) read as every barn unlocked.
   - Fix: schema v10 saves `BarnTier` (barns bought, 0–4). ZooSize is worked out from it on every load, and pen numbers are positions only.
   - Old saves map their ZooSize onto the barn they paid for: 10→Small, 14→Medium, 17→Large, 19/22→Gargantuan.
   - Old Mega (24) also gets Gargantuan; a refund for the 50M Mega barn is a design call. ZooSize 8 and 12 exist only in the v9 build of the new layout, so they map to Small and Large.
   - `ZooService.nextExpansion` and `expand` now use `BarnTier`.
   - Re-tested in Edit mode: every old size maps correctly, v10 tiers 0–4 are stable, junk and out-of-range values clamp, and a second load changes nothing. A playtest loads with no errors.
3. **[High, missing feature] The leaderboard is server-local only.** No persistence, no OrderedDataStore, no failure or rate-limit handling, and leavers vanish.
4. **[Medium, release blocker] Every monetization product and pass Id is 0** (`MonetizationConfig.luau`). The real prompt and receipt path can't be exercised; live non-owners see "Not on sale yet".
5. **[Medium, config] Place Max Players is 30 but BayCount is 8.** Overflow players stand at the map origin with no bay. README says 4.
6. **[Low] `Social.luau:352`:** flex cosmetics are rebuilt every 15 s, so the trail visibly resets. Rebuild only when the tier changes.
7. **[Low, design] Any player can co-op spray any bay's animal.** The roadmap said owner or party only, and the brief says visitors cannot interact. The helper multiplier is also super-linear: N helpers × (1 + (N−1)·bonus).
8. **[Low] Selene warnings** make the README check chain exit 1 (`OnboardingController.luau:60`, `ZooService.luau:1615`).
9. **[Low] Stale code and docs from the road-cage layout:**
   - `WorldBuilder.luau:17-18` header still lists Pen19/23/24 and Pen25-28.
   - `ZooService.placeCarried` "Buy the Cage barn upgrade" branch is unreachable.
   - README says BayCount 4.
10. **[Low] `rbxassetid://203785492` "Asset type does not match"** warning on every join. Not referenced in `src`, so it probably comes from the cutscene avatar description.

## Not tested, and why

- Real 2–8 client sessions, bays visible from other clients, a full server: the MCP can only start solo play.
- DataStore saves and reloads, the 60 s autosave, shutdown saves, the cross-server session lock, OrderedDataStore: the place is unpublished.
- Studio test purchase prompts: the code simulates in Studio and never calls MarketplaceService; IDs are 0.
- Friend and non-friend accounts: Studio test players can't be Roblox friends, and real accounts are excluded.
- Clicking through prompts (expand, place, swap, sell, collect): synthetic input doesn't trigger ProximityPrompts in the MCP playtest; covered in code review.

To finish these, publish a private place, enable API Services, set Max Players to 8, and run Test > Clients and Servers with 4 clients.

## Recommended fix order

1. Ship both save fixes together (animal rehoming and the v10 `BarnTier`, both done). Decide whether old Mega-barn owners get a refund.
2. Monetization IDs, then a test-prompt pass on a published place.
3. Max Players = 8, then the full-server and queue test.
4. A persistent leaderboard (OrderedDataStore with pcall, backoff, cached names), if it's in scope for launch.
5. Social cosmetic churn, the co-op scope decision, the selene warnings, stale docs, and the asset warning.
