-- New-player welcome, once per profile and always inside the first five minutes of play: a
-- Secret Kaiju stomps down the main road past the player's farm, and then every rarity above
-- Common walks in more often for LiveOpsConfig.NewPlayer.BoostMinutes.
--
-- It fires at ShowAtSeconds of play once the opening washes are done, or at LatestSeconds
-- either way. Play time is the saved PlaySeconds at the moment the bay is assigned plus this
-- session's clock. Profiles already past LatestSeconds are marked shown and never see it.
-- Saved in data.Extra.LiveOps (NewPlayerShown, NewPlayerBoostEndsAt). The client reads the
-- boost from the Player attribute NewPlayerBoostEndsAt (a GetServerTimeNow() instant) and
-- shows the banner on LiveOpsNewPlayer (minutes, multiplier).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local PlotLayout = require(ReplicatedStorage.Shared.PlotLayout)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Common = require(script.Parent.Common)
local Services = script.Parent.Parent.Parent.Services
local AnimalBuilder = require(Services.AnimalBuilder)
local AnimalService = require(Services.AnimalService)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

local Config = LiveOpsConfig.NewPlayer

local NewPlayer = {}

local ATTRIBUTE = "NewPlayerBoostEndsAt"

-- Players still waiting for their Kaiju: saved play seconds when the bay was assigned, the
-- os.clock() of that moment, and which plot they own.
local waiting: { [Player]: { Base: number, Started: number, Bay: number } } = {}

local function boostActive(player: Player): boolean
	local state = Common.state(player)
	local ends = state and state.NewPlayerBoostEndsAt
	return ends ~= nil and ends > Common.now()
end

local function publish(player: Player)
	local state = Common.state(player)
	local ends = state and state.NewPlayerBoostEndsAt
	player:SetAttribute(ATTRIBUTE, if ends and ends > Common.now() then Common.synced(ends) else nil)
end

-- Walks the Kaiju along the road lane on the player's side, from one end of their farm's
-- stretch to the other, then poofs it. Seen by everyone on the road; it touches nothing.
local function walkKaiju(bayIndex: number)
	local species = Config.Species
	local def = AnimalConfig.Animals[species]
	if not def or not AnimalBuilder.has(def.TemplateName) then
		species = "TRex"
		def = AnimalConfig.Animals[species]
	end
	if not def or not AnimalBuilder.has(def.TemplateName) then
		return
	end
	local plot = PlotLayout.frame(bayIndex)
	local laneX = GameConfig.RoadX + plot.Side * GameConfig.RoadWidth / 4
	local z = PlotLayout.zOf(bayIndex)
	local from = Vector3.new(laneX, 0, z - Config.RoadSpan)
	local to = Vector3.new(laneX, 0, z + Config.RoadSpan)

	local model = AnimalService.buildZooAnimal(species, MutationConfig.Default)
	model.Name = "NewPlayerKaiju"
	AnimalService.resize(model, AnimalService.bodyScale(species))
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end
	end
	model:PivotTo(CFrame.lookAt(from, to))
	local box, size = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + Vector3.new(0, -(box.Position.Y - size.Y / 2), 0))
	model.Parent = Workspace

	local start = model:GetPivot().Position
	local goal = Vector3.new(to.X, start.Y, to.Z)
	AnimalService.walkCorners(model, { CFrame.new(goal) }, Config.WalkSeconds, 0.6)
	if model.Parent then
		AnimalService.poof(model)
	end
end

local function trigger(player: Player, bayIndex: number)
	waiting[player] = nil
	local state = Common.state(player)
	if not state or state.NewPlayerShown then
		return
	end
	state.NewPlayerShown = true
	state.NewPlayerBoostEndsAt = Common.now() + Config.BoostMinutes * 60
	PlayerDataService.markDirty(player)
	publish(player)

	Remotes.event("LiveOpsNewPlayer"):FireClient(player, Config.BoostMinutes, Config.SpawnWeightMultiplier)
	task.spawn(function()
		local ok, err = pcall(walkKaiju, bayIndex)
		if not ok then
			warn(`[LiveOps] New-player Kaiju walk failed: {err}`)
		end
	end)
	task.delay(Config.BoostMinutes * 60 + 1, function()
		if player.Parent then
			publish(player)
		end
	end)
end

function NewPlayer.init()
	Remotes.event("LiveOpsNewPlayer") -- create it before any client listens

	Hooks.modify("SpawnWeight", function(weight: number, player: Player, species: string): number
		if not boostActive(player) then
			return weight
		end
		local def = AnimalConfig.Animals[species]
		local rarity = def and RarityConfig.ByKey[def.Rarity]
		return if rarity and rarity.Order > 1 then weight * Config.SpawnWeightMultiplier else weight
	end)

	Hooks.on("BayAssigned", function(player: Player, bay: Model)
		local state = Common.state(player)
		local bayIndex = bay:GetAttribute("BayIndex")
		if not state or typeof(bayIndex) ~= "number" then
			return
		end
		if state.NewPlayerShown then
			publish(player)
			-- A boost carried over from an earlier visit still has to clear its pill.
			local ends = state.NewPlayerBoostEndsAt
			if ends and ends > Common.now() then
				task.delay(ends - Common.now() + 1, function()
					if player.Parent then
						publish(player)
					end
				end)
			end
			return
		end
		if state.PlaySeconds > Config.LatestSeconds then
			state.NewPlayerShown = true
			PlayerDataService.markDirty(player)
			return
		end
		waiting[player] = { Base = state.PlaySeconds, Started = os.clock(), Bay = bayIndex }
	end)
	Players.PlayerRemoving:Connect(function(player)
		waiting[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			for player, entry in waiting do
				if not player.Parent then
					waiting[player] = nil
					continue
				end
				local played = entry.Base + (os.clock() - entry.Started)
				local data = PlayerDataService.get(player)
				local introDone = data ~= nil and data.IntroWashesLeft <= 0
				if (played >= Config.ShowAtSeconds and introDone) or played >= Config.LatestSeconds then
					trigger(player, entry.Bay)
				end
			end
		end
	end)
end

return NewPlayer
