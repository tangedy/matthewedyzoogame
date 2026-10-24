-- Retention and live-ops systems, started together by the feature loader:
--   MudStorm      scheduled server-wide Mud Storm (+ developer start/stop)
--   VariantEvents rotating Gold Rush / Rainbow Rush / ... (odds in DevParams.json)
--   RareGuarantee every 5 minutes of play, a walk-in one rarity above what the hose can wash
--   NewPlayer     once, in the first five minutes: a Kaiju walks the road, then a rarity boost
--   Daily         Daily Dirty Animal (one guaranteed Rare+ walk-in per UTC day)
--   CheckIn       seven-day check-in chart (cash, animals, a permanent buff and chat title)
--   Offline      offline earnings onto the pen pads + the WELCOME BACK popup
--   Stars        1-5 star zoo rating (bay sign, HUD attribute, announcements)
--   Leaderboard  native leaderstats and the plaza TOP ZOOS board
--   Analytics    onboarding funnel and economy events
-- Saved data lives in data.Extra.LiveOps (see Common). Tuning: FeatureConfig/LiveOpsConfig.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Offline = require(script.Offline)

local LiveOps = {}

-- RareGuarantee before Daily: the first NextAnimal override wins, and Daily waits a walk-in.
local MODULES = {
	"MudStorm",
	"VariantEvents",
	"RareGuarantee",
	"NewPlayer",
	"Daily",
	"CheckIn",
	"Offline",
	"Stars",
	"Leaderboard",
	"Analytics",
}

function LiveOps.init()
	-- Pull-on-start for anything the client may have missed before its controller listened.
	-- Answers once per player (later calls get nil), and never yields.
	Remotes.func("LiveOpsSync").OnServerInvoke = function(player: Player)
		return { WelcomeBack = Offline.claimPopup(player) }
	end

	for _, name in MODULES do
		local ok, err = pcall(function()
			local module = require(script:FindFirstChild(name) :: ModuleScript) :: any
			module.init()
		end)
		if not ok then
			warn(`[LiveOps] {name} failed to start: {err}`)
		end
	end
end

return LiveOps
