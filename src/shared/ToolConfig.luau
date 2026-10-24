-- Cleaning tool tiers. CleaningPower is dirt units removed per second of accepted spraying;
-- SprayRadius is how wide an area each hit cleans. Each tier also unlocks rarer animals
-- (RarityConfig.RequiredCleaningPower), sits in the player's backpack as its own tool, and
-- changes the gear parked at the wash station (StationProps). Prices are cash.
-- Range grows a lot over the first three tiers: the sponge and brush are hand tools, so the
-- player scrubs up close, and the garden hose is the first one that sprays from a distance.
--
-- From the Power Washer on, each hose also has cash sub-tier Upgrades bought in order before
-- the next hose (GearLadder flattens them into one shop ladder). The hose itself is sub-tier I.
-- Speed is wash speed relative to the sponge; sub-tiers raise it without touching
-- CleaningPower, so they never unlock the next rarity. Upgrade fields left out carry over
-- from the step before (WashCashBonus and WashRewardSeconds also carry into the next hose).

export type ToolUpgrade = {
	Name: string,
	Price: number,
	Speed: number,
	Range: number?,
	SprayRadius: number?,
	WashCashBonus: number?, -- extra fraction of wash cash (0.1 = +10%)
	WashRewardSeconds: number?, -- seconds of the animal's income a wash pays (GameConfig default 15)
	SnapThreshold: number?, -- an owner's patch snaps clean below this fraction (PatchCleanThreshold)
	Perk: string?, -- one line for the shop
}

export type ToolTier = {
	Tier: number,
	Name: string,
	CleaningPower: number,
	Range: number,
	SprayRadius: number,
	Price: number,
	Speed: number?, -- defaults to CleaningPower relative to the sponge
	SubName: string?, -- sub-tier I's name, for hoses with Upgrades
	Perk: string?,
	Upgrades: { ToolUpgrade }?,
}

local ToolConfig: { ToolTier } = {
	{ Tier = 1, Name = "Sponge", CleaningPower = 0.6, Range = 9, SprayRadius = 2.5, Price = 0 },
	-- The first goal: a few washes in (players start with $0).
	{ Tier = 2, Name = "Scrub Brush", CleaningPower = 0.72, Range = 11, SprayRadius = 2.8, Price = 500 },
	{ Tier = 3, Name = "Garden Hose", CleaningPower = 0.9, Range = 22, SprayRadius = 2.9, Price = 1000 },
	{
		Tier = 4,
		Name = "Power Washer",
		CleaningPower = 1.4,
		Range = 24,
		SprayRadius = 3.3,
		Price = 10000,
		Speed = 2.5,
		SubName = "Base Nozzle",
		Upgrades = {
			{
				Name = "Turbo Nozzle",
				Price = 18000,
				Speed = 3.5,
				SprayRadius = 3.7,
				WashCashBonus = 0.1,
				Perk = "Wider cone. +10% wash cash",
			},
		},
	},
	{
		Tier = 5,
		Name = "Foam Cannon",
		CleaningPower = 2.2,
		Range = 28,
		SprayRadius = 3.8,
		Price = 60000,
		Speed = 5,
		SubName = "Soaker",
		Perk = "Foam softens grime faster",
		Upgrades = {
			{ Name = "Dual-Tank", Price = 140000, Speed = 7, WashCashBonus = 0.15, Perk = "+15% wash cash" },
			{
				Name = "Industrial",
				Price = 280000,
				Speed = 9.5,
				SprayRadius = 4.3,
				WashRewardSeconds = 25,
				Perk = "Washes pay 25s of the animal's income (was 15s)",
			},
		},
	},
	-- Cash only. There is no game pass that skips to this hose.
	{
		Tier = 6,
		Name = "Fire Hose",
		CleaningPower = 3.5,
		Range = 32,
		SprayRadius = 4.5,
		Price = 750000,
		Speed = 14,
		SubName = "Standard Engine",
		Perk = "Long beam",
		Upgrades = {
			{
				Name = "Pneumatic Booster",
				Price = 1800000,
				Speed = 20,
				SnapThreshold = 0.3,
				Perk = "Hardened crust pops off instantly",
			},
			{
				Name = "Titan Spec",
				Price = 3500000,
				Speed = 28,
				Range = 38,
				SprayRadius = 5.2,
				WashRewardSeconds = 40,
				Perk = "Mega beam. Washes pay 40s of the animal's income",
			},
		},
	},
}

return ToolConfig
