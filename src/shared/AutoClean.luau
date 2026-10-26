-- How long the auto-wash pad takes on an animal (GameConfig.AutoClean). Shared so the server
-- (which runs the wash) and anything that shows the time agree.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local GearLadder = require(ReplicatedStorage.Shared.GearLadder)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)

local AutoClean = {}

-- Seconds for one animal of this rarity with the gear at (tier, level).
function AutoClean.seconds(rarityKey: string, tier: number, level: number?): number
	local config = GameConfig.AutoClean
	local rarity = RarityConfig.ByKey[rarityKey]
	local order = if rarity then rarity.Order else 1
	local base = config.BaseSeconds * config.RarityFactor ^ (order - 1)
	return base * (1 - config.UpgradeDiscount) ^ GearLadder.upgradesOwned(tier, level)
end

return AutoClean
