-- Offline earnings. LastSeen (unix seconds) is refreshed every minute while playing and when
-- the player leaves. On the next join, the time away (capped, then passed through the
-- "OfflineSeconds" modifier) earns a fraction of the zoo's income, deposited on the pen pads
-- once the bay and pens exist. The owner gets a "WELCOME BACK!" popup; the client fetches it
-- with LiveOpsSync if it was computed before the client was listening.

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

local function measure(player: Player)
	if awaySeconds[player] ~= nil or not player.Parent then
		return
	end
	local state = Common.state(player)
	if not state then
		return
	end
	local away = if state.LastSeen then Common.now() - state.LastSeen else 0
	awaySeconds[player] = math.clamp(away, 0, Config.MaxSeconds)
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
	if seconds < Config.MinSeconds then
		return
	end
	local modified = Hooks.apply("OfflineSeconds", seconds, player)
	if typeof(modified) == "number" and modified == modified and modified >= 0 and modified < math.huge then
		seconds = modified
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
	Hooks.on("PlayerLeaving", touch) -- PlayerLoaded (and so measure) always fires first

	task.spawn(function()
		while true do
			task.wait(Config.LastSeenInterval)
			for _, player in Players:GetPlayers() do
				if paid[player] or awaySeconds[player] ~= nil then -- only once the absence is measured
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
