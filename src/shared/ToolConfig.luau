-- Hose upgrade tiers. CleaningPower is dirt units removed per second of accepted spraying.
-- Each tier also unlocks rarer animals (AnimalConfig.RequiredToolTier). Prices are in cash.

export type ToolTier = {
	Tier: number,
	Name: string,
	CleaningPower: number,
	Range: number,
	Price: number,
}

local ToolConfig: { ToolTier } = {
	{ Tier = 1, Name = "Basic Hose", CleaningPower = 0.6, Range = 22, Price = 0 },
	{ Tier = 2, Name = "Strong Hose", CleaningPower = 0.9, Range = 22, Price = 1000 },
	{ Tier = 3, Name = "Power Washer", CleaningPower = 1.4, Range = 24, Price = 10000 },
	{ Tier = 4, Name = "Foam Cannon", CleaningPower = 2.2, Range = 28, Price = 100000 },
	{ Tier = 5, Name = "Fire-Hose Rig", CleaningPower = 3.5, Range = 32, Price = 1000000 },
}

return ToolConfig
