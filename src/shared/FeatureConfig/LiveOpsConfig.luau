-- Tuning for the retention and live-ops systems (src/server/Features/LiveOps): the Daily Dirty
-- Animal, the scheduled Mud Storm, offline earnings, the zoo star rating, leaderstats and the
-- plaza leaderboard, and the analytics funnel. All times are UTC so every server agrees.

export type StormSlot = {
	Hour: number, -- UTC
	Minute: number,
	DurationMinutes: number,
	Weekday: number?, -- 1 = Sunday ... 7 = Saturday; nil = every day
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
		MaxSeconds = 2 * 60 * 60, -- earnings cap
		MinSeconds = 60, -- shorter absences earn nothing (and show no popup)
		Rate = 0.5, -- fraction of normal income earned while away
		LastSeenInterval = 60, -- seconds between LastSeen refreshes while playing
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
		Position = Vector3.new(17, 0, -7), -- behind the plaza fountain, facing the welcome sign
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
