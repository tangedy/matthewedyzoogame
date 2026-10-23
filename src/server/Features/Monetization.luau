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
--     (SpawnWeight / MutationWeight, counted down on WashStarted), Incredible Luck
--     (SpawnWeight for Rare+ while its timestamp lasts), VIP (IncomeMultiplier),
--     Calm Treat (fires "CalmTreat" for the Tension feature). Speed is a timed WalkSpeed buff.
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
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Parent.Services
local CleaningService = require(Services.CleaningService)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)
local Offline = require(script.Parent.LiveOps.Offline)
local ZooService = require(Services.ZooService)
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
local standByPlayer: { [Player]: Model } = {}
local purchaseFromStand: (Player, string) -> ()

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local hours = s // 3600
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, (s % 3600) // 60, s % 60)
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

-- One kiosk just left of pen 1. It sells timed auto-collect only; there is no forever pass.
local function ensureStand(bay: Model): Model?
	local zoo = bay:FindFirstChild("Zoo")
	local existing = zoo and zoo:FindFirstChild("AutoCollectStand")
	if existing and existing:IsA("Model") and existing:FindFirstChild("TimedCounter") then
		local forever = existing:FindFirstChild("ForeverCounter")
		if forever then
			forever:Destroy()
		end
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local pen = zoo and zoo:FindFirstChild("Pen1")
	local floor = pen and pen:FindFirstChild("Floor")
	if not zoo or not floor or not floor:IsA("BasePart") then
		return nil
	end
	local product = MonetizationConfig.ProductsByKey.AutoCollect2h
	local stand = Instance.new("Model")
	stand.Name = "AutoCollectStand"
	local base = floor.Position + Vector3.new(-floor.Size.X / 2 - 6, floor.Size.Y / 2 + 1.6, floor.Size.Z / 2)

	local function kiosk(
		name: string,
		promptName: string,
		title: string,
		price: string,
		color: Color3,
		offset: Vector3
	): BasePart
		local counter = Instance.new("Part")
		counter.Name = name
		counter.Anchored = true
		counter.Size = Vector3.new(4.2, 3.2, 2.6)
		counter.Position = base + offset
		counter.Color = color
		counter.Material = Enum.Material.SmoothPlastic
		counter.TopSurface = Enum.SurfaceType.Smooth
		counter.BottomSurface = Enum.SurfaceType.Smooth
		counter.Parent = stand
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Sign"
		billboard.Size = UDim2.fromOffset(180, 70)
		billboard.StudsOffset = Vector3.new(0, 3.2, 0)
		billboard.MaxDistance = 70
		billboard.Parent = counter
		local label = Instance.new("TextLabel")
		label.Name = "Title"
		label.Size = UDim2.fromScale(1, 1)
		label.Parent = billboard
		UIStyle.text(label, Color3.new(1, 1, 1), nil, 3)
		label.Text = `{title}\n{price}`
		local created = Instance.new("ProximityPrompt")
		created.Name = promptName
		created.ActionText = `Buy ({price})`
		created.ObjectText = title
		created.HoldDuration = 0.4
		created.MaxActivationDistance = 8
		created.RequiresLineOfSight = false
		created.KeyboardKeyCode = Enum.KeyCode.E
		created.Parent = counter
		return counter
	end

	kiosk(
		"TimedCounter",
		"TimedPrompt",
		"10 MIN",
		`{product.Robux} ROBUX`,
		Color3.fromRGB(70, 190, 90),
		Vector3.zero
	)
	stand.Parent = zoo
	return stand
end

local function promptOn(stand: Model, counterName: string, promptName: string): ProximityPrompt?
	local counter = stand:FindFirstChild(counterName)
	local prompt = counter and counter:FindFirstChild(promptName)
	if prompt and prompt:IsA("ProximityPrompt") then
		return prompt
	end
	return nil
end

local function refreshStand(player: Player)
	local stand = standByPlayer[player]
	if not stand or not stand.Parent then
		return
	end
	local timed = promptOn(stand, "TimedCounter", "TimedPrompt")
	local product = MonetizationConfig.ProductsByKey.AutoCollect2h
	if timed then
		timed.Enabled = true
		timed.ObjectText = "10 MIN"
		local sign = timed.Parent and timed.Parent:FindFirstChild("Sign")
		local title = sign and sign:FindFirstChild("Title")
		if title and title:IsA("TextLabel") then
			title.Text = `10 MIN\n{product.Robux} ROBUX`
		end
		local left = MonetizationGrants.autoCollectLeft(player)
		timed.ActionText = if left > 0
			then `Add 10 minutes ({product.Robux} ROBUX) {clock(left)} left`
			else `Buy ({product.Robux} ROBUX)`
	end
end

local function bindPrompt(prompt: ProximityPrompt, player: Player, key: string)
	if prompt:GetAttribute("Bound") then
		return
	end
	prompt:SetAttribute("Bound", true)
	prompt.Triggered:Connect(function(who: Player)
		if who == player then
			purchaseFromStand(player, key)
		end
	end)
end

local function bindStand(player: Player, bay: Model)
	local stand = ensureStand(bay)
	if stand then
		standByPlayer[player] = stand
		local timed = promptOn(stand, "TimedCounter", "TimedPrompt")
		if timed then
			bindPrompt(timed, player, "AutoCollect2h")
		end
		refreshStand(player)
	end
end

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
	local ok, granted, message = pcall(MonetizationGrants.product, player, product, purchaseId, simulated)
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
	local session = MonetizationState.peek(player)
	if session then
		session.PendingOnce[product.Key] = nil
		if product.Kind == "OfflineDouble" then
			session.PendingOffline = false
		end
	end
	table.insert(saved.Receipts, purchaseId)
	while #saved.Receipts > MonetizationConfig.ReceiptsKept do
		table.remove(saved.Receipts, 1)
	end
	local pasture = MonetizationState.unlockPasture(player)
	PlayerDataService.saveNow(player)
	if pasture then
		local extra = "Medium cages unlocked!"
		message = if message then `{message} {extra}` else extra
	end
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
	local session = MonetizationState.peek(player)
	if not session then
		return
	end
	if product.OncePerPlayer and saved.Once[product.Key] then
		MonetizationState.notify(player, "You already used that offer.", false)
		return
	end
	-- A second intro prompt opened before the first receipt lands would also get the intro price.
	if product.OncePerPlayer and session.PendingOnce[product.Key] then
		MonetizationState.notify(player, "Finish your other purchase first.", false)
		return
	end
	-- Without a wash in progress the treat would do nothing.
	if product.Kind == "CalmTreat" and not CleaningService.getActiveJob(player) then
		MonetizationState.notify(player, "Start washing an animal first!", false)
		return
	end
	-- The price is the animal in the bay. A cheaper product cannot clean a rarer one.
	if product.Kind == "CleanNow" then
		local steps = CleaningService.blockedSteps(player)
		local expected = if steps ~= nil then MonetizationConfig.productForCleanSteps(steps) else nil
		if not expected or expected.Key ~= product.Key then
			MonetizationState.notify(player, "That price doesn't match the animal in your bay.", false)
			return
		end
	end
	if product.Kind == "HoseTier" then
		local data = PlayerDataService.get(player)
		if not data or data.ToolTier + 1 ~= product.ToolTier then
			MonetizationState.notify(player, "That hose isn't your next upgrade.", false)
			return
		end
	end
	if product.Kind == "OfflineDouble" then
		if session.PendingOffline then
			MonetizationState.notify(player, "Finish your other purchase first.", false)
			return
		end
		if Offline.peekDouble(player) < 1 then
			MonetizationState.notify(player, "Nothing to double right now.", false)
			return
		end
		session.PendingOffline = true
	end
	if product.Kind == "Truck" then
		-- Only while the truck is parked at their zoo; remember exactly what they're buying, so a
		-- receipt that lands after the truck drives off still delivers that animal.
		local data = PlayerDataService.get(player)
		local truck = data and data.Extra.Truck
		local offer = if typeof(truck) == "table" then truck.Offer else nil
		if typeof(offer) ~= "table" or (tonumber(offer.Expires) or 0) < os.time() then
			MonetizationState.notify(player, "The delivery truck has already left!", false)
			return
		end
		truck.Bought = { Species = offer.Species, Mutation = offer.Mutation }
		PlayerDataService.markDirty(player)
	end
	if product.Kind == "SidePasture" and MonetizationState.sidePastureOpen(player) then
		MonetizationState.notify(player, "You already own that large cage.", false)
		return
	end
	if product.Kind == "Limited" then
		if not (product.Species and AnimalConfig.Animals[product.Species]) then
			MonetizationState.notify(player, "Coming soon!", false)
			return
		end
		-- Robux can't be refunded, so check the stock before prompting (and again at receipt time).
		-- Stock is never restocked, so a known 0 is final; only an unknown stock is read again.
		local left = MonetizationStock.remaining(product.Key)
		if left == nil then
			left = MonetizationStock.refresh(product.Key, MonetizationConfig.StockRecheckSeconds)
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
			session.PendingOffline = false
			MonetizationState.notify(player, "[TEST] Purchase could not be granted right now.", false)
		end
	elseif product.Id ~= 0 then
		if product.OncePerPlayer then
			session.PendingOnce[product.Key] = true
		end
		MarketplaceService:PromptProductPurchase(player, product.Id)
	else
		session.PendingOffline = false
		MonetizationState.notify(player, "This item isn't on sale yet.", false)
	end
end

local function buyPass(player: Player, pass: Pass)
	if MonetizationState.ownsPass(player, pass.Key) then
		MonetizationState.notify(player, `You already own {pass.DisplayName}!`, false)
		return
	end
	if MonetizationState.shouldSimulate(player, pass.Id) then
		MonetizationGrants.grantPass(player, pass.Key, true)
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

purchaseFromStand = onBuy

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
		local boosted = weight
		local def = AnimalConfig.Animals[species]
		local rarity = def and RarityConfig.ByKey[def.Rarity]
		if luckyActive(player) and rarity and rarity.Order >= MonetizationConfig.LuckySoap.MinRarityOrder then
			boosted *= MonetizationConfig.LuckySoap.SpawnWeightMultiplier
		end
		local saved = MonetizationState.saved(player)
		local luck = MonetizationConfig.IncredibleLuck
		if saved and saved.LuckEndsAt > os.time() and rarity and rarity.Order >= luck.MinRarityOrder then
			boosted *= luck.SpawnWeightMultiplier
		end
		return boosted
	end)

	Hooks.modify("MutationWeight", function(weight: number, player: Player, mutation: string)
		if mutation ~= "Normal" and luckyActive(player) then
			return weight * MonetizationConfig.LuckySoap.MutationWeightMultiplier
		end
		return weight
	end)

	Hooks.modify("VariantOneIn", function(oneIn: number, player: Player, mutation: string): number
		if mutation ~= "Normal" and typeof(oneIn) == "number" and oneIn > 1 and luckyActive(player) then
			return math.max(1, math.floor(oneIn / MonetizationConfig.LuckySoap.MutationWeightMultiplier))
		end
		return oneIn
	end)

	-- Registered a frame later so it runs after the NextAnimal modifiers other features add in
	-- their init: a walk-in replaced by an override wasn't rolled with Lucky Soap, so it mustn't
	-- use a charge.
	task.defer(function()
		Hooks.modify("NextAnimal", function(override: any, player: Player, _isFirst: boolean)
			if typeof(override) == "table" and AnimalConfig.Animals[override.Species] then
				local session = MonetizationState.peek(player)
				if session then
					session.LuckyRolled = false
				end
			end
			return override
		end)
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
	-- The delivery truck's prompt (DeliveryTruck feature) asks to buy its animal.
	Hooks.on("TruckBuyRequested", function(player: Player)
		local product = MonetizationConfig.ProductsByKey.TruckAnimal
		if product then
			buyProduct(player, product)
		end
	end)
	Hooks.on("PatienceLow", function(player: any, _jobId: any, _fraction: any)
		if isPlayer(player) then
			offer(player, "CalmTreat", "CalmTreat")
		end
	end)

	Hooks.on("BayAssigned", function(player: Player, bay: Model)
		bindStand(player, bay)
	end)

	Hooks.on("IncomeTick", function(player: Player)
		if MonetizationState.autoCollectActive(player) then
			ZooService.collectAll(player)
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
		if session.AutoCollectEndsAt == 0 and saved.AutoCollectLeft > 0 then
			session.AutoCollectEndsAt = Workspace:GetServerTimeNow() + saved.AutoCollectLeft
		end
		for key in saved.Passes do
			MonetizationGrants.applyPass(player, key)
		end
		MonetizationGrants.syncBuffs(player)
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
						if MonetizationState.unlockPasture(player) then
							PlayerDataService.saveNow(player)
							MonetizationState.notify(player, "Medium cages unlocked!", true)
						end
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
		if session and saved and session.AutoCollectEndsAt > 0 then
			saved.AutoCollectLeft = math.max(0, session.AutoCollectEndsAt - Workspace:GetServerTimeNow())
		end
		standByPlayer[player] = nil
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
			MonetizationGrants.syncBuffs(player)
			if session and saved and session.SoapEndsAt > 0 then
				saved.SuperSoapLeft = math.max(0, session.SoapEndsAt - now)
				PlayerDataService.markDirty(player)
				if saved.SuperSoapLeft <= 0 then
					session.SoapEndsAt = 0
					MonetizationState.notify(player, "Super Soap ran out!", false)
					MonetizationState.push(player)
				end
			end
			local timedCollect = session and saved and session.AutoCollectEndsAt > 0
			if timedCollect then
				saved.AutoCollectLeft = math.max(0, session.AutoCollectEndsAt - now)
				PlayerDataService.markDirty(player)
				if saved.AutoCollectLeft <= 0 then
					session.AutoCollectEndsAt = 0
					MonetizationState.notify(player, "Auto-Collect ran out!", false)
					MonetizationState.push(player)
				end
			end
			refreshStand(player)
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
				MonetizationGrants.grantPass(player, pass.Key, false)
			end
		end
	)
	-- A closed or failed intro prompt frees the once-only product again; a successful one stays
	-- pending until its receipt is processed.
	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, purchased: boolean)
			local product = productsById[productId]
			local player = Players:GetPlayerByUserId(userId)
			local session = player and MonetizationState.peek(player)
			if product and session and not purchased then
				session.PendingOnce[product.Key] = nil
				if product.Kind == "OfflineDouble" then
					session.PendingOffline = false
				end
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
	Players.PlayerRemoving:Connect(function(player)
		MonetizationGrants.release(player)
		MonetizationState.release(player)
	end)

	task.spawn(runLoop)
end

return Monetization
