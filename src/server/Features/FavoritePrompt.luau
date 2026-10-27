-- Asks the player to favourite the game right after they wash their first Legendary (or
-- rarer) animal, the high point of an early session. Once per player, ever: the flag lives in
-- data.Extra.FavoritePrompted. The server only decides when; the client shows Roblox's own
-- favourite dialog (AvatarEditorService), which only a LocalScript can open.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Parent.Services
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

local FavoritePrompt = {}

local MIN_ORDER = RarityConfig.ByKey.Legendary.Order
local DELAY = 3 -- seconds; the payout and fanfare land first

function FavoritePrompt.init()
	local remote = Remotes.event("FavoritePrompt") -- () server -> client

	Hooks.on("WashCompleted", function(player: Player, info: Hooks.WashInfo)
		local animal = AnimalConfig.Animals[info.Species]
		local rarity = animal and RarityConfig.ByKey[animal.Rarity]
		if not rarity or rarity.Order < MIN_ORDER then
			return
		end
		local data = PlayerDataService.get(player)
		if not data or data.Extra.FavoritePrompted == true then
			return
		end
		data.Extra.FavoritePrompted = true
		PlayerDataService.markDirty(player)
		task.delay(DELAY, function()
			if player.Parent then
				remote:FireClient(player)
			end
		end)
	end)
end

return FavoritePrompt
