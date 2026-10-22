# Wash the Zoo: roadmap after the implementation doc

The implementation design doc (Milestones 1–5) is built: a washing-station loop with spatial cleaning, hose tiers, saving, multiplayer bays and mobile controls.

This plan takes the game toward the **concept doc's MVP**: one Farm zone, about 10 animals and 3 tools, playtested with paid testers before building more zones.

## Decisions made (2026-10-21)

| Question | Decision | What it changes from the concept doc |
| --- | --- | --- |
| What happens after a wash? | **The animal moves into your zoo.** It is kept in an enclosure and logged in the index. | Matches the concept. Replaces wash-and-leave. |
| How do animals arrive? | **Continuous walk-ins** with a rarity roll on each one. | No 5-minute truck. Restock FOMO becomes a rare walk-in reveal. Truck products (Instant Truck, Golden Truck) are replaced, see Phase F. |
| Next target | **Concept MVP first** | Farm only. Savanna, Arctic, Jungle, visitors and events wait until after the MVP playtests. |

## Decisions made (2026-10-22)

The game is now modelled on Steal a Brainrot.

| Question | Decision |
| --- | --- |
| What happens after a wash? | **The animal goes to a cache.** You carry it to a pen to place it, or swap it with an animal already there (the old one is sold). The zoo-full popup is gone. |
| How does the zoo earn? | **Cash per second** from each penned animal, collected by stepping on its pad. |
| How do rarities work? | **Each species has a fixed tier** (Common, Rare, Epic, Legendary, Mythic, Zoo God, Secret), and each walk-in **rolls a mutation** (Normal, Gold, Diamond, Rainbow). This replaces the per-walk-in rarity roll from 2026-10-21. |
| What about the lanes? | **Bays are built only while a player owns one**, so empty lanes never show. |
| How many animals? | **22 species** across all 7 tiers. Five hose tiers gate the rarer ones. |

## MVP phases

Each phase ends in something playable in Studio. Server authority, config-driven values and the saving rules from the implementation doc still apply.

### Phase A: Rarity and the zoo (the core change) ✅ built

Built as planned, except that new discoveries pay a double reward (`GameConfig.Zoo.DiscoveryBonusMultiplier`). When the zoo is full, the player gets 10 seconds to swap the new animal for their cheapest one.

- **Rarity roll per walk-in:** Common, Rare, Epic, Legendary or Mythic, from a weighted table in `AnimalConfig`.
  - Rare and above get a reveal as they walk in: a glow, a coloured nameplate, a sound and a server announcement for Legendary and up.
  - Rarity scales the payout and the wash time.
- **Zoo enclosures** next to each bay. A finished animal walks from the wash position into a free pen instead of out of the exit.
- **Full zoo:** when the zoo is full, the player can **release** an animal for coins or **expand** the zoo (coins). The first time it fills, a contextual tutorial explains expanding, as the concept says.
- **Index:** a UI panel listing every species × rarity, with undiscovered ones shown as silhouettes. The first discovery of each gives a bonus. "Index % complete" shows on the HUD.
- **Saving:** a profile schema v2 (owned animals, zoo size, index) with a migration from v1. Owned animals respawn in their pens on join.
- **Flex:** zoos are visible from spawn with no walls, as the concept says, so other players can see your rares.

### Phase B: Farm roster (~10 animals) ✅ built (placeholders)

The 10 species and the template loader are in. Rarity variants are the generic rarity looks (gold Legendary, rainbow Mythic). Real art and Farm zone dressing are still outside work.

- **Roster:** extend `AnimalBuilder` placeholders to about 10 Farm animals: pig, sheep, cow, goat, chicken, duck, horse, donkey, rabbit and llama.
  - A few rarity variants per species, such as a golden or rainbow pig.
  - Some animals require a higher tool tier (`RequiredToolTier` already exists).
- **Art pipeline:** a modeler builds ~10 animals in one locked style, as the concept's production plan says.
  - Models follow the existing template contract: `Root`, `Body`/`Head`, a `DirtPatches` folder, facing -Z and pivoted on the ground.
  - I'll add a loader that uses a model from `ServerStorage.AnimalTemplates` when one exists and falls back to the block placeholder otherwise.
- **Farm zone dressing:** fences, hay, a barn backdrop. This is builder work.

### Phase C: Tension (moods and patience)

- **Patience meter** per animal. If it runs out, the animal **shakes**: mud splatters back onto cleaned patches and onto nearby players. Progress is lost, but no coins are.
- **Moods per species:** calm animals stand still, ticklish ones squirm (they shift position), grumpy ones charge. Each species needs a different approach.
- **Mythic timer:** a Mythic wanders off if you don't finish in time.
- **Doc conflict:** the implementation doc deferred animals escaping and undoing progress. The concept makes them the core tension, so this phase adds them, behind config flags so they can be tuned or turned off.

### Phase D: Co-op

- Friends (and invited players) can spray your animal. Big animals clean faster with more people, and co-op washes pay a small bonus.
- The ownership checks become "owner or a member of the owner's party". Payout still goes to the bay owner once; helpers get a smaller helper reward.

### Phase E: Retention hooks and analytics for the playtest

- **Daily Dirty Animal:** one guaranteed Rare, extra muddy, each day.
- **Server leaderboard:** index % or zoo value.
- **Funnel analytics** (AnalyticsService) for every step the concept lists: join → first scrub → first animal clean → placed in zoo → second animal → first upgrade. Sliced by device.
- **First-session milestone checks** against the concept's table:
  - minute 1: first clean and first upgrade
  - minute 5: first Rare
  - minute 20: first Epic, index about 25%

### Phase F: Monetization wired before launch (no pay-to-win, nothing in the first 90 s)

| Product | Type | Notes |
| --- | --- | --- |
| Super Soap | Consumable | 2× clean speed for 10 min. Offered when an animal is over 50% dirty. |
| Calm Treat | Consumable | Freezes the patience meter. Offered under 20% patience. Needs Phase C. |
| Lucky Soap | Consumable | Better rarity odds for the next few walk-ins. **Replaces Golden Truck.** |
| Zoo Expansion pack | Consumable | Extra pens. |
| Starter / Pro / OP packs | Bundles | Three sizes for price anchoring. Priced so no pack skips a zone. |
| VIP Keeper | Game pass | Cosmetic uniform, chat tag, small payout bonus. |
| Limited animal | Limited | e.g. Rainbow Axolotl, 1,000 stock, never restocked. Shown in the zoo. |

- **Economy guardrail:** no auto-clean product.
- **Coin fallback:** after the third failed purchase, the coin shop opens automatically, at most 3 times per session.

### Phase G: MVP playtest

- 2–3 paid testers grind about 3 hours and log the time they reach each milestone.
- Test the dirt effect on low-end phones.
- Tune the economy from the results before building more zones.

## After the MVP (full launch scope from the concept doc)

- **Zones:** Savanna, Arctic, Jungle and a Fossil wing (T-rex, brontosaurus). Each is gated by tool tier, not just coins. About 40 animals in total.
- **Tools:** extend to 7 tiers, up to a fire-hose rig. The concept starts with a sponge; we kept the hose as tier 1, so the sponge could become a cosmetic or a small-animal tool.
- **Visitors and tips:** a tycoon layer with offline earnings (2× Offline Tips consumable).
- **Mutations:** glitter, frozen and lava-mud variants.
- **Zoo star rating** (1–5), which unlocks zones and mutations.
- **Weekly Mud Storm event:** every animal spawns filthy and rare spawns are boosted.
- **Live-ops cadence** from the concept: patch daily, ship one update every Saturday, each tied to one stat it should improve.
- **Possible second innovation:** a PvP "Clean-off" race between zoos.

## Open questions

- Do players pick which walk-in to wash, or wash whatever arrives? (Default: whatever arrives, so washing stays the focus.)
- Does every washed animal go into the zoo, or can the player choose "keep" or "sell" at completion? (Default: keep if there's a free pen; otherwise prompt to release or expand.)
- What does a zoo animal earn over time? Nothing until visitors are added (post-MVP), or a small passive income now?
