-- Monetization: Robux developer products and game passes, end to end.
--
--   * Shop requests (MonetizationBuy) only carry a product key. The server checks it, then
--     prompts the real purchase, or in test mode (Studio, or an unconfigured id 0) simulates
--     a successful one through the same grant path a real receipt takes.
--   * ProcessReceipt is idempotent: a PurchaseId is granted once (kept in
--     data.Extra.Monetization.Receipts), only on a saving profile, and PurchaseGranted is
--     returned only after the grant is recorded and a save is queued.
--   * Game passes: UserOwnsGamePassAsync on join (cached per session) plus
--     PromptGamePassPurchaseFinished.
--   * Boosts plug into the core through Hooks: Super Soap (CleaningPower), Lucky Soap
--     (SpawnWeight / MutationWeight, counted down on WashStarted), VIP (IncomeMultiplier),
--     Calm Treat (fires "CalmTreat" for the Tension feature).
--   * Contextual offers, never in a session's first 90 seconds: Calm Treat on "PatienceLow",
--     Super Soap when a big animal is still mostly dirty 8 seconds into its wash.
-- Split across MonetizationState (data), MonetizationGrants (effects), MonetizationStock.

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Parent.Services
local CleaningService = require(Services.CleaningService)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)
local MonetizationGrants = require(script.Parent.MonetizationGrants)
local MonetizationState = require(script.Parent.MonetizationState)
local MonetizationStock = require(script.Parent.MonetizationStock)

type Product = MonetizationConfig.Product
type Pass = MonetizationConfig.Pass

local Monetization = {}

local productsById: { [number]: Product } = {}
local passesById: { [number]: Pass } = {}
local processing: { [string]: boolean } = {} -- PurchaseIds being granted right now

local offerRemote: RemoteEvent

-- Receipts ------------------------------------------------------------------------------

-- The single grant path for real receipts and simulated purchases.
local function processPurchase(
	player: Player,
	product: Product,
	purchaseId: string,
	simulated: boolean
): Enum.ProductPurchaseDecision
	if processing[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local saved = MonetizationState.saved(player)
	if not saved or not MonetizationState.peek(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- A temporary profile is never saved, so a real purchase waits for a session that saves.
	if not simulated and PlayerDataService.getStatus(player) ~= "Loaded" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if table.find(saved.Receipts, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	processing[purchaseId] = true
	local ok, granted, message = pcall(MonetizationGrants.product, player, product, purchaseId)
	processing[purchaseId] = nil
	if not ok then
		warn(`[Monetization] Granting {product.Key} to {player.Name} failed: {granted}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Re-read: the Limited grant yields, and the player may have left meanwhile.
	saved = MonetizationState.saved(player)
	if not granted or not saved then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	table.insert(saved.Receipts, purchaseId)
	while #saved.Receipts > MonetizationConfig.ReceiptsKept do
		table.remove(saved.Receipts, 1)
	end
	PlayerDataService.saveNow(player)
	if message then
		MonetizationState.notify(player, if simulated then `[TEST] {message}` else message, true)
	end
	MonetizationState.push(player)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processReceipt(receipt: { [string]: any }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local product = productsById[receipt.ProductId]
	if not product then
		warn(`[Monetization] Receipt for unknown product id {receipt.ProductId}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- granted next time they join
	end
	return processPurchase(player, product, tostring(receipt.PurchaseId), false)
end

-- Shop requests ---------------------------------------------------------------------------

local function buyProduct(player: Player, product: Product)
	local saved = MonetizationState.saved(player)
	if not saved then
		MonetizationState.notify(player, "Still loading your data. Try again in a moment.", false)
		return
	end
	if product.OncePerPlayer and saved.Once[product.Key] then
		MonetizationState.notify(player, "You already used that offer.", false)
		return
	end
	if product.Kind == "Limited" then
		if not (product.Species and AnimalConfig.Animals[product.Species]) then
			MonetizationState.notify(player, "Coming soon!", false)
			return
		end
		-- Robux can't be refunded, so check the stock before prompting (and again at receipt time).
		local left = MonetizationStock.remaining(product.Key)
		if left == nil or left <= 0 then
			left = MonetizationStock.refresh(product.Key) or left
		end
		if left == nil then
			MonetizationState.notify(player, "Couldn't check the stock. Try again in a moment.", false)
			return
		end
		if left <= 0 then
			MonetizationState.notify(player, `{product.DisplayName} is SOLD OUT!`, false)
			MonetizationState.push(player)
			return
		end
	end
	if not player.Parent then
		return
	end
	if MonetizationState.shouldSimulate(player, product.Id) then
		local decision = processPurchase(player, product, "SIM-" .. HttpService:GenerateGUID(false), true)
		if decision ~= Enum.ProductPurchaseDecision.PurchaseGranted then
			MonetizationState.notify(player, "[TEST] Purchase could not be granted right now.", false)
		end
	elseif product.Id ~= 0 then
		MarketplaceService:PromptProductPurchase(player, product.Id)
	else
		MonetizationState.notify(player, "This item isn't on sale yet.", false)
	end
end

local function buyPass(player: Player, pass: Pass)
	if MonetizationState.ownsPass(player, pass.Key) then
		MonetizationState.notify(player, `You already own {pass.DisplayName}!`, false)
		return
	end
	if MonetizationState.shouldSimulate(player, pass.Id) then
		MonetizationGrants.grantPass(player, pass.Key)
	elseif pass.Id ~= 0 then
		MarketplaceService:PromptGamePassPurchase(player, pass.Id)
	else
		MonetizationState.notify(player, "This pass isn't on sale yet.", false)
	end
end

local function onBuy(player: Player, key: any)
	if typeof(key) ~= "string" or #key > 40 then
		return
	end
	if not MonetizationState.allow(player, "Buy", MonetizationConfig.BuyCooldown) then
		return
	end
	local product = MonetizationConfig.ProductsByKey[key]
	local pass = MonetizationConfig.PassesByKey[key]
	if product then
		buyProduct(player, product)
	elseif pass then
		buyPass(player, pass)
	end
end

-- Offers --------------------------------------------------------------------------------

local function offer(player: Player, kind: string, productKey: string)
	local session = MonetizationState.peek(player)
	if not session or not player.Parent then
		return
	end
	local cfg = MonetizationConfig.Offers
	local now = os.clock()
	if now - session.JoinedAt < cfg.QuietSeconds or session.OffersShown >= cfg.MaxPerSession then
		return
	end
	local last = session.LastOffer[kind]
	if last and now - last < cfg.CooldownSeconds then
		return
	end
	session.LastOffer[kind] = now
	session.OffersShown += 1
	offerRemote:FireClient(player, kind, productKey)
end

local function superSoapKey(player: Player): string
	local saved = MonetizationState.saved(player)
	return if saved and not saved.Once.SuperSoapStarter then "SuperSoapStarter" else "SuperSoap"
end

-- Hooks ---------------------------------------------------------------------------------

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

local function luckyActive(player: Player): boolean
	local saved = MonetizationState.saved(player)
	local session = MonetizationState.peek(player)
	if saved and session and saved.LuckyLeft > 0 then
		session.LuckyRolled = true -- this walk-in's roll used the boost
		return true
	end
	return false
end

local function connectHooks()
	Hooks.modify("CleaningPower", function(power: number, player: Player)
		if MonetizationState.soapActive(player) then
			return power * MonetizationConfig.SuperSoap.PowerMultiplier
		end
		return power
	end)

	Hooks.modify("IncomeMultiplier", function(mult: number, player: Player)
		if MonetizationState.ownsPass(player, "VIPKeeper") then
			return mult * MonetizationConfig.VIP.IncomeMultiplier
		end
		return mult
	end)

	Hooks.modify("SpawnWeight", function(weight: number, player: Player, species: string)
		if not luckyActive(player) then
			return weight
		end
		local def = AnimalConfig.Animals[species]
		local rarity = def and RarityConfig.ByKey[def.Rarity]
		if rarity and rarity.Order >= MonetizationConfig.LuckySoap.MinRarityOrder then
			return weight * MonetizationConfig.LuckySoap.SpawnWeightMultiplier
		end
		return weight
	end)

	Hooks.modify("MutationWeight", function(weight: number, player: Player, mutation: string)
		if mutation ~= "Normal" and luckyActive(player) then
			return weight * MonetizationConfig.LuckySoap.MutationWeightMultiplier
		end
		return weight
	end)

	Hooks.on("WashStarted", function(player: Player, info: Hooks.WashInfo)
		local session = MonetizationState.peek(player)
		local saved = MonetizationState.saved(player)
		if not session or not saved then
			return
		end
		-- Lucky Soap counts the walk-ins that were rolled with it (not the fixed first animal).
		if session.LuckyRolled then
			session.LuckyRolled = false
			saved.LuckyLeft = math.max(0, saved.LuckyLeft - 1)
			PlayerDataService.markDirty(player)
			MonetizationState.push(player)
			if saved.LuckyLeft == 0 then
				MonetizationState.notify(player, "Lucky Soap used up!", true)
			end
		end
		-- Super Soap offer: a big animal that's still mostly dirty a few seconds in.
		local def = AnimalConfig.Animals[info.Species]
		local cfg = MonetizationConfig.Offers
		if def and def.WashTimeMultiplier >= cfg.BigAnimalWashTime then
			task.delay(cfg.SuperSoapCheckDelay, function()
				local job = CleaningService.getActiveJob(player)
				if
					job
					and job.Id == info.JobId
					and job.Progress < cfg.SuperSoapMaxProgress
					and not MonetizationState.soapActive(player)
				then
					offer(player, "SuperSoap", superSoapKey(player))
				end
			end)
		end
	end)

	-- From the Tension feature, once per wash when patience drops under 20%.
	Hooks.on("PatienceLow", function(player: any, _jobId: any, _fraction: any)
		if isPlayer(player) then
			offer(player, "CalmTreat", "CalmTreat")
		end
	end)

	Hooks.on("PlayerLoaded", function(player: Player)
		if not player.Parent then
			return
		end
		local session = MonetizationState.session(player)
		local saved = MonetizationState.saved(player)
		if not saved then
			return
		end
		if session.SoapEndsAt == 0 and saved.SuperSoapLeft > 0 then
			session.SoapEndsAt = Workspace:GetServerTimeNow() + saved.SuperSoapLeft
		end
		for key in saved.Passes do
			MonetizationGrants.applyPass(player, key)
		end
		MonetizationState.push(player)
		-- Live ownership; a failed check just leaves the pass off until they rejoin.
		for _, pass in MonetizationConfig.Passes do
			if pass.Id ~= 0 and not MonetizationState.ownsPass(player, pass.Key) then
				task.spawn(function()
					local ok, owns = pcall(function()
						return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.Id)
					end)
					if ok and owns and player.Parent then
						MonetizationGrants.applyPass(player, pass.Key)
						MonetizationState.push(player)
					elseif not ok then
						warn(`[Monetization] Game pass check failed for {player.Name}: {owns}`)
					end
				end)
			end
		end
	end)

	-- Final Super Soap time for the leave-save (before any yield, per the Hooks contract).
	Hooks.on("PlayerLeaving", function(player: Player)
		local session = MonetizationState.peek(player)
		local saved = MonetizationState.saved(player)
		if session and saved and session.SoapEndsAt > 0 then
			saved.SuperSoapLeft = math.max(0, session.SoapEndsAt - Workspace:GetServerTimeNow())
		end
	end)
end

-- Background loop -------------------------------------------------------------------------

-- Super Soap countdown (1 s), queued animal delivery, and limited stock refresh.
local function runLoop()
	local sinceDelivery = 0
	local sinceStock = math.huge
	while true do
		local dt = task.wait(1)
		sinceDelivery += dt
		sinceStock += dt
		local now = Workspace:GetServerTimeNow()
		for _, player in MonetizationState.players() do
			local session = MonetizationState.peek(player)
			local saved = MonetizationState.saved(player)
			if session and saved and session.SoapEndsAt > 0 then
				saved.SuperSoapLeft = math.max(0, session.SoapEndsAt - now)
				PlayerDataService.markDirty(player)
				if saved.SuperSoapLeft <= 0 then
					session.SoapEndsAt = 0
					MonetizationState.notify(player, "Super Soap ran out!", false)
					MonetizationState.push(player)
				end
			end
		end
		if sinceDelivery >= MonetizationConfig.PendingDeliverySeconds then
			sinceDelivery = 0
			for _, player in MonetizationState.players() do
				task.spawn(MonetizationGrants.deliverPending, player)
			end
		end
		if sinceStock >= MonetizationConfig.StockRefreshSeconds then
			sinceStock = 0
			for _, product in MonetizationConfig.Products do
				if product.Kind == "Limited" then
					task.spawn(MonetizationStock.refresh, product.Key)
				end
			end
		end
	end
end

function Monetization.init()
	for _, product in MonetizationConfig.Products do
		if product.Id ~= 0 then
			productsById[product.Id] = product
		end
	end
	for _, pass in MonetizationConfig.Passes do
		if pass.Id ~= 0 then
			passesById[pass.Id] = pass
		end
	end

	offerRemote = Remotes.event("MonetizationOffer")
	Remotes.event("MonetizationState")
	Remotes.event("MonetizationNotice")
	local stockRemote = Remotes.event("MonetizationStock")
	Remotes.event("MonetizationBuy").OnServerEvent:Connect(onBuy)
	Remotes.func("GetMonetizationState").OnServerInvoke = function(player: Player)
		if not MonetizationState.allow(player, "State", MonetizationConfig.StateCooldown) then
			return nil
		end
		return MonetizationState.payload(player)
	end

	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			local pass = passesById[passId]
			if purchased and pass and player.Parent then
				MonetizationGrants.grantPass(player, pass.Key)
			end
		end
	)

	MonetizationStock.onChanged(function(key: string, left: number)
		stockRemote:FireAllClients(key, left)
	end)

	connectHooks()

	Players.PlayerAdded:Connect(function(player)
		MonetizationState.session(player)
	end)
	for _, player in Players:GetPlayers() do
		MonetizationState.session(player)
	end
	Players.PlayerRemoving:Connect(MonetizationState.release)

	task.spawn(runLoop)
end

return Monetization
