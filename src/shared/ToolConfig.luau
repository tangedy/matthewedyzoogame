-- Hose upgrade tiers. CleaningPower is dirt units removed per second of accepted spraying;
-- SprayRadius is how wide an area each hit cleans. Each tier also unlocks rarer animals
-- (AnimalConfig.RequiredToolTier) and has its own model in the player's hand. Prices are cash.

export type ToolTier = {
	Tier: number,
	Name: string,
	CleaningPower: number,
	Range: number,
	SprayRadius: number,
	Price: number,
}

local ToolConfig: { ToolTier } = {
	{ Tier = 1, Name = "Basic Hose", CleaningPower = 0.6, Range = 22, SprayRadius = 2.5, Price = 0 },
	-- A cheap first step: affordable after the first wash or two (players start with $90).
	{ Tier = 2, Name = "Spray Hose", CleaningPower = 0.72, Range = 22, SprayRadius = 2.7, Price = 100 },
	{ Tier = 3, Name = "Strong Hose", CleaningPower = 0.9, Range = 22, SprayRadius = 2.9, Price = 1000 },
	{ Tier = 4, Name = "Power Washer", CleaningPower = 1.4, Range = 24, SprayRadius = 3.3, Price = 10000 },
	{ Tier = 5, Name = "Foam Cannon", CleaningPower = 2.2, Range = 28, SprayRadius = 3.8, Price = 100000 },
	-- Cash only. There is no game pass that skips to this hose.
	{ Tier = 6, Name = "Fire-Hose Rig", CleaningPower = 3.5, Range = 32, SprayRadius = 4.5, Price = 1000000 },
}

return ToolConfig
