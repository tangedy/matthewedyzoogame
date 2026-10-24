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
-- Every AnalyticsService call is wrapped in pcall: it can error in Studio or when throttled.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
local CURRENCY = "Cash"

local Analytics = {}

local unloggedIncome: { [Player]: number } = {} -- pen income earned since the last flush
local claimed: { [Player]: { [string]: boolean } } = {} -- this session, set before any yield
local sessionStart: { [Player]: number } = {} -- os.clock() when this visit's play time started
local funnelSession: { [Player]: string } = {}

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
	for _, step in GameConfig.Zoo.Expansions do
		if data.ZooSize >= step.Pens then
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
		if next(state.Funnel) == nil and data.LifetimeAnimalsWashed > 0 then
			local mine = {}
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
	end)
	Hooks.on("WashStarted", function(player: Player)
		logStep(player, 2)
	end)
	Hooks.on("WashProgress", function(player: Player)
		logStep(player, 3)
	end)
	Hooks.on("WashCompleted", function(player: Player, info: Hooks.WashInfo, reward: number)
		logStep(player, 4)
		if typeof(reward) == "number" then
			logSource(player, reward, Enum.AnalyticsEconomyTransactionType.Gameplay, "Wash:" .. info.Species)
		end
	end)
	Hooks.on("AnimalPlaced", function(player: Player)
		logStep(player, 5)
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
			end
		end
	end)
end

return Analytics
