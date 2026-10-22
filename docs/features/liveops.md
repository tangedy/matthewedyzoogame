# LiveOps (retention and live-ops)

Systems that give players a reason to come back and stay: a Daily Dirty Animal, a scheduled server-wide Mud Storm, offline earnings, a zoo star rating, leaderstats with a plaza leaderboard, and an AnalyticsService onboarding funnel.

## Files

| File | What it does |
| --- | --- |
| `src/server/Features/LiveOps/init.luau` | Feature entry point. Starts the modules below and answers `LiveOpsSync`. |
| `src/server/Features/LiveOps/Common.luau` | Saved state (`data.Extra.LiveOps`, validated on first read), UTC day maths, developer check, announcements. |
| `src/server/Features/LiveOps/MudStorm.luau` | Storm schedule, developer start/stop, spawn/mutation/mud modifiers. |
| `src/server/Features/LiveOps/Daily.luau` | Daily Dirty Animal. |
| `src/server/Features/LiveOps/Offline.luau` | LastSeen tracking and offline earnings. |
| `src/server/Features/LiveOps/Stars.luau` | 1-5 star zoo rating and the bay sign stars. |
| `src/server/Features/LiveOps/Leaderboard.luau` | Native leaderstats and the TOP ZOOS board in the plaza. |
| `src/server/Features/LiveOps/Analytics.luau` | Onboarding funnel and economy events. |
| `src/client/Features/LiveOpsController/init.luau` | Client entry point, plus the developer M key. |
| `src/client/Features/LiveOpsController/Storm.luau` | Storm banner and teaser, murky lighting, mud rain, start splash. |
| `src/client/Features/LiveOpsController/Popups.luau` | WELCOME BACK panel and the DAILY DIRTY ANIMAL banner. |
| `src/client/Features/LiveOpsController/Stars.luau` | Star widget above the cash counter. |
| `src/shared/FeatureConfig/LiveOpsConfig.luau` | All tuning values. |

## What it does

### Daily Dirty Animal
Once per UTC day, the player's next walk-in becomes a guaranteed Rare-or-better species. It is never the session's first animal, and only species their hose tier can handle, that can spawn and have a model are picked. It comes in extra muddy (`WashTimeMultiplier` x1.5) and pays a bigger wash reward (x2). The owner sees a "DAILY DIRTY ANIMAL!" banner, and a rainbow tag floats over the animal while it is washed. The day counts as claimed when the animal reaches the wash spot (`WashStarted`). If the player leaves before that, they still get it next time. Saved as `DailyDay` (UTC day number).

Hooks used: `NextAnimal`, `WashTimeMultiplier` and `WashReward` modifiers, plus the `WashStarted` and `WashCompleted` events. The daily animal does not replace a walk-in that another feature has already overridden.

### Mud Storm
A server-wide event that runs on a fixed UTC schedule, so every server agrees: Saturday 18:00 for 15 minutes, plus 5-minute mini-storms every day at 01:00 and 17:00. While a storm is active:
- Legendary-and-up species get `SpawnWeight` x3.
- Non-Normal mutations get `MutationWeight` x3.
- Animals come in muddier (`WashTimeMultiplier` x1.4).
- Everyone sees an announcement and a big "MUD STORM!" splash.

Storm state is replicated as attributes on `ReplicatedStorage.LiveOpsState` (`MudStormActive`, `MudStormEndsAt`, `MudStormNextAt`, all unix seconds). The feature also fires `Hooks.fire("MudStormChanged", active, endsAt)`.

On the client, the free centre of the top bar shows "MUD STORM! 12:34". When the next storm is less than an hour away it shows "NEXT MUD STORM IN 42m 10s" instead. During a storm the lighting tweens to a murky brown-orange and back to the original values afterwards, and mud rain falls around the camera.

Developer controls (Studio, or the place owner):
- Press **M** to toggle a storm.
- Or type `/storm start` / `/storm stop` in chat.
- Or fire the `LiveOpsDev` remote with `"stormStart"` / `"stormStop"`.

The server rate-limits these to one per second and ignores anyone else. Starting a storm runs one for `DevStormMinutes`. Stopping one also skips the rest of a scheduled storm that is in progress.

### Offline earnings
`LastSeen` is saved when the player leaves and refreshed every 60 s while they play. On join, the time away is capped at 2 h, passed through `Hooks.apply("OfflineSeconds", seconds, player)`, and turned into earnings: `ZooService.totalIncome(player) * seconds * 0.5`. The cash is deposited with `ZooService.addToPads` on `BayAssigned`, once the pens exist. Absences under 60 s earn nothing.

The owner gets a bouncy "WELCOME BACK!" panel with the amount. Its COLLECT button only closes the panel, because the cash is already on the pads. If the server calculates the earnings before the client controller is listening, the client picks the popup up with the `LiveOpsSync` RemoteFunction. That function answers once per player and never yields.

### Zoo star rating
The rating runs from 1 to 5 stars and is built from three metrics:
- Base income per second: thresholds 10 / 100 / 1K / 10K / 100K.
- Index completion: 5% / 15% / 30% / 50% of species x mutations, not counting Limited species.
- Pens unlocked: 6 / 8.

Each threshold reached is worth one point, and the points total picks the stars (`StarPoints`). The stars appear in three places:
- On a separate billboard on the bay's `SignPost`, just above the core "<name>'s Zoo" label. The core label is not edited.
- In the `ZooStars` attribute on the Player, which drives the HUD widget above the cash counter. The widget pops and chimes when the rating goes up.
- In leaderstats.

When a zoo reaches a rating it has never had before (saved as `BestStars`), the server announces it to everyone.

### Leaderstats and leaderboard
LiveOps owns each player's `leaderstats` folder: `Cash` (StringValue, `UIStyle.formatMoney`), `Income` (StringValue, `$X/s`, base income x the `IncomeMultiplier` modifiers) and `Stars` (IntValue). They update every 2 s.

A "TOP ZOOS" board stands behind the plaza fountain at (17, 0, -7) and faces -X, toward the welcome sign. It ranks the top 8 players in the server by income per second, with their stars, and refreshes every 5 s.

### Analytics
`AnalyticsService:LogOnboardingFunnelStepEvent` logs each of these steps once per player. Logged steps are remembered in `data.Extra.LiveOps.Funnel`.

1. Joined
2. First wash started
3. First scrub (first `WashProgress`)
4. First wash completed
5. First animal placed in a pen
6. First hose upgrade (`ToolTier > 1`, polled)
7. First zoo expansion (`ZooSize > StartPens`, polled)

Players who had already washed animals before this feature shipped skip the funnel: all steps are marked done and nothing is logged.

`LogEconomyEvent` records three cash sources:
- Wash rewards (`Gameplay`, sku `Wash:<Species>`).
- Sales (`Gameplay`, sku `Sell:<Species>`).
- Offline earnings (`TimedReward`).

Every AnalyticsService call is wrapped in pcall.

### Saved data (`data.Extra.LiveOps`)
`{ LastSeen: number?, DailyDay: number?, BestStars: number, Funnel: { [ "S1".."S7" ]: true } }`. Every field is repaired on first read: non-finite numbers are dropped, `BestStars` is clamped to 0-5, and Funnel entries that aren't `true` are dropped.

### Remotes (created on demand)
| Remote | Direction | Payload |
| --- | --- | --- |
| `LiveOpsDaily` | server -> owner | (displayName, rarity, mutation, rewardMultiplier) |
| `LiveOpsWelcomeBack` | server -> owner | (amount, seconds) |
| `LiveOpsSync` (function) | client -> server | () -> { WelcomeBack: { Amount, Seconds }? } |
| `LiveOpsDev` | client -> server | ("stormStart" \| "stormStop"), developer only, 1/s |

## Config knobs (`LiveOpsConfig`)
- `Daily`: `MinRarity`, `WashTimeMultiplier`, `RewardMultiplier`, `WeightExponent` (flattens the species odds).
- `MudStorm`:
  - `Slots`: a list of `{ Weekday?, Hour, Minute, DurationMinutes }` in UTC. Weekday 1 is Sunday and 7 is Saturday; leave it out for every day.
  - `RareSpawnMultiplier`, `MinBoostedRarity`, `MutationMultiplier`, `WashTimeMultiplier`.
  - `DevStormMinutes`, `TeaserSeconds`, `CheckInterval`.
- `Offline`: `MaxSeconds`, `MinSeconds`, `Rate`, `LastSeenInterval`.
- `Stars`: `IncomeThresholds`, `IndexThresholds`, `PenThresholds`, `StarPoints`.
- `Leaderstats.UpdateInterval`.
- `Board`: `Position`, `Size`, `Height`, `Rows`, `UpdateInterval`.
- `Analytics.PollInterval`.

## Check in Studio
- [ ] Play: the player list shows Cash, Income and Stars for you, and they update within about 2 s of earning or spending.
- [ ] A "TOP ZOOS" board stands behind the plaza fountain, readable from the welcome sign, with your name, $/s and stars. Nothing clips into the fountain or the bays.
- [ ] Your bay sign shows a row of stars above "<name>'s Zoo", and the HUD shows "ZOO ★☆☆☆☆" above the cash counter without overlapping the cash or the INDEX button (check a phone emulator too).
- [ ] Grant cash (G), buy hoses and expand the zoo, and fill pens until income passes 100/s. The star rating goes up, the HUD widget pops, and an announcement "<name>'s zoo is now N STARS!" appears.
- [ ] Press M (or type `/storm start`): announcement, "MUD STORM!" splash, top-bar countdown "MUD STORM! 4:59", brown-orange lighting and mud rain around the camera. Walk-ins are muddier, and Legendary+ animals and mutations show up noticeably more often.
- [ ] Press M again (or `/storm stop`): the storm ends, the "Mud Storm has passed" announcement shows, and the lighting fades back to exactly the normal look.
- [ ] Change a `MudStorm.Slots` entry to start a few minutes from now (UTC). The "NEXT MUD STORM IN ..." teaser appears and counts down, then the storm starts by itself.
- [ ] Daily Dirty Animal: on a fresh day (or after clearing `DailyDay`), the second walk-in of the session is Rare or better and allowed by your hose. It shows the "DAILY DIRTY ANIMAL!" banner and a rainbow tag, takes longer to wash, and pays double. The next walk-in is normal. Rejoining the same day gives no second daily animal.
- [ ] Offline earnings: with animals in pens, leave, set `Offline.MinSeconds` low (or wait more than 60 s), and rejoin. The WELCOME BACK panel shows the amount, the pen pads hold that cash, and COLLECT closes the panel.
- [ ] A player who isn't the developer can't start or stop storms: the M key isn't bound, and the remote and chat command are ignored.
- [ ] Output shows no LiveOps errors. AnalyticsService warnings in Studio are expected and harmless.
