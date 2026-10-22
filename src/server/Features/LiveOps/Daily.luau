-- Daily Dirty Animal: once per UTC day, a player's next walk-in (never the session's first
-- animal) is a guaranteed Rare-or-better species their hose can handle. It comes in extra
-- muddy, pays a bigger wash reward, and the owner gets a "DAILY DIRTY ANIMAL!" banner.
-- The day is claimed when that animal reaches the wash spot, so leaving early doesn't lose it.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Common = require(script.Parent.Common)
local Services = script.Parent.Parent.Parent.Services
local AnimalBuilder = require(Services.AnimalBuilder)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

local Config = LiveOpsConfig.Daily
local TAG_NAME = "LiveOpsDailyTag"

local Daily = {}

-- Species overridden for the walk-in in progress. Only set when the override was returned,
-- and cleared on every NextAnimal call, so a walk-in that died before WashStarted (spawn or
-- path error) can never leave a stale entry that matches a later random animal.
local pending: { [Player]: string } = {}
local dailyJob: { [Player]: string } = {} -- job id of the daily animal being washed
local rng = Random.new()

local function pickSpecies(player: Player): string?
	local data = PlayerDataService.get(player)
	local tier = if data then data.ToolTier else 1
	local tool = ToolConfig[tier]
	local power = if tool then tool.CleaningPower else 0
	local minOrder = (RarityConfig.ByKey[Config.MinRarity] or RarityConfig.ByKey.Rare).Order
	local keys = {}
	for key in AnimalConfig.Animals do
		table.insert(keys, key)
	end
	table.sort(keys)
	local pool: { { Key: string, Weight: number } } = {}
	local total = 0
	for _, key in keys do
		local def = AnimalConfig.Animals[key]
		local rarity = RarityConfig.ByKey[def.Rarity]
		if
			rarity
			and rarity.Order >= minOrder
			and def.RequiredToolTier <= tier
			and CleanPower.canClean(power, def.Rarity)
			and def.SpawnWeight > 0
			and not def.Limited
			and AnimalBuilder.has(def.TemplateName)
		then
			local weight = def.SpawnWeight ^ Config.WeightExponent
			total += weight
			table.insert(pool, { Key = key, Weight = weight })
		end
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	for _, entry in pool do
		roll -= entry.Weight
		if roll <= 0 then
			return entry.Key
		end
	end
	return pool[#pool].Key
end

-- Rainbow "DAILY DIRTY ANIMAL" tag above the animal's nameplate while it's being washed.
local function addTag(model: Model)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = TAG_NAME
	billboard.Size = UDim2.fromOffset(240, 34)
	billboard.StudsOffset = Vector3.new(0, head.Size.Y / 2 + 2.6, 0)
	billboard.SizeOffset = Vector2.new(0, 4.2) -- above the nameplate and the clean meter
	billboard.MaxDistance = 80
	billboard.Parent = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = billboard
	UIStyle.text(label, Color3.new(1, 1, 1), nil, 3)
	label.Text = "DAILY DIRTY ANIMAL!"
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)),
		ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 200, 50)),
		ColorSequenceKeypoint.new(0.66, Color3.fromRGB(90, 255, 90)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(70, 200, 255)),
	})
	gradient.Parent = label
	CollectionService:AddTag(gradient, UIStyle.RainbowTag)
end

local function removeTag(model: Model)
	local head = model:FindFirstChild("Head")
	local tag = head and head:FindFirstChild(TAG_NAME)
	if tag then
		tag:Destroy()
	end
end

function Daily.init()
	local dailyEvent = Remotes.event("LiveOpsDaily") -- (displayName, rarity, mutation, rewardMultiplier)

	Hooks.modify("NextAnimal", function(value: any, player: Player, isFirst: boolean): any
		pending[player] = nil -- any entry still here belongs to a walk-in that never started
		if value ~= nil or isFirst or dailyJob[player] then
			return value -- another feature already chose, or the daily one is in progress
		end
		local state = Common.state(player)
		if not state or (state.DailyDay and state.DailyDay >= Common.utcDay()) then
			return value
		end
		local species = pickSpecies(player)
		if not species then
			return value
		end
		pending[player] = species
		return { Species = species }
	end)
	Hooks.modify("WashTimeMultiplier", function(mult: number, player: Player, species: string): number
		return if pending[player] == species then mult * Config.WashTimeMultiplier else mult
	end)
	Hooks.modify("WashReward", function(reward: number, player: Player, species: string): number
		return if pending[player] == species then reward * Config.RewardMultiplier else reward
	end)

	Hooks.on("WashStarted", function(player: Player, info: Hooks.WashInfo)
		if dailyJob[player] and dailyJob[player] ~= info.JobId then
			dailyJob[player] = nil -- that wash never finished (the bay reset)
		end
		local species = pending[player]
		if not species then
			return
		end
		pending[player] = nil
		local state = Common.state(player)
		if info.Species ~= species or not state then
			return -- something else replaced the walk-in; try again with the next one
		end
		state.DailyDay = Common.utcDay()
		PlayerDataService.markDirty(player)
		dailyJob[player] = info.JobId
		addTag(info.Model)
		local def = AnimalConfig.Animals[species]
		dailyEvent:FireClient(player, def.DisplayName, def.Rarity, info.Mutation, Config.RewardMultiplier)
	end)
	Hooks.on("BayAssigned", function(player: Player)
		pending[player] = nil -- a new bay's first animal skips NextAnimal
		dailyJob[player] = nil
	end)
	Hooks.on("WashCompleted", function(player: Player, info: Hooks.WashInfo)
		if dailyJob[player] == info.JobId then
			dailyJob[player] = nil
			removeTag(info.Model)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil
		dailyJob[player] = nil
	end)
end

return Daily
