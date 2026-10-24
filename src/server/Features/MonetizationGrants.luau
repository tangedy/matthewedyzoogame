-- What each paid item does once it's paid for: boosts, cash, the limited animal (into the cache,
-- or queued until a slot frees) and the VIP game pass. Speed and Incredible Luck are timed
-- consumables. A Janitor owns the speed boost's respawn listener and expiry timer.
-- Called from Monetization for real receipts and Studio-simulated purchases alike.
-- Part of the Monetization feature (no init of its own).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Services = script.Parent.Parent.Services
local AnimalService = require(Services.AnimalService)
local BayService = require(Services.BayService)
local CleaningService = require(Services.CleaningService)
local EconomyService = require(Services.EconomyService)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)
local ZooService = require(Services.ZooService)
local MonetizationState = require(script.Parent.MonetizationState)
local MonetizationStock = require(script.Parent.MonetizationStock)
local Offline = require(script.Parent.LiveOps.Offline)

type Product = MonetizationConfig.Product

local MonetizationGrants = {}

local warnedBuild: { [string]: boolean } = {}

-- Stacks `add` seconds onto an absolute expiry, never past `max` seconds from now.
local function extendUnix(current: number, add: number, max: number): number
	local now = os.time()
	local base = if current > now then current else now
	return math.min(base + add, now + max)
end

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

-- A bought animal goes straight into the cache, pushing out a free animal waiting there.
-- It's marked Paid, so a later wash never pushes it out; it only waits if another paid
-- animal is already in the slot.
local function canDeliver(player: Player): boolean
	return BayService.getSnapshot(player) ~= nil
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
	local record, slot = ZooService.addToCache(player, species, mutation, { Paid = true, Evict = true })
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
	local side = if species == "Axolotl" then MonetizationState.unlockSidePasture(player) else false
	local bonus = if side then " Large cage unlocked!" else ""
	if MonetizationGrants.deliverPending(player) > 0 then
		return true, `You got a Limited {name}!{bonus}`
	end
	return true, `You got a Limited {name}! It joins your cache when a slot is free.{bonus}`
end

-- The delivery truck's animal: the offer recorded when the purchase was prompted
-- (data.Extra.Truck.Bought, written by Monetization). It goes straight into the player's
-- hands; only if they can't hold it right now is it queued like a limited.
local function grantTruck(player: Player): (boolean, string?)
	local data = PlayerDataService.get(player)
	local truck = data and data.Extra.Truck
	local bought = if typeof(truck) == "table" then truck.Bought else nil
	if typeof(bought) ~= "table" or typeof(bought.Species) ~= "string" or not AnimalConfig.Animals[bought.Species] then
		return compensate(player, "That truck animal isn't available any more.")
	end
	local saved = MonetizationState.saved(player)
	if not saved then
		return false, nil
	end
	local mutation = if typeof(bought.Mutation) == "string" and MutationConfig.ByKey[bought.Mutation]
		then bought.Mutation
		else MutationConfig.Default
	truck.Bought = nil
	local name = AnimalConfig.Animals[bought.Species].DisplayName
	if ZooService.giveToCarry(player, bought.Species, mutation) then
		ZooService.discover(player, bought.Species, mutation)
		PlayerDataService.saveNow(player)
		Hooks.fire("TruckPurchased", player)
		return true, `You got the {name}! Take it to a pen.`
	end
	table.insert(saved.PendingAnimals, { Species = bought.Species, Mutation = mutation })
	PlayerDataService.markDirty(player)
	Hooks.fire("TruckPurchased", player)
	if MonetizationGrants.deliverPending(player) > 0 then
		return true, nil -- deliverPending already told them it's in the cache
	end
	return true, `You got the {name}! It joins your cache once you've moved the animal there.`
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
	elseif kind == "Truck" then
		return grantTruck(player)
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
	elseif kind == "SpeedBoost" then
		local cfg = MonetizationConfig.Speed
		saved.SpeedEndsAt = extendUnix(saved.SpeedEndsAt, cfg.Seconds, cfg.MaxSeconds)
		MonetizationGrants.watchSpeed(player)
		return true, `{cfg.Multiplier}x Speed for {clock(saved.SpeedEndsAt - os.time())}!`
	elseif kind == "IncredibleLuck" then
		local cfg = MonetizationConfig.IncredibleLuck
		saved.LuckEndsAt = extendUnix(saved.LuckEndsAt, cfg.Seconds, cfg.MaxSeconds)
		return true, `Incredible Luck for {clock(saved.LuckEndsAt - os.time())}! Rare animals show up more.`
	elseif kind == "OfflineDouble" then
		local data = PlayerDataService.get(player)
		if not data or #data.Animals == 0 then
			return false, nil -- retry once a pen is earning, so the Robux purchase is not lost
		end
		local amount = Offline.peekDouble(player)
		if amount < 1 then
			return compensate(player, "That offline bonus was already used.")
		end
		ZooService.addToPads(player, amount)
		Offline.takeDouble(player)
		if player.Parent then
			Remotes.event("LiveOpsOfflineDoubled"):FireClient(player, amount * 2)
		end
		if Offline.onEarned then
			Offline.onEarned(player, amount)
		end
		return true, `Offline earnings doubled! +{UIStyle.formatMoney(amount)}`
	elseif kind == "HoseTier" then
		local tier = product.ToolTier
		if not tier or not EconomyService.grantToolTier(player, tier) then
			return compensate(player, "That hose isn't your next upgrade.")
		end
		local tool = ToolConfig[tier]
		return true, `Upgraded to {if tool then tool.Name else "the next hose"}!`
	elseif kind == "AutoCollect" then
		local add = product.Seconds or (2 * 3600)
		local left =
			math.min(MonetizationGrants.autoCollectLeft(player) + add, MonetizationConfig.AutoCollect.MaxSeconds)
		saved.AutoCollectLeft = left
		local session = MonetizationState.peek(player)
		if session then
			session.AutoCollectEndsAt = Workspace:GetServerTimeNow() + left
		end
		ZooService.collectAll(player)
		return true, `Auto-Collect for {clock(left)}! Your pens pay themselves.`
	elseif kind == "CleanNow" then
		local paidSteps = product.CleanSteps or 0
		if CleaningService.grantCleanNow(player, paidSteps) then
			return true, "Cleaned! That animal is spotless."
		end
		return true, "Clean Now is saved for the next animal this price covers."
	elseif kind == "SidePasture" then
		MonetizationState.unlockSidePasture(player)
		return true, "Large cage unlocked!"
	end
	warn(`[Monetization] Unknown product kind {kind} for {product.Key}`)
	return false, nil
end

-- Game passes ---------------------------------------------------------------------------

-- 2x speed. One Janitor per player holds the respawn listener and the expiry timer.
-- Cleanup restores nothing by itself; clearSpeed puts WalkSpeed back, then Cleanup
-- drops the listener so a later spawn is not boosted.
local speedJanitors: { [Player]: Janitor.Janitor } = {}
local speedGeneration: { [Player]: number } = {}
local speedWatching: { [Player]: number } = {}

local function speedActive(player: Player): boolean
	local saved = MonetizationState.saved(player)
	return saved ~= nil and saved.SpeedEndsAt > os.time()
end

local function clearSpeed(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local base = humanoid:GetAttribute("SpeedBoostBase")
	if typeof(base) == "number" and base > 0 then
		humanoid.WalkSpeed = base
	end
	humanoid:SetAttribute("SpeedBoost", nil)
	humanoid:SetAttribute("SpeedBoostBase", nil)
end

local function applySpeed(player: Player, character: Model)
	if not speedActive(player) then
		return
	end
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") or not speedActive(player) or not player.Parent then
		return
	end
	local function boost()
		if not humanoid.Parent or not speedActive(player) then
			return
		end
		local base = humanoid:GetAttribute("SpeedBoostBase")
		if typeof(base) ~= "number" or base <= 0 then
			local speed = humanoid.WalkSpeed
			if speed <= 0 then
				return
			end
			humanoid:SetAttribute("SpeedBoostBase", speed)
			base = speed
		end
		humanoid:SetAttribute("SpeedBoost", true)
		humanoid.WalkSpeed = (base :: number) * MonetizationConfig.Speed.Multiplier
	end
	boost()
	task.delay(0.5, boost)
end

local function dropSpeed(player: Player)
	speedGeneration[player] = (speedGeneration[player] or 0) + 1
	speedWatching[player] = nil
	local janitor = speedJanitors[player]
	if janitor then
		janitor:Cleanup()
	end
	clearSpeed(player)
end

-- Starts (or restarts) the timer when the saved expiry changes. Safe to call often.
function MonetizationGrants.watchSpeed(player: Player)
	local saved = MonetizationState.saved(player)
	if not saved or saved.SpeedEndsAt <= os.time() or not player.Parent then
		return
	end
	if speedWatching[player] == saved.SpeedEndsAt then
		return
	end
	speedWatching[player] = saved.SpeedEndsAt
	speedGeneration[player] = (speedGeneration[player] or 0) + 1
	local generation = speedGeneration[player]
	local janitor = speedJanitors[player]
	if not janitor then
		janitor = Janitor.new()
		speedJanitors[player] = janitor
	end
	janitor:Cleanup()
	janitor:Add(player.CharacterAdded:Connect(function(character)
		applySpeed(player, character)
	end))
	if player.Character then
		task.spawn(applySpeed, player, player.Character)
	end
	local ends = saved.SpeedEndsAt
	janitor:Add(
		task.delay(math.max(0, ends - os.time()), function()
			if speedGeneration[player] ~= generation then
				return
			end
			MonetizationGrants.syncBuffs(player)
		end),
		true
	)
end

-- Zeros expired timestamps, tears the speed boost down, and tells the player once.
function MonetizationGrants.syncBuffs(player: Player)
	local saved = MonetizationState.saved(player)
	if not saved or not player.Parent then
		return
	end
	local now = os.time()
	local changed = false
	if saved.SpeedEndsAt > 0 and saved.SpeedEndsAt <= now then
		saved.SpeedEndsAt = 0
		changed = true
		dropSpeed(player)
		MonetizationState.notify(player, "Speed boost ran out!", false)
	end
	if saved.LuckEndsAt > 0 and saved.LuckEndsAt <= now then
		saved.LuckEndsAt = 0
		changed = true
		MonetizationState.notify(player, "Incredible Luck ran out!", false)
	end
	if changed then
		PlayerDataService.markDirty(player)
		MonetizationState.push(player)
	elseif saved.SpeedEndsAt > now then
		MonetizationGrants.watchSpeed(player)
	end
end

function MonetizationGrants.release(player: Player)
	dropSpeed(player)
	speedJanitors[player] = nil
	speedGeneration[player] = nil
end

-- Turns on a pass's effects for this session. Safe to call more than once.
function MonetizationGrants.applyPass(player: Player, key: string)
	local session = MonetizationState.peek(player)
	if not session or not player.Parent then
		return
	end
	session.OwnedPasses[key] = true
	if key == "VIPKeeper" then
		player:SetAttribute("Vip", true)
		local head = player.Character and player.Character:FindFirstChild("Head")
		local tag = head and head:FindFirstChild("VIPTag")
		if tag then
			tag:Destroy()
		end
	end
end

-- A pass was bought (or simulated): remember it in the profile too, then apply it. A simulated
-- pass on a live server only lasts the session, so it never outlives the switch to real ids.
function MonetizationGrants.grantPass(player: Player, key: string, simulated: boolean)
	local saved = MonetizationState.saved(player)
	local pasture = false
	if saved and (not simulated or RunService:IsStudio()) then
		saved.Passes[key] = true
		pasture = MonetizationState.unlockPasture(player)
		PlayerDataService.saveNow(player)
	end
	MonetizationGrants.applyPass(player, key)
	local pass = MonetizationConfig.PassesByKey[key]
	local text = `{pass.DisplayName} unlocked!`
	if pasture then
		text ..= " Medium cages unlocked!"
	end
	MonetizationState.notify(player, text, true)
	MonetizationState.push(player)
end

return MonetizationGrants
