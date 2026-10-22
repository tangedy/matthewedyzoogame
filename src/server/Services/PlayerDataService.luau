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

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Types = require(ReplicatedStorage.Shared.Types)

local SCHEMA_VERSION = 1

export type SavedData = {
	SchemaVersion: number,
	Coins: number,
	ToolTier: number,
	LifetimeAnimalsWashed: number,
	TutorialCompleted: boolean,
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
	}
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
	local tier = cleanCount(raw.ToolTier)
	data.ToolTier = if ToolConfig[tier] then tier else 1
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
	local snapshot = table.clone(profile.Data)
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
