# Studio test checklist

Milestones 1 and 2 passed in Studio. Claude ran parts of Milestones 3 and 4 in a solo Studio playtest through Studio MCP; those checks are marked ✅ below. The rest still need you: anything that needs saving (a published place), two real players, or a phone.

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

- [ ] A large SPRAY button sits above the jump button and doesn't overlap the thumbstick.
- [ ] The reticle sits above your character (40% down the screen), not on top of it.
- [ ] **Aim assist:** with the reticle near the animal (not exactly on a patch), holding SPRAY snaps the reticle to the nearest reachable mud patch and cleans it.
- [ ] Aim assist never snaps to a patch hidden behind the body or out of range.
- [ ] A full wash is comfortable with thumbs only. Opening the shop with the tap prompt works.
- [ ] The mud fade looks clear at phone size. This is the doc's #1 technical risk, so note how it feels.

## Report back

For each failing box, note what happened. Also note:

- the wash time
- whether the spray beam angle feels right (it comes from the hand toward the cursor)
- how the mud fade looks
