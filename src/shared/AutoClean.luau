-- How long the auto-wash pad takes on an animal (GameConfig.AutoClean), sped up by the
-- player's Auto-Wash Speed level (StatUpgrades). Shared so the server (which runs the wash)
-- and anything that shows the time agree.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local StatUpgrades = require(ReplicatedStorage.Shared.StatUpgrades)

local AutoClean = {}

-- Seconds for one animal of this rarity at this Auto-Wash Speed level.
function AutoClean.seconds(rarityKey: string, autoWashLevel: number?): number
	local config = GameConfig.AutoClean
	local rarity = RarityConfig.ByKey[rarityKey]
	local order = if rarity then rarity.Order else 1
	local base = config.BaseSeconds * config.RarityFactor ^ (order - 1)
	return base / StatUpgrades.multiplier("AutoWash", autoWashLevel or 0)
end

return AutoClean
