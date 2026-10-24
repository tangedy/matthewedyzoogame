-- Seven-day check-in (LiveOpsConfig.CheckIn): one claim every CooldownHours, days in order. Day 4's
-- earnings buff and day 6's PRO WASHER chat title are permanent flags in data.Extra.LiveOps;
-- animals go straight into the player's hands, or queue for the cache like a bought animal.
-- Remotes:
--   "CheckInState" (server -> client) ({ Count, CanClaim, NextDay, NextClaimIn, Claimed? })
--   "CheckInClaim" (client -> server) () claims today's reward; the server picks which one
-- The client asks once with "CheckInSync" in case it missed the first push.
-- The chart stays hidden until the player has upgraded their gear once and placed an animal
-- (Unlocked); after that it stays available for good.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Common = require(script.Parent.Common)
local Features = script.Parent.Parent
local Services = Features.Parent.Services
local AnimalService = require(Services.AnimalService)
local EconomyService = require(Services.EconomyService)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)
local ZooService = require(Services.ZooService)

local Rewards = LiveOpsConfig.CheckIn.Rewards

local CheckIn = {}

local stateEvent: RemoteEvent
local claiming: { [Player]: boolean } = {}

local function buffMultiplier(): number
	for _, reward in Rewards do
		if reward.Kind == "EarningsBuff" and reward.Multiplier then
			return reward.Multiplier
		end
	end
	return 1
end

-- Upgraded gear at least once and has an animal in a pen. Remembered once true, so selling
-- every animal later never hides the chart again.
local function unlocked(player: Player, state: Common.State): boolean
	if state.CheckInUnlocked then
		return true
	end
	local data = PlayerDataService.get(player)
	if not data then
		return false
	end
	local upgraded = data.ToolTier > 1 or data.ToolUpgrade > 0
	if upgraded and #data.Animals > 0 then
		state.CheckInUnlocked = true
		PlayerDataService.markDirty(player)
		return true
	end
	return false
end

local COOLDOWN = LiveOpsConfig.CheckIn.CooldownHours * 3600

-- When the next claim opens. Saves from before CheckInAt fall back to the next UTC midnight.
local function nextClaimAt(state: Common.State): number
	if state.CheckInAt then
		return state.CheckInAt + COOLDOWN
	elseif state.CheckInDay then
		return (state.CheckInDay + 1) * Common.DAY
	end
	return 0
end

local function payload(player: Player, claimed: string?): { [string]: any }?
	local state = Common.state(player)
	if not state then
		return nil
	end
	local canClaim = Common.now() >= nextClaimAt(state)
	return {
		-- Days ticked on the chart: a finished chart stays full until the next day starts it over.
		Count = if canClaim then state.CheckInCount % #Rewards else state.CheckInCount,
		CanClaim = canClaim,
		NextDay = state.CheckInCount % #Rewards + 1,
		NextClaimIn = math.max(0, nextClaimAt(state) - Common.now()),
		Claimed = claimed,
		Unlocked = unlocked(player, state),
	}
end

local function push(player: Player, claimed: string?)
	local data = payload(player, claimed)
	if data then
		stateEvent:FireClient(player, data)
	end
end

local function applyFlags(player: Player)
	local state = Common.state(player)
	player:SetAttribute("ProWasher", if state and state.ProWasher then true else nil)
end

-- Into the player's hands now, or queued for the cache (same path as a bought animal).
local function grantAnimal(player: Player, species: string, mutation: string): string
	local name = AnimalConfig.Animals[species].DisplayName
	local label = if mutation == MutationConfig.Default then name else `{mutation} {name}`
	if ZooService.giveToCarry(player, species, mutation) then
		ZooService.discover(player, species, mutation)
		return `{label}! Take it to a pen.`
	end
	local MonetizationState = require(Features.MonetizationState) :: any
	local MonetizationGrants = require(Features.MonetizationGrants) :: any
	local saved = MonetizationState.saved(player)
	if saved then
		table.insert(saved.PendingAnimals, { Species = species, Mutation = mutation })
		MonetizationGrants.deliverPending(player)
	end
	return `{label}! Joins your cache when free.`
end

local function grant(player: Player, reward: LiveOpsConfig.CheckInReward): string
	local state = Common.state(player)
	if reward.Kind == "Cash" and reward.Amount then
		EconomyService.addCoins(player, reward.Amount)
		return `+{UIStyle.formatMoney(reward.Amount)}!`
	elseif reward.Kind == "Animal" then
		local species = reward.Species
		if not species or not AnimalConfig.Animals[species] then
			species = AnimalService.randomOfRarity(reward.Rarity or "Common")
		end
		local mutation = if reward.Mutation and MutationConfig.ByKey[reward.Mutation]
			then reward.Mutation
			else MutationConfig.Default
		return grantAnimal(player, species, mutation)
	elseif reward.Kind == "EarningsBuff" and state then
		state.EarningsBuff = true
		return `{reward.Multiplier}x income forever!`
	elseif reward.Kind == "Title" and state then
		state.ProWasher = true
		applyFlags(player)
		return `{reward.Text} title unlocked!`
	end
	return "Reward claimed!"
end

local function claim(player: Player)
	if claiming[player] then
		return
	end
	local state = Common.state(player)
	if not state or Common.now() < nextClaimAt(state) or not unlocked(player, state) then
		push(player)
		return
	end
	claiming[player] = true
	-- Mark the day first, so nothing that yields below can let a second claim through.
	local index = state.CheckInCount % #Rewards + 1
	state.CheckInDay = Common.utcDay()
	state.CheckInAt = Common.now()
	state.CheckInCount = index
	PlayerDataService.markDirty(player)
	local ok, message = pcall(grant, player, Rewards[index])
	if not ok then
		warn(`[CheckIn] day {index} grant failed: {message}`)
		message = "Reward claimed!"
	end
	PlayerDataService.saveNow(player)
	claiming[player] = nil
	push(player, message)
end

function CheckIn.init()
	stateEvent = Remotes.event("CheckInState")
	Remotes.event("CheckInClaim").OnServerEvent:Connect(claim)
	Remotes.func("CheckInSync").OnServerInvoke = function(player: Player)
		return payload(player)
	end

	Hooks.modify("IncomeMultiplier", function(mult: number, player: Player): number
		local state = Common.state(player)
		return if state and state.EarningsBuff then mult * buffMultiplier() else mult
	end)

	Hooks.on("BayAssigned", function(player: Player)
		applyFlags(player)
		push(player)
	end)
	-- The two steps that unlock the chart. Once it is unlocked these pushes are harmless.
	for _, name in { "GearUpgraded", "ToolPurchased", "AnimalPlaced" } do
		Hooks.on(name, function(player: Player)
			push(player)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		claiming[player] = nil
	end)

	-- A cooldown ending while playing makes the next claim available without a rejoin.
	task.spawn(function()
		local ready: { [Player]: boolean } = {}
		while true do
			task.wait(5)
			for _, player in Players:GetPlayers() do
				local state = Common.state(player)
				local now = state ~= nil and Common.now() >= nextClaimAt(state)
				if now and ready[player] == false then
					push(player)
				end
				ready[player] = now
			end
			for player in ready do
				if player.Parent ~= Players then
					ready[player] = nil
				end
			end
		end
	end)
end

return CheckIn
