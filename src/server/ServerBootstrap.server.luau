-- Server entry point: builds the world, wires services, and handles player lifecycle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Services
local WorldBuilder = require(Services.WorldBuilder)
local PlayerDataService = require(Services.PlayerDataService)
local EconomyService = require(Services.EconomyService)
local CleaningService = require(Services.CleaningService)
local BayService = require(Services.BayService)
local DevService = require(Services.DevService)

BayService.init(WorldBuilder.build())
PlayerDataService.init()
EconomyService.init()
CleaningService.init({ getTool = EconomyService.getTool })
DevService.init()

Remotes.func("RequestInitialState").OnServerInvoke = function(player: Player)
	local data = PlayerDataService.waitFor(player, 30)
	local tool = EconomyService.getTool(player)
	return {
		DataStatus = PlayerDataService.getStatus(player) or "Failed",
		Coins = if data then data.Coins else 0,
		ToolTier = if tool then tool.Tier else 1,
		ToolName = if tool then tool.Name else "",
		TutorialCompleted = if data then data.TutorialCompleted else false,
		Bay = BayService.getSnapshot(player),
	}
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		CleaningService.giveHose(character)
	end)
	if player.Character then
		task.spawn(CleaningService.giveHose, player.Character)
	end

	-- Load before assigning a bay so payouts and tool tier always have a profile.
	PlayerDataService.load(player)
	if not player.Parent then
		return -- left while loading; PlayerDataService already released the lock
	end
	BayService.assign(player)
	EconomyService.sendTool(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	BayService.release(player) -- unfinished washes are never paid
end)
