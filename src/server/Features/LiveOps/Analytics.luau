-- AnalyticsService: the onboarding funnel and economy sources (wash rewards, sales, and cash
-- earned onto the pen pads, including offline earnings). Pad cash counts as a source when
-- it's earned, not when it's collected, so collecting it is not logged again.
-- endingBalance is always the wallet (data.Coins).
--
-- Progression time is play-seconds (time actually in a server), logged once when the player
-- first reaches each hose tier, each barn zone, and the $100,000 small barn. Progress that
-- was already on the profile before timing existed is marked and not logged.
--
-- Each funnel step is claimed once per session in memory before anything can yield, and
-- once per player in data.Extra.LiveOps.Funnel. A second WashProgress, a poll, and a later
-- session all no-op, so the funnel isn't counted twice. Players who had already washed
-- animals before the funnel existed skip it entirely.
-- Unwashable and Truck are per-encounter funnels: every too-dirty animal and every truck visit
-- is its own funnel session (a fresh id), so their drop-off is per encounter, not per player.
-- Every AnalyticsService call is wrapped in pcall: it can error in Studio or when throttled.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Common = require(script.Parent.Common)
local Offline = require(script.Parent.Offline)
local Services = script.Parent.Parent.Parent.Services
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

local STEPS = {
	"Joined",
	"First Wash Started",
	"First Scrub",
	"First Wash Completed",
	"First Animal Penned",
	"First Hose Upgrade",
	"First Zoo Expansion",
}
-- FirstSession: a finer funnel over the same opening, with steps inside the gaps where the
-- onboarding funnel loses players (wash -> pen, pen -> first upgrade, upgrade -> first barn).
-- Its session id is the UserId, so steps reached on a later visit still join the funnel.
local FIRST_SESSION = "FirstSession"
local FIRST_STEPS = {
	"Joined",
	"Cutscene Finished",
	"First Wash Started",
	"First Scrub",
	"Wash 1 Completed",
	"Wash 2 Completed",
	"Keeper Washed (Pens Open)",
	"First Pickup",
	"First Animal Penned",
	"First Pad Collect",
	"Can Afford Scrub Brush",
	"Opened Gear Shop",
	"Bought Scrub Brush",
	"10 Washes",
	"3 Animals Penned",
	"Starting Stalls Full",
	"25 Washes",
	"Can Afford First Barn",
	"Bought First Barn",
}
local F = {
	Joined = 1,
	Cutscene = 2,
	WashStarted = 3,
	Scrub = 4,
	Wash1 = 5,
	Wash2 = 6,
	Keeper = 7,
	Pickup = 8,
	Penned = 9,
	Collect = 10,
	AffordBrush = 11,
	OpenedShop = 12,
	BoughtBrush = 13,
	Washes10 = 14,
	Penned3 = 15,
	StallsFull = 16,
	Washes25 = 17,
	AffordBarn = 18,
	BoughtBarn = 19,
}

-- TooDirty: a player's first three encounters with an animal their gear can't wash (the "too
-- dirty" prompt). Saved as TD1-TD3. Only players who load with no washes yet get TDTrack, so
-- anyone already washing before this shipped is never counted mid-way.
local TOO_DIRTY = "TooDirty"
local TOO_DIRTY_STEPS = { "1st Too Dirty Encounter", "2nd Too Dirty Encounter", "3rd Too Dirty Encounter" }

-- Unwashable: one session per too-dirty animal. "Appeared" when it reaches the wash, "Resolved"
-- when the player lets it go (or AutoClean skips it) or it gets washed. UnwashableOutcome
-- carries the split: Skipped, Bought (Clean Now) or GearUp (a hose or Super Soap bought
-- mid-wait made it washable). Leaving first is the drop-off.
local UNWASHABLE = "Unwashable"
-- Truck: one session per visit. StillPlaying30s is logged only if the player is still in this
-- server TRUCK_RETAIN_SECONDS after the truck drives off.
local TRUCK = "Truck"
local TRUCK_RETAIN_SECONDS = 30

local CURRENCY = "Cash"

local Analytics = {}

local unloggedIncome: { [Player]: number } = {} -- pen income earned since the last flush
local claimed: { [Player]: { [string]: boolean } } = {} -- this session, set before any yield
local sessionStart: { [Player]: number } = {} -- os.clock() when this visit's play time started
local funnelSession: { [Player]: string } = {}
local encounters: { [Player]: { [string]: { Id: string, Rarity: string } } } = {} -- JobId -> open Unwashable session
local cleanNowPaid: { [Player]: boolean } = {} -- a Clean Now was granted since the last resolved encounter
local truckSteps: { [string]: { [number]: boolean } } = {} -- visitId -> Truck steps already logged

local function playSeconds(player: Player): number
	local state = Common.state(player)
	local base = if state then state.PlaySeconds else 0
	local started = sessionStart[player]
	local extra = if started then os.clock() - started else 0
	return base + math.max(0, extra)
end

local function flushPlay(player: Player)
	local state = Common.state(player)
	local started = sessionStart[player]
	if not state or not started then
		return
	end
	state.PlaySeconds += math.max(0, os.clock() - started)
	sessionStart[player] = os.clock()
	PlayerDataService.markDirty(player)
end

local function funnelId(player: Player): string
	local id = funnelSession[player]
	if not id then
		id = HttpService:GenerateGUID(false)
		funnelSession[player] = id
	end
	return id
end

-- Logs the play-seconds once. A milestone already stored (including -1 for old progress) is skipped.
local function reach(player: Player, key: string, funnel: string, step: number, stepName: string)
	local state = Common.state(player)
	if not state or state.Milestones[key] ~= nil or not player.Parent or step < 1 then
		return
	end
	local seconds = math.floor(playSeconds(player))
	state.Milestones[key] = seconds
	PlayerDataService.markDirty(player)
	local fields = {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = key,
	}
	local ok, err = pcall(function()
		AnalyticsService:LogCustomEvent(player, "ProgressionTime", seconds, fields)
	end)
	if not ok then
		warn(`[LiveOps] Progression time for {key} not logged: {err}`)
	end
	local funnelOk, funnelErr = pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, funnel, funnelId(player), step, stepName, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = tostring(seconds),
		})
	end)
	if not funnelOk then
		warn(`[LiveOps] Funnel {funnel} step {step} not logged: {funnelErr}`)
	end
end

-- Progress already on the profile has no trustworthy duration. Mark it so a later session
-- does not log "0 seconds" for a hose or barn they bought long ago.
local function backfill(player: Player)
	local data = PlayerDataService.get(player)
	local state = Common.state(player)
	if not data or not state then
		return
	end
	local dirty = false
	local function own(key: string)
		if state.Milestones[key] == nil then
			state.Milestones[key] = -1
			dirty = true
		end
	end
	if data.ToolTier > 1 then
		for tier = 1, data.ToolTier do
			own(`Hose{tier}`)
		end
	end
	local cages = data.Extra.RoadCages
	local cagesOpen = typeof(cages) == "table" and cages.Open == true
	for _, step in GameConfig.Zoo.Expansions do
		local bought = if step.RoadCages then cagesOpen else data.ZooSize >= (step.Pens or 0)
		if bought then
			own(`Zone{step.Barn}`)
			if step.Price == 100000 then
				own("Barn100K")
			end
		end
	end
	if dirty then
		PlayerDataService.markDirty(player)
	end
end

local function logStep(player: Player, step: number)
	if step < 1 or step > #STEPS or not player.Parent then
		return
	end
	local key = "S" .. step
	local mine = claimed[player]
	if not mine then
		mine = {}
		claimed[player] = mine
	end
	if mine[key] then
		return
	end
	local state = Common.state(player)
	if not state or state.Funnel[key] then
		-- Saved already, or no profile yet. Claiming a saved step stops the poll from
		-- retrying it; a missing profile is not claimed, so the step can still fire once
		-- the data is there.
		if state then
			mine[key] = true
		end
		return
	end
	mine[key] = true
	state.Funnel[key] = true
	PlayerDataService.markDirty(player)
	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, STEPS[step])
	end)
	if not ok then
		warn(`[LiveOps] Funnel step {step} not logged: {err}`)
	end
end

-- One FirstSession step, once per player (saved as F<step> in the LiveOps funnel state).
local function firstStep(player: Player, step: number)
	if step < 1 or step > #FIRST_STEPS or not player.Parent then
		return
	end
	local key = "F" .. step
	local mine = claimed[player]
	if not mine then
		mine = {}
		claimed[player] = mine
	end
	if mine[key] then
		return
	end
	local state = Common.state(player)
	if not state or state.Funnel[key] then
		if state then
			mine[key] = true
		end
		return
	end
	mine[key] = true
	state.Funnel[key] = true
	PlayerDataService.markDirty(player)
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, FIRST_SESSION, tostring(player.UserId), step, FIRST_STEPS[step])
	end)
	if not ok then
		warn(`[LiveOps] FirstSession step {step} not logged: {err}`)
	end
end

-- FirstSession steps that are counts or balances: checked on events and on the poll.
local function checkFirstSession(player: Player)
	local data = PlayerDataService.get(player)
	if not data then
		return
	end
	local washed = data.LifetimeAnimalsWashed
	if washed >= 1 then
		firstStep(player, F.Wash1)
	end
	if washed >= 2 then
		firstStep(player, F.Wash2)
	end
	if washed >= 10 then
		firstStep(player, F.Washes10)
	end
	if washed >= 25 then
		firstStep(player, F.Washes25)
	end
	local penned = #data.Animals
	if penned >= 1 then
		firstStep(player, F.Penned)
	end
	if penned >= 3 then
		firstStep(player, F.Penned3)
	end
	if penned >= GameConfig.Zoo.StartPens then
		firstStep(player, F.StallsFull)
	end
	local brush = ToolConfig[2]
	if data.ToolTier >= 2 or (brush and data.Coins >= brush.Price) then
		firstStep(player, F.AffordBrush)
	end
	if data.ToolTier >= 2 then
		firstStep(player, F.BoughtBrush)
	end
	local firstBarn = GameConfig.Zoo.Expansions[1]
	local bought = data.ZooSize > GameConfig.Zoo.StartPens
	if bought or (firstBarn and data.Coins >= firstBarn.Price) then
		firstStep(player, F.AffordBarn)
	end
	if bought then
		firstStep(player, F.BoughtBarn)
	end
end

-- The next TooDirty step for this player, if they are tracked and have steps left.
local function tooDirtyStep(player: Player)
	local state = Common.state(player)
	if not state or state.Funnel.TDTrack ~= true or not player.Parent then
		return
	end
	for step, name in TOO_DIRTY_STEPS do
		local key = "TD" .. step
		if not state.Funnel[key] then
			state.Funnel[key] = true
			PlayerDataService.markDirty(player)
			local ok, err = pcall(function()
				AnalyticsService:LogFunnelStepEvent(player, TOO_DIRTY, tostring(player.UserId), step, name)
			end)
			if not ok then
				warn(`[LiveOps] TooDirty step {step} not logged: {err}`)
			end
			return
		end
	end
end

-- One step of a per-encounter funnel.
local function encounterStep(player: Player, funnel: string, id: string, step: number, stepName: string)
	if not player.Parent then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, funnel, id, step, stepName)
	end)
	if not ok then
		warn(`[LiveOps] {funnel} step {step} not logged: {err}`)
	end
end

local function unwashableAppeared(player: Player, info: Hooks.WashInfo?)
	if typeof(info) ~= "table" or typeof(info.JobId) ~= "string" or not player.Parent then
		return
	end
	local open = encounters[player] or {}
	encounters[player] = open
	if open[info.JobId] then
		return
	end
	local def = AnimalConfig.Animals[info.Species]
	local encounter = { Id = HttpService:GenerateGUID(false), Rarity = if def then def.Rarity else "Unknown" }
	open[info.JobId] = encounter
	encounterStep(player, UNWASHABLE, encounter.Id, 1, "Appeared")
end

-- Closes the encounter for this wash, if one is open. Removed before logging so it can't resolve twice.
local function unwashableResolved(player: Player, info: Hooks.WashInfo?, outcome: string)
	local open = encounters[player]
	local encounter = open and typeof(info) == "table" and open[info.JobId]
	if not open or not encounter then
		return
	end
	open[info.JobId] = nil
	encounterStep(player, UNWASHABLE, encounter.Id, 2, "Resolved")
	local ok, err = pcall(function()
		AnalyticsService:LogCustomEvent(player, "UnwashableOutcome", 1, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = outcome,
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = encounter.Rarity,
		})
	end)
	if not ok then
		warn(`[LiveOps] UnwashableOutcome not logged: {err}`)
	end
end

-- One Truck step per visit, never twice.
local function truckStep(player: Player, visitId: string, step: number, stepName: string)
	if typeof(visitId) ~= "string" then
		return
	end
	local logged = truckSteps[visitId] or {}
	truckSteps[visitId] = logged
	if logged[step] then
		return
	end
	logged[step] = true
	encounterStep(player, TRUCK, visitId, step, stepName)
end

local function logSource(
	player: Player,
	amount: number,
	transactionType: Enum.AnalyticsEconomyTransactionType,
	sku: string
)
	local data = PlayerDataService.get(player)
	if not data or amount < 1 or not player.Parent then
		return
	end
	pcall(function()
		AnalyticsService:LogEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			CURRENCY,
			math.floor(amount),
			data.Coins,
			transactionType.Name,
			sku
		)
	end)
end

local function flushIncome(player: Player)
	local amount = unloggedIncome[player]
	if amount and amount >= 1 then
		unloggedIncome[player] = amount - math.floor(amount)
		logSource(player, amount, Enum.AnalyticsEconomyTransactionType.Gameplay, "PenIncome")
	end
end

-- Steps that are states rather than events: checked on load and then polled.
local function checkProgress(player: Player)
	local data = PlayerDataService.get(player)
	if not data then
		return
	end
	if data.ToolTier > 1 then
		logStep(player, 6)
	end
	if data.ZooSize > GameConfig.Zoo.StartPens then
		logStep(player, 7)
	end
end

function Analytics.init()
	Hooks.on("PlayerLoaded", function(player: Player)
		sessionStart[player] = os.clock()
		backfill(player)
		local data = PlayerDataService.get(player)
		if data and data.ToolTier == 1 then
			local tool = ToolConfig[1]
			reach(player, "Hose1", "HoseTier", 1, if tool then tool.Name else "Sponge")
		end
		local state = Common.state(player)
		if not state or not data then
			return
		end
		-- FirstSession only follows players who start after it shipped: anyone who has already
		-- washed but never logged its first step is skipped, so they can't enter mid-funnel.
		local noFunnelYet = next(state.Funnel) == nil
		if not state.Funnel.TDTrack and data.LifetimeAnimalsWashed == 0 then
			state.Funnel.TDTrack = true
			PlayerDataService.markDirty(player)
		end
		local skipFirst = not state.Funnel["F" .. F.Joined] and data.LifetimeAnimalsWashed > 0
		if skipFirst then
			local mine = claimed[player] or {}
			claimed[player] = mine
			for step in FIRST_STEPS do
				state.Funnel["F" .. step] = true
				mine["F" .. step] = true
			end
			PlayerDataService.markDirty(player)
		end
		if noFunnelYet and data.LifetimeAnimalsWashed > 0 then
			local mine = claimed[player] or {}
			claimed[player] = mine
			for step in STEPS do
				local key = "S" .. step
				state.Funnel[key] = true -- a returning player from before the funnel
				mine[key] = true
			end
			PlayerDataService.markDirty(player)
			return
		end
		logStep(player, 1)
		checkProgress(player)
		firstStep(player, F.Joined)
		checkFirstSession(player)
	end)
	Hooks.on("CutsceneFinished", function(player: Player)
		firstStep(player, F.Cutscene)
	end)
	Hooks.on("YardRevealed", function(player: Player)
		firstStep(player, F.Keeper)
	end)
	Hooks.on("AnimalPickedUp", function(player: Player)
		firstStep(player, F.Pickup)
	end)
	Hooks.on("TooDirtyEncounter", function(player: Player, _species: string, info: Hooks.WashInfo?)
		tooDirtyStep(player)
		unwashableAppeared(player, info)
	end)
	Hooks.on("CleanNowBought", function(player: Player)
		cleanNowPaid[player] = true
	end)
	Hooks.on("WashAbandoned", function(player: Player, info: Hooks.WashInfo)
		unwashableResolved(player, info, "Skipped")
	end)
	Hooks.on("TruckArrived", function(player: Player, visitId: string)
		truckStep(player, visitId, 1, "Arrived")
	end)
	Hooks.on("TruckLeft", function(player: Player, visitId: string)
		truckStep(player, visitId, 2, "Left")
		task.delay(TRUCK_RETAIN_SECONDS, function()
			if player.Parent then
				truckStep(player, visitId, 3, "StillPlaying30s")
			end
			truckSteps[visitId] = nil
		end)
	end)
	Hooks.on("CashCollected", function(player: Player)
		firstStep(player, F.Collect)
		checkFirstSession(player)
	end)
	-- The gear shop opens from its prompt, which fires on the server too.
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if prompt.Name == "UpgradePrompt" then
			firstStep(player, F.OpenedShop)
		end
	end)
	Hooks.on("WashStarted", function(player: Player)
		logStep(player, 2)
		firstStep(player, F.WashStarted)
	end)
	Hooks.on("WashProgress", function(player: Player)
		logStep(player, 3)
		firstStep(player, F.Scrub)
	end)
	Hooks.on("WashCompleted", function(player: Player, info: Hooks.WashInfo, reward: number)
		local open = encounters[player]
		if open and typeof(info) == "table" and open[info.JobId] then
			unwashableResolved(player, info, if cleanNowPaid[player] then "Bought" else "GearUp")
			cleanNowPaid[player] = nil
		end
		logStep(player, 4)
		checkFirstSession(player)
		if typeof(reward) == "number" then
			logSource(player, reward, Enum.AnalyticsEconomyTransactionType.Gameplay, "Wash:" .. info.Species)
		end
	end)
	Hooks.on("AnimalPlaced", function(player: Player)
		logStep(player, 5)
		checkFirstSession(player)
	end)
	Hooks.on("AnimalSold", function(player: Player, species: string, _mutation: string, value: number)
		if typeof(value) == "number" then
			logSource(player, value, Enum.AnalyticsEconomyTransactionType.Gameplay, "Sell:" .. tostring(species))
		end
	end)
	Hooks.on("IncomeTick", function(player: Player, amount: number)
		if typeof(amount) == "number" and amount > 0 and amount < math.huge then
			unloggedIncome[player] = (unloggedIncome[player] or 0) + amount
		end
	end)
	Hooks.on("ToolPurchased", function(player: Player, tier: number, name: string)
		if typeof(tier) == "number" and typeof(name) == "string" then
			reach(player, `Hose{tier}`, "HoseTier", tier, name)
		end
	end)
	Hooks.on("ZooExpanded", function(player: Player, _pens: number, price: number, barn: string)
		if typeof(barn) ~= "string" then
			return
		end
		local stepNumber = 1
		for index, step in GameConfig.Zoo.Expansions do
			if step.Barn == barn then
				stepNumber = index
				break
			end
		end
		reach(player, `Zone{barn}`, "ZooZone", stepNumber, `{barn} barn`)
		if price == 100000 then
			reach(player, "Barn100K", "First100KBarn", 1, "$100K barn")
		end
	end)
	Hooks.on("PlayerLeaving", function(player: Player)
		flushPlay(player)
		flushIncome(player) -- profile still loaded here
		sessionStart[player] = nil
		unloggedIncome[player] = nil
	end)
	Offline.onEarned = function(player: Player, amount: number)
		-- Deposited on the pads, so the wallet balance doesn't include it yet.
		logSource(player, amount, Enum.AnalyticsEconomyTransactionType.TimedReward, "OfflineEarnings")
	end
	Players.PlayerRemoving:Connect(function(player)
		task.defer(function() -- after PlayerLeaving's flush, whichever handler runs first
			unloggedIncome[player] = nil
			claimed[player] = nil
			sessionStart[player] = nil
			funnelSession[player] = nil
			encounters[player] = nil -- unresolved encounters stay at step 1: the drop-off
			cleanNowPaid[player] = nil
		end)
	end)
	task.spawn(function()
		while true do
			task.wait(LiveOpsConfig.Analytics.IncomeFlushInterval)
			for _, player in Players:GetPlayers() do
				flushIncome(player)
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(LiveOpsConfig.Analytics.PollInterval)
			for _, player in Players:GetPlayers() do
				flushPlay(player)
				checkProgress(player)
				checkFirstSession(player)
			end
		end
	end)
end

return Analytics
