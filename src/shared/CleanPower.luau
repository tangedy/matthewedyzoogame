-- Whether a hose's cleaning power is enough for a rarity. Shared so the server (which
-- actually blocks the spray) and the client prompt agree.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
