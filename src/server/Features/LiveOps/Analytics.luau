-- AnalyticsService: the onboarding funnel (each step logged once per player, remembered in
-- data.Extra.LiveOps.Funnel) and economy sources: wash rewards, sales, and cash earned onto
-- the pen pads (pen income, batched per player, and offline earnings). Pad cash counts as a
-- source when it's earned, not when it's collected, so collecting it (or the pad cash paid out
-- with a sale) is not logged again. endingBalance is always the wallet (data.Coins).
-- Players who had already washed animals before the funnel existed skip it entirely.
-- Every AnalyticsService call is wrapped in pcall: it can error in Studio or when throttled.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
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

local function logStep(player: Player, step: number)
	local state = Common.state(player)
	local key = "S" .. step
	if not state or state.Funnel[key] or not player.Parent then
		return
	end
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
		local state = Common.state(player)
		local data = PlayerDataService.get(player)
		if not state or not data then
			return
		end
		if next(state.Funnel) == nil and data.LifetimeAnimalsWashed > 0 then
			for step in STEPS do
				state.Funnel["S" .. step] = true -- a returning player from before the funnel
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
	Hooks.on("PlayerLeaving", function(player: Player)
		flushIncome(player) -- profile still loaded here
		unloggedIncome[player] = nil
	end)
	Offline.onEarned = function(player: Player, amount: number)
		-- Deposited on the pads, so the wallet balance doesn't include it yet.
		logSource(player, amount, Enum.AnalyticsEconomyTransactionType.TimedReward, "OfflineEarnings")
	end
	Players.PlayerRemoving:Connect(function(player)
		task.defer(function() -- after PlayerLeaving's flush, whichever handler runs first
			unloggedIncome[player] = nil
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
				checkProgress(player)
			end
		end
	end)
end

return Analytics
