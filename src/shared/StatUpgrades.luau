-- Repeatable cash upgrades bought in the Gear Shop beside the hose ladder: walk speed and pen
-- pad capacity. A player's place on each is a saved level (0 = none bought). Shared so the
-- server (which charges and applies them) and the shop agree.
--
-- Prices sit between the hose (ToolConfig) and barn (GameConfig.Zoo.Expansions) prices, so a
-- player always has something affordable to aim for between the big buys:
--   Hose 500 · Hose 1K · Speed I 2.5K · Pens I 5K · Hose 10K · Speed II 14K · Hose 18K ·
--   Barn 25K · Pens II 40K · Hose 60K · Speed III 80K · Barn 100K · Hose 140K · Pens III 200K ·
--   Hose 280K · Speed IV 400K · Barn 500K · Hose 750K · Pens IV 1.2M · Hose 1.8M · Barn 2.5M ·
--   Speed V 3M · Hose 3.5M · Pens V 6M · Barn 10M · Pens VI 20M

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

export type Kind = "Speed" | "PenCap"

export type Track = {
	Kind: Kind,
	Name: string, -- shop row title
	Field: string, -- SavedData field holding the level
	PerLevel: number, -- each level adds this much of the base stat
	Prices: { number }, -- Prices[n] buys level n
}

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII" }

local StatUpgrades = {}

StatUpgrades.Tracks = {
	Speed = {
		Kind = "Speed",
		Name = "Run Speed",
		Field = "SpeedLevel",
		PerLevel = 0.1, -- +10% walk speed per level, 1.5x at max
		Prices = { 2500, 14000, 80000, 400000, 3000000 },
	},
	PenCap = {
		Kind = "PenCap",
		Name = "Pen Storage",
		Field = "PenCapLevel",
		PerLevel = 0.25, -- +0.25x every pen's cash cap per level, 2.5x at max
		Prices = { 5000, 40000, 200000, 1200000, 6000000, 20000000 },
	},
} :: { [Kind]: Track }

StatUpgrades.Order = { "Speed", "PenCap" } :: { Kind }

function StatUpgrades.maxLevel(kind: Kind): number
	return #StatUpgrades.Tracks[kind].Prices
end

-- Clamps a saved or sent level into range.
function StatUpgrades.clamp(kind: Kind, level: any): number
	local value = if typeof(level) == "number" and level == level then math.floor(level) else 0
	return math.clamp(value, 0, StatUpgrades.maxLevel(kind))
end

-- Price of the level after `level`, or nil once maxed.
function StatUpgrades.nextPrice(kind: Kind, level: number): number?
	return StatUpgrades.Tracks[kind].Prices[level + 1]
end

function StatUpgrades.multiplier(kind: Kind, level: number): number
	return 1 + StatUpgrades.Tracks[kind].PerLevel * StatUpgrades.clamp(kind, level)
end

-- Character walk speed at this Speed level (before any Robux speed boost).
function StatUpgrades.walkSpeed(level: number): number
	return GameConfig.WalkSpeed * StatUpgrades.multiplier("Speed", level)
end

-- A pen's cash cap with this PenCap level applied to its class's base cap.
function StatUpgrades.penCap(baseCap: number, level: number): number
	return math.floor(baseCap * StatUpgrades.multiplier("PenCap", level))
end

-- "Run Speed III" style label for a level (level 0 reads as the base).
function StatUpgrades.label(kind: Kind, level: number): string
	local name = StatUpgrades.Tracks[kind].Name
	return if level <= 0 then name else `{name} {ROMAN[level] or level}`
end

return StatUpgrades
