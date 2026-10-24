-- Helpers shared by the LiveOps modules: the saved state under data.Extra.LiveOps (repaired
-- the first time it is read each session), UTC day maths, the replicated state folder,
-- announcements and the developer check.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Parent.Parent.Services
local PlayerDataService = require(Services.PlayerDataService)

-- Saved per player. Funnel keys are "S1".."S7" (onboarding steps already logged).
-- Milestones map a progression key to the play-seconds when it was first reached.
-- -1 means the player already had it before timing existed, so no duration was logged.
export type State = {
	LastSeen: number?, -- unix seconds
	DailyDay: number?, -- UTC day number of the last Daily Dirty Animal
	BestStars: number,
	Funnel: { [string]: boolean },
	WashesRolled: number?, -- animals that walked in; gold/rainbow pity uses this, never shown
	PlaySeconds: number, -- seconds actually in a server, across sessions
	Milestones: { [string]: number },
	OfflineDouble: number, -- welcome-back cash that can still be doubled once
	RareClock: number, -- play seconds toward the next guaranteed rarer walk-in
	CheckInDay: number?, -- UTC day number of the last check-in claim
	CheckInCount: number, -- days claimed in the current seven-day chart (0..7)
	EarningsBuff: boolean, -- check-in day 4: permanent income multiplier
	ProWasher: boolean, -- check-in day 6: PRO WASHER chat title
	CheckInUnlocked: boolean, -- has upgraded gear once and placed an animal; the chart shows from then on
}

local Common = {}

Common.DAY = 86400
Common.STATE_FOLDER = "LiveOpsState" -- ReplicatedStorage folder; storm state lives in its attributes
Common.STARS_ATTRIBUTE = "ZooStars" -- set on each Player

local repaired: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function finite(value: any): number?
	if typeof(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

-- The player's LiveOps state (created and validated on first read). nil before the profile loads.
function Common.state(player: Player): State?
	local data = PlayerDataService.get(player)
	if not data then
		return nil
	end
	local raw = data.Extra.LiveOps
	if typeof(raw) ~= "table" then
		raw = {}
		data.Extra.LiveOps = raw
	end
	if not repaired[raw] then
		repaired[raw] = true
		local lastSeen = finite(raw.LastSeen)
		raw.LastSeen = if lastSeen and lastSeen > 0 then math.floor(lastSeen) else nil
		local day = finite(raw.DailyDay)
		raw.DailyDay = if day and day > 0 then math.floor(day) else nil
		raw.BestStars = math.clamp(math.floor(finite(raw.BestStars) or 0), 0, 5)
		local funnel = {}
		if typeof(raw.Funnel) == "table" then
			for key, done in raw.Funnel do
				if typeof(key) == "string" and done == true then
					funnel[key] = true
				end
			end
		end
		raw.Funnel = funnel
		local milestones = {}
		if typeof(raw.Milestones) == "table" then
			for key, done in raw.Milestones do
				if typeof(key) == "string" and #key <= 40 then
					if done == true then
						milestones[key] = -1
					elseif typeof(done) == "number" and done == done and done >= -1 and done < math.huge then
						milestones[key] = math.floor(done)
					end
				end
			end
		end
		raw.Milestones = milestones
	end
	raw.PlaySeconds = math.clamp(math.floor(finite(raw.PlaySeconds) or 0), 0, 315360000)
	raw.OfflineDouble = math.max(0, math.floor(finite(raw.OfflineDouble) or 0))
	raw.RareClock = math.max(0, math.floor(finite(raw.RareClock) or 0))
	local checkInDay = finite(raw.CheckInDay)
	raw.CheckInDay = if checkInDay and checkInDay > 0 then math.floor(checkInDay) else nil
	raw.CheckInCount = math.clamp(math.floor(finite(raw.CheckInCount) or 0), 0, 7)
	raw.EarningsBuff = raw.EarningsBuff == true
	raw.ProWasher = raw.ProWasher == true
	raw.CheckInUnlocked = raw.CheckInUnlocked == true
	-- Seed from washes already finished so a zoo in progress still hits the next pity mark.
	-- Counted when an animal walks in. Not replicated.
	local rolled = finite(raw.WashesRolled)
	raw.WashesRolled = if rolled and rolled >= 0
		then math.floor(rolled)
		else math.floor(finite(data.LifetimeAnimalsWashed) or 0)
	return raw :: State
end

-- UTC unix time. Schedules and saved LastSeen use this so every server agrees.
-- It is not the clock clients count down with; replicated end times go through synced().
function Common.now(): number
	return os.time()
end

-- Shift a unix instant into Workspace:GetServerTimeNow() space. Clients subtract
-- GetServerTimeNow() from attributes written with this, so the countdown matches the
-- server even when os.time() and the synced clock disagree.
function Common.synced(unix: number): number
	if typeof(unix) ~= "number" or unix ~= unix or unix <= 0 or unix == math.huge then
		return 0
	end
	return unix + (Workspace:GetServerTimeNow() - os.time())
end

-- How far os.time() and the synced server clock are apart, in seconds. Offline pay
-- treats anything beyond a small tolerance as clock desync, not time the player was away.
function Common.clockSkew(): number
	return math.abs(os.time() - Workspace:GetServerTimeNow())
end

function Common.utcDay(now: number?): number
	return math.floor((now or os.time()) / Common.DAY)
end

-- Weekday of a UTC day number: 1 = Sunday ... 7 = Saturday (day 0 was a Thursday).
function Common.weekday(day: number): number
	return (day + 4) % 7 + 1
end

function Common.isDeveloper(player: Player): boolean
	return RunService:IsStudio() or (game.CreatorId ~= 0 and player.UserId == game.CreatorId)
end

-- Server-wide announcement through the core HUD (coloured like the given rarity tier).
function Common.announce(text: string, rarityKey: string)
	Remotes.event("Announcement"):FireAllClients(text, rarityKey)
end

function Common.stateFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(Common.STATE_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = Common.STATE_FOLDER
	folder.Parent = ReplicatedStorage
	return folder
end

return Common
