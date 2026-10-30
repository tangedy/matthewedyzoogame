-- Pops the 2x Cash Forever early-access offer right after the player washes their
-- first Legendary (or rarer) animal, when a doubled payout feels best. Once per player, ever:
-- the flag lives in data.Extra.CashPassOffered. Owners of the pass never see it. The client
-- (MonetizationController) draws the pop-up; buying goes through MonetizationBuy as usual.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local MonetizationState = require(script.Parent.MonetizationState)
local Services = script.Parent.Parent.Services
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

local CashPassOffer = {}

local MIN_ORDER = RarityConfig.ByKey.Legendary.Order
local DELAY = 2.5 -- seconds; the payout and fanfare land first

function CashPassOffer.init()
	local remote = Remotes.event("CashPassOffer") -- () server -> client

	Hooks.on("WashCompleted", function(player: Player, info: Hooks.WashInfo)
		local animal = AnimalConfig.Animals[info.Species]
		local rarity = animal and RarityConfig.ByKey[animal.Rarity]
		if not rarity or rarity.Order < MIN_ORDER then
			return
		end
		local data = PlayerDataService.get(player)
		if not data or data.Extra.CashPassOffered == true then
			return
		end
		data.Extra.CashPassOffered = true
		PlayerDataService.markDirty(player)
		if MonetizationState.ownsPass(player, "DoubleCash") then
			return
		end
		task.delay(DELAY, function()
			if player.Parent and not MonetizationState.ownsPass(player, "DoubleCash") then
				remote:FireClient(player)
			end
		end)
	end)
end

return CashPassOffer
