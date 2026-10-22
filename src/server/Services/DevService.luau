-- Studio and place-owner shortcuts. A published client cannot grant coins or skip a wash:
-- the server drops DevCommand unless this session is Studio or the sender owns the place.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CleaningService = require(script.Parent.CleaningService)
local EconomyService = require(script.Parent.EconomyService)

local DevService = {}

local function isDeveloper(player: Player): boolean
	return RunService:IsStudio() or (game.CreatorId ~= 0 and player.UserId == game.CreatorId)
end

function DevService.init()
	if RunService:IsStudio() then
		print(`[Dev] C cleans the current animal. G grants {GameConfig.DevCoinGrant} coins.`)
	end
	Remotes.event("DevCommand").OnServerEvent:Connect(function(player: Player, action: any)
		if not isDeveloper(player) or typeof(action) ~= "string" then
			return
		end
		if action == "clean" then
			CleaningService.forceComplete(player)
		elseif action == "grant" then
			EconomyService.grant(player, GameConfig.DevCoinGrant)
		end
	end)
end

return DevService
