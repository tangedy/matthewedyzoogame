-- Rare guarantee: every LiveOpsConfig.RareGuarantee.EverySeconds of play time, the next walk-in
-- is a species one rarity above the rarest the player's hose can wash (Secret at the top).
-- The hose can't wash it, so it arrives like any other too-dirty walk-in (let it go or Clean
-- Now). The clock is saved in data.Extra.LiveOps.RareClock and only runs while the player has
-- a zoo; it resets when the guaranteed animal is picked. Another feature's override (the Daily
-- Dirty Animal, scripted walk-ins) goes first and this one waits for the next walk-in.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Common = require(script.Parent.Common)
local Services = script.Parent.Parent.Parent.Services
local AnimalBuilder = require(Services.AnimalBuilder)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

local Config = LiveOpsConfig.RareGuarantee

local RareGuarantee = {}

local playing: { [Player]: boolean } = {} -- has a zoo this session
local rng = Random.new()

local function pickSpecies(player: Player): string?
	local data = PlayerDataService.get(player)
	local tool = ToolConfig[if data then data.ToolTier else 1] or ToolConfig[1]
	local rarityKey = CleanPower.rarityAbove(tool.CleaningPower)
	local keys = {}
	for key in AnimalConfig.Animals do
		table.insert(keys, key)
	end
	table.sort(keys)
	local pool: { string } = {}
	local total = 0
	for _, key in keys do
		local def = AnimalConfig.Animals[key]
		if
			def.Rarity == rarityKey
			and def.SpawnWeight > 0
			and not def.Limited
			and AnimalBuilder.has(def.TemplateName)
		then
			table.insert(pool, key)
			total += def.SpawnWeight
		end
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	for _, key in pool do
		roll -= AnimalConfig.Animals[key].SpawnWeight
		if roll <= 0 then
			return key
		end
	end
	return pool[#pool]
end

function RareGuarantee.init()
	Hooks.modify("NextAnimal", function(value: any, player: Player, isFirst: boolean): any
		if value ~= nil or isFirst then
			return value
		end
		local state = Common.state(player)
		if not state or state.RareClock < Config.EverySeconds then
			return value
		end
		local species = pickSpecies(player)
		if not species then
			return value
		end
		state.RareClock = 0
		PlayerDataService.markDirty(player)
		return { Species = species }
	end)

	Hooks.on("BayAssigned", function(player: Player)
		playing[player] = true
	end)
	Players.PlayerRemoving:Connect(function(player)
		playing[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			for player in playing do
				local state = if player.Parent then Common.state(player) else nil
				if state and state.RareClock < Config.EverySeconds then
					state.RareClock += 1 -- saved with the profile's autosave
				end
			end
		end
	end)
end

return RareGuarantee
