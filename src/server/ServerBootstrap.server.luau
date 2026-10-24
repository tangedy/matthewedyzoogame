-- Server entry point: builds the world, wires services, and handles player lifecycle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

-- The character waits until a base exists, then loads on that base's spawn.
Players.CharacterAutoLoads = false
StarterPlayer.CharacterWalkSpeed = GameConfig.WalkSpeed

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
local CutsceneService = require(Services.CutsceneService)
local StationProps = require(Services.StationProps)

EnvironmentBuilder.build()
WorldBuilder.init()
CutsceneService.init()
ZooService.init()
PlayerDataService.init()
EconomyService.init()
CleaningService.init({ getTool = EconomyService.getGear })
StationProps.init()
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
	local tool = EconomyService.getGear(player)
	local state = {
		DataStatus = PlayerDataService.getStatus(player) or "Failed",
		Coins = if data then data.Coins else 0,
		ToolTier = if tool then tool.Tier else 1,
		ToolName = if tool then tool.Name else "",
		ToolUpgrade = if tool then tool.Level else 0,
		TutorialCompleted = if data then data.TutorialCompleted else false,
		GuideStep = if data then data.GuideStep else "Done",
		PlayCutscene = if data then not data.CutsceneSeen else false,
		IntroWashesLeft = if data then data.IntroWashesLeft else 0,
		Bay = BayService.getSnapshot(player),
		Zoo = ZooService.getZooSummary(player),
		Index = if data then data.Index else nil,
	}
	initialStatePending[player] = nil
	return state
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		CleaningService.refreshHose(player)
		-- CharacterAutoLoads is off, so a death has to load the character again.
		-- RespawnLocation is this player's base pad.
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid or not player.Parent or player.Character ~= character then
			return
		end
		humanoid.Died:Once(function()
			task.delay(Players.RespawnTime, function()
				if player.Parent and player.Character == character then
					player:LoadCharacter()
				end
			end)
		end)
	end)
	if player.Character then
		task.spawn(CleaningService.refreshHose, player)
	end

	-- Load before assigning a bay so payouts and tool tier always have a profile.
	PlayerDataService.load(player)
	if not player.Parent then
		return -- left while loading; PlayerDataService already released the lock
	end
	CutsceneService.begin(player)
	Hooks.fire("PlayerLoaded", player, PlayerDataService.get(player))
	BayService.assign(player)
	EconomyService.sendTool(player)
	CleaningService.refreshHose(player) -- now that the tool tier is known
	-- RespawnLocation is already the owner's pad, so this first load lands on the base.
	if player.Parent and not player.Character then
		player:LoadCharacter()
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	initialStatePending[player] = nil
	BayService.release(player) -- unfinished washes are never paid
end)
