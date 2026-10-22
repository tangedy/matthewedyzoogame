-- Server entry point: builds the world, wires services, and handles player lifecycle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Services
local WorldBuilder = require(Services.WorldBuilder)
local EconomyService = require(Services.EconomyService)
local CleaningService = require(Services.CleaningService)
local BayService = require(Services.BayService)

BayService.init(WorldBuilder.build())
CleaningService.init({ getTool = EconomyService.getTool })

Remotes.func("RequestInitialState").OnServerInvoke = function(player: Player)
	local profile = EconomyService.getProfile(player)
	local tool = EconomyService.getTool(player)
	return {
		Coins = if profile then profile.Coins else 0,
		ToolTier = if tool then tool.Tier else 1,
		ToolName = if tool then tool.Name else "",
		TutorialCompleted = if profile then profile.TutorialCompleted else false,
		Bay = BayService.getSnapshot(player),
	}
end

local function onPlayerAdded(player: Player)
	EconomyService.load(player)
	player.CharacterAdded:Connect(function(character)
		CleaningService.giveHose(character)
	end)
	if player.Character then
		task.spawn(CleaningService.giveHose, player.Character)
	end
	BayService.assign(player)
	EconomyService.sendTool(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	BayService.release(player)
	EconomyService.unload(player)
end)
