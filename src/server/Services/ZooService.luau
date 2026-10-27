-- The player's zoo, Steal a Brainrot style:
--   * Every washed animal walks into the bay's cache and waits there.
--   * A full cache does not delete that animal when the next wash finishes. The new one
--     waits as an overflow until the owner keeps it (carries it to a pen) or auto-sells it.
--   * The owner picks one up (it rides above their head) and carries it to a pen: an empty
--     pen takes it, an occupied pen swaps (the old animal comes out into their hands).
--     A washed animal can be grabbed while it is still walking to the cache.
--   * The first three washes of a new profile auto-sell, and the pens stay hidden until then.
--   * Animals in pens earn cash every second into the pen's collect pad; stepping on the
--     pad collects it. Animals can also be sold from the cache or a pen.
--   * Index: every species x mutation the player has washed.
-- Owns those parts of the profile. Only the bay owner can use their bay's prompts and pads.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local StatUpgrades = require(ReplicatedStorage.Shared.StatUpgrades)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local AnimalService = require(script.Parent.AnimalService)
local EconomyService = require(script.Parent.EconomyService)
local FarmDecor = require(script.Parent.FarmDecor)
local MutationPayout = require(script.Parent.MutationPayout)
local GuideService = require(script.Parent.GuideService)
local Hooks = require(script.Parent.Hooks)
local WorldBuilder = require(script.Parent.WorldBuilder)
local PlayerDataService = require(script.Parent.PlayerDataService)

local socialModule: any = nil
local function social(): any
	if not socialModule then
		socialModule = require(script.Parent.Parent.Features.Social)
	end
	return socialModule
end

type OwnedAnimal = PlayerDataService.OwnedAnimal
type CachedAnimal = PlayerDataService.CachedAnimal

type Zoo = {
	Bay: Model,
	PenModels: { [string]: Model }, -- animal id -> model standing in its pen
	CacheModels: { [string]: Model }, -- animal id -> model waiting in the cache
	-- animal id -> washed model still walking to its cache slot. Its record is already
	-- waiting (and can be sold or picked up); it joins CacheModels when it gets there.
	Arriving: { [string]: Model },
	OverflowModels: { [string]: Model }, -- animal id -> model waiting on a full-cache decision
	CarriedId: string?, -- cache record currently being carried
	CarryModel: Model?,
	ShowcaseId: string?, -- animal standing on the showcase podium
	ShowcaseModel: Model?,
	Cleaner: Janitor.Janitor,
	PadDebounce: { [number]: number },
}

local ZooService = {}

local zoos: { [Player]: Zoo } = {}

local zooChanged = Remotes.event("ZooChanged")
local indexChanged = Remotes.event("IndexChanged")
local carryChanged = Remotes.event("CarryChanged")
local purchaseResult = Remotes.event("PurchaseResult")
local introAutoSold = Remotes.event("IntroAutoSold")
local overflowPrompt = Remotes.event("OverflowPrompt")
local yardRevealed = Remotes.event("YardRevealed")
local paidConfirm = Remotes.event("PaidSellConfirm")

-- Robux animals ask first: selling one (or swapping it out of a pen) sends the question to the
-- client, and only an Accept with the matching token runs the action. Each action checks
-- again when it runs, since the zoo may have changed while the question was open.
local pendingConfirm: { [Player]: { Token: number, Run: () -> () } } = {}
local confirmCount = 0

local function askPaid(player: Player, text: string, run: () -> ())
	confirmCount += 1
	pendingConfirm[player] = { Token = confirmCount, Run = run }
	paidConfirm:FireClient(player, confirmCount, text)
end

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

function ZooService.introRemaining(player: Player): number
	local data = PlayerDataService.get(player)
	return if data then data.IntroWashesLeft else 0
end

function ZooService.introWashReward(): number
	return math.floor(GameConfig.Intro.PayoutIncome * GameConfig.WashRewardSeconds)
end

function ZooService.introSellValue(): number
	return math.floor(GameConfig.Intro.PayoutIncome * GameConfig.SellValueSeconds)
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

local function roadCage(index: number): any
	return GameConfig.Zoo.RoadCages[index - GameConfig.Zoo.MaxPens]
end

-- The four road cages open together with the Pasture barn upgrade. Saves from before that
-- (cages opened by Robux, the Axolotl or cash) are migrated into the same flag on load.
local function roadCagesOpen(data: PlayerDataService.SavedData): boolean
	local cages = data.Extra.RoadCages
	return typeof(cages) == "table" and cages.Open == true
end

local function openRoadCages(data: PlayerDataService.SavedData)
	local cages = data.Extra.RoadCages
	if typeof(cages) ~= "table" then
		cages = {}
		data.Extra.RoadCages = cages
	end
	cages.Open = true
end

local function penOpen(data: PlayerDataService.SavedData, index: number): boolean
	if index >= 1 and index <= data.ZooSize then
		return true
	end
	return roadCage(index) ~= nil and roadCagesOpen(data)
end

local LAST_PEN = GameConfig.Zoo.MaxPens + #GameConfig.Zoo.RoadCages

local function cacheSlot(zoo: Zoo, index: number): BasePart?
	local folder = zoo.Bay:FindFirstChild("Cache")
	local slot = folder and folder:FindFirstChild("Slot" .. index)
	return if slot and slot:IsA("BasePart") then slot else nil
end

type Expansion = { Pens: number?, RoadCages: boolean?, Price: number, Barn: string }

-- The first step along the walkway not bought yet: the barn after the saved tier.
local function nextExpansion(data: PlayerDataService.SavedData): Expansion?
	return GameConfig.Zoo.Expansions[data.BarnTier + 1]
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

local function animalsInPen(data: PlayerDataService.SavedData, pen: number): { OwnedAnimal }
	local list = {}
	for _, animal in data.Animals do
		if animal.Pen == pen then
			table.insert(list, animal)
		end
	end
	return list
end

-- Most uncollected cash this pen's pad holds: GameConfig.PenCashCap by the pen's class, raised
-- by the owner's Pen Storage level (StatUpgrades).
local function penCap(zoo: Zoo?, data: PlayerDataService.SavedData, penIndex: number): number
	local pen = if zoo then penOf(zoo, penIndex) else nil
	local class = pen and pen:GetAttribute("PenClass")
	local caps: { [string]: number } = GameConfig.PenCashCap
	local base = caps[if typeof(class) == "string" then class else "Standard"] or caps.Standard
	return StatUpgrades.penCap(base, data.PenCapLevel)
end

local function penPending(data: PlayerDataService.SavedData, penIndex: number): number
	local sum = 0
	for _, animal in data.Animals do
		if animal.Pen == penIndex then
			sum += animal.Pending
		end
	end
	return sum
end

-- Adds cash to an animal's share of its pen's pad, stopping at the pen's cap. Returns what
-- actually went in.
local function credit(zoo: Zoo?, data: PlayerDataService.SavedData, animal: OwnedAnimal, amount: number): number
	local room = math.max(0, penCap(zoo, data, animal.Pen) - penPending(data, animal.Pen))
	local added = math.min(amount, room)
	animal.Pending += added
	return added
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
	local step = nextExpansion(data)
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
	if zoo.Bay:GetAttribute("YardRevealed") ~= true then
		return
	end
	local carried = carriedRecord(player)
	-- The next unlock group shows as ghost pens: what the next barn buys, and where.
	local upcoming = nextExpansion(data)
	local ghostFrom = data.ZooSize
	local ghostTo = if upcoming and upcoming.Pens then upcoming.Pens else 0
	for i = 1, LAST_PEN do
		local pen = penOf(zoo, i)
		if not pen then
			continue
		end
		local unlocked = penOpen(data, i)
		local nextCages = upcoming ~= nil and upcoming.RoadCages == true and roadCage(i) ~= nil
		if unlocked then
			WorldBuilder.setShown(pen, true)
		elseif (ghostFrom < i and i <= ghostTo) or nextCages then
			WorldBuilder.setGhost(pen)
		else
			WorldBuilder.setShown(pen, false)
		end
		if not unlocked then
			continue
		end
		local occupants = animalsInPen(data, i)
		local animal = occupants[1]
		local floor = pen:FindFirstChild("Floor") :: BasePart
		floor.Color = Color3.fromRGB(120, 170, 80)
		local status = floor:FindFirstChild("Status")
		local text = status and status:FindFirstChild("Label") :: TextLabel?
		if text then
			-- An empty pen says how much cash its pad can hold, so bigger pens read as worth more.
			text.Text = if not unlocked or animal then "" else `EMPTY\nMax {UIStyle.formatMoney(penCap(zoo, data, i))}`
		end
		local pad = pen:FindFirstChild("CollectPad") :: BasePart?
		if pad then
			pad.Transparency = 0
			local cash, rate = 0, 0
			for _, occupant in occupants do
				cash += occupant.Pending
				rate += ZooService.income(occupant.Species, occupant.Mutation)
			end
			-- The client renders the counter (count-up, bounce, money pop) from these.
			pad:SetAttribute("Cash", if #occupants > 0 then math.floor(cash) else nil)
			pad:SetAttribute("Rate", if #occupants > 0 then rate else nil)
			pad:SetAttribute("Cap", penCap(zoo, data, i))
		end

		local post = pen:FindFirstChild("GatePost")
		local prompt = post and post:FindFirstChild("PenPrompt") :: ProximityPrompt?
		local prompt2 = post and post:FindFirstChild("PenPrompt2") :: ProximityPrompt?
		local sellPrompt = post and post:FindFirstChild("PenSellPrompt") :: ProximityPrompt?
		if sellPrompt then
			sellPrompt.Enabled = false -- armed below for an unlocked pen with an animal
		end
		if prompt2 then
			prompt2.Enabled = false
		end
		if not prompt then
			continue
		end
		if not unlocked then
			prompt.Enabled = false
			local lockedPet = post and post:FindFirstChild("PetPrompt")
			local lockedPet2 = post and post:FindFirstChild("PetPrompt2")
			if lockedPet and lockedPet:IsA("ProximityPrompt") then
				lockedPet.Enabled = false
			end
			if lockedPet2 and lockedPet2:IsA("ProximityPrompt") then
				lockedPet2.Enabled = false
			end
			continue
		end
		local penClassAttr = pen:GetAttribute("PenClass")
		local penClass = if typeof(penClassAttr) == "string" then penClassAttr else "Standard"
		local function armSell(target: ProximityPrompt, occupant: OwnedAnimal)
			target.Enabled = true
			target.ObjectText = ZooService.label(occupant.Species, occupant.Mutation)
			target.ActionText = `Sell {UIStyle.formatMoney(ZooService.sellValue(occupant.Species, occupant.Mutation))}`
			target.HoldDuration = 0 -- a tap sells; no hold
		end
		if not carried and not animal then
			prompt.Enabled = false
		elseif carried then
			local bodyClass = AnimalConfig.Animals[carried.Species].BodyClass
			prompt.Enabled = true
			prompt.ObjectText = ZooService.label(carried.Species, carried.Mutation)
			if not AnimalConfig.fits(bodyClass, penClass) then
				prompt.ActionText = AnimalConfig.placementHint(bodyClass, penClass)
				prompt.HoldDuration = 0
			elseif not animal then
				prompt.ActionText = "Place"
				prompt.HoldDuration = 0
			else
				prompt.ActionText = "Swap"
				prompt.HoldDuration = 0.5
			end
		elseif animal then
			-- E picks it up to move it; F sells it.
			prompt.Enabled = true
			prompt.ObjectText = ZooService.label(animal.Species, animal.Mutation)
			prompt.ActionText = "Pick up"
			prompt.HoldDuration = 0
			if sellPrompt then
				armSell(sellPrompt, animal)
			end
			if prompt2 and occupants[2] then
				armSell(prompt2, occupants[2])
			end
		end
		local pets = social()
		local function armPet(target: ProximityPrompt?, occupant: OwnedAnimal?)
			if not target then
				return
			end
			if carried or not occupant then
				target.Enabled = false
				return
			end
			target.Enabled = true
			target.ObjectText = ZooService.label(occupant.Species, occupant.Mutation)
			if pets.isPet(player, occupant.Id) then
				target.ActionText = "Remove pet"
			elseif pets.petCount(player) >= pets.petCap(player) then
				target.ActionText = "Replace pet"
			else
				target.ActionText = "Set pet"
			end
		end
		local petPrompt = post and post:FindFirstChild("PetPrompt") :: ProximityPrompt?
		local petPrompt2 = post and post:FindFirstChild("PetPrompt2") :: ProximityPrompt?
		armPet(petPrompt, if carried then nil else animal)
		armPet(petPrompt2, if carried then nil else occupants[2])
	end

	-- The unlock stand moves to the front of the next locked group and names its price.
	local zooFolder = zoo.Bay:FindFirstChild("Zoo")
	local stand = zooFolder and zooFolder:FindFirstChild("ExpandStand")
	local counter = stand and stand:FindFirstChild("ExpandCounter")
	local expandPrompt = counter and counter:FindFirstChild("ExpandPrompt") :: ProximityPrompt?
	local step = nextExpansion(data)
	local stepIndex = 0
	for index, candidate in GameConfig.Zoo.Expansions do
		if candidate == step then
			stepIndex = index
		end
	end
	local spot = zooFolder and zooFolder:FindFirstChild("UnlockSpot" .. stepIndex)
	if stand and stand:IsA("Model") then
		WorldBuilder.setShown(stand, step ~= nil)
		-- refreshPens runs every income tick; only move the stand (every part replicates) when
		-- its spot changed.
		if spot and spot:IsA("BasePart") then
			local at = stand:GetPivot()
			if (at.Position - spot.Position).Magnitude > 0.01 or at.LookVector:Dot(spot.CFrame.LookVector) < 0.9999 then
				stand:PivotTo(spot.CFrame)
			end
		end
		-- The hanging sign and the counter's label both show the next upgrade's price.
		if step then
			for _, label in stand:GetDescendants() do
				if label:IsA("TextLabel") and label.Name == "NextLabel" then
					label.Text = `FARM UPGRADE\n{UIStyle.formatMoney(step.Price)}`
				end
			end
		end
	end
	if expandPrompt then
		expandPrompt.Enabled = step ~= nil
		if step then
			expandPrompt.ActionText = `Farm upgrade ({UIStyle.formatMoney(step.Price)})`
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
	if zoo.Bay:GetAttribute("YardRevealed") ~= true then
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
				sell.ActionText = `Sell {UIStyle.formatMoney(ZooService.sellValue(record.Species, record.Mutation))}`
			end
		end
		local model = record and zoo.CacheModels[record.Id]
		if model then
			model:PivotTo(slot.CFrame)
		end
	end
end

-- The showcase podium at the road: the farm's best animal (by income) stands on it, with the
-- farm's income under the farm name, so passers-by see what this player has. It is a copy:
-- the animal still lives and earns in its pen.
local SHOWCASE_MAX = 11 -- studs: a giant on the podium shrinks to fit it
local PODIUM_EMPTY = 16 -- plinth width with nobody on it (WorldBuilder.buildShowcase)
local PODIUM_RIM = 3 -- plinth past the cloth top
local PODIUM_MIN_TOP = 4

-- Fits the plinth, cloth top and corner posts to `top` studs of standing room, about the
-- plinth's own centre, so the podium is as big as the animal on it.
local function sizePodium(showcase: Instance, top: number)
	local plinth = showcase:FindFirstChild("Plinth") :: BasePart?
	local cloth = showcase:FindFirstChild("Top") :: BasePart?
	if not plinth then
		return
	end
	local width = top + PODIUM_RIM
	plinth.Size = Vector3.new(width, plinth.Size.Y, width)
	if cloth then
		cloth.Size = Vector3.new(top, cloth.Size.Y, top)
	end
	local corners = {}
	for _, child in showcase:GetChildren() do
		if child.Name == "Corner" and child:IsA("BasePart") then
			table.insert(corners, child)
		end
	end
	local inset = width / 2 - 0.7
	for i, corner in corners do
		local x = if i <= 2 then -1 else 1
		local z = if i % 2 == 1 then -1 else 1
		corner.CFrame = plinth.CFrame * CFrame.new(x * inset, 0.4, z * inset)
	end
end

local function setShowcaseEmpty(showcase: Instance, empty: boolean)
	local gui = showcase:FindFirstChild("Empty", true) :: BillboardGui?
	if gui then
		gui:SetAttribute("RestEnabled", empty)
		gui.Enabled = empty
	end
end

local function refreshShowcase(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return
	end
	local showcase = zoo.Bay:FindFirstChild("Showcase")
	local slot = showcase and showcase:FindFirstChild("ShowcaseSlot")
	if not showcase or not slot or not slot:IsA("BasePart") then
		return
	end
	local summary = ZooService.getZooSummary(player)
	local income = showcase:FindFirstChild("IncomeLabel", true) :: TextLabel?
	if income then
		income.Text = `{UIStyle.formatMoney(if summary then summary.IncomePerSecond else 0)}/s`
	end
	local best: OwnedAnimal? = nil
	local bestIncome = -1
	for _, animal in data.Animals do
		local value = ZooService.income(animal.Species, animal.Mutation)
		if value > bestIncome then
			best, bestIncome = animal, value
		end
	end
	local id = best and best.Id
	setShowcaseEmpty(showcase, #data.Animals == 0)
	if id == zoo.ShowcaseId and (zoo.ShowcaseModel == nil) == (best == nil) then
		return
	end
	if zoo.ShowcaseModel then
		zoo.ShowcaseModel:Destroy()
		zoo.ShowcaseModel = nil
	end
	zoo.ShowcaseId = id
	if not best then
		sizePodium(showcase, PODIUM_EMPTY - PODIUM_RIM)
		return
	end
	local model = AnimalService.buildZooAnimal(best.Species, best.Mutation)
	model.Name = "ShowcaseAnimal"
	AnimalService.resize(model, AnimalService.bodyScale(best.Species), SHOWCASE_MAX)
	model:PivotTo(slot.CFrame)
	model.Parent = showcase
	zoo.ShowcaseModel = model
	-- The rarity aura's ground ring would make the footprint read wider than the animal.
	local footprint = 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 and part.Name ~= "AuraRing" and part.Name ~= "AuraBase" then
			local size = part.Size
			local offset = slot.CFrame:PointToObjectSpace(part.Position)
			local reach = math.max(math.abs(offset.X), math.abs(offset.Z)) + math.max(size.X, size.Z) / 2
			footprint = math.max(footprint, reach * 2)
		end
	end
	sizePodium(showcase, math.max(PODIUM_MIN_TOP, footprint + 0.5))
end

local function refreshAll(player: Player)
	refreshPens(player)
	refreshCache(player)
	refreshShowcase(player)
	sendZoo(player)
	sendCarry(player)
end

function ZooService.refresh(player: Player)
	refreshAll(player)
end

local function slotFor(pen: Model, _data: PlayerDataService.SavedData, _animal: OwnedAnimal): BasePart?
	local slot = pen:FindFirstChild("Slot") :: BasePart?
	return slot
end

local function seatPen(zoo: Zoo, data: PlayerDataService.SavedData, penIndex: number)
	local pen = penOf(zoo, penIndex)
	if not pen then
		return
	end
	for _, animal in data.Animals do
		if animal.Pen ~= penIndex then
			continue
		end
		local model = zoo.PenModels[animal.Id]
		local slot = slotFor(pen, data, animal)
		if model and slot then
			model:PivotTo(slot.CFrame)
		end
	end
end

local function placeInPen(zoo: Zoo, animal: OwnedAnimal, model: Model, data: PlayerDataService.SavedData?)
	local pen = penOf(zoo, animal.Pen)
	local slot = if pen and data then slotFor(pen, data, animal) else pen and pen:FindFirstChild("Slot") :: BasePart?
	model.Name = "ZooAnimal"
	model:SetAttribute("AnimalId", animal.Id)
	-- The same size as at the wash, in the cache and in your arms: animals never shrink.
	AnimalService.resize(model, AnimalService.bodyScale(animal.Species))
	if slot then
		model:PivotTo(slot.CFrame)
	end
	model.Parent = pen or zoo.Bay
	zoo.PenModels[animal.Id] = model
	if data and pen then
		seatPen(zoo, data, animal.Pen)
	end
end

local function buildCacheModel(zoo: Zoo, record: CachedAnimal)
	local model = AnimalService.buildZooAnimal(record.Species, record.Mutation)
	AnimalService.resize(model, AnimalService.bodyScale(record.Species))
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

-- A washed animal walking to its slot carries its record id here, and the owner's client puts
-- a Pick up card on it (ZooController). The grab comes back as the WalkPickup remote, since
-- the server's copy of a walking model stays at the start of its walk (AnimalService).
local WALK_PICKUP = "WalkPickupId"
local WALK_REACH = 16 -- studs from where the animal is now, as clients see it

local function markArriving(zoo: Zoo, record: CachedAnimal, model: Model)
	zoo.Arriving[record.Id] = model
	model:SetAttribute("WalkPickupLabel", ZooService.label(record.Species, record.Mutation))
	model:SetAttribute(WALK_PICKUP, record.Id)
end

-- Takes a waiting record's model out of the zoo's books: the one standing in its slot, or the
-- washed one still walking there (that walk then stops at once, see receiveWashed).
local function takeCacheModel(zoo: Zoo, id: string): Model?
	local model = zoo.CacheModels[id] or zoo.Arriving[id]
	zoo.CacheModels[id] = nil
	zoo.Arriving[id] = nil
	if model then
		model:SetAttribute(WALK_PICKUP, nil)
	end
	return model
end

-- Pays for a cache animal and walks it forward off the pad, hops a sold beat, then jogs to the
-- street and runs off down it. One sold while still walking (on the drive from the wash, or
-- out to an overflow spot) first follows the rest of that route except its final spot, so it
-- leaves along the drive instead of cutting across the grass.
local function sendSoldHome(zoo: Zoo, model: Model?)
	if not model then
		return
	end
	model.Name = "SoldAnimal"
	local sold = zoo.Bay:FindFirstChild("SoldSpot")
	local back = zoo.Bay:FindFirstChild("RoadReturn")
	local bay = zoo.Bay
	local route: { CFrame } = {}
	local pending = AnimalService.pendingCorners(model)
	for i = 1, #pending - 1 do
		table.insert(route, CFrame.new(pending[i]))
	end
	task.spawn(function()
		if sold and sold:IsA("BasePart") and model.Parent then
			table.insert(route, sold.CFrame)
			AnimalService.walkCorners(model, route, 0.55)
		end
		if model.Parent then
			AnimalService.sold(model)
		end
		if back and back:IsA("BasePart") and model.Parent then
			AnimalService.walkCorners(model, { back.CFrame }, 0.7, 0.55)
		end
		AnimalService.runOff(model, bay)
	end)
end

-- Sells the oldest unpaid animal waiting in the cache and returns its model, still standing
-- in the slot (or still walking to it). The caller walks it out, then walks whoever is left
-- into the open slot.
local function takeOldestUnpaid(player: Player): Model?
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return nil
	end
	for _, record in waitingRecords(zoo, data) do
		if record.Paid then
			continue
		end
		removeCached(data, record.Id)
		local model = takeCacheModel(zoo, record.Id)
		EconomyService.addCoins(player, ZooService.sellValue(record.Species, record.Mutation))
		Hooks.fire(
			"AnimalSold",
			player,
			record.Species,
			record.Mutation,
			ZooService.sellValue(record.Species, record.Mutation)
		)
		PlayerDataService.markDirty(player)
		return model
	end
	return nil
end

-- Pushes the oldest unpaid animal out so a bought animal fits. A full wash cache sells
-- the same way before the new animal is allowed in.
local function makeCacheRoom(player: Player): boolean
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return false
	end
	if #waitingRecords(zoo, data) < GameConfig.Cache.Slots then
		return true
	end
	sendSoldHome(zoo, takeOldestUnpaid(player))
	return #waitingRecords(zoo, data) < GameConfig.Cache.Slots
end

local fireOverflow: (player: Player) -> ()
local promoteOverflow: (player: Player) -> ()

-- returnCarry is defined before the overflow helpers, so those two locals are assigned later.
-- A full cache keeps the waiting animal and parks the one that was in hand as an overflow.
local function returnCarryToCache(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = carriedRecord(player)
	if not zoo or not data or not record then
		dropCarry(player)
		refreshAll(player)
		return
	end
	if #waitingRecords(zoo, data) >= GameConfig.Cache.Slots then
		removeCached(data, record.Id)
		table.insert(data.Overflow, record)
		dropCarry(player)
		local model = AnimalService.buildZooAnimal(record.Species, record.Mutation)
		model.Name = "OverflowAnimal"
		model:SetAttribute("AnimalId", record.Id)
		model.Parent = zoo.Bay
		zoo.OverflowModels[record.Id] = model
		local slot = cacheSlot(zoo, 1)
		if slot then
			model:PivotTo(slot.CFrame * CFrame.new(6 * #data.Overflow, 0, 0))
		end
		PlayerDataService.markDirty(player)
		refreshAll(player)
		fireOverflow(player)
		return
	end
	dropCarry(player)
	if not zoo.CacheModels[record.Id] then
		buildCacheModel(zoo, record)
	end
	refreshAll(player)
	GuideService.onCarryReturned(player)
end

-- Lifts a waiting record into the player's hands: from its slot, or grabbed while it was
-- still walking there.
local function pickUpRecord(player: Player, record: CachedAnimal)
	local zoo = zoos[player]
	local character = player.Character
	local hand = character
		and (character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")) :: BasePart?
	if not zoo or zoo.CarriedId or not hand then
		return
	end
	-- Picked up from its slot, or grabbed while it was still walking there.
	local cached = takeCacheModel(zoo, record.Id)
	if cached then
		cached:Destroy()
	end
	zoo.CarriedId = record.Id
	zoo.CarryModel = AnimalService.buildCarryModel(record.Species, record.Mutation, hand)
	refreshAll(player)
	GuideService.onPickedUp(player)
	promoteOverflow(player)
end

local function pickUp(player: Player, slotIndex: number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = zoo and data and waitingRecords(zoo, data)[slotIndex]
	if record then
		pickUpRecord(player, record)
	end
end

-- The owner grabbed a washed animal on its way to the cache. It must still be walking there,
-- and the player must be standing near where it is now.
local function pickUpWalking(player: Player, id: string)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local model = zoo and zoo.Arriving[id]
	local record = data and (findCached(data, id))
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not zoo or not model or not model.Parent or not record or not root or zoo.CarriedId then
		return
	end
	local at = AnimalService.currentPivot(model).Position
	local offset = at - root.Position
	if Vector2.new(offset.X, offset.Z).Magnitude > WALK_REACH then
		return
	end
	pickUpRecord(player, record)
end

-- Lifts a penned animal into the player's hands so it can go in another pen. Cash still on
-- its pad is paid out first. In hand it is a cache record like any other (Paid carries over).
local function pickUpFromPen(player: Player, penIndex: number, which: number?)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local character = player.Character
	local hand = character
		and (character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")) :: BasePart?
	if not zoo or not data or zoo.CarriedId or not hand then
		return
	end
	local animal = animalsInPen(data, penIndex)[which or 1]
	local index = animal and table.find(data.Animals, animal)
	if not animal or not index then
		return
	end
	table.remove(data.Animals, index)
	EconomyService.addCoins(player, math.floor(animal.Pending))
	local model = zoo.PenModels[animal.Id]
	if model then
		zoo.PenModels[animal.Id] = nil
		model:Destroy()
	end
	seatPen(zoo, data, penIndex)
	local record: CachedAnimal = {
		Id = animal.Id,
		Species = animal.Species,
		Mutation = animal.Mutation,
		Paid = animal.Paid,
	}
	table.insert(data.Cache, record)
	zoo.CarriedId = record.Id
	zoo.CarryModel = AnimalService.buildCarryModel(record.Species, record.Mutation, hand)
	PlayerDataService.markDirty(player)
	refreshAll(player)
end

-- Put the carried animal into a pen. An occupied pen swaps: its animal comes out into the
-- player's hands (cash still on its pad is paid out), and the carried one takes its place.
local function placeCarried(player: Player, penIndex: number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = carriedRecord(player)
	if not zoo or not data or not record then
		return
	end
	if not penOpen(data, penIndex) then
		local cage = roadCage(penIndex)
		if cage then
			purchaseResult:FireClient(player, false, "Buy the Cage farm upgrade to open this pen.")
		end
		return
	end
	local penModel = penOf(zoo, penIndex)
	local penClassAttr = penModel and penModel:GetAttribute("PenClass")
	local penClass = if typeof(penClassAttr) == "string" then penClassAttr else "Standard"
	local bodyClass = AnimalConfig.Animals[record.Species].BodyClass
	if not AnimalConfig.fits(bodyClass, penClass) then
		purchaseResult:FireClient(player, false, `{AnimalConfig.placementHint(bodyClass, penClass)}.`)
		return
	end
	local character = player.Character
	local hand = character
		and (character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")) :: BasePart?
	local old, oldIndex = animalInPen(data, penIndex)
	if old and not hand then
		return -- nothing to hold the swapped-out animal with
	end
	if old and oldIndex then
		table.remove(data.Animals, oldIndex)
		EconomyService.addCoins(player, math.floor(old.Pending))
		local oldModel = zoo.PenModels[old.Id]
		if oldModel then
			zoo.PenModels[old.Id] = nil
			oldModel:Destroy()
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
		Paid = record.Paid,
	}
	table.insert(data.Animals, animal)
	dropCarry(player)
	placeInPen(zoo, animal, AnimalService.buildZooAnimal(animal.Species, animal.Mutation), data)
	if old and hand then
		-- The one that was in the pen is in hand now: a cache record like any other carry.
		local swapped: CachedAnimal = {
			Id = old.Id,
			Species = old.Species,
			Mutation = old.Mutation,
			Paid = old.Paid,
		}
		table.insert(data.Cache, swapped)
		zoo.CarriedId = swapped.Id
		zoo.CarryModel = AnimalService.buildCarryModel(swapped.Species, swapped.Mutation, hand)
	end
	PlayerDataService.saveNow(player)
	refreshAll(player)
	Hooks.fire("AnimalPlaced", player, animal)
	GuideService.onPlaced(player)
end

-- Sells the animal in hand for its sell value.
local function sellCarried(player: Player, confirmed: boolean?)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = carriedRecord(player)
	if not zoo or not data or not record then
		return
	end
	if record.Paid and not confirmed then
		local label = ZooService.label(record.Species, record.Mutation)
		askPaid(player, `Sell the {label}?`, function()
			local held = carriedRecord(player)
			if held and held.Id == record.Id then
				sellCarried(player, true)
			end
		end)
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

-- The open, empty pen nearest the player that this animal fits, and how far it is. Pens
-- with an animal are skipped: putting down never swaps.
local function nearestFreePen(player: Player, record: CachedAnimal, from: Vector3): (number?, number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data or zoo.Bay:GetAttribute("YardRevealed") ~= true then
		return nil, math.huge
	end
	local bodyClass = AnimalConfig.Animals[record.Species].BodyClass
	local best, bestDistance = nil, math.huge
	for i = 1, LAST_PEN do
		local pen = penOf(zoo, i)
		if not pen or not penOpen(data, i) or animalInPen(data, i) then
			continue
		end
		local penClassAttr = pen:GetAttribute("PenClass")
		local penClass = if typeof(penClassAttr) == "string" then penClassAttr else "Standard"
		if not AnimalConfig.fits(bodyClass, penClass) then
			continue
		end
		local floor = pen:FindFirstChild("Floor")
		local at = if floor and floor:IsA("BasePart") then floor.Position else pen:GetPivot().Position
		local distance = (at - from).Magnitude
		if distance < bestDistance then
			best, bestDistance = i, distance
		end
	end
	return best, bestDistance
end

local function nearestCacheDistance(zoo: Zoo, from: Vector3): number
	local best = math.huge
	for i = 1, GameConfig.Cache.Slots do
		local slot = cacheSlot(zoo, i)
		if slot then
			best = math.min(best, (slot.Position - from).Magnitude)
		end
	end
	return best
end

-- Put Down: into the nearest free pen it fits, or back into the cache when that is closer
-- (onto the overflow line when the slot is taken).
local function putDownCarried(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = carriedRecord(player)
	if not zoo or not data or not zoo.CarriedId then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if record and root then
		local penIndex, penDistance = nearestFreePen(player, record, root.Position)
		if penIndex and penDistance <= nearestCacheDistance(zoo, root.Position) then
			placeCarried(player, penIndex)
			return
		end
	end
	returnCarryToCache(player)
end

local function sellFromPen(player: Player, penIndex: number, which: number?, confirmed: boolean?)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return
	end
	local occupants = animalsInPen(data, penIndex)
	local animal = occupants[which or 1]
	if not animal then
		return
	end
	if animal.Paid and not confirmed then
		local label = ZooService.label(animal.Species, animal.Mutation)
		askPaid(player, `Sell the {label}?`, function()
			local now = PlayerDataService.get(player)
			if now and animalsInPen(now, penIndex)[which or 1] == animal then
				sellFromPen(player, penIndex, which, true)
			end
		end)
		return
	end
	local index = table.find(data.Animals, animal)
	if not index then
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
	seatPen(zoo, data, penIndex)
	PlayerDataService.markDirty(player)
	refreshAll(player)
end

local function sellFromCache(player: Player, slotIndex: number, confirmed: boolean?)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = zoo and data and waitingRecords(zoo, data)[slotIndex]
	if not zoo or not data or not record then
		return
	end
	if record.Paid and not confirmed then
		local label = ZooService.label(record.Species, record.Mutation)
		askPaid(player, `Sell the {label}?`, function()
			local nowZoo, now = zoos[player], PlayerDataService.get(player)
			if nowZoo and now then
				for index, waiting in waitingRecords(nowZoo, now) do
					if waiting.Id == record.Id then
						sellFromCache(player, index, true)
						return
					end
				end
			end
		end)
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
	-- Also covers an animal sold before it reached its slot: it turns round and leaves.
	sendSoldHome(zoo, takeCacheModel(zoo, record.Id))
	PlayerDataService.markDirty(player)
	refreshAll(player)
	promoteOverflow(player)
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
	local amount = 0
	for _, animal in animalsInPen(data, penIndex) do
		local take = math.floor(animal.Pending)
		if take >= 1 then
			animal.Pending -= take
			amount += take
		end
	end
	if amount < 1 then
		return
	end
	EconomyService.addCoins(player, amount)
	Hooks.fire("CashCollected", player, amount)
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
	for i = 1, LAST_PEN do
		if penOpen(data, i) then
			collect(player, i)
		end
	end
end

local function expand(player: Player)
	local data = PlayerDataService.get(player)
	if not data then
		return
	end
	local step = nextExpansion(data)
	if not step then
		return
	end
	if not EconomyService.spend(player, step.Price) then
		purchaseResult:FireClient(player, false, `Need {UIStyle.formatMoney(step.Price)}.`)
		return
	end
	if step.RoadCages then
		openRoadCages(data)
	end
	data.BarnTier += 1
	data.ZooSize = PlayerDataService.pensForTier(data.BarnTier)
	PlayerDataService.saveNow(player)
	refreshAll(player)
	local zoo = zoos[player]
	if zoo then
		FarmDecor.apply(zoo.Bay, data.BarnTier, true)
	end
	Hooks.fire("ZooExpanded", player, data.ZooSize, step.Price, step.Barn)
	purchaseResult:FireClient(player, true, `Farm upgrade unlocked!`)
end

-- Washed animals ------------------------------------------------------------------------

local function overflowCFrame(zoo: Zoo, index: number): CFrame?
	local slot = cacheSlot(zoo, 1)
	if not slot then
		return nil
	end
	return slot.CFrame * CFrame.new(6 * index, 0, 0)
end

function fireOverflow(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data or zoo.Bay:GetAttribute("YardRevealed") ~= true then
		overflowPrompt:FireClient(player, nil)
		return
	end
	local first = data.Overflow[1]
	if not first then
		overflowPrompt:FireClient(player, nil)
		return
	end
	overflowPrompt:FireClient(player, {
		Label = ZooService.label(first.Species, first.Mutation),
		SellValue = ZooService.sellValue(first.Species, first.Mutation),
		Waiting = #data.Overflow,
	})
end

local function parkOverflow(zoo: Zoo, record: CachedAnimal, model: Model, index: number, walk: boolean?)
	model.Name = "OverflowAnimal"
	model:SetAttribute("AnimalId", record.Id)
	model:SetAttribute("JobId", nil)
	AnimalService.resize(model, AnimalService.bodyScale(record.Species))
	model.Parent = zoo.Bay
	zoo.OverflowModels[record.Id] = model
	local at = overflowCFrame(zoo, index)
	if not at then
		return
	end
	if walk and model.Parent then
		-- Fresh from the wash: across the drive to the cache arm, then out to its spot.
		AnimalService.walkCorners(model, ZooService.fromWash(zoo.Bay, { at }), GameConfig.DepartDuration * 0.6)
	end
	-- Unless it was sold or kept on the way: then it's someone else's to move.
	if model.Parent and zoo.OverflowModels[record.Id] == model then
		model:PivotTo(at)
	end
end

function promoteOverflow(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return
	end
	while #waitingRecords(zoo, data) < GameConfig.Cache.Slots and #data.Overflow > 0 do
		local record = table.remove(data.Overflow, 1)
		if not record then
			break
		end
		table.insert(data.Cache, record)
		local model = zoo.OverflowModels[record.Id]
		zoo.OverflowModels[record.Id] = nil
		local slot = cacheSlot(zoo, #waitingRecords(zoo, data))
		if model and slot then
			markArriving(zoo, record, model) -- sellable and grabbable on the way, like a fresh wash
			task.spawn(function()
				AnimalService.walkCorners(model, { slot.CFrame }, GameConfig.DepartDuration)
				if zoo.Arriving[record.Id] ~= model then
					return
				end
				zoo.Arriving[record.Id] = nil
				model:SetAttribute(WALK_PICKUP, nil)
				if model.Parent and zoos[player] == zoo then
					ZooService.adoptIntoCache(player, record, model)
				elseif model.Parent then
					model:Destroy()
				end
			end)
		else
			if model then
				model:Destroy()
			end
			buildCacheModel(zoo, record)
		end
	end
	for index, record in data.Overflow do
		local model = zoo.OverflowModels[record.Id]
		local at = overflowCFrame(zoo, index)
		if model and at then
			model:PivotTo(at)
		end
	end
	PlayerDataService.markDirty(player)
	refreshAll(player)
	fireOverflow(player)
end

local function pushOverflow(player: Player, species: string, mutation: string, model: Model)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		AnimalService.destroy(model)
		return
	end
	local record: CachedAnimal = {
		Id = tostring(data.NextAnimalId),
		Species = species,
		Mutation = mutation,
	}
	data.NextAnimalId += 1
	table.insert(data.Overflow, record)
	PlayerDataService.markDirty(player)
	fireOverflow(player)
	parkOverflow(zoo, record, model, #data.Overflow, true)
end

local function keepOverflow(player: Player)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = data and data.Overflow[1]
	if not zoo or not data or not record then
		fireOverflow(player)
		return
	end
	if zoo.CarriedId then
		purchaseResult:FireClient(player, false, "Place your animal first.")
		return
	end
	local character = player.Character
	local hand = character
		and (character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")) :: BasePart?
	if not hand then
		return
	end
	table.remove(data.Overflow, 1)
	local parked = zoo.OverflowModels[record.Id]
	zoo.OverflowModels[record.Id] = nil
	if parked then
		parked:Destroy()
	end
	table.insert(data.Cache, record)
	zoo.CarriedId = record.Id
	zoo.CarryModel = AnimalService.buildCarryModel(record.Species, record.Mutation, hand)
	PlayerDataService.markDirty(player)
	refreshAll(player)
	fireOverflow(player)
end

local function sellOverflow(player: Player, confirmed: boolean?)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local record = data and data.Overflow[1]
	if not zoo or not data or not record then
		fireOverflow(player)
		return
	end
	if record.Paid and not confirmed then
		local label = ZooService.label(record.Species, record.Mutation)
		askPaid(player, `Sell the {label}?`, function()
			local now = PlayerDataService.get(player)
			if now and now.Overflow[1] == record then
				sellOverflow(player, true)
			end
		end)
		return
	end
	table.remove(data.Overflow, 1)
	local model = zoo.OverflowModels[record.Id]
	zoo.OverflowModels[record.Id] = nil
	local value = ZooService.sellValue(record.Species, record.Mutation)
	EconomyService.addCoins(player, value)
	Hooks.fire("AnimalSold", player, record.Species, record.Mutation, value)
	PlayerDataService.markDirty(player)
	sendSoldHome(zoo, model)
	refreshAll(player)
	fireOverflow(player)
end

function ZooService.noteIntroWash(player: Player)
	local data = PlayerDataService.get(player)
	if not data or data.IntroWashesLeft <= 0 then
		return
	end
	data.IntroWashesLeft -= 1
	PlayerDataService.markDirty(player)
	PlayerDataService.saveNow(player)
	if data.IntroWashesLeft > 0 then
		return
	end
	local zoo = zoos[player]
	if zoo then
		WorldBuilder.setYardShown(zoo.Bay, true)
		refreshAll(player)
	end
	yardRevealed:FireClient(player)
	Hooks.fire("YardRevealed", player)
end

-- A route out of the wash spot: along the drive's cross piece to the cache arm first
-- (WorldBuilder's CacheTurn), so animals follow the U instead of cutting across the grass.
function ZooService.fromWash(bay: Instance, points: { CFrame }): { CFrame }
	local turn = bay:FindFirstChild("CacheTurn")
	if not turn or not turn:IsA("BasePart") then
		return points
	end
	-- Back onto the wash spot first: a lunge or squirm can leave the animal off it, and the
	-- cross piece only lines up from there. walkCorners skips it when already in place.
	local wash = bay:FindFirstChild("WashPosition")
	local route = if wash and wash:IsA("BasePart") then { wash.CFrame, turn.CFrame } else { turn.CFrame }
	for _, point in points do
		table.insert(route, point)
	end
	return route
end

-- The washed model has finished celebrating. Intro animals are sold on the spot and never
-- enter the cache. Once the yard is open, two animals can wait; a third sells the oldest
-- and the one behind walks up into that slot.
function ZooService.receiveWashed(player: Player, model: Model, species: string, mutation: string)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data or not model.Parent then
		AnimalService.destroy(model)
		return
	end
	if model:GetAttribute("ScriptedIntro") == true then
		local value = ZooService.introSellValue()
		EconomyService.addCoins(player, value)
		Hooks.fire("AnimalSold", player, species, mutation, value)
		PlayerDataService.markDirty(player)
		introAutoSold:FireClient(player, value, data.IntroWashesLeft)
		-- Across the drive and down the cache arm: the same way out as a sale.
		local sold = zoo.Bay:FindFirstChild("SoldSpot")
		local back = zoo.Bay:FindFirstChild("RoadReturn")
		if sold and sold:IsA("BasePart") and back and back:IsA("BasePart") and model.Parent then
			local route = ZooService.fromWash(zoo.Bay, { sold.CFrame, back.CFrame })
			AnimalService.walkCorners(model, route, GameConfig.DepartDuration * 0.6)
		end
		AnimalService.runOff(model, zoo.Bay)
		return
	end
	-- Same size it was washed at: an animal never changes size between wash, cache and pen.
	AnimalService.resize(model, AnimalService.bodyScale(species))
	if #waitingRecords(zoo, data) >= GameConfig.Cache.Slots then
		local soldModel = takeOldestUnpaid(player)
		if soldModel then
			-- The sale and the shuffle up run alongside, so the washed animal leaves the
			-- wash spot right after its hop instead of waiting for them.
			sendSoldHome(zoo, soldModel)
			local current = PlayerDataService.get(player)
			if current and zoos[player] == zoo then
				for index, waiting in waitingRecords(zoo, current) do
					local cached = zoo.CacheModels[waiting.Id]
					local slotPart = cacheSlot(zoo, index)
					if cached and slotPart and cached.Parent then
						task.spawn(AnimalService.walkCorners, cached, { slotPart.CFrame }, 0.6)
					end
				end
				refreshCache(player)
			end
		end
	end
	local record, slot = ZooService.addToCache(player, species, mutation)
	if record and slot then
		-- Its record is already waiting, so it can be sold or picked up on the way. Whoever
		-- takes it clears Arriving and owns the model from then on (sendSoldHome or pickUp).
		markArriving(zoo, record, model)
		AnimalService.walkCorners(model, ZooService.fromWash(zoo.Bay, { slot }), GameConfig.DepartDuration)
		if zoo.Arriving[record.Id] ~= model then
			return
		end
		zoo.Arriving[record.Id] = nil
		model:SetAttribute(WALK_PICKUP, nil)
		if zoos[player] == zoo and model.Parent then
			ZooService.adoptIntoCache(player, record, model)
			return
		end
		AnimalService.destroy(model)
		return
	end
	pushOverflow(player, species, mutation, model)
end

-- For features: adds cash straight onto every penned animal's pad (e.g. offline earnings),
-- split by each animal's share of total income.
function ZooService.addToPads(player: Player, total: number)
	local data = PlayerDataService.get(player)
	if not data or #data.Animals == 0 or total <= 0 then
		return
	end
	local sum = totalIncome(data)
	local zoo = zoos[player]
	for _, animal in data.Animals do
		local share = if sum > 0 then ZooService.income(animal.Species, animal.Mutation) / sum else 1 / #data.Animals
		credit(zoo, data, animal, total * share)
	end
	PlayerDataService.markDirty(player)
	refreshPens(player)
end

-- Offline earnings: every animal earns its own per-second income for `seconds` (times `rate`)
-- onto its pen's pad, stopping at that pen's cap given the cash already there. Then every pad
-- is collected. Returns (earned offline, total collected including cash that was waiting).
function ZooService.payOffline(player: Player, seconds: number, rate: number): (number, number)
	local data = PlayerDataService.get(player)
	if not data or #data.Animals == 0 then
		return 0, 0
	end
	local zoo = zoos[player]
	local earned = 0
	for _, animal in data.Animals do
		earned += credit(zoo, data, animal, ZooService.income(animal.Species, animal.Mutation) * seconds * rate)
	end
	local collected = 0
	for i = 1, LAST_PEN do
		if penOpen(data, i) then
			local amount = 0
			for _, animal in animalsInPen(data, i) do
				local take = math.floor(animal.Pending)
				if take >= 1 then
					animal.Pending -= take
					amount += take
				end
			end
			collected += amount
		end
	end
	if collected >= 1 then
		EconomyService.addCoins(player, collected)
	end
	PlayerDataService.markDirty(player)
	refreshPens(player)
	return math.floor(earned), collected
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
-- `options.Evict` is for a Robux animal that has to fit: it sells the oldest unpaid animal
-- already waiting. A wash that finds both slots full sells that animal first, then the
-- animal behind it steps forward. Paid animals are left for the keep-or-sell prompt.
-- `options.Paid`: Robux animals, which are never pushed out themselves.
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

-- Puts a bought animal straight into the player's hands. Anything already carried goes back
-- to the cache first. Returns false when it can't be carried right now (no zoo, or no
-- character to hold it), so the caller can queue it instead.
function ZooService.giveToCarry(player: Player, species: string, mutation: string): boolean
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local hand = character
		and (character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")) :: BasePart?
	if not zoo or not data or not hand or not humanoid or humanoid.Health <= 0 then
		return false
	end
	if zoo.CarriedId then
		returnCarryToCache(player)
	end
	-- Carried animals are cache records too (the carried one just isn't "waiting").
	local record: CachedAnimal = {
		Id = tostring(data.NextAnimalId),
		Species = species,
		Mutation = mutation,
		Paid = true,
	}
	data.NextAnimalId += 1
	table.insert(data.Cache, record)
	zoo.CarriedId = record.Id
	zoo.CarryModel = AnimalService.buildCarryModel(species, mutation, hand)
	PlayerDataService.markDirty(player)
	refreshAll(player)
	GuideService.onPickedUp(player)
	return true
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
	model:SetAttribute(WALK_PICKUP, nil)
	AnimalService.resize(model, AnimalService.bodyScale(record.Species))
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
		Arriving = {},
		OverflowModels = {},
		CarriedId = nil,
		CarryModel = nil,
		Cleaner = Janitor.new(),
		PadDebounce = {},
	}
	zoos[player] = zoo
	local data = PlayerDataService.get(player)
	if data and data.IntroWashesLeft <= 0 then
		WorldBuilder.setYardShown(bay, true)
	end
	if data then
		FarmDecor.apply(bay, data.BarnTier)
		for _, animal in data.Animals do
			placeInPen(zoo, animal, AnimalService.buildZooAnimal(animal.Species, animal.Mutation), data)
		end
		for _, record in data.Cache do
			buildCacheModel(zoo, record)
		end
		-- A save can hold one more than fits (an animal carried at leave time). Move the
		-- extras onto the overflow list instead of selling them.
		local guard = 0
		while #waitingRecords(zoo, data) > GameConfig.Cache.Slots and guard < 4 do
			guard += 1
			local list = waitingRecords(zoo, data)
			local extra: CachedAnimal? = nil
			for index = #list, 1, -1 do
				if not list[index].Paid then
					extra = list[index]
					break
				end
			end
			if not extra then
				break
			end
			removeCached(data, extra.Id)
			table.insert(data.Overflow, extra)
		end
		for index, record in data.Overflow do
			if not zoo.OverflowModels[record.Id] then
				local model = AnimalService.buildZooAnimal(record.Species, record.Mutation)
				parkOverflow(zoo, record, model, index)
			end
		end
	end

	local function connect(signal: RBXScriptSignal, fn: (...any) -> ())
		zoo.Cleaner:Add(signal:Connect(fn))
	end
	for i = 1, LAST_PEN do
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
					pickUpFromPen(player, i, 1)
				end
			end)
		end
		local sellPrompt = post and post:FindFirstChild("PenSellPrompt") :: ProximityPrompt?
		if sellPrompt then
			connect(sellPrompt.Triggered, function(who: Player)
				if who == player and not zoo.CarriedId then
					sellFromPen(player, i, 1)
				end
			end)
		end
		local prompt2 = post and post:FindFirstChild("PenPrompt2") :: ProximityPrompt?
		if prompt2 then
			connect(prompt2.Triggered, function(who: Player)
				if who == player and not zoo.CarriedId then
					sellFromPen(player, i, 2)
				end
			end)
		end
		local function onPet(slot: number)
			return function(who: Player)
				if who ~= player or zoo.CarriedId then
					return
				end
				local data = PlayerDataService.get(player)
				local occupants = data and animalsInPen(data, i)
				local occupant = occupants and occupants[slot]
				if occupant then
					social().togglePet(player, occupant.Id)
					refreshPens(player)
				end
			end
		end
		local petPrompt = post and post:FindFirstChild("PetPrompt") :: ProximityPrompt?
		if petPrompt then
			connect(petPrompt.Triggered, onPet(1))
		end
		local petPrompt2 = post and post:FindFirstChild("PetPrompt2") :: ProximityPrompt?
		if petPrompt2 then
			connect(petPrompt2.Triggered, onPet(2))
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
	local counter = zooFolder and zooFolder:FindFirstChild("ExpandCounter", true)
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
	fireOverflow(player)
	ZooService.sendIndex(player, nil)
end

-- Dev level keys (DevService): jumps the farm to any barn tier, up or down, to look at each
-- level's pens and scenery. It's saved like a bought barn. Animals in pens the new level
-- doesn't have are hidden until it comes back; a save left like that rehomes them to the
-- cache on the next load.
function ZooService.devSetBarnTier(player: Player, tier: number)
	local zoo = zoos[player]
	local data = PlayerDataService.get(player)
	if not zoo or not data then
		return
	end
	tier = math.clamp(math.floor(tier), 0, #GameConfig.Zoo.Expansions)
	data.BarnTier = tier
	data.ZooSize = PlayerDataService.pensForTier(tier)
	if data.IntroWashesLeft > 0 then
		data.IntroWashesLeft = 0
		WorldBuilder.setYardShown(zoo.Bay, true)
		yardRevealed:FireClient(player)
		GuideService.onWashCompleted(player) -- past the wash lesson, on to the pen one
	end
	for _, animal in data.Animals do
		local model = zoo.PenModels[animal.Id]
		if model then
			model.Parent = if penOpen(data, animal.Pen) then penOf(zoo, animal.Pen) else nil
		end
	end
	PlayerDataService.markDirty(player)
	refreshAll(player)
	FarmDecor.apply(zoo.Bay, tier, true)
end

function ZooService.detach(player: Player)
	local zoo = zoos[player]
	if not zoo then
		return
	end
	zoos[player] = nil
	zoo.Cleaner:Cleanup()
	if zoo.CarryModel then
		zoo.CarryModel:Destroy()
	end
	for _, model in zoo.PenModels do
		model:Destroy()
	end
	for _, model in zoo.CacheModels do
		model:Destroy()
	end
	for _, model in zoo.Arriving do
		model:Destroy()
	end
	for _, model in zoo.OverflowModels do
		model:Destroy()
	end
end

function ZooService.init()
	-- A Pen Storage level raises every pad's cap: redraw the caps and EMPTY labels.
	Hooks.on("StatUpgraded", function(player: Player, kind: string)
		if kind == "PenCap" then
			refreshPens(player)
		end
	end)
	-- Choices while carrying: put it back in the cache, or sell it on the spot.
	local lastAction: { [Player]: number } = {}
	local choiceJanitor = Janitor.new()
	choiceJanitor:Add(Remotes.event("CarryAction").OnServerEvent:Connect(function(player: Player, action: any)
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
	end))
	choiceJanitor:Add(Remotes.event("OverflowChoice").OnServerEvent:Connect(function(player: Player, choice: any)
		local now = os.clock()
		if (lastAction[player] or 0) > now or (choice ~= "keep" and choice ~= "sell") then
			return
		end
		lastAction[player] = now + 0.4
		if choice == "keep" then
			keepOverflow(player)
		else
			sellOverflow(player)
		end
	end))
	choiceJanitor:Add(Remotes.event("WalkPickup").OnServerEvent:Connect(function(player: Player, id: any)
		local now = os.clock()
		if (lastAction[player] or 0) > now or typeof(id) ~= "string" then
			return
		end
		lastAction[player] = now + 0.4
		pickUpWalking(player, id)
	end))
	choiceJanitor:Add(paidConfirm.OnServerEvent:Connect(function(player: Player, token: any, accepted: any)
		local pending = pendingConfirm[player]
		if not pending or pending.Token ~= token then
			return
		end
		pendingConfirm[player] = nil
		if accepted == true then
			pending.Run()
		end
	end))
	choiceJanitor:Add(Players.PlayerRemoving:Connect(function(player)
		lastAction[player] = nil
		pendingConfirm[player] = nil
	end))
	-- Income: every tick, each penned animal adds its income to its pen's pad.
	task.spawn(function()
		while true do
			task.wait(GameConfig.IncomeTickSeconds)
			for player in zoos do
				local data = PlayerDataService.get(player)
				if data and #data.Animals > 0 then
					local multiplier = Hooks.apply("IncomeMultiplier", 1, player)
					local zoo = zoos[player]
					local tick = 0
					for _, animal in data.Animals do
						local amount = ZooService.income(animal.Species, animal.Mutation)
							* multiplier
							* GameConfig.IncomeTickSeconds
						tick += credit(zoo, data, animal, amount) -- a full pad stops filling
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
