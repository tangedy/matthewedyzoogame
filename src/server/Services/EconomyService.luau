-- Coin transactions and validated tool upgrades. Reads and writes the profile owned by
-- PlayerDataService; never trusts client-supplied amounts, tiers, or prices.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local GearLadder = require(ReplicatedStorage.Shared.GearLadder)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local StatUpgrades = require(ReplicatedStorage.Shared.StatUpgrades)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local CleanGateService = require(script.Parent.CleanGateService)
local CleaningService = require(script.Parent.CleaningService)
local Hooks = require(script.Parent.Hooks)
local PlayerDataService = require(script.Parent.PlayerDataService)

local EconomyService = {}

local coinsChanged = Remotes.event("CoinsChanged")
local toolTierChanged = Remotes.event("ToolTierChanged")
local purchaseResult = Remotes.event("PurchaseResult")
local statUpgradesChanged = Remotes.event("StatUpgradesChanged")

function EconomyService.getProfile(player: Player): PlayerDataService.SavedData?
	return PlayerDataService.get(player)
end

function EconomyService.getTool(player: Player): ToolConfig.ToolTier?
	local data = PlayerDataService.get(player)
	return data and ToolConfig[data.ToolTier]
end

-- The player's hose with its bought sub-tier applied: range, spray, wash speed and wash perks.
function EconomyService.getGear(player: Player): GearLadder.Step?
	local data = PlayerDataService.get(player)
	return data and GearLadder.get(data.ToolTier, data.ToolUpgrade)
end

-- Coins from a completed wash. Amount comes from server config.
function EconomyService.awardWash(player: Player, amount: number): boolean
	local data = PlayerDataService.get(player)
	if not data or typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return false
	end
	data.Coins += math.floor(amount)
	data.LifetimeAnimalsWashed += 1
	data.TutorialCompleted = true
	PlayerDataService.markDirty(player)
	coinsChanged:FireClient(player, data.Coins)
	return true
end

-- Coins from zoo releases and index discoveries. Amount always comes from server config.
function EconomyService.addCoins(player: Player, amount: number): boolean
	local data = PlayerDataService.get(player)
	if not data or typeof(amount) ~= "number" or amount ~= amount or amount <= 0 or amount == math.huge then
		return false
	end
	data.Coins += math.floor(amount)
	PlayerDataService.markDirty(player)
	coinsChanged:FireClient(player, data.Coins)
	return true
end

-- Deducts a server-priced cost. Returns false (and changes nothing) if the player can't afford it.
function EconomyService.spend(player: Player, amount: number): boolean
	local data = PlayerDataService.get(player)
	if not data or typeof(amount) ~= "number" or amount ~= amount or amount < 0 or data.Coins < amount then
		return false
	end
	data.Coins -= amount
	PlayerDataService.markDirty(player)
	coinsChanged:FireClient(player, data.Coins)
	return true
end

-- Developer coin grant. The amount is a server constant; the client never supplies it.
function EconomyService.grant(player: Player, amount: number): boolean
	local data = PlayerDataService.get(player)
	if not data or typeof(amount) ~= "number" or amount ~= amount or amount <= 0 or amount == math.huge then
		return false
	end
	data.Coins += math.floor(amount)
	PlayerDataService.markDirty(player)
	coinsChanged:FireClient(player, data.Coins)
	return true
end

-- Writes the next hose onto the profile and tells the client. Cash is the caller's job.
-- A new hose starts at its own sub-tier I.
local function commitTier(player: Player, data: PlayerDataService.SavedData, nextTool: ToolConfig.ToolTier)
	local previousTier = data.ToolTier
	data.ToolTier = nextTool.Tier
	data.ToolUpgrade = 0
	CleanGateService.onTiersGained(player, previousTier, nextTool.Tier)
	PlayerDataService.saveNow(player)
	toolTierChanged:FireClient(player, nextTool.Tier, nextTool.Name, 0)
	CleaningService.refreshHose(player)
	Hooks.fire("ToolPurchased", player, nextTool.Tier, nextTool.Name)
end

-- Grants exactly one hose tier, and only when it is the player's next tier.
-- Used by the Robux fallback so a receipt cannot skip the ladder.
function EconomyService.grantToolTier(player: Player, tier: number): boolean
	local data = PlayerDataService.get(player)
	local nextTool = ToolConfig[tier]
	if not data or not nextTool or data.ToolTier + 1 ~= tier then
		return false
	end
	commitTier(player, data, nextTool)
	return true
end

-- Buys the next step on the gear ladder: the current hose's next sub-tier, or the next hose
-- once those are all owned. The server picks the step and price; nothing comes from the client.
-- Doesn't yield, so two requests can't both pass the balance check.
local function purchaseToolUpgrade(player: Player)
	local data = PlayerDataService.get(player)
	if not data then
		purchaseResult:FireClient(player, false, "Still loading. Try again.")
		return
	end
	local step = GearLadder.next(data.ToolTier, data.ToolUpgrade)
	if not step then
		purchaseResult:FireClient(player, false, "Max gear!")
		return
	end
	if data.Coins < step.Price then
		purchaseResult:FireClient(player, false, `Need {UIStyle.formatMoney(step.Price - data.Coins)} more.`)
		return
	end

	data.Coins -= step.Price
	coinsChanged:FireClient(player, data.Coins)
	if step.Level == 0 then
		commitTier(player, data, ToolConfig[step.Tier])
	else
		data.ToolUpgrade = step.Level
		PlayerDataService.saveNow(player)
		toolTierChanged:FireClient(player, step.Tier, step.Name, step.Level)
		Hooks.fire("GearUpgraded", player, step.Tier, step.Level, step.Label)
	end
	purchaseResult:FireClient(player, true, `Upgraded to {step.Label}!`)
end

-- Sets the character's walk speed from the player's Speed level. A running Robux speed boost
-- (MonetizationGrants) keeps its multiplier on top: its saved base moves to the new speed.
function EconomyService.applyWalkSpeed(player: Player)
	local data = PlayerDataService.get(player)
	local speed = StatUpgrades.walkSpeed(if data then data.SpeedLevel else 0)
	-- The client reads this to restore speed after it freezes the character (cutscene).
	player:SetAttribute("BaseWalkSpeed", speed)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local boostBase = humanoid:GetAttribute("SpeedBoostBase")
	if humanoid:GetAttribute("SpeedBoost") and typeof(boostBase) == "number" and boostBase > 0 then
		humanoid.WalkSpeed = humanoid.WalkSpeed / boostBase * speed
		humanoid:SetAttribute("SpeedBoostBase", speed)
	elseif humanoid.WalkSpeed > 0 then
		humanoid.WalkSpeed = speed
	end
end

function EconomyService.sendStatUpgrades(player: Player)
	local data = PlayerDataService.get(player)
	if data then
		statUpgradesChanged:FireClient(player, { Speed = data.SpeedLevel, PenCap = data.PenCapLevel })
	end
end

-- Buys the next level of a repeatable stat upgrade. The client only names the track; the
-- server picks the level and price. Doesn't yield, so two requests can't both pass the check.
local function purchaseStatUpgrade(player: Player, kind: any)
	local data = PlayerDataService.get(player)
	if not data then
		purchaseResult:FireClient(player, false, "Still loading. Try again.")
		return
	end
	local track = if typeof(kind) == "string" then StatUpgrades.Tracks[kind :: StatUpgrades.Kind] else nil
	if not track then
		purchaseResult:FireClient(player, false, "")
		return
	end
	local levels = data :: any -- SpeedLevel / PenCapLevel, picked by the track
	local level = levels[track.Field] :: number
	local price = StatUpgrades.nextPrice(track.Kind, level)
	if not price then
		purchaseResult:FireClient(player, false, `{track.Name} is maxed!`)
		return
	end
	if data.Coins < price then
		purchaseResult:FireClient(player, false, `Need {UIStyle.formatMoney(price - data.Coins)} more.`)
		return
	end

	data.Coins -= price
	level += 1
	levels[track.Field] = level
	PlayerDataService.saveNow(player)
	coinsChanged:FireClient(player, data.Coins)
	EconomyService.sendStatUpgrades(player)
	if track.Kind == "Speed" then
		EconomyService.applyWalkSpeed(player)
	end
	Hooks.fire("StatUpgraded", player, track.Kind, level)
	purchaseResult:FireClient(player, true, `Upgraded to {StatUpgrades.label(track.Kind, level)}!`)
end

function EconomyService.sendTool(player: Player)
	local gear = EconomyService.getGear(player)
	if gear then
		toolTierChanged:FireClient(player, gear.Tier, gear.Name, gear.Level)
	end
end

function EconomyService.init()
	-- Sub-tier wash perks: more seconds of income per wash, plus a flat cash bonus.
	Hooks.modify("WashReward", function(reward: number, player: Player): number
		local gear = EconomyService.getGear(player)
		if not gear then
			return reward
		end
		return reward * gear.WashRewardSeconds / GameConfig.WashRewardSeconds * (1 + gear.WashCashBonus)
	end)
	local lastPurchaseAt: { [Player]: number } = {}
	Remotes.event("PurchaseToolUpgrade").OnServerEvent:Connect(function(player)
		local now = os.clock()
		if lastPurchaseAt[player] and now - lastPurchaseAt[player] < 0.5 then
			-- Always answer: the shop waits for a result before it re-enables Buy.
			purchaseResult:FireClient(player, false, "")
			return
		end
		lastPurchaseAt[player] = now
		purchaseToolUpgrade(player)
	end)
	Remotes.event("PurchaseStatUpgrade").OnServerEvent:Connect(function(player, kind)
		local now = os.clock()
		if lastPurchaseAt[player] and now - lastPurchaseAt[player] < 0.5 then
			purchaseResult:FireClient(player, false, "")
			return
		end
		lastPurchaseAt[player] = now
		purchaseStatUpgrade(player, kind)
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastPurchaseAt[player] = nil
	end)
end

return EconomyService
