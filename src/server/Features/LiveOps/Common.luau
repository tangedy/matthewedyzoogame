-- Helpers shared by the LiveOps modules: the saved state under data.Extra.LiveOps (repaired
-- the first time it is read each session), UTC day maths, the replicated state folder,
-- announcements and the developer check.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Parent.Parent.Services
local PlayerDataService = require(Services.PlayerDataService)

-- Saved per player. Funnel keys are "S1".."S7" (onboarding steps already logged).
export type State = {
	LastSeen: number?, -- unix seconds
	DailyDay: number?, -- UTC day number of the last Daily Dirty Animal
	BestStars: number,
	Funnel: { [string]: boolean },
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
	end
	return raw :: State
end

function Common.now(): number
	return os.time()
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
