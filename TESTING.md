# Studio test checklist

Milestones 1 and 2 passed in Studio. Claude ran parts of Milestones 3–5 and the zoo loop in solo Studio playtests through Studio MCP; those checks are marked ✅ below. The rest still need you: anything that needs saving (a published place), two real players, or a phone.

Watch the **Output** window for `[BayService]` / `[PlayerDataService]` warnings or script errors the whole time.

## Milestone 1: one animal can be washed

Press Play (solo).

- [ ] You spawn on the blue pad beside a concrete bay holding a green hose, and the sign reads "<you>'s Wash Bay".
- [ ] A pink block pig covered in brown mud discs walks in from the left and stops on the blue drain.
- [ ] The instruction "Hold to spray. Wash off all the mud!" appears.
- [ ] Holding the left mouse button shows a water beam from the hose to the cursor, with a splash where it lands.
- [ ] Spraying a mud disc makes it shrink and fade, then disappear. The clean % rises.
- [ ] Spraying the floor, the sky or a clean spot does **not** raise the clean %.
- [ ] Spraying the pig's left side never cleans patches on its right side. You have to walk around it.
- [ ] Every patch can be reached while standing: sides, back, rump, head sides.
- [ ] The reticle turns green while it's over the animal.
- [ ] Around 85%, the remaining mud glows yellow and shows through the body, with the "Almost clean!" hint.
- [ ] The first pig takes roughly **30–45 s**. To tune it, change `GameConfig.BaseWashSeconds` or `ToolConfig[1].CleaningPower`.

## Milestone 2: complete repeatable loop

- [ ] At 100% the pig hops, sparkles and plays a chime, and "+25 coins!" floats up. Coins in the top right go to 25.
- [ ] The pig walks out to the right and is removed. About a second later the next animal walks in without you doing anything.
- [ ] After the first animal, a mix of pigs, sheep and cows arrives.
- [ ] **Ten washes in a row** without restarting. The coin total equals the sum of the rewards shown, so each animal paid exactly once.
- [ ] Explorer → `Workspace.WashBays.Bay1` holds at most one `Animal` at a time, and no old animals or effects build up.
- [ ] Spraying hard during the last patch never pays twice.
- [ ] Every patch on the sheep and cow can be reached. The cow has no mud on top by design, because a standing player can't reach it.

## Milestone 3: progression and saving

Setup: publish the place and turn on **Game Settings → Security → Enable Studio Access to API Services**.

- [ ] No red "won't save" banner appears under the wash meter.
- [ ] A blue **HOSE UPGRADES** counter with a yellow awning stands next to your spawn pad. Walking up shows an "Upgrade Hose" prompt (E on desktop, a tap button on mobile).
- [ ] The shop never opens on its own, and spraying never opens it.
- [ ] The panel shows Current: Basic Hose (Tier 1), Next: Strong Hose, Cleaning speed +50%, and Buy for 150 coins.
- [x] ✅ Buying with fewer than 150 coins shows "Not enough coins. You need N more." and nothing changes.
- [x] ✅ Buying with enough coins takes exactly 150, then 600 for Tier 3. Coins and the tool label update. (Not yet checked by eye: the panel text and the thicker beam.)
- [x] ✅ 5 purchase requests sent at once charge only once.
- [x] ✅ At Tier 3 the server refuses: "Your hose is already fully upgraded!"
- [ ] Washing is noticeably faster after upgrading (server-side power).
- [ ] At Tier 3 the panel says "Your hose is fully upgraded!" and has no Buy button.
- [ ] Walking more than about 14 studs from the counter closes the panel.
- [ ] **Rejoin:** stop, then play again. Coins and tool tier come back, and the first-wash instruction doesn't show again.
- [ ] **Failed load can't overwrite data:** turn API Services **off**, then play. The red banner appears. Earn some coins, stop, turn API Services back **on**, then play again. Your earlier saved coins come back, not 0 and not the temporary session's coins.
- [ ] Pacing: the first upgrade is affordable after a few animals (about 5 washes, 3–4 minutes).

## Milestone 4: multiplayer and mobile

### Server hardening (verified in a solo playtest)

- [x] ✅ CleaningIntent with a fake job ID, NaN, a huge vector, a string, or aimed at the sky: no progress.
- [x] ✅ 200 requests in one frame count as one. Spamming at 60 Hz cleans no faster than real time (+0.091 per second against a 0.097 maximum at Tier 3).
- [x] ✅ Spamming completion (10 force-cleans and 20 cleaning requests at once) pays exactly once, 3 rounds in a row. Only one animal is left in the bay afterwards.
- [x] ✅ When the hint shows (≥85%), the remaining mud pulses yellow (Neon) and the outline shows through the body.
- [x] ✅ Neighbouring bays' signs no longer pile up on screen (shorter draw distance).
- [x] ✅ Server ran at about 59 fps with one active bay.

### Two players (Test → Clients and Servers → 2 players)

- [ ] Each player gets their own bay and animal, and they wash independently.
- [ ] Player 2 spraying player 1's animal does nothing. Player 2 can watch.
- [ ] When a player leaves, their animal is removed and their sign goes back to "Wash Bay N".
- [ ] **Queue:** temporarily set `GameConfig.BayCount = 1` and start 2 players. Player 2 sees "All wash bays are taken". When player 1 leaves, player 2 is moved to the bay and an animal arrives.
- [ ] With 4 players all washing at once, there's no noticeable lag (Shift+F5 shows the frame rate).

### Mobile (Studio Device emulator, then a real phone)

- [ ] A large round WASH button sits right above the jump button and doesn't overlap the thumbstick or jump.
- [ ] Holding WASH sprays. Dragging the same finger turns the camera and the reticle while the water keeps flowing. Letting go anywhere stops it.
- [ ] Landscape phone: `PlayerGui.UIFormFactor` reads **Mobile**. Cash sits top left, with INDEX / DAILY / SHOP under it, and nothing overlaps.
- [ ] Moving with the thumbstick while holding WASH works (two thumbs).
- [ ] The reticle sits above your character (40% down the screen), not on top of it.
- [ ] **Aim assist:** with the reticle near the animal (not exactly on a patch), holding WASH snaps the reticle to the nearest reachable mud patch and cleans it.
- [ ] Aim assist never snaps to a patch hidden behind the body or out of range.
- [ ] A full wash is comfortable with thumbs only. Opening the shop with the tap prompt works.
- [ ] The mud fade looks clear at phone size. This is the doc's #1 technical risk, so note how it feels.

## Milestone 5: presentation

Verified in a Studio playtest:

- [x] ✅ Mud patches have 2 splatters each (24 patches, 48 splatters on the pig).
- [x] ✅ The animal arrives mud-tinted and its colour brightens as it's cleaned, back to its true colour at 100%.
- [x] ✅ "Squeaky clean!" appears above the animal on completion.
- [x] ✅ The next animal can be sprayed about 6–7 s after the last one finished.
- [x] ✅ The first time an upgrade is affordable, a yellow banner says "You can afford the Strong Hose!…" and the marker is attached to the bay's upgrade counter.
- [x] ✅ No script errors in Output.

Check by eye (the screenshot tool couldn't render these):

- [ ] On the first wash of a session, a bobbing **"Wash me! ▼"** marker floats over the animal's head and disappears once you've cleaned about 15%.
- [ ] The **"Upgrade! ▼"** marker floats over the HOSE UPGRADES stand and disappears when you open the shop.
- [ ] Each patch that comes clean bursts into mud chunks with a squelch, and soap bubbles appear where the spray hits the animal.
- [ ] The mud reads as brown mud, not black spots, from normal play distance. If not, tune `MUD_COLOR` in `AnimalBuilder` and `DirtRenderer`.
- [ ] Doc pass criteria: a new player finishes the first wash without help, the remaining dirt is easy to find, the dirty-to-clean change is obvious, and washing (not menus or waiting) stays the focus.

## Zoo loop: cache, carry, income, tiers, mutations

Verified in a Studio playtest (forced washes with the C dev key):

- [x] ✅ Only the occupied bay is built (`Workspace.WashBays` holds just `Bay1` in solo play).
- [x] ✅ Wash rewards are paid in cash and scale with income and mutation (Pig $45, Gold Sheep $112). A first discovery pays double.
- [x] ✅ Each washed animal walks into the cache. After 3, the bay shows `CacheFull` and no new animal arrives until there's room.
- [x] ✅ Picking up from the cache puts a small copy of the animal on your head, and `CarryChanged` reports it.
- [x] ✅ Using a pen's gate prompt while carrying an animal places it. On an occupied pen it swaps: the old animal sells for 60 s of its income plus its uncollected cash (+$201 for a Pig).
- [x] ✅ A penned animal fills its pad at its income rate (Pig: $12 after 4 s), and stepping on the pad collects it.
- [x] ✅ Once the cache has room again, washing resumes.
- [x] ✅ No script errors.

Check by eye or with saving:

- [ ] **Nameplates:** each animal shows its mutation (if any), name, rarity in its tier colour, and green `$X/s`. Zoo God text cycles through a rainbow, and Secret is black with a white outline.
- [ ] **HUD:** big green cash with `+$X/s` on the left, and the INDEX button below it. The wash panel at the top shows name, rarity, mutation and a black-outlined clean bar.
- [ ] **Carrying:** the "CARRYING …" banner appears while you hold an animal. Dying or resetting puts the animal back in the cache.
- [ ] **Hints:** the "Cache full!" hint shows when the line is paused. For a new player, "Pick me up!" and "Place here!" markers guide the first placement.
- [ ] **Selling from the cache:** hold F at a waiting animal to sell it for 60 s of its income.
- [ ] **Hose shop:** shows `$` prices and "unlocks Epic animals" (and so on). Rarer tiers only walk in after buying the matching hose.
- [ ] **Announcements:** a Mythic, Zoo God or Secret walk-in, or any Rainbow mutation, shows a server-wide message.
- [ ] **Saving (published place):** pens, uncollected cash, cache contents and the index all come back after rejoining. Saves made before this change convert over (Legendary becomes Gold, Mythic becomes Rainbow).
- [ ] **Two players:** each gets their own bay, a second bay appears and disappears with its player, and nobody can use another player's prompts or pads.

## Presentation pass

Verified in a Studio playtest:

- [x] ✅ **World:** bright sky and green grass (the Studio grid is removed), white fences, trees, a red barn and silo, the dirt road the animals walk in on, flower beds, hay bales, a pond and clouds. About 1,100 scenery parts, no errors.
- [x] ✅ **Cleaning speed:** each hit cleans every mud patch within the hose's spray radius that faces you. A Pig took 3.3 s in total, 2.3 s of it spraying.
- [x] ✅ **Cash pads:** the counter reads `$21` with a green glow, and a "+$3" floats up each second.
- [x] ✅ **Hoses:** each tier swaps the model in your hand: green hose, blue with brass rings, yellow pressure washer, purple foam cannon, red fire-hose rig with a tank on the back.
- [x] ✅ **Rarity looks:** each tier's nameplate colour is correct. Zoo God glows with a halo and has a rainbow label; Secret is black with a white outline.

Check by eye (live motion doesn't come across in screenshots):

- [ ] **Patch pops:** each patch swells and pops with a mud and sparkle burst, and the chime rises in pitch toward 100%.
- [ ] **Cash pads in motion:** the counter bobs, counts up with a bounce every second, and shows "COLLECTED!" with a big burst when you step on it.
- [ ] **Wash card:** springs in for each new animal. A shine sweeps along the clean bar, the bar's border pulses, the % pops as it rises, and it ends on "SQUEAKY CLEAN!" in green.
- [ ] **Auras:** Epic twinkles, Legendary glitters, Mythic gives off rising embers, Zoo God shows rainbow sparkles, and Secret has dark smoke with stars.
- [ ] **Washing feel:** it should feel close to instant. Tune with `GameConfig.BaseWashSeconds` and each tier's `ToolConfig.SprayRadius`.
- [ ] **Pen life** (`src/client/Features/PenLife.luau`): pen animals wander, swing their legs as they walk, look around, graze, wag, hop, shake off droplets and sometimes nap with a "z z Z". Nobody pokes through a fence; animals too long to turn round only shuffle forward and back. Walk up to a pen and its animal sometimes turns to you. Check a Giraffe/Elephant (neck and trunk move with the head) and a penguin-style upright animal (no head bob, turns instead).
- [ ] **Delivery truck:** red cab with grille, round headlights, windows, mirrors and door paw prints; ANIMAL DELIVERY on the roof sign and both bed sides; the animal rides on straw between stake rails. Wheels spin and the stack puffs while it drives, it nods on the springs when it stops, and the roof beacon flashes while it waits.
- [ ] **Audio pass** (licensed Roblox audio, ids in `GameConfig.Sounds`, `GameConfig.Music` and `src/shared/AnimalSounds.luau`; audition each and swap any that sound wrong):
  - Robux shop buttons give a soft wooden tap, and a purchase a gentle chime (no more electronic ping).
  - Collecting a pen pad plays a cash-register ca-ching.
  - Lo-fi music plays quietly from the start, fades in, and moves to a different track when one ends.
  - Aiming the hose at an animal it is too weak for plays an "eh-ehhh" buzzer, at most every 1.4 s while held, and not when aiming elsewhere.
  - A washed animal makes its call with its chat bubble; pen animals near the camera call out now and then (one at a time). Chicken, Duck, Rabbit, Giraffe and Panda have no call yet.
- [ ] **Pens:** any animal can go in any pen (no "Needs a … pen" prompt). An animal stays one size everywhere: wash, cache, carried overhead and pen (a giant in a small stall pokes past the fence). A pad stops filling at its cap and reads "$1K FULL" in orange: stalls $1K, medium stalls and medium pastures $10K, giant barns and large pastures $100K, gargantuan yards $1M (`GameConfig.PenCashCap`).
- [ ] **Legendary+ walk-ins** (force one with the dev tools): a beam drops onto the animal, rings race out, sparkles burst, the model flashes and a tier stamp pops over it, with a whoosh, boom and rising chord. The owner also gets the screen stamp ("A Golden Lion is walking in!"), a colour flash and a camera shake. Each tier is bigger than the last; Secret dims the screen and strikes lightning first. A soft pillar of light stays over it until it leaves the wash. Washing one adds tier-coloured shockwaves, a sparkle fountain and the fanfare to the usual celebration.

## Feature systems

Each feature's Studio checklist is in its doc: [models](docs/features/models.md), [tension](docs/features/tension.md), [live ops](docs/features/liveops.md) and [monetization](docs/features/monetization.md).

Verified in a merged Studio playtest:

- [x] ✅ All features start with no script errors, and the onboarding analytics events fire.
- [x] ✅ **Tension:** the dev shake brought mud back (69% → 57% clean), flung the nearby player, showed the mud splat overlay, and the patience bar drained.
- [x] ✅ **Mud Storm:** the dev toggle shows the banner countdown and murky lighting, and lighting goes back to normal afterwards.
- [x] ✅ **Studio test-mode purchases:**
  - Super Soap and 2x Speed both show timers.
  - The cash pack paid out.
  - VIP shows its overhead tag.
  - The Limited Axolotl appeared in the cache and stock dropped from 1000 to 999.
- [x] ✅ **Leaderstats:** Stars, Cash and Income show in the player list. The plaza leaderboard board and the stars on the bay sign show.
- [x] ✅ **Model audit:** after shrinking Cow and Hippo, only T-Rex is over, by 0.02 studs (11.52 vs 11.5); pens are 12 deep.

## Report back

For each failing box, note what happened. Also note:

- the wash time
- whether the spray beam angle feels right (it comes from the hand toward the cursor)
- how the mud fade looks
