-- Retention and live-ops systems, started together by the feature loader:
--   MudStorm      scheduled server-wide Mud Storm (+ developer start/stop)
--   VariantEvents rotating Gold Rush / Rainbow Rush / ... (odds in DevParams.json)
--   Daily         Daily Dirty Animal (one guaranteed Rare+ walk-in per UTC day)
--   Offline      offline earnings onto the pen pads + the WELCOME BACK popup
--   Stars        1-5 star zoo rating (bay sign, HUD attribute, announcements)
--   Leaderboard  native leaderstats and the plaza TOP ZOOS board
--   Analytics    onboarding funnel and economy events
-- Saved data lives in data.Extra.LiveOps (see Common). Tuning: FeatureConfig/LiveOpsConfig.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Offline = require(script.Offline)

local LiveOps = {}

local MODULES = { "MudStorm", "VariantEvents", "Daily", "Offline", "Stars", "Leaderboard", "Analytics" }

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
