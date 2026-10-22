-- HUD in Steal a Brainrot style: big outlined cash on the left with income per second, the
-- animal being washed (name, rarity, mutation) with its clean meter at the top, outlined
-- hints at the bottom, payout pops and server-wide announcements.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local UIPlatform = require(script.Parent.Parent.UI)

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
local panelScale: UIScale
local percentScale: UIScale
local barGradient: UIGradient
local shineGradient: UIGradient
local barStroke: UIStroke?
local shownPercent = -1
local toast: TextLabel
local payout: TextLabel
local announcementLabel: TextLabel

local tutorialCompleted = false
local currentJobId: string? = nil
local currentState: Types.BayState? = nil
local currentProgress = 0
local hintShowing = false
local inputMode: UIPlatform.InputMode = "KeyboardMouse"

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

	-- Top center: the animal being washed, on a framed card that pops in per animal
	washPanel = Instance.new("Frame")
	washPanel.AnchorPoint = Vector2.new(0.5, 0)
	washPanel.Position = UDim2.new(0.5, 0, 0, 8)
	washPanel.Size = UDim2.fromOffset(380, 150)
	washPanel.BackgroundColor3 = Color3.fromRGB(40, 70, 130)
	washPanel.BackgroundTransparency = 0.15
	washPanel.Visible = false
	washPanel.Parent = gui
	UIStyle.border(washPanel, 4)
	local cardGradient = Instance.new("UIGradient")
	cardGradient.Rotation = 90
	cardGradient.Color = ColorSequence.new(Color3.fromRGB(120, 190, 255), Color3.fromRGB(60, 90, 200))
	cardGradient.Parent = washPanel
	panelScale = Instance.new("UIScale")
	panelScale.Parent = washPanel

	mutationLabel = textLabel(washPanel, { Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 20) })
	nameLabel = textLabel(washPanel, { Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 40) })
	local nameShine = Instance.new("UIGradient")
	nameShine.Rotation = 90
	nameShine.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(255, 235, 150))
	nameShine.Parent = nameLabel
	local nameStroke = nameLabel:FindFirstChildOfClass("UIStroke")
	if nameStroke then
		nameStroke.Thickness = 3.5
	end

	-- Rarity badge: a dark pill with the tier-coloured name inside
	local badge = Instance.new("Frame")
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.new(0.5, 0, 0, 66)
	badge.Size = UDim2.fromOffset(150, 24)
	badge.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	badge.BackgroundTransparency = 0.2
	badge.Parent = washPanel
	UIStyle.border(badge, 2)
	rarityLabel = textLabel(badge, { Size = UDim2.fromScale(1, 1) })

	local bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(20, 96)
	bar.Size = UDim2.new(1, -40, 0, 28)
	bar.BackgroundColor3 = Color3.fromRGB(70, 50, 35)
	bar.ClipsDescendants = true
	bar.Parent = washPanel
	UIStyle.border(bar, 3)
	barStroke = bar:FindFirstChildOfClass("UIStroke")
	barFill = Instance.new("Frame")
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = Color3.new(1, 1, 1)
	barFill.Parent = bar
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 12)
	fillCorner.Parent = barFill
	barGradient = Instance.new("UIGradient")
	barGradient.Rotation = 90
	barGradient.Parent = barFill
	-- A soft white shine that sweeps along the fill forever.
	local shine = Instance.new("Frame")
	shine.Size = UDim2.fromScale(1, 1)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.Parent = barFill
	local shineCorner = Instance.new("UICorner")
	shineCorner.CornerRadius = UDim.new(0, 12)
	shineCorner.Parent = shine
	shineGradient = Instance.new("UIGradient")
	shineGradient.Rotation = 20
	shineGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 1),
		NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(0.6, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	shineGradient.Parent = shine
	percentLabel = textLabel(bar, { Size = UDim2.fromScale(1, 1), ZIndex = 2 })
	percentScale = Instance.new("UIScale")
	percentScale.Parent = percentLabel
	rewardLabel =
		textLabel(washPanel, { Position = UDim2.fromOffset(0, 126), Size = UDim2.new(1, 0, 0, 20) }, UIStyle.CashColor)

	-- Announcements under the wash panel
	announcementLabel = textLabel(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 196), -- below the tension patience row
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

-- Phone controls are small and the screen scale already lifts this line. A tablet
-- jump button is tall enough that the same offset sits on top of it.
local function placeToast(profile: UIPlatform.Profile)
	local lift = if profile.inputMode == "Touch" and profile.formFactor ~= "Mobile" then 260 else 140
	toast.Position = UDim2.new(0.5, 0, 1, -lift)
end

local function showToast(text: string?)
	if text then
		toast.Text = text
		toast.Visible = true
	else
		toast.Visible = false
	end
end

local BAR_COLORS = ColorSequence.new(Color3.fromRGB(130, 230, 255), BAR_COLOR)
local BAR_DONE_COLORS = ColorSequence.new(Color3.fromRGB(170, 255, 140), BAR_DONE_COLOR)

local function pop(scale: UIScale, size: number, seconds: number)
	scale.Scale = size
	TweenService:Create(scale, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

-- The bar glides to the new value; the % text pops each time it ticks up.
local function setProgress(progress: number, finalized: boolean)
	currentProgress = progress
	local shown = if finalized then 100 else math.min(math.floor(progress * 100), 99)
	percentLabel.Text = if finalized then "SQUEAKY CLEAN!" else `{shown}% CLEAN`
	local width = if finalized then 1 else math.clamp(progress, 0, 0.99)
	TweenService:Create(barFill, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(width, 1),
	}):Play()
	barGradient.Color = if finalized then BAR_DONE_COLORS else BAR_COLORS
	if shown > shownPercent and shownPercent >= 0 then
		pop(percentScale, if finalized then 1.5 else 1.15, if finalized then 0.5 else 0.2)
	end
	shownPercent = shown
end

local function refreshToast()
	if currentState == "Washing" then
		if not tutorialCompleted and currentProgress < 0.1 then
			showToast(
				if inputMode == "Touch"
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
		shownPercent = -1
		if bay.JobId then
			pop(panelScale, 0.6, 0.45) -- new animal: the card springs in
		end
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

local function playPayout(reward: number, discoveryBonus: number)
	if discoveryBonus > 0 then
		local wash = reward - discoveryBonus
		payout.Text = `+{UIStyle.formatMoney(wash)} WASH\n+{UIStyle.formatMoney(discoveryBonus)} NEW`
	else
		payout.Text = "+" .. UIStyle.formatMoney(reward)
	end
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
	-- Left column, under the SHOP button. A full-width footer covered the index, the
	-- shop, and the phone thumbstick.
	local warning = textLabel(gui, {
		Name = "DataWarning",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 16, 0.5, 100),
		Size = UDim2.fromOffset(210, 52),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = if status == "Locked"
			then "Your save is open on another server. Progress this session won't save."
			else "Couldn't load your save. Progress this session won't save.",
	}, Color3.fromRGB(255, 110, 100))
	warning.TextScaled = false
	warning.TextSize = 16
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(220, 64)
	constraint.Parent = warning
end

function HUDController.init(initial: Types.InitialState)
	buildGui()
	local profile = UIPlatform.get()
	inputMode = profile.inputMode
	placeToast(profile)
	UIPlatform.onChanged(function(nextProfile)
		local inputChanged = nextProfile.inputMode ~= inputMode
		inputMode = nextProfile.inputMode
		placeToast(nextProfile)
		if inputChanged then
			refreshToast()
		end
	end)
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

	-- Passive life on the clean bar: the shine sweeps along and the border gently pulses.
	RunService.RenderStepped:Connect(function()
		if not washPanel.Visible then
			return
		end
		local t = os.clock()
		shineGradient.Offset = Vector2.new((t * 0.8) % 2.4 - 1.2, 0)
		if barStroke then
			local pulse = (math.sin(t * 4) + 1) / 2
			barStroke.Color = Color3.new(0, 0, 0):Lerp(Color3.fromRGB(255, 255, 255), pulse * 0.35)
		end
	end)
	Remotes.event("WashCompleted").OnClientEvent:Connect(
		function(jobId: string, reward: number, coins: number, discoveryBonus: number?)
			if jobId == currentJobId then
				setProgress(1, true)
			end
			tutorialCompleted = true
			cashLabel.Text = UIStyle.formatMoney(coins)
			playPayout(reward, discoveryBonus or 0)
			refreshToast()
		end
	)
end

return HUDController
