-- Tuning for the retention and live-ops systems (src/server/Features/LiveOps): the Daily Dirty
-- Animal, the five-minute rare guarantee, the seven-day check-in, the scheduled Mud Storm,
-- offline earnings, the zoo star rating, leaderstats and the plaza leaderboard, and the
-- analytics funnel. All times are UTC so every server agrees.
-- Rotating variant events (Gold Rush, Rainbow Rush, and the rest) and the hidden gold/rainbow
-- odds are not in this file. Edit src/server/DevParams.json.

export type StormSlot = {
	Hour: number, -- UTC
	Minute: number,
	DurationMinutes: number,
	Weekday: number?, -- 1 = Sunday ... 7 = Saturday; nil = every day
}

export type CheckInReward = {
	Kind: string,
	Label: string,
	Detail: string,
	Amount: number?,
	Species: string?,
	Rarity: string?,
	Mutation: string?,
	Multiplier: number?,
	Text: string?,
}

local LiveOpsConfig = {
	Daily = {
		MinRarity = "Rare", -- the daily animal is this tier or better (and allowed by the hose)
		WashTimeMultiplier = 1.5, -- extra muddy
		RewardMultiplier = 2, -- its wash pays this much more
		-- Species are picked by SpawnWeight ^ WeightExponent: below 1 flattens the odds so
		-- the daily animal is more often something exciting.
		WeightExponent = 0.5,
	},

	-- Every EverySeconds of play time (saved across sessions), the next walk-in is a species one
	-- rarity above the rarest the player's hose can wash.
	RareGuarantee = {
		EverySeconds = 300,
	},

	-- New players, once: a Secret Kaiju stomps down the main road past their farm, then every
	-- rarity above Common walks in more often for BoostMinutes. It happens at ShowAtSeconds of
	-- play once the opening washes are done, and at LatestSeconds either way, so always inside
	-- the first five minutes. Profiles already past LatestSeconds never see it.
	NewPlayer = {
		ShowAtSeconds = 240,
		LatestSeconds = 290,
		BoostMinutes = 10,
		SpawnWeightMultiplier = 2.5, -- every rarity above Common
		Species = "Kaiju",
		RoadSpan = 200, -- studs the Kaiju walks either side of the player's farm
		WalkSeconds = 32,
	},

	-- Seven-day check-in: one claim every CooldownHours, in order. Missing a day does not reset the
	-- chart; after day 7 it starts over at day 1 (permanent rewards are kept, never stacked).
	-- Kind: "Cash" (Amount) | "Animal" (Species or Rarity, Mutation) | "EarningsBuff" (Multiplier)
	-- | "Title" (Text). Label / Detail are what the chart shows.
	CheckIn = {
		CooldownHours = 23, -- after a claim, the next day's reward unlocks this many hours later
		Rewards = {
			{ Kind = "Cash", Amount = 1000, Label = "$1,000", Detail = "Cash" },
			{ Kind = "Animal", Species = "Horse", Mutation = "Rainbow", Label = "Rainbow Horse", Detail = "Animal" },
			{ Kind = "Cash", Amount = 100000, Label = "$100,000", Detail = "Cash" },
			{ Kind = "EarningsBuff", Multiplier = 1.25, Label = "1.25x Earnings", Detail = "Permanent" },
			{ Kind = "Cash", Amount = 1000000, Label = "$1,000,000", Detail = "Cash" },
			{ Kind = "Title", Text = "PRO WASHER", Label = "PRO WASHER", Detail = "Chat title, permanent" },
			{ Kind = "Animal", Rarity = "Secret", Label = "Random Secret", Detail = "Secret animal" },
		} :: { CheckInReward },
	},

	MudStorm = {
		Slots = {
			{ Weekday = 7, Hour = 18, Minute = 0, DurationMinutes = 15 }, -- weekly: Saturday
			{ Hour = 1, Minute = 0, DurationMinutes = 5 }, -- daily mini-storms
			{ Hour = 17, Minute = 0, DurationMinutes = 5 },
		} :: { StormSlot },
		RareSpawnMultiplier = 3, -- SpawnWeight multiplier for MinBoostedRarity and better
		MinBoostedRarity = "Legendary",
		MutationMultiplier = 3, -- MutationWeight multiplier for every non-Normal mutation
		WashTimeMultiplier = 1.4,
		DevStormMinutes = 5, -- length of a storm started with the developer command
		TeaserSeconds = 3600, -- the client shows "next storm in ..." when one is this close
		CheckInterval = 1, -- seconds between schedule checks
	},

	Offline = {
		-- 6 hours of absence, then it stops. 12 or 24 are the other safe caps; the
		-- server also refuses anything above HardMaxSeconds so a config typo can't pay a week.
		MaxSeconds = 6 * 60 * 60,
		HardMaxSeconds = 24 * 60 * 60,
		MinSeconds = 60, -- shorter absences earn nothing (and show no popup)
		Rate = 0.5, -- fraction of normal income earned while away
		LastSeenInterval = 60, -- seconds between LastSeen refreshes while playing
		-- os.time() and GetServerTimeNow() normally differ by a second or two. A bigger
		-- gap is clock drift, and that gap is not paid out as offline time.
		ClockSkewSeconds = 120,
		EarliestLastSeen = 1577836800, -- 2020-01-01; anything older is a bad save, not a long trip
	},

	Stars = {
		-- Each metric earns a point per threshold reached; the total points pick the stars.
		IncomeThresholds = { 10, 100, 1000, 10000, 100000 }, -- base income per second
		IndexThresholds = { 0.05, 0.15, 0.3, 0.5 }, -- fraction of species x mutations found
		PenThresholds = { 6, 8 }, -- pens unlocked
		StarPoints = { 0, 2, 4, 7, 10 }, -- points needed for 1..5 stars (11 points max)
	},

	Leaderstats = {
		UpdateInterval = 2,
	},

	Board = {
		Position = Vector3.new(0, 0, 0), -- middle of the world: centre of the road, between the plots
		Size = Vector3.new(0.6, 9, 13),
		Height = 3, -- gap under the board
		Rows = 8,
		UpdateInterval = 5,
	},

	Analytics = {
		PollInterval = 5, -- seconds between hose-upgrade / expansion funnel checks
		IncomeFlushInterval = 120, -- pen income is summed per player and logged this often (and on leave)
	},
}

return LiveOpsConfig
