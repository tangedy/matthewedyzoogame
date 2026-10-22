-- Offline earnings. LastSeen (server os.time(), never a client timestamp) is refreshed every
-- minute while playing and when the player leaves. On the next join, the time away earns a
-- fraction of the zoo's income onto the pen pads, once the bay exists.
--
-- The absence is clamped to MaxSeconds (6 hours; never above HardMaxSeconds). A LastSeen in
-- the future, or one from before the game existed, pays nothing. If os.time() and
-- GetServerTimeNow() disagree by more than ClockSkewSeconds, that disagreement is removed
-- from the payout so a jumped clock can't mint cash. The "OfflineSeconds" hook cannot raise
-- the result back over the cap. The owner gets a "WELCOME BACK!" popup; the client fetches
-- it with LiveOpsSync if it was computed before the client was listening.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Common = require(script.Parent.Common)
local Services = script.Parent.Parent.Parent.Services
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)
local ZooService = require(Services.ZooService)

local Config = LiveOpsConfig.Offline

export type Popup = { Amount: number, Seconds: number }

local Offline = {}

local awaySeconds: { [Player]: number } = {} -- measured at load, paid out on BayAssigned
local paid: { [Player]: boolean } = {}
local clientReady: { [Player]: boolean } = {}
local pendingPopup: { [Player]: Popup } = {}

-- Called with (player, amount) after offline cash lands on the pads (for analytics).
Offline.onEarned = nil :: ((Player, number) -> ())?

local function touch(player: Player)
	local state = Common.state(player)
	if state then
		state.LastSeen = Common.now()
		PlayerDataService.markDirty(player)
	end
end

local function payCap(): number
	local configured = if typeof(Config.MaxSeconds) == "number" then Config.MaxSeconds else 0
	local hard = if typeof(Config.HardMaxSeconds) == "number" then Config.HardMaxSeconds else 24 * 60 * 60
	return math.clamp(configured, 0, hard)
end

-- Seconds the player was actually away. Server clocks only; a bad or future LastSeen is zero.
local function absence(lastSeen: number?): number
	if typeof(lastSeen) ~= "number" then
		return 0
	end
	local now = Common.now()
	-- Edited save, or the clock stepped backwards: this is not time they were gone.
	if lastSeen < Config.EarliestLastSeen or lastSeen > now + Config.ClockSkewSeconds then
		return 0
	end
	local away = now - lastSeen
	local skew = Common.clockSkew()
	if skew > Config.ClockSkewSeconds then
		away -= skew - Config.ClockSkewSeconds
	end
	return math.clamp(away, 0, payCap())
end

local function measure(player: Player)
	if awaySeconds[player] ~= nil or not player.Parent then
		return
	end
	local state = Common.state(player)
	if not state then
		return
	end
	awaySeconds[player] = absence(state.LastSeen)
	touch(player)
end

local function payOut(player: Player)
	if paid[player] or not player.Parent then
		return
	end
	measure(player)
	local seconds = awaySeconds[player]
	if seconds == nil then
		return -- profile not loaded
	end
	paid[player] = true
	awaySeconds[player] = nil
	local modified = Hooks.apply("OfflineSeconds", seconds, player)
	if typeof(modified) == "number" and modified == modified and modified >= 0 and modified < math.huge then
		seconds = modified
	end
	seconds = math.clamp(seconds, 0, payCap())
	if seconds < Config.MinSeconds then
		return
	end
	local amount = math.floor(ZooService.totalIncome(player) * seconds * Config.Rate)
	if amount < 1 then
		return
	end
	ZooService.addToPads(player, amount)
	if Offline.onEarned then
		Offline.onEarned(player, amount)
	end
	local popup: Popup = { Amount = amount, Seconds = math.floor(seconds) }
	if clientReady[player] then
		Remotes.event("LiveOpsWelcomeBack"):FireClient(player, popup.Amount, popup.Seconds)
	else
		pendingPopup[player] = popup
	end
end

-- The client asks once when its controller starts; returns a popup computed before then.
function Offline.claimPopup(player: Player): Popup?
	if clientReady[player] then
		return nil
	end
	clientReady[player] = true
	local popup = pendingPopup[player]
	pendingPopup[player] = nil
	return popup
end

function Offline.init()
	Remotes.event("LiveOpsWelcomeBack") -- (amount, seconds)

	Hooks.on("PlayerLoaded", function(player: Player)
		measure(player) -- before anything refreshes LastSeen
	end)
	Hooks.on("BayAssigned", function(player: Player)
		payOut(player)
	end)
	Hooks.on("PlayerLeaving", function(player: Player)
		-- PlayerLoaded (and so measure) always fires first. A player who never got a bay
		-- (queued while all bays were taken) wasn't paid: carry the absence over to next time.
		local away = awaySeconds[player]
		local state = Common.state(player)
		if not paid[player] and away and state then
			state.LastSeen = Common.now() - away
			PlayerDataService.markDirty(player)
		else
			touch(player)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(Config.LastSeenInterval)
			for _, player in Players:GetPlayers() do
				if paid[player] then -- unpaid absences stay pending (see PlayerLeaving)
					touch(player)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		awaySeconds[player] = nil
		paid[player] = nil
		clientReady[player] = nil
		pendingPopup[player] = nil
	end)
end

return Offline
