-- HUD in Steal a Brainrot style: big outlined cash on the left with income per second, outlined
-- hints at the bottom, payout pops and server-wide announcements. The clean meter rides on
-- the animal's nameplate, above the animal. Name, rarity and mutation already live there.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local UIPlatform = require(script.Parent.Parent.UI)

local player = Players.LocalPlayer

local HUDController = {}

local BAR_COLOR = Color3.fromRGB(90, 200, 255)
local BAR_DONE_COLOR = Color3.fromRGB(90, 255, 90)

local PROGRESS_HEIGHT = 56 -- clean bar, then the Tension patience row (y 32)

local gui: ScreenGui
local cashLabel: TextLabel
local incomeLabel: TextLabel
local progressBoard: BillboardGui
local progressRoot: Frame
local barFill: Frame
local percentLabel: TextLabel
local percentScale: UIScale
local barGradient: UIGradient
local shineGradient: UIGradient
local barStroke: UIStroke?
local shownPercent = -1
local wantProgress = false
local currentBayName: string? = nil
local mountedHead: BasePart? = nil
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

	-- Bottom left, big: cash, then income. On phones it sits above the thumbstick.
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	local wallet = Instance.new("Frame")
	wallet.AnchorPoint = Vector2.new(0, 1)
	wallet.Position = UDim2.new(0, 16, 1, if touchOnly then -190 else -16)
	wallet.Size = UDim2.fromOffset(380, 150)
	wallet.BackgroundTransparency = 1
	wallet.Parent = gui
	cashLabel = textLabel(wallet, {
		Size = UDim2.new(1, 0, 0, 110),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "$0",
	}, UIStyle.CashColor)
	incomeLabel = textLabel(wallet, {
		Position = UDim2.fromOffset(0, 110),
		Size = UDim2.new(1, 0, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "+$0/s",
	}, UIStyle.CashColor)

	-- Clean meter above the animal. A BillboardGui inside a ScreenGui is never drawn,
	-- so this one sits directly under PlayerGui and points at the animal's head.
	progressBoard = Instance.new("BillboardGui")
	progressBoard.Name = "CleanProgress"
	progressBoard.Size = UDim2.fromOffset(220, PROGRESS_HEIGHT)
	progressBoard.MaxDistance = 80
	progressBoard.Enabled = false
	progressBoard.Parent = gui.Parent
	progressRoot = Instance.new("Frame")
	progressRoot.Name = "CleanProgress"
	progressRoot.BackgroundTransparency = 1
	progressRoot.Size = UDim2.fromScale(1, 1)
	progressRoot.Parent = progressBoard
	local bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(6, 0)
	bar.Size = UDim2.new(1, -12, 0, 26)
	bar.BackgroundColor3 = Color3.fromRGB(70, 50, 35)
	bar.ClipsDescendants = true
	bar.Parent = progressRoot
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

	-- Announcements under the patience row
	announcementLabel = textLabel(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 40),
		Size = UDim2.new(0.9, 0, 0, 26),
		Visible = false,
	})
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(560, 26)
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
	percentLabel.Text = if finalized then "100%" else `{shown}%`
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

local function findAnimal(): Model?
	if not currentBayName or not currentJobId then
		return nil
	end
	local bays = Workspace:FindFirstChild("WashBays")
	local bayModel = bays and bays:FindFirstChild(currentBayName)
	local animal = bayModel and bayModel:FindFirstChild("Animal")
	if animal and animal:IsA("Model") and animal:GetAttribute("JobId") == currentJobId then
		return animal
	end
	return nil
end

local function unmountProgress()
	if mountedHead and mountedHead.Parent then
		UIStyle.liftNameplate(mountedHead, false)
	end
	progressBoard.Enabled = false
	progressBoard.Adornee = nil
	mountedHead = nil
end

-- Point the meter at this animal's head, under its nameplate (which lifts to make room).
-- The nameplate already shows the animal, so a screen card would only repeat it.
local function mountProgress(animal: Model): boolean
	local head = animal:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return false
	end
	if mountedHead == head and progressBoard.Enabled then
		return true
	end
	UIStyle.overhead(progressBoard, head, UIStyle.Overhead.Meter)
	UIStyle.liftNameplate(head, true)
	progressBoard.Adornee = head
	progressBoard.Enabled = true
	mountedHead = head
	return true
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
		unmountProgress()
	end
	currentBayName = bay.BayName
	currentJobId = bay.JobId
	currentState = bay.State

	wantProgress = bay.AnimalName ~= nil and (bay.State == "Washing" or bay.State == "Completing") -- not while it walks in
	if wantProgress then
		local animal = findAnimal()
		if animal then
			mountProgress(animal)
		end
	else
		hintShowing = false
		unmountProgress()
	end

	if bay.State == "Washing" then
		setProgress(bay.Progress or 0, false)
	elseif bay.State == "Completing" or bay.State == "Departing" then
		setProgress(1, true)
	end
	refreshToast()
end

-- Server-wide "X found a Mythic Lion!" in the tier's colour (rainbow for Zoo God).
local announcementToken = 0
local function showAnnouncement(text: string, rarityKey: string)
	UIStyle.rarity(announcementLabel, rarityKey)
	if RarityConfig.ByKey[rarityKey] == nil then
		announcementLabel.TextColor3 = Color3.new(1, 1, 1)
	else
		-- Softened toward white with a thin outline, so a loud tier colour still reads calmly.
		announcementLabel.TextColor3 = announcementLabel.TextColor3:Lerp(Color3.new(1, 1, 1), 0.35)
	end
	local outline = announcementLabel:FindFirstChildOfClass("UIStroke")
	if outline then
		outline.Thickness = 1.5
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

-- The washed animal with this job, while it is still in a bay.
local function washedAnimal(jobId: string): Model?
	local bays = Workspace:FindFirstChild("WashBays")
	if not bays then
		return nil
	end
	for _, model in bays:GetDescendants() do
		if model:IsA("Model") and model:GetAttribute("JobId") == jobId then
			return model
		end
	end
	return nil
end

-- "+$12" pops over the washed animal, above its Squeaky clean! banner, then rises and fades.
-- Falls back to the middle of the screen if the animal is already gone.
local function playPayout(jobId: string, reward: number, discoveryBonus: number)
	local text = if discoveryBonus > 0
		then `+{UIStyle.formatMoney(reward - discoveryBonus)} WASH\n+{UIStyle.formatMoney(discoveryBonus)} NEW`
		else "+" .. UIStyle.formatMoney(reward)
	local animal = washedAnimal(jobId)
	local head = animal and animal:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		payout.Text = text
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
		return
	end
	local board = Instance.new("BillboardGui")
	board.Name = "WashPayout"
	board.Size = UDim2.fromOffset(240, if discoveryBonus > 0 then 70 else 48)
	board.MaxDistance = 120
	board.AlwaysOnTop = true
	board.ResetOnSpawn = false
	board.Adornee = head
	UIStyle.overhead(board, head, UIStyle.Overhead.Payout)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = board
	UIStyle.text(label, UIStyle.CashColor, nil, 3)
	label.Text = text
	local scale = Instance.new("UIScale")
	scale.Scale = 0.4
	scale.Parent = label
	board.Parent = player:WaitForChild("PlayerGui")
	TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	local rise = board.SizeOffset + Vector2.new(0, 40 / board.Size.Y.Offset)
	local info = TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(board, info, { SizeOffset = rise }):Play()
	task.delay(0.7, function()
		local fade = TweenService:Create(label, TweenInfo.new(0.9), { TextTransparency = 1 })
		fade.Completed:Once(function()
			board:Destroy()
		end)
		fade:Play()
	end)
end

-- Persistent warning: the doc requires explaining when progress can't be saved.
local function showDataWarning(status: Types.DataStatus)
	-- Left column, under the SHOP and DAILY buttons. A full-width footer covered the index,
	-- the shop, and the phone thumbstick.
	local warning = textLabel(gui, {
		Name = "DataWarning",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 16, 0.5, 140),
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
	Remotes.event("Announcement").OnClientEvent:Connect(showAnnouncement)

	-- Passive life on the clean bar: the shine sweeps along and the border gently pulses.
	-- The animal can replicate a moment after the bay snapshot, so keep trying to attach.
	RunService.RenderStepped:Connect(function()
		if wantProgress and not progressBoard.Enabled then
			local animal = findAnimal()
			if animal then
				mountProgress(animal)
			end
		end
		if not progressBoard.Enabled then
			return
		end
		local t = os.clock()
		shineGradient.Offset = Vector2.new((t * 0.8) % 2.4 - 1.2, 0)
		if barStroke then
			local pulse = (math.sin(t * 4) + 1) / 2
			barStroke.Color = Color3.new(0, 0, 0):Lerp(Color3.fromRGB(255, 255, 255), pulse * 0.35)
		end
	end)
	Remotes.event("WashCompleted").OnClientEvent
		:Connect(function(jobId: string, reward: number, coins: number, discoveryBonus: number?)
			if jobId == currentJobId then
				setProgress(1, true)
			end
			tutorialCompleted = true
			cashLabel.Text = UIStyle.formatMoney(coins)
			playPayout(jobId, reward, discoveryBonus or 0)
			refreshToast()
		end)
end

return HUDController
