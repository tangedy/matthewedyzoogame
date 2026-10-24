-- Whether a hose's cleaning power is enough for a rarity. Shared so the server (which
-- actually blocks the spray) and the client prompt agree.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)

local CleanPower = {}

function CleanPower.required(rarityKey: string): number
	local rarity = RarityConfig.ByKey[rarityKey]
	return if rarity then rarity.RequiredCleaningPower else math.huge
end

function CleanPower.canClean(power: number, rarityKey: string): boolean
	return typeof(power) == "number" and power + 1e-4 >= CleanPower.required(rarityKey)
end

-- How many rarity steps this animal sits above the cheapest one `power` cannot wash.
-- 0 is that next animal. nil means this hose can already wash it (or the rarity is unknown).
function CleanPower.stepsAbove(power: number, rarityKey: string): number?
	if CleanPower.canClean(power, rarityKey) then
		return nil
	end
	local rarity = RarityConfig.ByKey[rarityKey]
	if not rarity then
		return nil
	end
	for _, entry in RarityConfig.List do
		if not CleanPower.canClean(power, entry.Key) then
			return math.max(0, rarity.Order - entry.Order)
		end
	end
	return nil
end

-- The rarest tier this power can wash (rarities are ordered by required power), or nil.
function CleanPower.maxWashable(power: number): string?
	local best: string? = nil
	for _, entry in RarityConfig.List do
		if CleanPower.canClean(power, entry.Key) then
			best = entry.Key
		end
	end
	return best
end

-- One rarity above the rarest this power can wash, capped at the rarest tier there is.
function CleanPower.rarityAbove(power: number): string
	local best = CleanPower.maxWashable(power)
	local order = if best then RarityConfig.ByKey[best].Order else 0
	local index = math.clamp(order + 1, 1, #RarityConfig.List)
	return RarityConfig.List[index].Key
end

-- The cheapest hose that can wash this rarity, or nil when none of them can.
function CleanPower.hoseName(rarityKey: string): string?
	local need = CleanPower.required(rarityKey)
	for _, tool in ToolConfig do
		if tool.CleaningPower + 1e-4 >= need then
			return tool.Name
		end
	end
	return nil
end

-- What it takes to wash this animal, for its nameplate and the "too dirty" prompt: the
-- cheapest gear that can, plus Super Soap when only soap gets it there or the animal is
-- soap-only. nil for animals the starting sponge can already wash.
function CleanPower.gearNeeded(rarityKey: string, requiresSoap: boolean?): string?
	local need = CleanPower.required(rarityKey)
	local soapMult = MonetizationConfig.SuperSoap.PowerMultiplier
	for _, tool in ToolConfig do
		if tool.CleaningPower + 1e-4 >= need then
			if requiresSoap then
				return `{tool.Name} + Super Soap`
			end
			return if tool.Tier > 1 then tool.Name else nil
		end
	end
	for _, tool in ToolConfig do
		if tool.CleaningPower * soapMult + 1e-4 >= need then
			return `{tool.Name} + Super Soap`
		end
	end
	return nil
end

function CleanPower.format(power: number): string
	local scaled = power * 100
	if math.abs(scaled - math.floor(scaled + 1e-4)) < 0.01 then
		local text = string.format("%.2f", power)
		text = string.gsub(text, "0$", "")
		text = string.gsub(text, "%.0$", "")
		return text
	end
	return string.format("%.2f", power)
end

return CleanPower
