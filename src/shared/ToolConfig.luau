-- Hose upgrade tiers. CleaningPower is dirt units removed per second of accepted spraying.
-- Phase 1 only uses tier 1; prices and the shop arrive in Phase 2.

export type ToolTier = {
	Tier: number,
	Name: string,
	CleaningPower: number,
	Range: number,
	Price: number,
}

local ToolConfig: { ToolTier } = {
	{ Tier = 1, Name = "Basic Hose", CleaningPower = 0.6, Range = 22, Price = 0 },
	{ Tier = 2, Name = "Strong Hose", CleaningPower = 0.9, Range = 22, Price = 150 },
	{ Tier = 3, Name = "Power Washer", CleaningPower = 1.4, Range = 24, Price = 600 },
}

return ToolConfig
