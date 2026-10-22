-- HUD: coins, tool, current animal + clean meter + reward, onboarding and payout feedback.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local player = Players.LocalPlayer

local HUDController = {}

local FONT = Enum.Font.FredokaOne
local PANEL_COLOR = Color3.fromRGB(25, 30, 45)
local BAR_COLOR = Color3.fromRGB(90, 200, 255)
local BAR_DONE_COLOR = Color3.fromRGB(110, 230, 120)

local coinsLabel: TextLabel
local toolLabel: TextLabel
local washPanel: Frame
local animalLabel: TextLabel
local rewardLabel: TextLabel
local barFill: Frame
local percentLabel: TextLabel
local toast: TextLabel
local payout: TextLabel

local tutorialCompleted = false
local currentJobId: string? = nil
local currentState: Types.BayState? = nil
local currentProgress = 0
local hintShowing = false

local function round(instance: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function label(props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextScaled = true
	for key, value in props do
		(l :: any)[key] = value
	end
	return l
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "HUD"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Top-right: balance and tool
	local wallet = Instance.new("Frame")
	wallet.AnchorPoint = Vector2.new(1, 0)
	wallet.Position = UDim2.new(1, -16, 0, 12)
	wallet.Size = UDim2.fromOffset(190, 74)
	wallet.BackgroundColor3 = PANEL_COLOR
	wallet.BackgroundTransparency = 0.25
	wallet.Parent = gui
	round(wallet, 12)
	coinsLabel = label({
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(255, 220, 90),
		Text = "0 coins",
		Parent = wallet,
	})
	toolLabel = label({
		Position = UDim2.fromOffset(12, 44),
		Size = UDim2.new(1, -24, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = wallet,
	})

	-- Top-center: current animal and clean meter
	washPanel = Instance.new("Frame")
	washPanel.AnchorPoint = Vector2.new(0.5, 0)
	washPanel.Position = UDim2.new(0.5, 0, 0, 12)
	washPanel.Size = UDim2.fromOffset(340, 86)
	washPanel.BackgroundColor3 = PANEL_COLOR
	washPanel.BackgroundTransparency = 0.25
	washPanel.Visible = false
	washPanel.Parent = gui
	round(washPanel, 12)
	animalLabel = label({
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(0.6, -14, 0, 32),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = washPanel,
	})
	rewardLabel = label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 10),
		Size = UDim2.new(0.4, -14, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(255, 220, 90),
		Parent = washPanel,
	})
	local bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(14, 46)
	bar.Size = UDim2.new(1, -28, 0, 28)
	bar.BackgroundColor3 = Color3.fromRGB(60, 50, 40)
	bar.Parent = washPanel
	round(bar, 8)
	barFill = Instance.new("Frame")
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = BAR_COLOR
	barFill.Parent = bar
	round(barFill, 8)
	percentLabel = label({
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = bar,
	})

	-- Bottom-center: contextual instructions and hints
	toast = label({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -130),
		Size = UDim2.fromOffset(520, 44),
		BackgroundColor3 = PANEL_COLOR,
		BackgroundTransparency = 0.2,
		Visible = false,
		Parent = gui,
	})
	round(toast, 12)
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(520, 44)
	constraint.Parent = toast
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = toast
	toast.Size = UDim2.new(0.9, 0, 0, 44)

	-- Center: payout popup
	payout = label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(360, 70),
		TextColor3 = Color3.fromRGB(255, 220, 90),
		Visible = false,
		Parent = gui,
	})
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(90, 60, 20)
	stroke.Parent = payout
end

local function showToast(text: string?)
	if text then
		toast.Text = text
		toast.Visible = true
	else
		toast.Visible = false
	end
end

local function setProgress(progress: number, finalized: boolean)
	currentProgress = progress
	local shown = if finalized then 100 else math.min(math.floor(progress * 100), 99)
	percentLabel.Text = `{shown}% clean`
	barFill.Size = UDim2.fromScale(if finalized then 1 else math.clamp(progress, 0, 0.99), 1)
	barFill.BackgroundColor3 = if finalized then BAR_DONE_COLOR else BAR_COLOR
end

local function refreshToast()
	if currentState == "Washing" then
		if not tutorialCompleted and currentProgress < 0.1 then
			showToast(
				if UserInputService.TouchEnabled
					then "Hold SPRAY to wash. Wash off all the mud!"
					else "Hold to spray. Wash off all the mud!"
			)
		elseif hintShowing then
			showToast("Almost clean! Spray the glowing mud.")
		else
			showToast(nil)
		end
	else
		showToast(nil)
	end
end

local function applyBay(bay: Types.BaySnapshot?)
	if not bay then
		return
	end
	if bay.JobId ~= currentJobId then
		hintShowing = false
	end
	currentJobId = bay.JobId
	currentState = bay.State

	if bay.AnimalName then
		washPanel.Visible = true
		animalLabel.Text = bay.AnimalName
		rewardLabel.Text = `+{bay.Reward or 0} coins`
	end

	if bay.State == "Arriving" then
		setProgress(0, false)
		percentLabel.Text = `{bay.AnimalName or "Animal"} arriving...`
	elseif bay.State == "Washing" then
		setProgress(bay.Progress or 0, false)
	elseif bay.State == "Completing" then
		setProgress(1, true)
	elseif bay.State == "Departing" or bay.State == "Empty" then
		hintShowing = false
		if bay.State == "Empty" then
			washPanel.Visible = false
		end
	end
	refreshToast()
end

local function playPayout(reward: number)
	payout.Text = `+{reward} coins!`
	payout.Visible = true
	payout.TextTransparency = 0
	payout.Position = UDim2.fromScale(0.5, 0.42)
	local info = TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(payout, info, { Position = UDim2.fromScale(0.5, 0.32), TextTransparency = 1 })
	tween.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed then
			payout.Visible = false
		end
	end)
	tween:Play()
end

-- Persistent banner: the doc requires explaining when progress can't be saved.
local function showDataWarning(status: Types.DataStatus)
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("HUD")
	local banner = label({
		Name = "DataWarning",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 106),
		Size = UDim2.new(0.9, 0, 0, 30),
		BackgroundColor3 = Color3.fromRGB(170, 60, 50),
		BackgroundTransparency = 0.1,
		Text = if status == "Locked"
			then "Your save is still open on another server. Progress this session won't save. Rejoin in a minute."
			else "Couldn't load your save. Progress this session won't save. Rejoin to try again.",
		Parent = gui,
	})
	round(banner, 8)
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(620, 30)
	constraint.Parent = banner
end

function HUDController.init(initial: Types.InitialState)
	buildGui()
	tutorialCompleted = initial.TutorialCompleted
	coinsLabel.Text = `{initial.Coins} coins`
	toolLabel.Text = `{initial.ToolName} (Tier {initial.ToolTier})`
	applyBay(initial.Bay)
	if initial.DataStatus ~= "Loaded" then
		showDataWarning(initial.DataStatus)
	end

	local gotBay = initial.Bay ~= nil
	Remotes.event("BayStateChanged").OnClientEvent:Connect(function(bay)
		gotBay = true
		applyBay(bay)
	end)
	task.delay(4, function()
		if not gotBay then
			showToast("All wash bays are taken right now. Look around and watch!")
		end
	end)

	Remotes.event("CleaningProgressChanged").OnClientEvent
		:Connect(function(jobId: string, progress: number, showHint: boolean)
			if jobId ~= currentJobId then
				return
			end
			hintShowing = showHint
			setProgress(progress, false)
			refreshToast()
		end)
	Remotes.event("CoinsChanged").OnClientEvent:Connect(function(coins: number)
		coinsLabel.Text = `{coins} coins`
	end)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(tier: number, name: string)
		toolLabel.Text = `{name} (Tier {tier})`
	end)
	Remotes.event("WashCompleted").OnClientEvent:Connect(function(jobId: string, reward: number, coins: number)
		if jobId == currentJobId then
			setProgress(1, true)
		end
		tutorialCompleted = true
		coinsLabel.Text = `{coins} coins`
		playPayout(reward)
		refreshToast()
	end)
end

return HUDController
