-- What each paid item does once it's paid for: boosts, cash, the limited animal (into the cache,
-- or queued until a slot frees) and game pass effects (VIP tag, Fire-Hose Rig unlock).
-- Called from Monetization for real receipts and Studio-simulated purchases alike.
-- Part of the Monetization feature (no init of its own).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Services = script.Parent.Parent.Services
local AnimalService = require(Services.AnimalService)
local BayService = require(Services.BayService)
local CleanGateService = require(Services.CleanGateService)
local CleaningService = require(Services.CleaningService)
local EconomyService = require(Services.EconomyService)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)
local ZooService = require(Services.ZooService)
local MonetizationState = require(script.Parent.MonetizationState)
local MonetizationStock = require(script.Parent.MonetizationStock)

type Product = MonetizationConfig.Product

local MonetizationGrants = {}

local warnedBuild: { [string]: boolean } = {}

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local hours = s // 3600
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, (s % 3600) // 60, s % 60)
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Super Soap seconds left, whether or not the session timer has started yet.
function MonetizationGrants.soapLeft(player: Player): number
	local session = MonetizationState.peek(player)
	if session and session.SoapEndsAt > 0 then
		return math.max(0, session.SoapEndsAt - Workspace:GetServerTimeNow())
	end
	local saved = MonetizationState.saved(player)
	return if saved then saved.SuperSoapLeft else 0
end

function MonetizationGrants.autoCollectLeft(player: Player): number
	local session = MonetizationState.peek(player)
	if session and session.AutoCollectEndsAt > 0 then
		return math.max(0, session.AutoCollectEndsAt - Workspace:GetServerTimeNow())
	end
	local saved = MonetizationState.saved(player)
	return if saved then saved.AutoCollectLeft else 0
end

-- Limited animals --------------------------------------------------------------------------

-- A bought animal can join the cache when there's a slot that the bay isn't about to fill:
-- the bay checks for room before an animal walks in and then assumes it still fits, so with
-- one free slot we only deliver while no animal is on its way through the bay.
local function canDeliver(player: Player): boolean
	local data = PlayerDataService.get(player)
	local snapshot = BayService.getSnapshot(player)
	if not data or not snapshot then
		return false
	end
	local free = GameConfig.Cache.Slots - #data.Cache
	if free >= 2 then
		return true
	end
	return free == 1 and (snapshot.State == "Empty" or snapshot.State == "CacheFull")
end

local function deliver(player: Player, species: string, mutation: string): boolean
	if not AnimalConfig.Animals[species] or not canDeliver(player) then
		return false
	end
	-- Build first: an animal that can't be built stays queued instead of an invisible cache entry.
	local ok, model = pcall(AnimalService.buildZooAnimal, species, mutation)
	if not ok then
		if not warnedBuild[species] then
			warnedBuild[species] = true
			warn(`[Monetization] Could not build {species}; it stays queued: {model}`)
		end
		return false
	end
	local record, slot = ZooService.addToCache(player, species, mutation)
	if not record then
		model:Destroy()
		return false
	end
	if slot then
		model:PivotTo(slot)
	end
	ZooService.adoptIntoCache(player, record, model)
	ZooService.discover(player, species, mutation)
	return true
end

-- Delivers queued animals while there's room. Returns how many were delivered.
function MonetizationGrants.deliverPending(player: Player): number
	local saved = MonetizationState.saved(player)
	if not saved or #saved.PendingAnimals == 0 then
		return 0
	end
	local delivered = 0
	while #saved.PendingAnimals > 0 do
		local entry = saved.PendingAnimals[1]
		if not deliver(player, entry.Species, entry.Mutation) then
			break
		end
		table.remove(saved.PendingAnimals, 1)
		delivered += 1
		local def = AnimalConfig.Animals[entry.Species]
		MonetizationState.notify(player, `Your {def.DisplayName} is waiting in your cache!`, true)
	end
	if delivered > 0 then
		PlayerDataService.saveNow(player)
		MonetizationState.push(player)
	end
	return delivered
end

-- Not capped below its floor like a cash pack: this replaces a Robux purchase that can't be refunded.
local function compensate(player: Player, reason: string): (boolean, string?)
	local cfg = MonetizationConfig.SoldOutCompensation
	local amount = math.max(cfg.Floor, MonetizationState.cashAmount(player, cfg))
	if not EconomyService.addCoins(player, amount) then
		return false, nil
	end
	return true, `{reason} You got {UIStyle.formatMoney(amount)} instead.`
end

-- Yields (global stock). Returns false to leave the receipt unprocessed; claiming is idempotent
-- per purchase, so the retry never takes a second unit.
local function grantLimited(
	player: Player,
	product: Product,
	purchaseId: string,
	simulated: boolean
): (boolean, string?)
	local species = product.Species
	local mutation = product.Mutation or "Normal"
	if not species or not AnimalConfig.Animals[species] then
		return compensate(player, `{product.DisplayName} isn't in the game right now.`)
	end
	-- Outside Studio a simulated purchase must not take a real unit from the global stock.
	local result = if simulated and not RunService:IsStudio()
		then MonetizationStock.claimTest(product.Key, purchaseId)
		else MonetizationStock.claim(product.Key, purchaseId)
	if result == "Error" then
		return false, nil
	end
	local saved = MonetizationState.saved(player)
	if not saved or not player.Parent then
		return false, nil -- left while claiming
	end
	if result == "SoldOut" then
		return compensate(player, `{product.DisplayName} sold out just before your purchase!`)
	end
	table.insert(saved.PendingAnimals, { Species = species, Mutation = mutation })
	PlayerDataService.markDirty(player)
	local name = AnimalConfig.Animals[species].DisplayName
	if MonetizationGrants.deliverPending(player) > 0 then
		return true, `You got a Limited {name}!`
	end
	return true, `You got a Limited {name}! It joins your cache when a slot is free.`
end

-- Products ------------------------------------------------------------------------------

-- Applies a paid product. Returns whether it was granted (false = try the receipt again later)
-- and a message for the player. Only the Limited kind yields.
function MonetizationGrants.product(
	player: Player,
	product: Product,
	purchaseId: string,
	simulated: boolean
): (boolean, string?)
	local saved = MonetizationState.saved(player)
	if not saved then
		return false, nil
	end
	local kind = product.Kind
	if kind == "Limited" then
		return grantLimited(player, product, purchaseId, simulated)
	end
	if product.OncePerPlayer then
		saved.Once[product.Key] = true
	end
	if kind == "SuperSoap" then
		local cfg = MonetizationConfig.SuperSoap
		local left = math.min(MonetizationGrants.soapLeft(player) + cfg.Seconds, cfg.MaxSeconds)
		saved.SuperSoapLeft = left
		local session = MonetizationState.peek(player)
		if session then
			session.SoapEndsAt = Workspace:GetServerTimeNow() + left
		end
		return true, `Super Soap! {cfg.PowerMultiplier}x cleaning for {clock(left)}`
	elseif kind == "CalmTreat" then
		Hooks.fire("CalmTreat", player, MonetizationConfig.CalmTreatSeconds)
		return true, `Calm Treat! Patience frozen for {MonetizationConfig.CalmTreatSeconds}s`
	elseif kind == "LuckySoap" then
		local cfg = MonetizationConfig.LuckySoap
		saved.LuckyLeft = math.min(saved.LuckyLeft + cfg.WalkIns, cfg.MaxWalkIns)
		return true, `Lucky Soap! Next {saved.LuckyLeft} walk-ins are luckier`
	elseif kind == "Cash" then
		local amount = MonetizationState.cashAmount(player, product)
		if not EconomyService.addCoins(player, amount) then
			return false, nil
		end
		return true, `+{UIStyle.formatMoney(amount)}!`
	elseif kind == "AutoCollect" then
		local add = product.Seconds or (2 * 3600)
		local left = math.min(
			MonetizationGrants.autoCollectLeft(player) + add,
			MonetizationConfig.AutoCollect.MaxSeconds
		)
		saved.AutoCollectLeft = left
		local session = MonetizationState.peek(player)
		if session then
			session.AutoCollectEndsAt = Workspace:GetServerTimeNow() + left
		end
		ZooService.collectAll(player)
		return true, `Auto-Collect for {clock(left)}! Your pens pay themselves.`
	elseif kind == "CleanNow" then
		if CleaningService.grantCleanNow(player) then
			return true, "Cleaned! That animal is spotless."
		end
		return true, "Clean Now is ready for the next animal your hose can't wash."
	end
	warn(`[Monetization] Unknown product kind {kind} for {product.Key}`)
	return false, nil
end

-- Game passes ---------------------------------------------------------------------------

local function addVipTag(character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") or head:FindFirstChild("VIPTag") then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "VIPTag"
	billboard.Size = UDim2.fromOffset(100, 36)
	billboard.StudsOffset = Vector3.new(0, 2.6, 0)
	billboard.MaxDistance = 80
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = billboard
	UIStyle.text(label, MonetizationConfig.VIP.TagColor, nil, 3)
	label.Text = MonetizationConfig.VIP.TagText
	local shine = Instance.new("UIGradient")
	shine.Rotation = 90
	shine.Color = ColorSequence.new(Color3.fromRGB(255, 250, 200), Color3.fromRGB(255, 170, 20))
	shine.Parent = label
	billboard.Parent = head
end

local function unlockTopHose(player: Player)
	local data = PlayerDataService.get(player)
	local top = #ToolConfig
	if data and data.ToolTier < top then
		local previous = data.ToolTier
		data.ToolTier = top
		CleanGateService.onTiersGained(player, previous, top)
		PlayerDataService.saveNow(player)
		EconomyService.sendTool(player)
		CleaningService.refreshHose(player)
	end
end

-- Turns on a pass's effects for this session. Safe to call more than once.
function MonetizationGrants.applyPass(player: Player, key: string)
	local session = MonetizationState.peek(player)
	if not session or not player.Parent then
		return
	end
	local first = not session.OwnedPasses[key]
	session.OwnedPasses[key] = true
	if key == "VIPKeeper" and first then
		table.insert(session.Connections, player.CharacterAdded:Connect(addVipTag))
		if player.Character then
			task.spawn(addVipTag, player.Character)
		end
	elseif key == "FireHoseRig" then
		unlockTopHose(player)
	elseif key == "AutoCollectForever" and first then
		ZooService.collectAll(player)
	end
end

-- A pass was bought (or simulated): remember it in the profile too, then apply it. A simulated
-- pass on a live server only lasts the session, so it never outlives the switch to real ids.
function MonetizationGrants.grantPass(player: Player, key: string, simulated: boolean)
	local saved = MonetizationState.saved(player)
	if saved and (not simulated or RunService:IsStudio()) then
		saved.Passes[key] = true
		PlayerDataService.saveNow(player)
	end
	MonetizationGrants.applyPass(player, key)
	local pass = MonetizationConfig.PassesByKey[key]
	MonetizationState.notify(player, `{pass.DisplayName} unlocked!`, true)
	MonetizationState.push(player)
end

return MonetizationGrants
