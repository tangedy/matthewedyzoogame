-- Coin transactions and tool tier. Phase 1 keeps profiles in memory only; Phase 2 moves
-- loading/saving into PlayerDataService and this module keeps the same API.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

type Profile = {
	Coins: number,
	ToolTier: number,
	LifetimeAnimalsWashed: number,
	TutorialCompleted: boolean,
}

local EconomyService = {}

local profiles: { [Player]: Profile } = {}
local coinsChanged = Remotes.event("CoinsChanged")
local toolTierChanged = Remotes.event("ToolTierChanged")

function EconomyService.load(player: Player)
	profiles[player] = {
		Coins = 0,
		ToolTier = 1,
		LifetimeAnimalsWashed = 0,
		TutorialCompleted = false,
	}
end

function EconomyService.unload(player: Player)
	profiles[player] = nil
end

function EconomyService.getProfile(player: Player): Profile?
	return profiles[player]
end

function EconomyService.getTool(player: Player): ToolConfig.ToolTier?
	local profile = profiles[player]
	return profile and ToolConfig[profile.ToolTier]
end

-- The only way coins enter the game in Phase 1. Amount comes from server config.
function EconomyService.awardWash(player: Player, amount: number): boolean
	local profile = profiles[player]
	if not profile or typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return false
	end
	profile.Coins += math.floor(amount)
	profile.LifetimeAnimalsWashed += 1
	profile.TutorialCompleted = true
	coinsChanged:FireClient(player, profile.Coins)
	return true
end

function EconomyService.sendTool(player: Player)
	local tool = EconomyService.getTool(player)
	if tool then
		toolTierChanged:FireClient(player, tool.Tier, tool.Name)
	end
end

return EconomyService
