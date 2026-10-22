-- Server entry point: builds the world, wires services, and handles player lifecycle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Services
local EnvironmentBuilder = require(Services.EnvironmentBuilder)
local WorldBuilder = require(Services.WorldBuilder)
local PlayerDataService = require(Services.PlayerDataService)
local EconomyService = require(Services.EconomyService)
local CleaningService = require(Services.CleaningService)
local BayService = require(Services.BayService)
local DevService = require(Services.DevService)
local ZooService = require(Services.ZooService)
local Hooks = require(Services.Hooks)

EnvironmentBuilder.build()
WorldBuilder.init()
ZooService.init()
PlayerDataService.init()
EconomyService.init()
CleaningService.init({ getTool = EconomyService.getTool })
DevService.init()

-- Feature modules (src/server/Features): each is required and its init() called once the
-- core is up. They plug in through Services.Hooks, so a broken feature can't stop the game.
for _, module in script.Parent.Features:GetChildren() do
	if module:IsA("ModuleScript") then
		local ok, err = pcall(function()
			local feature = require(module) :: any
			if typeof(feature) == "table" and typeof(feature.init) == "function" then
				feature.init()
			end
		end)
		if not ok then
			warn(`[Features] {module.Name} failed to start: {err}`)
		end
	end
end

local initialStatePending: { [Player]: boolean } = {}
Remotes.func("RequestInitialState").OnServerInvoke = function(player: Player)
	-- One request in flight per player, so spamming can't pile up waiting threads.
	if initialStatePending[player] then
		return nil
	end
	initialStatePending[player] = true
	local data = PlayerDataService.waitFor(player, 30)
	local tool = EconomyService.getTool(player)
	local state = {
		DataStatus = PlayerDataService.getStatus(player) or "Failed",
		Coins = if data then data.Coins else 0,
		ToolTier = if tool then tool.Tier else 1,
		ToolName = if tool then tool.Name else "",
		TutorialCompleted = if data then data.TutorialCompleted else false,
		GuideStep = if data then data.GuideStep else "Done",
		Bay = BayService.getSnapshot(player),
		Zoo = ZooService.getZooSummary(player),
		Index = if data then data.Index else nil,
	}
	initialStatePending[player] = nil
	return state
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function()
		CleaningService.refreshHose(player)
	end)
	if player.Character then
		task.spawn(CleaningService.refreshHose, player)
	end

	-- Load before assigning a bay so payouts and tool tier always have a profile.
	PlayerDataService.load(player)
	if not player.Parent then
		return -- left while loading; PlayerDataService already released the lock
	end
	Hooks.fire("PlayerLoaded", player, PlayerDataService.get(player))
	BayService.assign(player)
	EconomyService.sendTool(player)
	CleaningService.refreshHose(player) -- now that the tool tier is known
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	initialStatePending[player] = nil
	BayService.release(player) -- unfinished washes are never paid
end)
