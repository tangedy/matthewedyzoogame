-- Loads, validates, saves, and exposes player progression.
--
-- ProfileService owns the session lock, autosave, and release. A failed load (or Studio
-- with API access off) gives the player a temporary profile that is NEVER saved, so a bad
-- load can't overwrite real data with defaults.
--
-- The first time a profile opens, a save in the older DataStore (PlayerData_v1) is copied
-- across. After that, only the ProfileService store is written.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local GearLadder = require(ReplicatedStorage.Shared.GearLadder)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local Hooks = require(script.Parent.Hooks)
local MutationPayout = require(script.Parent.MutationPayout)
local ProfileService = require(script.Parent.Parent.Libs.ProfileService)

-- v1: coins, tool tier, counters. v2 added the zoo and the index (keyed by a rolled rarity).
-- v3: species have fixed rarities and walk-ins roll a mutation instead; adds the cache and
-- each pen's uncollected cash. v2 rarities map onto mutations when migrating.
-- v4: the eight-plot barn ladder. Old sizes 4/6/8 become 6 or the small barn (10).
-- v5: the Spray Hose became tier 2, so every bought tier above Basic moved up one.
-- v6: intro washes, the spawn cutscene, and overflow animals that a full cache no longer drops.
-- v7: consumable buffs store absolute expiry timestamps in Extra.Monetization
-- (SpeedEndsAt, LuckEndsAt). Removed passes are dropped when that table is read,
-- because they are no longer in the pass catalog.
-- v8: the two flex road pastures became four cages (large, medium, medium, large).
-- v9: the four road cages open together as the Pasture barn upgrade (Extra.RoadCages.Open).
--     A v8 save that had any of them open by Robux, the Axolotl or cash gets all four.
-- v10: the barn tier bought (BarnTier) is saved instead of trusting ZooSize. Pen numbers are
--     positions only; older saves map their ZooSize onto the barn they paid for.
local SCHEMA_VERSION = 10
local MAX_OVERFLOW = 8

export type CachedAnimal = {
	Id: string,
	Species: string,
	Mutation: string,
	Paid: boolean?, -- bought with Robux (truck, limited): never pushed out of the cache
}

export type OwnedAnimal = {
	Id: string,
	Species: string,
	Mutation: string,
	Pen: number,
	Pending: number, -- cash earned but not yet collected from the pen's pad
	Paid: boolean?, -- bought with Robux: selling or swapping it out asks first
}

export type SavedData = {
	SchemaVersion: number,
	Coins: number,
	ToolTier: number,
	ToolUpgrade: number, -- sub-tier bought on the current hose (GearLadder); 0 is the hose itself
	LifetimeAnimalsWashed: number,
	TutorialCompleted: boolean,
	-- First lesson is the wash. "Done" once the intro auto-sells are finished.
	GuideStep: string,
	-- Washes left in the opening auto-sell. 0 once pens and the cache are revealed.
	IntroWashesLeft: number,
	CutsceneSeen: boolean,
	-- True after the one-time copy from the pre-ProfileService DataStore.
	LegacyImported: boolean,
	-- Walk-ins seen. The older tease fields stay so saves from that system still load.
	AnimalsSeen: number,
	TenthLegendaryGiven: boolean,
	CleanUpgradeCount: number,
	TeaseOrder: number,
	AnimalsUntilTease: number,
	-- Completed washes since an unwashable animal last walked in.
	-- Each one adds ChancePerWash to the next rarity this hose cannot wash.
	WashesSinceUnwashable: number,
	-- Barns bought: 0 is the starting stalls, n is GameConfig.Zoo.Expansions[n]. This is what
	-- persists. ZooSize (pens open) is worked out from it on every load.
	BarnTier: number,
	ZooSize: number,
	Animals: { OwnedAnimal },
	Cache: { CachedAnimal },
	-- Washed animals that didn't fit the cache. They stay until the owner keeps or sells them.
	Overflow: { CachedAnimal },
	Index: { [string]: boolean }, -- "Species:Mutation" -> discovered
	NextAnimalId: number,
	-- Feature-owned data (src/server/Features). Each feature uses its own key and must
	-- validate what it reads back; only plain JSON-safe values survive a save.
	Extra: { [string]: any },
}

type Session = {
	Data: SavedData,
	Status: Types.DataStatus,
	Service: any?,
}

local PlayerDataService = {}

local storeName = if RunService:IsStudio() then GameConfig.StudioProfileStoreName else GameConfig.ProfileStoreName
local profileStore: any = nil
local sessions: { [Player]: Session } = {}
local loading: { [Player]: boolean } = {}
local leftWhileLoading: { [Player]: boolean } = {}
local leaving: { [Player]: boolean } = {}
local sessionJanitor = Janitor.new()
local studioApi: boolean? = nil

local function defaults(): SavedData
	return {
		SchemaVersion = SCHEMA_VERSION,
		Coins = GameConfig.StartingCoins,
		ToolTier = 1,
		ToolUpgrade = 0,
		LifetimeAnimalsWashed = 0,
		TutorialCompleted = false,
		GuideStep = "Wash",
		IntroWashesLeft = GameConfig.Intro.AutoSellCount,
		CutsceneSeen = false,
		LegacyImported = false,
		AnimalsSeen = 0,
		TenthLegendaryGiven = false,
		CleanUpgradeCount = 0,
		TeaseOrder = 4,
		AnimalsUntilTease = 0,
		WashesSinceUnwashable = 0,
		BarnTier = 0,
		ZooSize = GameConfig.Zoo.StartPens,
		Animals = {},
		Cache = {},
		Overflow = {},
		Index = {},
		NextAnimalId = 1,
		Extra = {},
	}
end

function PlayerDataService.indexKey(species: string, mutation: string): string
	return species .. ":" .. mutation
end

-- v2 stored a rolled rarity per animal; the closest v3 equivalent is a mutation.
local V2_RARITY_TO_MUTATION = {
	Common = "Normal",
	Rare = "Normal",
	Epic = "Normal",
	Legendary = "Gold",
	Mythic = "Rainbow",
}

local function validMutation(raw: any, version: number): string?
	if typeof(raw) ~= "string" then
		return nil
	end
	local key = if version < 3 then V2_RARITY_TO_MUTATION[raw] else raw
	return if key and MutationConfig.ByKey[key] then key else nil
end

-- Pens open at a barn tier: 0 is the starting stalls, n is GameConfig.Zoo.Expansions[n] bought.
function PlayerDataService.pensForTier(tier: number): number
	local step = GameConfig.Zoo.Expansions[tier]
	return if step and step.Pens then step.Pens else GameConfig.Zoo.StartPens
end

-- Before v10 the save kept ZooSize (pens open) instead of the barn bought. Every ladder up to
-- v9 sold the same barns in the same order at these sizes: Small 10, Medium 14, Large 17,
-- Gargantuan 19 or 22, Mega 24. Mega is gone, so it keeps the top barn.
local LEGACY_BARN_PENS = { 10, 14, 17, 19 }

local function legacyBarnTier(zooSize: number): number
	-- 8 and 12 only exist in the v9 build of this layout (no old ladder stopped there).
	if zooSize == 8 then
		return 1
	elseif zooSize == 12 then
		return 3
	end
	local tier = 0
	for index, pens in LEGACY_BARN_PENS do
		if zooSize >= pens then
			tier = index
		end
	end
	return math.min(tier, #GameConfig.Zoo.Expansions)
end

-- True when this profile has already spent Robux, so the medium road cages stay open.
-- Kept in step with MonetizationState's PastureUnlocked inference.
local function spentRobux(extra: any): boolean
	if typeof(extra) ~= "table" then
		return false
	end
	local mon = extra.Monetization
	if typeof(mon) ~= "table" then
		return false
	end
	if mon.PastureUnlocked == true then
		return true
	end
	if typeof(mon.Receipts) == "table" and #mon.Receipts > 0 then
		return true
	end
	if typeof(mon.PendingAnimals) == "table" and #mon.PendingAnimals > 0 then
		return true
	end
	local function flagged(value: any): boolean
		if typeof(value) ~= "table" then
			return false
		end
		for _, on in value do
			if on == true then
				return true
			end
		end
		return false
	end
	if flagged(mon.Passes) or flagged(mon.Once) then
		return true
	end
	local function positive(value: any): boolean
		return typeof(value) == "number" and value > 0
	end
	return positive(mon.SuperSoapLeft)
		or positive(mon.AutoCollectLeft)
		or positive(mon.LuckyLeft)
		or positive(mon.SpeedEndsAt)
		or positive(mon.LuckEndsAt)
end

local function sidePastureOpen(raw: any): boolean
	local extra = raw.Extra
	local mon = if typeof(extra) == "table" then extra.Monetization else nil
	if typeof(mon) == "table" then
		if mon.SidePastureUnlocked == true then
			return true
		end
		if typeof(mon.Once) == "table" and mon.Once.SidePasture == true then
			return true
		end
		if typeof(mon.PendingAnimals) == "table" then
			for _, entry in mon.PendingAnimals do
				if typeof(entry) == "table" and entry.Species == "Axolotl" then
					return true
				end
			end
		end
	end
	local function hasAxolotl(list: any): boolean
		if typeof(list) ~= "table" then
			return false
		end
		for _, animal in list do
			if typeof(animal) == "table" and animal.Species == "Axolotl" then
				return true
			end
		end
		return false
	end
	if hasAxolotl(raw.Animals) or hasAxolotl(raw.Cache) or hasAxolotl(raw.Overflow) then
		return true
	end
	if typeof(raw.Index) == "table" then
		for key, discovered in raw.Index do
			if discovered == true and typeof(key) == "string" and string.match(key, "^Axolotl:") then
				return true
			end
		end
	end
	return false
end

-- Copies plain data (strings, numbers, booleans, tables of those), dropping anything else.
local function plainCopy(value: any, depth: number): any
	local kind = typeof(value)
	if kind == "string" or kind == "boolean" then
		return value
	elseif kind == "number" then
		return if value == value and value ~= math.huge and value ~= -math.huge then value else nil
	elseif kind == "table" and depth < 6 then
		local out = {}
		for k, v in value do
			if typeof(k) == "string" or typeof(k) == "number" then
				out[k] = plainCopy(v, depth + 1)
			end
		end
		return out
	end
	return nil
end
PlayerDataService.plainCopy = function(value: any): any
	return plainCopy(value, 0)
end

local function cleanCount(value: any): number
	if typeof(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
		return 0
	end
	return math.floor(value)
end

-- Never trust stored values blindly: coerce each field into its valid range.
local function sanitize(raw: any): SavedData
	local data = defaults()
	if typeof(raw) ~= "table" then
		return data
	end
	-- Future schema migrations go here, keyed on raw.SchemaVersion.
	data.Coins = cleanCount(raw.Coins)
	data.LifetimeAnimalsWashed = cleanCount(raw.LifetimeAnimalsWashed)
	data.TutorialCompleted = raw.TutorialCompleted == true
	data.Extra = if typeof(raw.Extra) == "table" then plainCopy(raw.Extra, 0) else {}
	local tier = cleanCount(raw.ToolTier)
	-- v5 added the Spray Hose as tier 2, so every bought tier moved up one.
	if cleanCount(raw.SchemaVersion) < 5 and tier >= 2 then
		tier += 1
	end
	data.ToolTier = if ToolConfig[tier] then tier else 1
	data.ToolUpgrade = math.min(cleanCount(raw.ToolUpgrade), GearLadder.upgradeCount(data.ToolTier))

	local version = cleanCount(raw.SchemaVersion)
	-- The barn bought is what's saved; the pens it opens come from the current layout.
	local barnTier: number
	if version >= 10 then
		barnTier = math.min(cleanCount(raw.BarnTier), #GameConfig.Zoo.Expansions)
	else
		local zooSize = cleanCount(raw.ZooSize)
		-- v4 replaced the 4/6/8 pen row with face stalls (6) and a small barn (10).
		if version < 4 and (zooSize == 6 or zooSize == 8) then
			zooSize = 10
		end
		barnTier = legacyBarnTier(zooSize)
	end
	data.BarnTier = barnTier
	data.ZooSize = PlayerDataService.pensForTier(barnTier)
	data.NextAnimalId = math.max(cleanCount(raw.NextAnimalId), 1)

	if typeof(raw.Index) == "table" then
		for key, discovered in raw.Index do
			if typeof(key) == "string" and discovered == true then
				local species, variant = string.match(key, "^(%w+):(%w+)$")
				local mutation = validMutation(variant, version)
				if species and AnimalConfig.Animals[species] and mutation then
					data.Index[PlayerDataService.indexKey(species, mutation)] = true
				end
			end
		end
	end

	local usedIds: { [string]: boolean } = {}
	local function validAnimal(animal: any): (string?, string?)
		if typeof(animal) ~= "table" or typeof(animal.Id) ~= "string" or usedIds[animal.Id] then
			return nil, nil
		end
		if typeof(animal.Species) ~= "string" or not AnimalConfig.Animals[animal.Species] then
			return nil, nil
		end
		local mutation = validMutation(if version < 3 then animal.Rarity else animal.Mutation, version)
		if not mutation then
			return nil, nil
		end
		usedIds[animal.Id] = true
		return animal.Species, mutation
	end

	if typeof(raw.Animals) == "table" then
		local usedSlots: { [number]: number } = {}
		local spent = spentRobux(raw.Extra)
		local sideOpen = sidePastureOpen(raw)
		local legacyRoad = version < 8
		local oldLeft = GameConfig.Zoo.MaxPens + 1
		local oldRight = oldLeft + 1
		local held = {}
		local displaced = {}
		-- Before v9 each road cage opened on its own; any one of them open opens all four.
		local function ownedBefore(cage: any, offset: number): boolean
			local mon = raw.Extra
			local savedMon = if typeof(mon) == "table" then mon.Monetization else nil
			local bought = if typeof(savedMon) == "table" then savedMon.CashCages else nil
			if typeof(bought) == "table" and bought[tostring(offset)] == true then
				return true
			end
			if cage.Unlock == "AnyRobux" then
				return spent or sideOpen
			elseif cage.Unlock == "Axolotl" then
				return sideOpen
			elseif cage.Unlock == "Cash" then
				return typeof(savedMon) == "table" and savedMon.CashPastureUnlocked == true
			end
			return false
		end
		if version < 9 then
			for offset, cage in GameConfig.Zoo.RoadCages do
				if ownedBefore(cage, offset) then
					data.Extra.RoadCages = { Open = true }
					break
				end
			end
		end
		local function ownsRoad(): boolean
			local cages = data.Extra.RoadCages
			return typeof(cages) == "table" and cages.Open == true
		end
		local function pushAnimal(animal: any, species: string, mutation: string, pen: number)
			table.insert(data.Animals, {
				Id = animal.Id,
				Species = species,
				Mutation = mutation,
				Pen = pen,
				Pending = cleanCount(animal.Pending),
				Paid = if animal.Paid == true then true else nil,
			})
			data.Index[PlayerDataService.indexKey(species, mutation)] = true
		end
		for _, animal in raw.Animals do
			local pen = if typeof(animal) == "table" then cleanCount(animal.Pen) else 0
			local species, mutation = validAnimal(animal)
			if not species or not mutation then
				continue
			end
			if legacyRoad and (pen == oldLeft or pen == oldRight) then
				table.insert(held, {
					Order = #held,
					Pen = pen,
					Id = animal.Id,
					Species = species,
					Mutation = mutation,
					Pending = cleanCount(animal.Pending),
					Paid = animal.Paid == true,
					Body = AnimalConfig.Animals[species].BodyClass,
				})
				continue
			end
			local cage = GameConfig.Zoo.RoadCages[pen - GameConfig.Zoo.MaxPens]
			local inZoo = pen >= 1 and pen <= data.ZooSize
			-- A pen this layout no longer has (a bigger old zoo, a removed road cage) or a
			-- doubled-up pen: rehomed below instead of dropped.
			if (cage and (not ownsRoad() or usedSlots[pen])) or (not cage and (not inZoo or usedSlots[pen])) then
				table.insert(displaced, {
					Id = animal.Id,
					Species = species,
					Mutation = mutation,
					Pending = cleanCount(animal.Pending),
					Paid = if animal.Paid == true then true else nil,
				})
				continue
			end
			usedSlots[pen] = 1
			pushAnimal(animal, species, mutation, pen)
		end
		if #held > 0 then
			table.sort(held, function(a, b)
				local aRight = a.Body == "ExtraLarge" and a.Pen == oldRight
				local bRight = b.Body == "ExtraLarge" and b.Pen == oldRight
				if aRight ~= bRight then
					return aRight
				end
				if a.Pen ~= b.Pen then
					return a.Pen < b.Pen
				end
				return a.Order < b.Order
			end)
			local axolotlPen: number? = nil
			local cashPen: number? = nil
			local mediumPens = {}
			for index, cage in GameConfig.Zoo.RoadCages do
				local pen = GameConfig.Zoo.MaxPens + index
				if cage.Unlock == "Axolotl" then
					axolotlPen = pen
				elseif cage.Unlock == "Cash" then
					cashPen = pen
				else
					table.insert(mediumPens, pen)
				end
			end
			local function markCash()
				if typeof(data.Extra.Monetization) ~= "table" then
					data.Extra.Monetization = {}
				end
				data.Extra.Monetization.CashPastureUnlocked = true
				data.Extra.RoadCages = { Open = true }
			end
			local function parkSpare(entry)
				data.Coins += entry.Pending
				table.insert(data.Overflow, {
					Id = entry.Id,
					Species = entry.Species,
					Mutation = entry.Mutation,
					Paid = if entry.Paid then true else nil,
				})
			end
			local mediumCount = 0
			local anyRobux = spent or sideOpen
			for _, entry in held do
				if entry.Body == "Large" and anyRobux and mediumCount < #mediumPens then
					mediumCount += 1
					usedSlots[mediumPens[mediumCount]] = 1
					pushAnimal(entry, entry.Species, entry.Mutation, mediumPens[mediumCount])
				elseif entry.Body == "ExtraLarge" and sideOpen and axolotlPen and not usedSlots[axolotlPen] then
					usedSlots[axolotlPen] = 1
					pushAnimal(entry, entry.Species, entry.Mutation, axolotlPen)
				elseif entry.Body == "ExtraLarge" and cashPen and not usedSlots[cashPen] then
					usedSlots[cashPen] = 1
					markCash()
					pushAnimal(entry, entry.Species, entry.Mutation, cashPen)
				else
					parkSpare(entry)
				end
			end
		end

		-- The road cages were pastures for large animals before they became two stalls and two
		-- medium pens. Anything that no longer fits moves to a free cage it fits, else overflow.
		local misfits = {}
		for i = #data.Animals, 1, -1 do
			local animal = data.Animals[i]
			local cage = GameConfig.Zoo.RoadCages[animal.Pen - GameConfig.Zoo.MaxPens]
			if cage and not AnimalConfig.fits(AnimalConfig.Animals[animal.Species].BodyClass, cage.Class) then
				table.remove(data.Animals, i)
				usedSlots[animal.Pen] = nil
				table.insert(misfits, animal)
			end
		end
		for _, animal in misfits do
			local body = AnimalConfig.Animals[animal.Species].BodyClass
			local moved = false
			for offset, cage in GameConfig.Zoo.RoadCages do
				local pen = GameConfig.Zoo.MaxPens + offset
				if not usedSlots[pen] and AnimalConfig.fits(body, cage.Class) then
					usedSlots[pen] = 1
					animal.Pen = pen
					table.insert(data.Animals, animal)
					moved = true
					break
				end
			end
			if not moved then
				data.Coins += animal.Pending
				table.insert(data.Overflow, {
					Id = animal.Id,
					Species = animal.Species,
					Mutation = animal.Mutation,
					Paid = animal.Paid,
				})
			end
		end

		-- Displaced animals take the free pens first, then wait in overflow. Pad cash is paid out.
		for _, entry in displaced do
			data.Index[PlayerDataService.indexKey(entry.Species, entry.Mutation)] = true
			data.Coins += entry.Pending
			local free: number? = nil
			for pen = 1, data.ZooSize do
				if not usedSlots[pen] then
					free = pen
					break
				end
			end
			if free then
				usedSlots[free] = 1
				entry.Pending = 0
				pushAnimal(entry, entry.Species, entry.Mutation, free)
			else
				table.insert(data.Overflow, {
					Id = entry.Id,
					Species = entry.Species,
					Mutation = entry.Mutation,
					Paid = entry.Paid,
				})
			end
		end
	end

	if typeof(raw.Cache) == "table" then
		for _, animal in raw.Cache do
			-- One extra: an animal that was being carried when the player left is still listed.
			if #data.Cache >= GameConfig.Cache.Slots + 1 then
				break
			end
			local species, mutation = validAnimal(animal)
			if species and mutation then
				table.insert(data.Cache, {
					Id = animal.Id,
					Species = species,
					Mutation = mutation,
					Paid = if animal.Paid == true then true else nil,
				})
			end
		end
	end

	if typeof(raw.Overflow) == "table" then
		for _, animal in raw.Overflow do
			local species, mutation = validAnimal(animal)
			if species and mutation then
				table.insert(data.Overflow, {
					Id = animal.Id,
					Species = species,
					Mutation = mutation,
					Paid = if animal.Paid == true then true else nil,
				})
			end
		end
	end

	-- Overflow holds at most MAX_OVERFLOW. Extras are sold at their sell value (newest unpaid
	-- first) rather than dropped; Robux animals are always kept.
	local index = #data.Overflow
	while #data.Overflow > MAX_OVERFLOW and index >= 1 do
		local animal = data.Overflow[index]
		if not animal.Paid then
			local income = AnimalConfig.Animals[animal.Species].Income * MutationPayout.multiplier(animal.Mutation)
			data.Coins += math.floor(income * GameConfig.SellValueSeconds)
			table.remove(data.Overflow, index)
		end
		index -= 1
	end

	-- The opening lesson is the wash only. Pickup, place, and the hose stand are no longer
	-- taught, so an old save sitting on those steps is finished. A zoo that's already
	-- underway does not replay the baby-elephant intro.
	local played = data.LifetimeAnimalsWashed > 0 or #data.Animals > 0 or #data.Cache > 0 or #data.Overflow > 0
	data.GuideStep = if played then "Done" else "Wash"
	if raw.IntroWashesLeft == nil then
		data.IntroWashesLeft = if played then 0 else GameConfig.Intro.AutoSellCount
	else
		data.IntroWashesLeft = math.clamp(cleanCount(raw.IntroWashesLeft), 0, GameConfig.Intro.AutoSellCount)
	end
	if played and data.IntroWashesLeft > 0 then
		data.IntroWashesLeft = 0
	end
	-- The rainbow trail is the wash step. Keep it on until the opening pigs are done,
	-- including a save that was marked finished before the first one.
	if data.IntroWashesLeft > 0 then
		data.GuideStep = "Wash"
	end
	if raw.CutsceneSeen == nil then
		data.CutsceneSeen = played
	else
		data.CutsceneSeen = raw.CutsceneSeen == true
	end
	data.LegacyImported = raw.LegacyImported == true
	if raw.AnimalsSeen == nil then
		data.AnimalsSeen = data.LifetimeAnimalsWashed
		data.TenthLegendaryGiven = data.AnimalsSeen >= 10
	else
		data.AnimalsSeen = cleanCount(raw.AnimalsSeen)
		data.TenthLegendaryGiven = raw.TenthLegendaryGiven == true
	end
	if raw.CleanUpgradeCount == nil then
		data.CleanUpgradeCount = math.max(0, data.ToolTier - 1)
		data.TeaseOrder = math.clamp(4 + math.max(0, data.CleanUpgradeCount - 1), 4, 7)
		data.AnimalsUntilTease = if data.CleanUpgradeCount >= 1 then 10 else 0
	else
		data.CleanUpgradeCount = cleanCount(raw.CleanUpgradeCount)
		data.TeaseOrder = math.clamp(cleanCount(raw.TeaseOrder), 4, 7)
		data.AnimalsUntilTease = math.clamp(cleanCount(raw.AnimalsUntilTease), 0, 10)
	end
	data.WashesSinceUnwashable = math.clamp(cleanCount(raw.WashesSinceUnwashable), 0, 100000)
	return data
end

local function profileApi(): any
	if profileStore == nil then
		profileStore = (ProfileService :: any).GetProfileStore(storeName, defaults())
	end
	return profileStore
end

-- Studio with API access off cannot save. Skip ProfileService there so the player gets the
-- temporary-profile banner instead of a mock store that looks saved. Live servers always try.
local function studioCanSave(): boolean
	if not RunService:IsStudio() then
		return true
	end
	if studioApi ~= nil then
		return studioApi
	end
	local ok = pcall(function()
		DataStoreService:GetDataStore(GameConfig.StudioProfileStoreName):GetAsync("__availability")
	end)
	studioApi = ok
	return ok
end

-- ok is false when the read itself failed, so a later join can try again.
local function readLegacy(userId: number): (boolean, any?)
	local name = if RunService:IsStudio() then GameConfig.StudioDataStoreName else GameConfig.DataStoreName
	local okStore, ds = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if not okStore then
		return false, nil
	end
	local ok, record = pcall(function()
		return ds:GetAsync("Player_" .. userId)
	end)
	if not ok then
		warn(`[PlayerDataService] Legacy read failed for {userId}: {record}`)
		return false, nil
	end
	if typeof(record) == "table" and typeof(record.Data) == "table" then
		return true, record.Data
	end
	return true, nil
end

local function adopt(serviceProfile: any, raw: any): SavedData
	local clean = sanitize(raw)
	local data = serviceProfile.Data
	table.clear(data)
	for key, value in clean :: any do
		data[key] = value
	end
	return data
end

local function importLegacy(player: Player, serviceProfile: any)
	local raw = serviceProfile.Data
	if typeof(raw) == "table" and raw.LegacyImported == true then
		adopt(serviceProfile, raw)
		return
	end
	local ok, legacy = readLegacy(player.UserId)
	local source = if ok and typeof(legacy) == "table" then legacy else raw
	if typeof(source) == "table" and ok then
		source.LegacyImported = true
	end
	adopt(serviceProfile, source)
end

local function fireLeaving(player: Player)
	if leaving[player] or not sessions[player] then
		return
	end
	leaving[player] = true
	Hooks.fire("PlayerLeaving", player)
end

-- Yields. Always leaves the player with a profile; check getStatus for whether it persists.
function PlayerDataService.load(player: Player)
	if sessions[player] or loading[player] then
		return
	end
	loading[player] = true
	local serviceProfile = nil
	if studioCanSave() then
		local ok, result = pcall(function()
			return profileApi():LoadProfileAsync("Player_" .. player.UserId, "ForceLoad")
		end)
		if ok then
			serviceProfile = result
		else
			warn(`[PlayerDataService] Load failed for {player.Name}: {result}`)
		end
	end
	loading[player] = nil

	if leftWhileLoading[player] or not player.Parent then
		leftWhileLoading[player] = nil
		if serviceProfile then
			serviceProfile:Release()
		end
		return
	end

	if not serviceProfile then
		sessions[player] = {
			Data = defaults(),
			Status = "Failed",
			Service = nil,
		}
		warn(`[PlayerDataService] {player.Name} is on a temporary profile (Failed); progress will not save`)
		return
	end

	serviceProfile:AddUserId(player.UserId)
	serviceProfile:Reconcile()
	importLegacy(player, serviceProfile)
	serviceProfile:ListenToRelease(function()
		local session = sessions[player]
		if session and session.Service == serviceProfile then
			session.Service = nil
			session.Status = "Locked"
			warn(`[PlayerDataService] {player.Name}'s save opened somewhere else; progress this session won't save`)
		end
	end)

	if not player.Parent then
		serviceProfile:Release()
		return
	end

	sessions[player] = {
		Data = serviceProfile.Data,
		Status = "Loaded",
		Service = serviceProfile,
	}
end

function PlayerDataService.get(player: Player): SavedData?
	local session = sessions[player]
	return session and session.Data
end

function PlayerDataService.getStatus(player: Player): Types.DataStatus?
	local session = sessions[player]
	return session and session.Status
end

-- Yields until the player's profile exists, or the timeout passes.
function PlayerDataService.waitFor(player: Player, timeout: number): SavedData?
	local deadline = os.clock() + timeout
	while not sessions[player] and player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	return PlayerDataService.get(player)
end

-- ProfileService writes the live table on its own autosave. Callers still mark the
-- session after a change; saveNow asks for a save immediately.
function PlayerDataService.markDirty(_player: Player) end

function PlayerDataService.saveNow(player: Player)
	local session = sessions[player]
	local service = session and session.Service
	if service and service:IsActive() then
		service:Save()
	end
end

-- Final save + session release when the player leaves.
function PlayerDataService.release(player: Player)
	if loading[player] then
		leftWhileLoading[player] = true
		return
	end
	fireLeaving(player)
	local session = sessions[player]
	sessions[player] = nil
	local service = session and session.Service
	if service and service:IsActive() then
		service:Release()
	end
end

function PlayerDataService.init()
	sessionJanitor:Add(Players.PlayerRemoving:Connect(function(player)
		PlayerDataService.release(player)
		leaving[player] = nil
	end))
	-- Register after ProfileService's own close handler so this one runs first and the
	-- leaving hook's writes are in the table ProfileService then saves.
	task.spawn(function()
		pcall(function()
			(ProfileService :: any).IsLive()
		end)
		task.wait()
		game:BindToClose(function()
			for player in sessions do
				fireLeaving(player)
			end
		end)
	end)
end

return PlayerDataService
