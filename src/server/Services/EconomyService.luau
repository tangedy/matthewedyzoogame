-- Coin transactions and validated tool upgrades. Reads and writes the profile owned by
-- PlayerDataService; never trusts client-supplied amounts, tiers, or prices.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local CleanGateService = require(script.Parent.CleanGateService)
local CleaningService = require(script.Parent.CleaningService)
local Hooks = require(script.Parent.Hooks)
local PlayerDataService = require(script.Parent.PlayerDataService)

local EconomyService = {}

local coinsChanged = Remotes.event("CoinsChanged")
local toolTierChanged = Remotes.event("ToolTierChanged")
local purchaseResult = Remotes.event("PurchaseResult")

function EconomyService.getProfile(player: Player): PlayerDataService.SavedData?
	return PlayerDataService.get(player)
end

function EconomyService.getTool(player: Player): ToolConfig.ToolTier?
	local data = PlayerDataService.get(player)
	return data and ToolConfig[data.ToolTier]
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
local function commitTier(player: Player, data: PlayerDataService.SavedData, nextTool: ToolConfig.ToolTier)
	local previousTier = data.ToolTier
	data.ToolTier = nextTool.Tier
	CleanGateService.onTiersGained(player, previousTier, nextTool.Tier)
	PlayerDataService.saveNow(player)
	toolTierChanged:FireClient(player, nextTool.Tier, nextTool.Name)
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

-- Buys the next hose tier. The server picks the tier and price; nothing comes from the client.
-- Doesn't yield, so two requests can't both pass the balance check.
local function purchaseToolUpgrade(player: Player)
	local data = PlayerDataService.get(player)
	if not data then
		purchaseResult:FireClient(player, false, "Still loading your data. Try again in a moment.")
		return
	end
	local nextTool = ToolConfig[data.ToolTier + 1]
	if not nextTool then
		purchaseResult:FireClient(player, false, "Your hose is already fully upgraded!")
		return
	end
	if data.Coins < nextTool.Price then
		purchaseResult:FireClient(
			player,
			false,
			`Not enough cash. You need {UIStyle.formatMoney(nextTool.Price - data.Coins)} more.`
		)
		return
	end

	data.Coins -= nextTool.Price
	coinsChanged:FireClient(player, data.Coins)
	commitTier(player, data, nextTool)
	purchaseResult:FireClient(player, true, `Upgraded to {nextTool.Name}!`)
end

function EconomyService.sendTool(player: Player)
	local tool = EconomyService.getTool(player)
	if tool then
		toolTierChanged:FireClient(player, tool.Tier, tool.Name)
	end
end

function EconomyService.init()
	local lastPurchaseAt: { [Player]: number } = {}
	Remotes.event("PurchaseToolUpgrade").OnServerEvent:Connect(function(player)
		local now = os.clock()
		if lastPurchaseAt[player] and now - lastPurchaseAt[player] < 0.5 then
			return
		end
		lastPurchaseAt[player] = now
		purchaseToolUpgrade(player)
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastPurchaseAt[player] = nil
	end)
end

return EconomyService
