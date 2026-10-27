-- Every gear purchase in shop order: each hose (ToolConfig) followed by its sub-tier
-- Upgrades. A player's place on it is (ToolTier, ToolUpgrade), where ToolUpgrade 0 is the hose
-- itself. Shared so the server (which pays and cleans with these stats) and the shop agree.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)

export type Step = {
	Tier: number,
	Level: number, -- 0 for the hose itself, then 1.. for its Upgrades
	Name: string, -- the hose's name (backpack tool, gates)
	Label: string, -- shop name, e.g. "Foam Cannon II (Dual-Tank)"
	Price: number,
	CleaningPower: number, -- rarity gate; only the Fire Hose's Titan Spec raises it
	Range: number,
	SprayRadius: number,
	Speed: number, -- wash speed relative to the sponge
	WashSpeed: number, -- multiplier on dirt removed per hit, on top of CleaningPower
	WashCashBonus: number,
	WashRewardSeconds: number,
	SnapThreshold: number,
	Perk: string?,
}

local ROMAN = { "I", "II", "III", "IV", "V" }

local GearLadder = {}

local steps: { Step } = {}
local byTier: { [number]: { [number]: Step } } = {}

local sponge = ToolConfig[1].CleaningPower
local carried = {
	WashCashBonus = 0,
	WashRewardSeconds = GameConfig.WashRewardSeconds,
	SnapThreshold = GameConfig.PatchCleanThreshold,
}

local function add(step: Step)
	step.WashSpeed = step.Speed * sponge / step.CleaningPower
	table.insert(steps, step)
	byTier[step.Tier] = byTier[step.Tier] or {}
	byTier[step.Tier][step.Level] = step
end

for _, tool in ToolConfig do
	local upgrades = tool.Upgrades or {}
	local hasSubTiers = #upgrades > 0
	-- A new hose starts with the base snap; the cash perks carry on.
	carried.SnapThreshold = GameConfig.PatchCleanThreshold
	local base: Step = {
		Tier = tool.Tier,
		Level = 0,
		Name = tool.Name,
		Label = if hasSubTiers and tool.SubName then `{tool.Name} I ({tool.SubName})` else tool.Name,
		Price = tool.Price,
		CleaningPower = tool.CleaningPower,
		Range = tool.Range,
		SprayRadius = tool.SprayRadius,
		Speed = tool.Speed or tool.CleaningPower / sponge,
		WashSpeed = 1,
		WashCashBonus = carried.WashCashBonus,
		WashRewardSeconds = carried.WashRewardSeconds,
		SnapThreshold = carried.SnapThreshold,
		Perk = tool.Perk,
	}
	add(base)
	local previous = base
	for level, upgrade in upgrades do
		carried.WashCashBonus = upgrade.WashCashBonus or carried.WashCashBonus
		carried.WashRewardSeconds = upgrade.WashRewardSeconds or carried.WashRewardSeconds
		carried.SnapThreshold = upgrade.SnapThreshold or carried.SnapThreshold
		local step: Step = {
			Tier = tool.Tier,
			Level = level,
			Name = tool.Name,
			Label = `{tool.Name} {ROMAN[level + 1] or level + 1} ({upgrade.Name})`,
			Price = upgrade.Price,
			CleaningPower = upgrade.CleaningPower or previous.CleaningPower,
			Range = upgrade.Range or previous.Range,
			SprayRadius = upgrade.SprayRadius or previous.SprayRadius,
			Speed = upgrade.Speed,
			WashSpeed = 1,
			WashCashBonus = carried.WashCashBonus,
			WashRewardSeconds = carried.WashRewardSeconds,
			SnapThreshold = carried.SnapThreshold,
			Perk = upgrade.Perk,
		}
		add(step)
		previous = step
	end
end

GearLadder.Steps = steps

-- The player's current step. Unknown tiers fall back to the sponge; a level past the hose's
-- last upgrade is clamped to it.
function GearLadder.get(tier: number, level: number?): Step
	local levels = byTier[tier] or byTier[1]
	local wanted = math.max(0, math.floor(level or 0))
	while wanted > 0 and not levels[wanted] do
		wanted -= 1
	end
	return levels[wanted]
end

-- Gear purchases made to reach (tier, level): 0 for the starting sponge.
function GearLadder.upgradesOwned(tier: number, level: number?): number
	local current = GearLadder.get(tier, level)
	return (table.find(steps, current) or 1) - 1
end

-- Cleaning power (the rarity gate) at (tier, level).
function GearLadder.power(tier: number, level: number?): number
	return GearLadder.get(tier, level).CleaningPower
end

-- Number of sub-tier upgrades a hose has (0 for the first three).
function GearLadder.upgradeCount(tier: number): number
	local tool = ToolConfig[tier]
	return if tool and tool.Upgrades then #tool.Upgrades else 0
end

-- The next purchase after (tier, level): the hose's next sub-tier, else the next hose.
-- nil once the last step is owned.
function GearLadder.next(tier: number, level: number?): Step?
	local current = GearLadder.get(tier, level)
	local levels = byTier[current.Tier]
	return levels[current.Level + 1] or (byTier[current.Tier + 1] and byTier[current.Tier + 1][0])
end

return GearLadder
