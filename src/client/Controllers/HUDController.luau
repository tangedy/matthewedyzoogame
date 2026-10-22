-- HUD in Steal a Brainrot style: big outlined cash on the left with income per second, the
-- animal being washed (name, rarity, mutation) with its clean meter at the top, outlined
-- hints at the bottom, payout pops and server-wide announcements.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local HUDController = {}

local BAR_COLOR = Color3.fromRGB(90, 200, 255)
local BAR_DONE_COLOR = Color3.fromRGB(90, 255, 90)

local gui: ScreenGui
local cashLabel: TextLabel
local incomeLabel: TextLabel
local toolLabel: TextLabel
local washPanel: Frame
local mutationLabel: TextLabel
local nameLabel: TextLabel
local rarityLabel: TextLabel
local barFill: Frame
local percentLabel: TextLabel
local rewardLabel: TextLabel
local toast: TextLabel
local payout: TextLabel
local announcementLabel: TextLabel

local tutorialCompleted = false
local currentJobId: string? = nil
local currentState: Types.BayState? = nil
local currentProgress = 0
local hintShowing = false

local function textLabel(parent: Instance, props: { [string]: any }, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	UIStyle.text(l, color)
	return l
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "HUD"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Left middle: cash, income, hose
	local wallet = Instance.new("Frame")
	wallet.AnchorPoint = Vector2.new(0, 0.5)
	wallet.Position = UDim2.new(0, 16, 0.5, -70)
	wallet.Size = UDim2.fromOffset(240, 110)
	wallet.BackgroundTransparency = 1
	wallet.Parent = gui
	cashLabel = textLabel(wallet, {
		Size = UDim2.new(1, 0, 0, 52),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "$0",
	}, UIStyle.CashColor)
	incomeLabel = textLabel(wallet, {
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "+$0/s",
	}, UIStyle.CashColor)
	toolLabel = textLabel(wallet, {
		Position = UDim2.fromOffset(0, 80),
		Size = UDim2.new(1, 0, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	-- Top center: the animal being washed
	washPanel = Instance.new("Frame")
	washPanel.AnchorPoint = Vector2.new(0.5, 0)
	washPanel.Position = UDim2.new(0.5, 0, 0, 8)
	washPanel.Size = UDim2.fromOffset(360, 132)
	washPanel.BackgroundTransparency = 1
	washPanel.Visible = false
	washPanel.Parent = gui
	mutationLabel = textLabel(washPanel, { Size = UDim2.new(1, 0, 0, 20) })
	nameLabel = textLabel(washPanel, { Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 34) })
	rarityLabel = textLabel(washPanel, { Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 0, 22) })
	local bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(20, 80)
	bar.Size = UDim2.new(1, -40, 0, 26)
	bar.BackgroundColor3 = Color3.fromRGB(60, 50, 40)
	bar.Parent = washPanel
	UIStyle.border(bar, 3)
	barFill = Instance.new("Frame")
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = BAR_COLOR
	barFill.Parent = bar
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 12)
	fillCorner.Parent = barFill
	percentLabel = textLabel(bar, { Size = UDim2.fromScale(1, 1), ZIndex = 2 })
	rewardLabel =
		textLabel(washPanel, { Position = UDim2.fromOffset(0, 108), Size = UDim2.new(1, 0, 0, 22) }, UIStyle.CashColor)

	-- Announcements under the wash panel
	announcementLabel = textLabel(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 176),
		Size = UDim2.new(0.9, 0, 0, 34),
		Visible = false,
	})
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(720, 34)
	constraint.Parent = announcementLabel

	-- Bottom center: contextual instructions and hints
	toast = textLabel(gui, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -140),
		Size = UDim2.new(0.9, 0, 0, 34),
		Visible = false,
	})
	local toastConstraint = Instance.new("UISizeConstraint")
	toastConstraint.MaxSize = Vector2.new(720, 34)
	toastConstraint.Parent = toast

	-- Center: payout pop
	payout = textLabel(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(360, 70),
		Visible = false,
	}, UIStyle.CashColor)
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
	percentLabel.Text = `{shown}% CLEAN`
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
		local mutation = bay.Mutation or MutationConfig.Default
		mutationLabel.Visible = mutation ~= MutationConfig.Default
		UIStyle.mutation(mutationLabel, mutation)
		nameLabel.Text = bay.AnimalName
		UIStyle.rarity(rarityLabel, bay.Rarity or "Common")
		rewardLabel.Text = `Wash reward: +{UIStyle.formatMoney(bay.Reward or 0)}`
	end

	if bay.State == "Arriving" then
		setProgress(0, false)
		percentLabel.Text = "ARRIVING..."
	elseif bay.State == "Washing" then
		setProgress(bay.Progress or 0, false)
	elseif bay.State == "Completing" then
		setProgress(1, true)
	elseif bay.State == "Departing" or bay.State == "Empty" or bay.State == "CacheFull" then
		hintShowing = false
		if bay.State ~= "Departing" then
			washPanel.Visible = false
		end
	end
	refreshToast()
end

-- Server-wide "X found a Mythic Lion!" in the tier's colour (rainbow for Zoo God).
local announcementToken = 0
local function showAnnouncement(text: string, rarityKey: string)
	UIStyle.rarity(announcementLabel, rarityKey)
	if RarityConfig.ByKey[rarityKey] == nil then
		announcementLabel.TextColor3 = Color3.new(1, 1, 1)
	end
	announcementLabel.Text = text
	announcementLabel.Visible = true
	announcementToken += 1
	local token = announcementToken
	task.delay(5, function()
		if announcementToken == token then
			announcementLabel.Visible = false
		end
	end)
end

local function playPayout(reward: number)
	payout.Text = "+" .. UIStyle.formatMoney(reward)
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

-- Persistent warning: the doc requires explaining when progress can't be saved.
local function showDataWarning(status: Types.DataStatus)
	local warning = textLabel(gui, {
		Name = "DataWarning",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(0.9, 0, 0, 20),
		Text = if status == "Locked"
			then "Your save is open on another server. Progress this session won't save. Rejoin in a minute."
			else "Couldn't load your save. Progress this session won't save. Rejoin to try again.",
	}, Color3.fromRGB(255, 110, 100))
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(720, 20)
	constraint.Parent = warning
end

function HUDController.init(initial: Types.InitialState)
	buildGui()
	tutorialCompleted = initial.TutorialCompleted
	cashLabel.Text = UIStyle.formatMoney(initial.Coins)
	toolLabel.Text = initial.ToolName
	if initial.Zoo then
		incomeLabel.Text = `+{UIStyle.formatMoney(initial.Zoo.IncomePerSecond)}/s`
	end
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
			showToast("Every zoo slot is taken right now. You'll get one as soon as a player leaves!")
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
		cashLabel.Text = UIStyle.formatMoney(coins)
	end)
	Remotes.event("ZooChanged").OnClientEvent:Connect(function(summary: Types.ZooSummary)
		incomeLabel.Text = `+{UIStyle.formatMoney(summary.IncomePerSecond)}/s`
	end)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(_tier: number, name: string)
		toolLabel.Text = name
	end)
	Remotes.event("Announcement").OnClientEvent:Connect(showAnnouncement)
	Remotes.event("WashCompleted").OnClientEvent:Connect(function(jobId: string, reward: number, coins: number)
		if jobId == currentJobId then
			setProgress(1, true)
		end
		tutorialCompleted = true
		cashLabel.Text = UIStyle.formatMoney(coins)
		playPayout(reward)
		refreshToast()
	end)
end

return HUDController
