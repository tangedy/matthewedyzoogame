# Studio test checklist

Milestones 1 and 2 have passed in Studio. Milestone 3 is new and untested. It passes `selene` and the luau-lsp type check, and `rojo build` succeeds, but it hasn't been run in Roblox.

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
- [ ] Buying with fewer than 150 coins shows "Not enough coins. You need N more." and nothing changes.
- [ ] Buying with enough coins takes exactly 150. Coins update, the HUD shows "Strong Hose (Tier 2)", the panel moves on to Power Washer (+56%, 600), and the spray beam gets thicker.
- [ ] Clicking Buy quickly several times charges only once.
- [ ] Washing is noticeably faster after upgrading (server-side power).
- [ ] At Tier 3 the panel says "Your hose is fully upgraded!" and has no Buy button.
- [ ] Walking more than about 14 studs from the counter closes the panel.
- [ ] **Rejoin:** stop, then play again. Coins and tool tier come back, and the first-wash instruction doesn't show again.
- [ ] **Failed load can't overwrite data:** turn API Services **off**, then play. The red banner appears. Earn some coins, stop, turn API Services back **on**, then play again. Your earlier saved coins come back, not 0 and not the temporary session's coins.
- [ ] Pacing: the first upgrade is affordable after a few animals (about 5 washes, 3–4 minutes).

## Early mobile check (pulled forward from Milestone 4)

Use Studio's **Device emulator** (Test → Device, pick a phone), then a real phone if possible.

- [ ] A large SPRAY button sits above the jump button and doesn't overlap the thumbstick.
- [ ] Holding SPRAY sprays toward the center reticle. Rotating the camera with the other thumb aims.
- [ ] A full wash is comfortable with thumbs only.
- [ ] The mud fade looks clear at phone size. This is the doc's #1 technical risk, so note how it feels.

## Quick multiplayer smoke test (optional now, required in Milestone 4)

Use Test → Clients and Servers → 2 players.

- [ ] Each player gets their own bay and animal.
- [ ] Player 2 spraying player 1's animal does nothing.
- [ ] When a player leaves, their animal is removed and their sign goes back to "Wash Bay N".

## Report back

For each failing box, note what happened. Also note:

- the wash time
- whether the spray beam angle feels right (it comes from the hand toward the cursor)
- how the mud fade looks
