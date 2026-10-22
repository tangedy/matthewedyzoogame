-- The player's zoo, Steal a Brainrot style:
--   * Every washed animal walks into the bay's cache and waits there.
--   * The owner picks one up (it rides above their head) and carries it to a pen: an empty
--     pen takes it, an occupied pen swaps (the old animal is sold for cash).
--   * Animals in pens earn cash every second into the pen's collect pad; stepping on the
--     pad collects it. Animals can also be sold from the cache or a pen.
--   * Index: every species x mutation the player has washed.
-- Owns those parts of the profile. Only the bay owner can use their bay's prompts and pads.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local AnimalService = require(script.Parent.AnimalService)
local EconomyService = require(script.Parent.EconomyService)
local MutationPayout = require(script.Parent.MutationPayout)
local GuideService = require(script.Parent.GuideService)
local Hooks = require(script.Parent.Hooks)
local PlayerDataService = require(script.Parent.PlayerDataService)

type OwnedAnimal = PlayerDataService.OwnedAnimal
type CachedAnimal = PlayerDataService.CachedAnimal

type Zoo = {
	Bay: Model,
	PenModels: { [string]: Model }, -- animal id -> model standing in its pen
	CacheModels: { [string]: Model }, -- animal id -> model waiting in the cache
	CarriedId: string?, -- cache record currently being carried
	CarryModel: Model?,
	Connections: { RBXScriptConnection },
	PadDebounce: { [number]: number },
}

local ZooService = {}

local zoos: { [Player]: Zoo } = {}

local zooChanged = Remotes.event("ZooChanged")
local indexChanged = Remotes.event("IndexChanged")
local carryChanged = Remotes.event("CarryChanged")
local purchaseResult = Remotes.event("PurchaseResult")

-- Values -------------------------------------------------------------------------------

function ZooService.income(species: string, mutation: string): number
	local def = AnimalConfig.Animals[species]
	return def.Income * MutationPayout.multiplier(mutation)
end

function ZooService.washReward(species: string, mutation: string): number
	return math.floor(ZooService.income(species, mutation) * GameConfig.WashRewardSeconds)
end

function ZooService.sellValue(species: string, mutation: string): number
	return math.floor(ZooService.income(species, mutation) * GameConfig.SellValueSeconds)
end

function ZooService.label(species: string, mutation: string): string
	local def = AnimalConfig.Animals[species]
	return if mutation == MutationConfig.Default then def.DisplayName else `{mutation} {def.DisplayName}`
end

-- Helpers ------------------------------------------------------------------------------

local function penOf(zoo: Zoo, index: number): Model?
	local folder = zoo.Bay:FindFirstChild("Zoo")
	local pen = folder and folder:FindFirstChild("Pen" .. index)
	return if pen and pen:IsA("Model") then pen else nil
end

local function cacheSlot(zoo: Zoo, index: number): BasePart?
	local folder = zoo.Bay:FindFirstChild("Cache")
	local slot = folder and folder:FindFirstChild("Slot" .. index)
	return if slot and slot:IsA("BasePart") then slot else nil
end

local function nextExpansion(zooSize: number): { Pens: number, Price: number }?
	for _, step in GameConfig.Zoo.Expansions do
		if step.Pens > zooSize then
			return step
		end
	end
	return nil
end

local function findCached(data: PlayerDataService.SavedData, id: string): (CachedAnimal?, number?)
	for i, animal in data.Cache do
		if animal.Id == id then
			return animal, i
		end
	end
	return nil, nil
end

-- Cache records that are waiting in a slot (not the one being carried), oldest first.
-- Slot i shows waiting[i].
local function waitingRecords(zoo: Zoo, data: PlayerDataService.SavedData): { CachedAnimal }
	local waiting = {}
	for _, record in data.Cache do
		if record.Id ~= zoo.CarriedId then
			table.insert(waiting, record)
		end
	end
	return waiting
end

local function removeCached(data: PlayerDataService.SavedData, id: string)
	local _, index = findCached(data, id)
	if index then
		table.remove(data.Cache, index)
	end
end

local function animalInPen(data: PlayerDataService.SavedData, pen: number): (OwnedAnimal?, number?)
	for i, animal in data.Animals do
		if animal.Pen == pen then
			return animal, i
		end
	end
	return nil, nil
end

local function totalIncome(data: PlayerDataService.SavedData): number
	local sum = 0
	for _, animal in data.Animals do
		sum += ZooService.income(animal.Species, animal.Mutation)
	end
	return sum
end

function ZooService.getZooSummary(player: Player): Types.ZooSummary?
	local data = PlayerDataService.get(player)
	if not data then
		return nil
	end
	local step = nextExpansion(data.ZooSize)
	return {
		ZooSize = data.ZooSize,
		MaxPens = GameConfig.Zoo.MaxPens,
		Count = #data.Animals,
		NextExpansionPrice = step and step.Price,
		CacheCount = #data.Cache,
		CacheSlots = GameConfig.Cache.Slots,
		IncomePerSecond = totalIncome(data),
	}
end

local function sendZoo(player: Player)
	local summary = ZooService.getZooSummary(player)
	if summary then
		zooChanged:FireClient(player, summary)
	end
end

function ZooService.sendIndex(player: Player, newKey: string?)
	local data = PlayerDataService.get(player)
	if data then
		indexChanged:FireClient(player, data.Index, newKey)
	end
end

-- Visual state ------------------------------------------------------------------------

local function carriedRecord(player: Player): CachedAnimal?
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data or not zoo.CarriedId then
		return nil
	end
	return (findCached(data, zoo.CarriedId))
end

local function sendCarry(player: Player)
	local carried = carriedRecord(player)
	if carried then
		carryChanged:FireClient(player, {
			Label = ZooService.label(carried.Species, carried.Mutation),
			Rarity = AnimalConfig.Animals[carried.Species].Rarity,
			Mutation = carried.Mutation,
			IncomePerSecond = ZooService.income(carried.Species, carried.Mutation),
			SellValue = ZooService.sellValue(carried.Species, carried.Mutation),
		})
	else
		carryChanged:FireClient(player, nil)
	end
end

-- Pens: floor colour, labels, cash pads and the context-sensitive pen prompt.
local function refreshPens(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return
	end
	local carried = carriedRecord(player)
	for i = 1, GameConfig.Zoo.MaxPens do
		local pen = penOf(zoo, i)
		if not pen then
			continue
		end
		local animal = animalInPen(data, i)
		local locked = i > data.ZooSize
		local floor = pen:FindFirstChild("Floor") :: BasePart
		floor.Color = if locked then Color3.fromRGB(90, 90, 90) else Color3.fromRGB(120, 170, 80)
		local status = floor:FindFirstChild("Status")
		local text = status and status:FindFirstChild("Label") :: TextLabel?
		if text then
			text.Text = if locked then "LOCKED" elseif animal then "" else "EMPTY"
		end
		local pad = pen:FindFirstChild("CollectPad") :: BasePart?
		if pad then
			pad.Transparency = if locked then 1 else 0
			-- The client renders the counter (count-up, bounce, money pop) from these.
			pad:SetAttribute("Cash", if animal then math.floor(animal.Pending) else nil)
			pad:SetAttribute("Rate", if animal then ZooService.income(animal.Species, animal.Mutation) else nil)
		end

		local post = pen:FindFirstChild("GatePost")
		local prompt = post and post:FindFirstChild("PenPrompt") :: ProximityPrompt?
		if not prompt then
			continue
		end
		if locked or (not carried and not animal) then
			prompt.Enabled = false
		elseif carried then
			prompt.Enabled = true
			prompt.ObjectText = ZooService.label(carried.Species, carried.Mutation)
			if animal then
				local value = UIStyle.formatMoney(ZooService.sellValue(animal.Species, animal.Mutation))
				prompt.ActionText = `Swap (sell {ZooService.label(animal.Species, animal.Mutation)} {value})`
				prompt.HoldDuration = 0.5
			else
				prompt.ActionText = "Place"
				prompt.HoldDuration = 0
			end
		elseif animal then
			prompt.Enabled = true
			prompt.ObjectText = ZooService.label(animal.Species, animal.Mutation)
			prompt.ActionText = `Sell ({UIStyle.formatMoney(ZooService.sellValue(animal.Species, animal.Mutation))})`
			prompt.HoldDuration = 1 -- a hold, so animals aren't sold by accident
		end
	end

	local folder = zoo.Bay:FindFirstChild("Zoo")
	local counter = folder and folder:FindFirstChild("ExpandCounter")
	local expandPrompt = counter and counter:FindFirstChild("ExpandPrompt") :: ProximityPrompt?
	local step = nextExpansion(data.ZooSize)
	if expandPrompt then
		expandPrompt.Enabled = step ~= nil
		if step then
			expandPrompt.ActionText = `Expand to {step.Pens} pens ({UIStyle.formatMoney(step.Price)})`
		end
	end
end

-- Cache: waiting animals fill the slots in order; the carried one isn't in a slot.
local function refreshCache(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return
	end
	local list = waitingRecords(zoo, data)
	for i = 1, GameConfig.Cache.Slots do
		local slot = cacheSlot(zoo, i)
		if not slot then
			continue
		end
		local record = list[i]
		local waiting = record ~= nil
		local pickup = slot:FindFirstChild("PickupPrompt") :: ProximityPrompt?
		local sell = slot:FindFirstChild("SellPrompt") :: ProximityPrompt?
		if pickup then
			pickup.Enabled = waiting and zoo.CarriedId == nil
			if record then
				pickup.ObjectText = ZooService.label(record.Species, record.Mutation)
			end
		end
		if sell then
			sell.Enabled = waiting
			if record then
				sell.ObjectText = ZooService.label(record.Species, record.Mutation)
				sell.ActionText = `Sell ({UIStyle.formatMoney(ZooService.sellValue(record.Species, record.Mutation))})`
			end
		end
		local model = record and zoo.CacheModels[record.Id]
		if model then
			model:PivotTo(slot.CFrame)
		end
	end
end

local function refreshAll(player: Player)
	refreshPens(player)
	refreshCache(player)
	sendZoo(player)
	sendCarry(player)
end

local function placeInPen(zoo: Zoo, animal: OwnedAnimal, model: Model)
	local pen = penOf(zoo, animal.Pen)
	local slot = pen and pen:FindFirstChild("Slot") :: BasePart?
	model.Name = "ZooAnimal"
	model:SetAttribute("AnimalId", animal.Id)
	if slot then
		model:PivotTo(slot.CFrame)
	end
	model.Parent = pen or zoo.Bay
	zoo.PenModels[animal.Id] = model
end

local function buildCacheModel(zoo: Zoo, record: CachedAnimal)
	local model = AnimalService.buildZooAnimal(record.Species, record.Mutation)
	model.Name = "CachedAnimal"
	model:SetAttribute("AnimalId", record.Id)
	model.Parent = zoo.Bay:FindFirstChild("Cache") or zoo.Bay
	zoo.CacheModels[record.Id] = model
end

-- Carrying -----------------------------------------------------------------------------

local function dropCarry(player: Player)
	local zoo = zoos[player]
	if not zoo then
		return
	end
	if zoo.CarryModel then
		zoo.CarryModel:Destroy()
		zoo.CarryModel = nil
	end
	zoo.CarriedId = nil
end

-- Pushes the oldest waiting animal out of the cache so a new one fits. Paid animals are never
-- pushed out. Returns false if nothing could make room.
local function makeCacheRoom(player: Player): boolean
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return false
	end
	local list = waitingRecords(zoo, data)
	if #list < GameConfig.Cache.Slots then
		return true
	end
	for _, record in list do
		if not record.Paid then
			removeCached(data, record.Id)
			local model = zoo.CacheModels[record.Id]
			if model then
				zoo.CacheModels[record.Id] = nil
				AnimalService.poof(model)
			end
			PlayerDataService.markDirty(player)
			return true
		end
	end
	return false
end

-- Back in the cache (the carrier died or respawned, or chose Put Down). If the slot is taken,
-- the waiting animal leaves to make room for the one that was chosen.
local function returnCarryToCache(player: Player)
	local zoo = zoos[player]
	local record = carriedRecord(player)
	makeCacheRoom(player) -- while it's still carried, so it can't push itself out
	dropCarry(player)
	if zoo and record and not zoo.CacheModels[record.Id] then
		buildCacheModel(zoo, record)
	end
	refreshAll(player)
	GuideService.onCarryReturned(player)
end

local function pickUp(player: Player, slotIndex: number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local character = player.Character
	local hand = character
		and (character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")) :: BasePart?
	if not zoo or not data or zoo.CarriedId or not hand then
		return
	end
	local record = waitingRecords(zoo, data)[slotIndex]
	if not record then
		return
	end
	local cached = zoo.CacheModels[record.Id]
	if cached then
		cached:Destroy()
		zoo.CacheModels[record.Id] = nil
	end
	zoo.CarriedId = record.Id
	zoo.CarryModel = AnimalService.buildCarryModel(record.Species, record.Mutation, hand)
	refreshAll(player)
	GuideService.onPickedUp(player)
end

-- Put the carried animal into a pen. An occupied pen sells its animal first (plus any cash
-- still on its pad), which is the swap.
local function placeCarried(player: Player, penIndex: number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = carriedRecord(player)
	if not zoo or not data or not record or penIndex > data.ZooSize then
		return
	end
	local old, oldIndex = animalInPen(data, penIndex)
	if old and oldIndex then
		table.remove(data.Animals, oldIndex)
		EconomyService.addCoins(player, ZooService.sellValue(old.Species, old.Mutation) + math.floor(old.Pending))
		Hooks.fire("AnimalSold", player, old.Species, old.Mutation, ZooService.sellValue(old.Species, old.Mutation))
		local oldModel = zoo.PenModels[old.Id]
		if oldModel then
			zoo.PenModels[old.Id] = nil
			AnimalService.poof(oldModel)
		end
	end
	local _, cacheIndex = findCached(data, record.Id)
	if cacheIndex then
		table.remove(data.Cache, cacheIndex)
	end
	local animal: OwnedAnimal = {
		Id = record.Id,
		Species = record.Species,
		Mutation = record.Mutation,
		Pen = penIndex,
		Pending = 0,
	}
	table.insert(data.Animals, animal)
	dropCarry(player)
	placeInPen(zoo, animal, AnimalService.buildZooAnimal(animal.Species, animal.Mutation))
	PlayerDataService.saveNow(player)
	refreshAll(player)
	Hooks.fire("AnimalPlaced", player, animal)
	GuideService.onPlaced(player)
end

-- Sells the animal in hand for its sell value.
local function sellCarried(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = carriedRecord(player)
	if not zoo or not data or not record then
		return
	end
	removeCached(data, record.Id)
	dropCarry(player)
	local value = ZooService.sellValue(record.Species, record.Mutation)
	EconomyService.addCoins(player, value)
	Hooks.fire("AnimalSold", player, record.Species, record.Mutation, value)
	PlayerDataService.markDirty(player)
	refreshAll(player)
end

-- Put Down: back into the cache slot. Refused if the slot holds a paid animal.
local function putDownCarried(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data or not zoo.CarriedId then
		return
	end
	local list = waitingRecords(zoo, data)
	if #list >= GameConfig.Cache.Slots then
		for _, record in list do
			if record.Paid then
				purchaseResult:FireClient(player, false, "Your cache is full. Place it in a pen or sell it.")
				return
			end
		end
	end
	returnCarryToCache(player)
end

local function sellFromPen(player: Player, penIndex: number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return
	end
	local animal, index = animalInPen(data, penIndex)
	if not animal or not index then
		return
	end
	table.remove(data.Animals, index)
	EconomyService.addCoins(player, ZooService.sellValue(animal.Species, animal.Mutation) + math.floor(animal.Pending))
	Hooks.fire(
		"AnimalSold",
		player,
		animal.Species,
		animal.Mutation,
		ZooService.sellValue(animal.Species, animal.Mutation)
	)
	local model = zoo.PenModels[animal.Id]
	if model then
		zoo.PenModels[animal.Id] = nil
		AnimalService.poof(model)
	end
	PlayerDataService.markDirty(player)
	refreshAll(player)
end

local function sellFromCache(player: Player, slotIndex: number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = zoo and data and waitingRecords(zoo, data)[slotIndex]
	if not zoo or not data or not record then
		return
	end
	removeCached(data, record.Id)
	EconomyService.addCoins(player, ZooService.sellValue(record.Species, record.Mutation))
	Hooks.fire(
		"AnimalSold",
		player,
		record.Species,
		record.Mutation,
		ZooService.sellValue(record.Species, record.Mutation)
	)
	local model = zoo.CacheModels[record.Id]
	if model then
		zoo.CacheModels[record.Id] = nil
		AnimalService.poof(model)
	end
	PlayerDataService.markDirty(player)
	refreshAll(player)
end

local function collect(player: Player, penIndex: number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return
	end
	local now = os.clock()
	if (zoo.PadDebounce[penIndex] or 0) > now then
		return
	end
	zoo.PadDebounce[penIndex] = now + 0.5
	local animal = animalInPen(data, penIndex)
	if not animal or animal.Pending < 1 then
		return
	end
	local amount = math.floor(animal.Pending)
	animal.Pending -= amount
	EconomyService.addCoins(player, amount)
	GuideService.onCollected(player)
	local pen = penOf(zoo, penIndex)
	local pad = pen and pen:FindFirstChild("CollectPad") :: BasePart?
	if pad then
		AnimalService.collectEffect(pad)
	end
	refreshPens(player)
end

-- Collects every pen that has at least $1 waiting. Used by the auto-collect purchase.
function ZooService.collectAll(player: Player)
	local data = PlayerDataService.get(player)
	if not data then
		return
	end
	for i = 1, math.min(data.ZooSize, GameConfig.Zoo.MaxPens) do
		collect(player, i)
	end
end

local function expand(player: Player)
	local data = PlayerDataService.get(player)
	if not data then
		return
	end
	local step = nextExpansion(data.ZooSize)
	if not step then
		return
	end
	if not EconomyService.spend(player, step.Price) then
		purchaseResult:FireClient(player, false, `Expanding needs {UIStyle.formatMoney(step.Price)}.`)
		return
	end
	data.ZooSize = step.Pens
	PlayerDataService.saveNow(player)
	refreshAll(player)
	purchaseResult:FireClient(player, true, `Zoo expanded to {step.Pens} pens!`)
end

-- Washed animals ------------------------------------------------------------------------

-- For features: adds cash straight onto every penned animal's pad (e.g. offline earnings),
-- split by each animal's share of total income.
function ZooService.addToPads(player: Player, total: number)
	local data = PlayerDataService.get(player)
	if not data or #data.Animals == 0 or total <= 0 then
		return
	end
	local sum = totalIncome(data)
	for _, animal in data.Animals do
		local share = if sum > 0 then ZooService.income(animal.Species, animal.Mutation) / sum else 1 / #data.Animals
		animal.Pending += total * share
	end
	PlayerDataService.markDirty(player)
	refreshPens(player)
end

function ZooService.totalIncome(player: Player): number
	local data = PlayerDataService.get(player)
	return if data then totalIncome(data) else 0
end

function ZooService.cacheHasRoom(player: Player): boolean
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	return zoo ~= nil and data ~= nil and #waitingRecords(zoo, data) < GameConfig.Cache.Slots
end

-- Adds an animal to the cache. Returns the record and the slot it should walk to.
-- `options.Evict`: a freshly washed animal pushes out the one waiting (unless that one was
-- paid for). `options.Paid`: Robux animals, which are never pushed out themselves.
function ZooService.addToCache(
	player: Player,
	species: string,
	mutation: string,
	options: { Evict: boolean?, Paid: boolean? }?
): (CachedAnimal?, CFrame?)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return nil, nil
	end
	local opts: { Evict: boolean?, Paid: boolean? } = options or {}
	if opts.Evict then
		makeCacheRoom(player)
	end
	if #waitingRecords(zoo, data) >= GameConfig.Cache.Slots then
		return nil, nil
	end
	local record: CachedAnimal = {
		Id = tostring(data.NextAnimalId),
		Species = species,
		Mutation = mutation,
		Paid = if opts.Paid then true else nil,
	}
	data.NextAnimalId += 1
	table.insert(data.Cache, record)
	PlayerDataService.markDirty(player)
	local slot = cacheSlot(zoo, #waitingRecords(zoo, data))
	sendZoo(player)
	return record, slot and slot.CFrame
end

-- The washed model has walked to its cache slot: it becomes the waiting cache animal.
function ZooService.adoptIntoCache(player: Player, record: CachedAnimal, model: Model)
	local zoo = zoos[player]
	if not zoo then
		model:Destroy()
		return
	end
	local body = model:FindFirstChild("Body")
	if body then
		for _, name in { "Sparkle", "CompleteSound" } do
			local child = body:FindFirstChild(name)
			if child then
				child:Destroy()
			end
		end
	end
	local patches = model:FindFirstChild("DirtPatches")
	if patches then
		patches:ClearAllChildren()
	end
	model.Name = "CachedAnimal"
	model:SetAttribute("AnimalId", record.Id)
	model:SetAttribute("JobId", nil)
	model.Parent = zoo.Bay:FindFirstChild("Cache") or zoo.Bay
	zoo.CacheModels[record.Id] = model
	refreshCache(player)
end

-- Records a species x mutation discovery. Returns true the first time.
function ZooService.discover(player: Player, species: string, mutation: string): boolean
	local data = PlayerDataService.get(player)
	if not data then
		return false
	end
	local key = PlayerDataService.indexKey(species, mutation)
	if data.Index[key] then
		return false
	end
	data.Index[key] = true
	PlayerDataService.markDirty(player)
	ZooService.sendIndex(player, key)
	return true
end

-- Lifecycle ----------------------------------------------------------------------------

-- Called when the player gets a bay: build their animals and wire this bay's prompts/pads.
function ZooService.attach(player: Player, bay: Model)
	ZooService.detach(player)
	local zoo: Zoo = {
		Bay = bay,
		PenModels = {},
		CacheModels = {},
		CarriedId = nil,
		CarryModel = nil,
		Connections = {},
		PadDebounce = {},
	}
	zoos[player] = zoo
	local data = PlayerDataService.get(player)
	if data then
		for _, animal in data.Animals do
			placeInPen(zoo, animal, AnimalService.buildZooAnimal(animal.Species, animal.Mutation))
		end
		for _, record in data.Cache do
			buildCacheModel(zoo, record)
		end
		-- A save can hold one more than fits (an animal carried at leave time).
		local guard = 0
		while #waitingRecords(zoo, data) > GameConfig.Cache.Slots and guard < 4 do
			guard += 1
			if not makeCacheRoom(player) then
				break
			end
		end
	end

	local function connect(signal: RBXScriptSignal, fn: (...any) -> ())
		table.insert(zoo.Connections, signal:Connect(fn))
	end
	for i = 1, GameConfig.Zoo.MaxPens do
		local pen = penOf(zoo, i)
		local post = pen and pen:FindFirstChild("GatePost")
		local prompt = post and post:FindFirstChild("PenPrompt") :: ProximityPrompt?
		if prompt then
			connect(prompt.Triggered, function(who: Player)
				if who ~= player then
					return
				end
				if zoo.CarriedId then
					placeCarried(player, i)
				else
					sellFromPen(player, i)
				end
			end)
		end
		local pad = pen and pen:FindFirstChild("CollectPad") :: BasePart?
		if pad then
			connect(pad.Touched, function(hit: BasePart)
				local character = player.Character
				if character and hit:IsDescendantOf(character) then
					collect(player, i)
				end
			end)
		end
	end
	local zooFolder = bay:FindFirstChild("Zoo")
	local counter = zooFolder and zooFolder:FindFirstChild("ExpandCounter")
	local expandPrompt = counter and counter:FindFirstChild("ExpandPrompt") :: ProximityPrompt?
	if expandPrompt then
		connect(expandPrompt.Triggered, function(who: Player)
			if who == player then
				expand(player)
			end
		end)
	end
	for i = 1, GameConfig.Cache.Slots do
		local slot = cacheSlot(zoo, i)
		local pickup = slot and slot:FindFirstChild("PickupPrompt") :: ProximityPrompt?
		local sell = slot and slot:FindFirstChild("SellPrompt") :: ProximityPrompt?
		if pickup then
			connect(pickup.Triggered, function(who: Player)
				if who == player then
					pickUp(player, i)
				end
			end)
		end
		if sell then
			connect(sell.Triggered, function(who: Player)
				if who == player then
					sellFromCache(player, i)
				end
			end)
		end
	end
	-- A carried animal goes back to the cache if the carrier dies or respawns.
	connect(player.CharacterAdded, function()
		if zoo.CarriedId then
			returnCarryToCache(player)
		end
	end)

	refreshAll(player)
	ZooService.sendIndex(player, nil)
end

function ZooService.detach(player: Player)
	local zoo = zoos[player]
	if not zoo then
		return
	end
	zoos[player] = nil
	for _, connection in zoo.Connections do
		connection:Disconnect()
	end
	if zoo.CarryModel then
		zoo.CarryModel:Destroy()
	end
	for _, model in zoo.PenModels do
		model:Destroy()
	end
	for _, model in zoo.CacheModels do
		model:Destroy()
	end
end

function ZooService.init()
	-- Choices while carrying: put it back in the cache, or sell it on the spot.
	local lastAction: { [Player]: number } = {}
	Remotes.event("CarryAction").OnServerEvent:Connect(function(player: Player, action: any)
		local now = os.clock()
		if (lastAction[player] or 0) > now or (action ~= "drop" and action ~= "sell") then
			return
		end
		lastAction[player] = now + 0.4
		if action == "sell" then
			sellCarried(player)
		else
			putDownCarried(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastAction[player] = nil
	end)
	-- Income: every tick, each penned animal adds its income to its pen's pad.
	task.spawn(function()
		while true do
			task.wait(GameConfig.IncomeTickSeconds)
			for player in zoos do
				local data = PlayerDataService.get(player)
				if data and #data.Animals > 0 then
					local multiplier = Hooks.apply("IncomeMultiplier", 1, player)
					local tick = 0
					for _, animal in data.Animals do
						local amount = ZooService.income(animal.Species, animal.Mutation)
							* multiplier
							* GameConfig.IncomeTickSeconds
						animal.Pending += amount
						tick += amount
					end
					PlayerDataService.markDirty(player)
					refreshPens(player)
					Hooks.fire("IncomeTick", player, tick)
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(ZooService.detach)
end

return ZooService
