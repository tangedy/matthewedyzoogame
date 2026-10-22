-- Loads, validates, saves, and exposes player progression.
--
-- Session safety: each record carries a Session lock { JobId, LockedAt }. A server only
-- loads a record it can lock (or whose lock went stale), and only writes a record it still
-- holds the lock on. A failed or blocked load gives the player a temporary profile that is
-- NEVER saved, so a bad load can't overwrite real data with defaults.
--
-- Stored record: { SchemaVersion, Data = SavedData, Session = { JobId, LockedAt }? }

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local Hooks = require(script.Parent.Hooks)

-- v1: coins, tool tier, counters. v2 added the zoo and the index (keyed by a rolled rarity).
-- v3: species have fixed rarities and walk-ins roll a mutation instead; adds the cache and
-- each pen's uncollected cash. v2 rarities map onto mutations when migrating.
local SCHEMA_VERSION = 3

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
}

export type SavedData = {
	SchemaVersion: number,
	Coins: number,
	ToolTier: number,
	LifetimeAnimalsWashed: number,
	TutorialCompleted: boolean,
	-- First-cycle arrow guide. "Done" once they've washed the animal after visiting upgrades.
	GuideStep: string,
	-- Walk-ins seen. The older tease fields stay so saves from that system still load.
	AnimalsSeen: number,
	TenthLegendaryGiven: boolean,
	CleanUpgradeCount: number,
	TeaseOrder: number,
	AnimalsUntilTease: number,
	-- Completed washes since an unwashable animal last walked in.
	-- Each one adds ChancePerWash to the next rarity this hose cannot wash.
	WashesSinceUnwashable: number,
	ZooSize: number,
	Animals: { OwnedAnimal },
	Cache: { CachedAnimal },
	Index: { [string]: boolean }, -- "Species:Mutation" -> discovered
	NextAnimalId: number,
	-- Feature-owned data (src/server/Features). Each feature uses its own key and must
	-- validate what it reads back; only plain JSON-safe values survive a save.
	Extra: { [string]: any },
}

type Profile = {
	Key: string,
	Data: SavedData,
	Status: Types.DataStatus,
	Dirty: boolean,
	Saving: boolean,
}

local PlayerDataService = {}

local sessionId = if game.JobId ~= "" then game.JobId else "Studio"
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}
local leftWhileLoading: { [Player]: boolean } = {}
local store: DataStore? = nil
local savesInFlight = 0 -- BindToClose waits for these, including leave-saves already running

local function defaults(): SavedData
	return {
		SchemaVersion = SCHEMA_VERSION,
		Coins = 0,
		ToolTier = 1,
		LifetimeAnimalsWashed = 0,
		TutorialCompleted = false,
		GuideStep = "Wash",
		AnimalsSeen = 0,
		TenthLegendaryGiven = false,
		CleanUpgradeCount = 0,
		TeaseOrder = 4,
		AnimalsUntilTease = 0,
		WashesSinceUnwashable = 0,
		ZooSize = GameConfig.Zoo.StartPens,
		Animals = {},
		Cache = {},
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

local function isValidZooSize(size: number): boolean
	if size == GameConfig.Zoo.StartPens then
		return true
	end
	for _, step in GameConfig.Zoo.Expansions do
		if step.Pens == size then
			return true
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
	data.ToolTier = if ToolConfig[tier] then tier else 1

	-- v2 fields. A v1 record simply has none of them and keeps the defaults.
	local zooSize = cleanCount(raw.ZooSize)
	data.ZooSize = if isValidZooSize(zooSize) then zooSize else GameConfig.Zoo.StartPens
	data.NextAnimalId = math.max(cleanCount(raw.NextAnimalId), 1)

	local version = cleanCount(raw.SchemaVersion)
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
		local usedPens: { [number]: boolean } = {}
		for _, animal in raw.Animals do
			local pen = if typeof(animal) == "table" then cleanCount(animal.Pen) else 0
			if pen < 1 or pen > data.ZooSize or usedPens[pen] then
				continue
			end
			local species, mutation = validAnimal(animal)
			if species and mutation then
				usedPens[pen] = true
				table.insert(data.Animals, {
					Id = animal.Id,
					Species = species,
					Mutation = mutation,
					Pen = pen,
					Pending = cleanCount(animal.Pending),
				})
				data.Index[PlayerDataService.indexKey(species, mutation)] = true
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

	-- Guide, and the older clean-gate fields. Missing fields follow progress already on
	-- the profile, so a zoo that's underway doesn't replay the arrows. The 10th-animal
	-- tease is no longer scheduled; WashesSinceUnwashable starts at 0 when it is absent.
	local guideSteps =
		{ Wash = true, Pickup = true, Place = true, Collect = true, Upgrade = true, Repeat = true, Done = true }
	if guideSteps[raw.GuideStep] then
		data.GuideStep = raw.GuideStep
	else
		local played = data.LifetimeAnimalsWashed > 0 or #data.Animals > 0 or #data.Cache > 0
		data.GuideStep = if played then "Done" else "Wash"
	end
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

local function isLockedByOther(record: any): boolean
	local session = typeof(record) == "table" and record.Session
	if typeof(session) ~= "table" or session.JobId == sessionId then
		return false
	end
	local lockedAt = tonumber(session.LockedAt) or 0
	return os.time() - lockedAt < GameConfig.SessionLockExpiry
end

local function getStore(): DataStore?
	if store then
		return store
	end
	local name = if RunService:IsStudio() then GameConfig.StudioDataStoreName else GameConfig.DataStoreName
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if ok then
		store = result
		return result
	end
	warn("[PlayerDataService] DataStore unavailable:", result)
	return nil
end

-- Tries to load and lock. Returns status plus data (data only when Loaded).
local function tryLoad(key: string): (Types.DataStatus, SavedData?)
	local ds = getStore()
	if not ds then
		return "Failed", nil
	end
	for attempt = 1, GameConfig.LockRetryAttempts do
		local blocked = false
		local loaded: SavedData? = nil
		local ok, err = pcall(function()
			ds:UpdateAsync(key, function(record)
				if isLockedByOther(record) then
					blocked = true
					return nil -- cancel: another live server owns this profile
				end
				blocked = false
				local data = sanitize(if typeof(record) == "table" then record.Data else nil)
				loaded = data
				return {
					SchemaVersion = SCHEMA_VERSION,
					Data = data,
					Session = { JobId = sessionId, LockedAt = os.time() },
				}
			end)
		end)
		if ok and not blocked and loaded then
			return "Loaded", loaded
		end
		if not ok then
			warn(`[PlayerDataService] Load attempt {attempt} failed for {key}: {err}`)
		end
		if attempt < GameConfig.LockRetryAttempts then
			task.wait(GameConfig.LockRetryDelay)
		elseif blocked then
			return "Locked", nil
		end
	end
	return "Failed", nil
end

-- Writes only while we still hold the lock. `release` clears the lock (leaving / shutdown).
local function save(profile: Profile, release: boolean): boolean
	if profile.Status ~= "Loaded" then
		return false -- temporary profiles are never written
	end
	local ds = getStore()
	if not ds then
		return false
	end
	savesInFlight += 1 -- counted while queued too, so shutdown never sees a gap
	-- Wait for any save already in flight so writes stay ordered.
	while profile.Saving do
		task.wait()
	end
	profile.Saving = true
	-- Deep enough copy that edits during the async write can't change what's being saved.
	local snapshot = table.clone(profile.Data)
	snapshot.Animals = {}
	for i, animal in profile.Data.Animals do
		snapshot.Animals[i] = table.clone(animal) -- Pending changes every income tick
	end
	snapshot.Cache = table.clone(profile.Data.Cache)
	snapshot.Extra = plainCopy(profile.Data.Extra, 0)
	snapshot.Index = table.clone(profile.Data.Index)
	local lostLock = false
	local ok, err = pcall(function()
		ds:UpdateAsync(profile.Key, function(record)
			local session = typeof(record) == "table" and record.Session
			if typeof(session) == "table" and session.JobId ~= sessionId then
				lostLock = true
				return nil -- another server took over; never overwrite its newer data
			end
			lostLock = false
			return {
				SchemaVersion = SCHEMA_VERSION,
				Data = snapshot,
				Session = if release then nil else { JobId = sessionId, LockedAt = os.time() },
			}
		end)
	end)
	profile.Saving = false
	savesInFlight -= 1
	if not ok then
		warn(`[PlayerDataService] Save failed for {profile.Key}: {err}`)
		return false
	end
	if lostLock then
		warn(`[PlayerDataService] Lost session lock for {profile.Key}; stopped saving`)
		profile.Status = "Locked"
		return false
	end
	profile.Dirty = false
	return true
end

-- Yields. Always leaves the player with a profile; check getStatus for whether it persists.
function PlayerDataService.load(player: Player)
	if profiles[player] or loading[player] then
		return
	end
	loading[player] = true
	local key = "Player_" .. player.UserId
	local status, data = tryLoad(key)
	loading[player] = nil

	local profile: Profile = {
		Key = key,
		Data = data or defaults(),
		Status = status :: Types.DataStatus,
		Dirty = false,
		Saving = false,
	}
	if leftWhileLoading[player] then
		leftWhileLoading[player] = nil
		save(profile, true)
		return
	end
	profiles[player] = profile
	if status ~= "Loaded" then
		warn(`[PlayerDataService] {player.Name} is on a temporary profile ({status}); progress will not save`)
	end
end

function PlayerDataService.get(player: Player): SavedData?
	local profile = profiles[player]
	return profile and profile.Data
end

function PlayerDataService.getStatus(player: Player): Types.DataStatus?
	local profile = profiles[player]
	return profile and profile.Status
end

-- Yields until the player's profile exists, or the timeout passes.
function PlayerDataService.waitFor(player: Player, timeout: number): SavedData?
	local deadline = os.clock() + timeout
	while not profiles[player] and player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	return PlayerDataService.get(player)
end

function PlayerDataService.markDirty(player: Player)
	local profile = profiles[player]
	if profile then
		profile.Dirty = true
	end
end

-- Saves soon after an important change (e.g. a purchase) instead of waiting for autosave.
function PlayerDataService.saveNow(player: Player)
	local profile = profiles[player]
	if profile then
		profile.Dirty = true
		task.spawn(save, profile, false)
	end
end

-- Yields. Final save + lock release when the player leaves.
function PlayerDataService.release(player: Player)
	if loading[player] then
		leftWhileLoading[player] = true
		return
	end
	local profile = profiles[player]
	if profile then
		-- Listeners run synchronously up to their first yield, so writes they make
		-- (e.g. a last-seen time) land in this final save.
		Hooks.fire("PlayerLeaving", player)
	end
	profiles[player] = nil
	if profile then
		save(profile, true)
	end
end

function PlayerDataService.init()
	-- Autosave also refreshes LockedAt so live sessions never look stale.
	task.spawn(function()
		while true do
			task.wait(GameConfig.AutosaveInterval)
			for _, profile in profiles do
				task.spawn(save, profile, false)
			end
		end
	end)

	game:BindToClose(function()
		for player, profile in profiles do
			Hooks.fire("PlayerLeaving", player)
			profiles[player] = nil
			task.spawn(save, profile, true)
		end
		task.wait() -- let the saves above start
		local deadline = os.clock() + 25
		while savesInFlight > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)

	Players.PlayerRemoving:Connect(PlayerDataService.release)
end

return PlayerDataService
