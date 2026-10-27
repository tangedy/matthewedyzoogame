-- Client side of Monetization: keeps the shop's state from the server, shows active boost
-- timers next to the cash, the one-tap quick-buy column on the right (MonetizationQuickBuy),
-- the server's contextual offers (small and dismissible), purchase notices, and the Robux
-- kiosks around the plot. The shop panel only opens when the player
-- asks (SHOP button or the plaza booth), never by itself. Nothing here decides a price or a
-- grant: BUY only sends a product key, and offers never show in a session's first QuietSeconds.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Janitor = require(ReplicatedStorage.Shared.Janitor)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local MonetizationQuickBuy = require(script.Parent.MonetizationQuickBuy)
local MonetizationShop = require(script.Parent.MonetizationShop)
local Modals = require(script.Parent.Parent.UI.Modals)
local UIPlatform = require(script.Parent.Parent.UI)

type ShopState = MonetizationConfig.ShopState

local player = Players.LocalPlayer

local MonetizationController = {}

local OK_COLOR = UIStyle.CashColor
local ERROR_COLOR = UIStyle.Colors.ErrorText

local startedAt = os.clock()
local state: ShopState = {
	SoapEndsAt = 0,
	AutoCollectEndsAt = 0,
	SpeedEndsAt = 0,
	Passes = {},
	Once = {},
	Stock = {},
	Cash = {},
	Unavailable = {},
	TestMode = false,
	PendingAnimals = 0,
}

local gui: ScreenGui
local buffPills: { [string]: TextLabel } = {}
local buffEnds: { [string]: number } = {}
local buffJanitors: { [string]: Janitor.Janitor } = {}
local notice: TextLabel
local noticeScale: UIScale
local noticeToken = 0
local offerFrame: Frame
local offerTitle: TextLabel
local offerText: TextLabel
local offerBuy: TextButton
local offerKey: string? = nil
local offerToken = 0
local clickSound: Sound
local buySound: Sound

local buyRemote: RemoteEvent
local stateFunction: RemoteFunction

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function pop(scale: UIScale, from: number, seconds: number)
	scale.Scale = from
	TweenService:Create(scale, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

local function sound(id: string, volume: number): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.Parent = gui
	return s
end

local function play(s: Sound)
	SoundService:PlayLocalSound(s)
end

local function quiet(): boolean
	return os.clock() - startedAt < MonetizationConfig.Offers.QuietSeconds
end

-- Timers next to the cash -------------------------------------------------------------------

local function pill(order: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.LayoutOrder = order
	label.Size = UDim2.fromOffset(160, 32)
	label.BackgroundColor3 = color
	label.Visible = false
	label.Parent = gui:FindFirstChild("BoostTimers")
	UIStyle.text(label)
	label.BackgroundTransparency = 0 -- UIStyle.text clears it for labels
	UIStyle.border(label, 3)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = label
	local scale = Instance.new("UIScale")
	scale.Parent = label
	return label
end

local function setPill(label: TextLabel, text: string?)
	local wasVisible = label.Visible
	label.Visible = text ~= nil
	if text then
		label.Text = text
		if not wasVisible then
			pop(label:FindFirstChildOfClass("UIScale") :: UIScale, 0.5, 0.4)
		end
	end
end

local function buffGroup(key: string): Janitor.Janitor
	local janitor = buffJanitors[key]
	if not janitor then
		janitor = Janitor.new()
		buffJanitors[key] = janitor
	end
	return janitor
end

-- Shows a countdown pill while `endsAt` is in the future. When it expires, the Janitor
-- destroys the pill and cancels the timer so nothing keeps ticking.
local function syncTimed(key: string, order: number, color: Color3, endsAt: number, text: string)
	local now = Workspace:GetServerTimeNow()
	local left = endsAt - now
	local active = endsAt > 0 and left > 0
	local janitor = buffGroup(key)
	if not active then
		if buffEnds[key] ~= nil then
			buffEnds[key] = nil
			buffPills[key] = nil
			janitor:Cleanup()
		end
		return
	end
	local label = buffPills[key]
	if buffEnds[key] ~= endsAt or not label or not label.Parent then
		buffEnds[key] = endsAt
		janitor:Cleanup()
		label = pill(order, color)
		label.Visible = true
		buffPills[key] = label
		janitor:Add(label, "Destroy")
		local token = endsAt
		janitor:Add(
			task.delay(left, function()
				if buffEnds[key] ~= token then
					return
				end
				buffEnds[key] = nil
				buffPills[key] = nil
				janitor:Cleanup()
			end),
			true
		)
		pop(label:FindFirstChildOfClass("UIScale") :: UIScale, 0.5, 0.4)
	end
	if label then
		label.Text = text
	end
end

local function refreshTimers()
	local now = Workspace:GetServerTimeNow()
	local soapLeft = state.SoapEndsAt - now
	syncTimed(
		"Soap",
		1,
		Color3.fromRGB(60, 160, 255),
		state.SoapEndsAt,
		if soapLeft > 0 then `2X SOAP {clock(soapLeft)}` else ""
	)
	local speedEnds = state.SpeedEndsAt or 0
	local speedLeft = speedEnds - now
	syncTimed(
		"Speed",
		2,
		Color3.fromRGB(255, 140, 40),
		speedEnds,
		if speedLeft > 0 then `{MonetizationConfig.Speed.Multiplier}X SPEED {clock(speedLeft)}` else ""
	)
	-- LiveOps NewPlayer: the first-five-minutes rarity boost.
	local newEnds = player:GetAttribute("NewPlayerBoostEndsAt")
	newEnds = if typeof(newEnds) == "number" then newEnds else 0
	local newLeft = newEnds - now
	syncTimed(
		"NewPlayer",
		0,
		Color3.fromRGB(60, 190, 90),
		newEnds,
		if newLeft > 0 then `BOOST {clock(newLeft)}` else ""
	)
end

-- Notices and offers ------------------------------------------------------------------------

local function showNotice(text: string, ok: boolean)
	noticeToken += 1
	local token = noticeToken
	notice.Text = text
	notice.TextColor3 = if ok then OK_COLOR else ERROR_COLOR
	notice.Visible = true
	pop(noticeScale, 0.6, 0.35)
	task.delay(4, function()
		if noticeToken == token then
			notice.Visible = false
		end
	end)
end

local function hideOffer()
	offerKey = nil
	MonetizationQuickBuy.setBlocked("Offer", false)
	if offerFrame.Visible then
		local tween = TweenService:Create(
			offerFrame,
			TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.new(1, 300, 0.5, -70) }
		)
		tween.Completed:Once(function()
			if offerKey == nil then
				offerFrame.Visible = false
			end
		end)
		tween:Play()
	end
end

local OFFER_TITLES = {
	CalmTreat = "About to shake!",
}

local function showOffer(kind: string, key: string)
	local product = MonetizationConfig.ProductsByKey[key]
	if not product or quiet() or MonetizationShop.isOpen() then
		return
	end
	offerKey = key
	offerToken += 1
	local token = offerToken
	offerTitle.Text = OFFER_TITLES[kind] or product.DisplayName
	offerText.Text = product.Description
	offerBuy.Text = `BUY R$ {product.Robux}`
	-- The offer takes the quick-buy column's spot on the right while it is up.
	MonetizationQuickBuy.setBlocked("Offer", true)
	offerFrame.Visible = true
	offerFrame.Position = UDim2.new(1, 300, 0.5, -70)
	TweenService:Create(
		offerFrame,
		TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(1, -16, 0.5, -70) }
	):Play()
	play(clickSound)
	task.delay(MonetizationConfig.Offers.AutoHideSeconds, function()
		if offerToken == token then
			hideOffer()
		end
	end)
end

-- State -------------------------------------------------------------------------------------

local function applyState(value: any)
	if typeof(value) ~= "table" then
		return
	end
	state = value :: ShopState
	refreshTimers()
	MonetizationShop.refresh(state)
	MonetizationQuickBuy.refresh(state)
end

local function requestState()
	task.spawn(function()
		local ok, value = pcall(function()
			return stateFunction:InvokeServer()
		end)
		if ok then
			applyState(value)
		end
	end)
end

local function buy(key: string)
	play(buySound)
	buyRemote:FireServer(key)
end

-- Build -------------------------------------------------------------------------------------

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "Monetization"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 31 -- above the index dim, so SHOP still clicks while the index is open
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Soft and low: a wooden tap on clicks, a gentle chime on a purchase.
	clickSound = sound(GameConfig.Sounds.ShopClick, 0.3)
	buySound = sound(GameConfig.Sounds.ShopBuy, 0.35)

	-- Right of the INDEX / SHOP rail
	local timers = Instance.new("Frame")
	timers.Name = "BoostTimers"
	UIPlatform.Layout.watch(function(spec)
		timers.AnchorPoint = spec.boostTimers.anchor
		timers.Position = spec.boostTimers.position
	end)
	timers.AutomaticSize = Enum.AutomaticSize.Y
	timers.Size = UDim2.fromOffset(160, 0)
	timers.BackgroundTransparency = 1
	timers.Parent = gui
	local timerList = Instance.new("UIListLayout")
	timerList.Padding = UDim.new(0, 8)
	timerList.SortOrder = Enum.SortOrder.LayoutOrder
	timerList.Parent = timers

	-- Purchase notices, under the index toast
	notice = Instance.new("TextLabel")
	notice.AnchorPoint = Vector2.new(0.5, 0)
	notice.Position = UDim2.new(0.5, 0, 0, 252)
	notice.Size = UDim2.new(0.9, 0, 0, 30)
	notice.Visible = false
	notice.Parent = gui
	UIStyle.text(notice)
	local noticeConstraint = Instance.new("UISizeConstraint")
	noticeConstraint.MaxSize = Vector2.new(600, 30)
	noticeConstraint.Parent = notice
	noticeScale = Instance.new("UIScale")
	noticeScale.Parent = notice

	-- Contextual offer: right middle, clear of the SPRAY button
	offerFrame = Instance.new("Frame")
	offerFrame.AnchorPoint = Vector2.new(1, 0.5)
	offerFrame.Position = UDim2.new(1, 300, 0.5, -70)
	offerFrame.Size = UDim2.fromOffset(270, 150)
	offerFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	offerFrame.Visible = false
	offerFrame.Parent = gui
	Modals.holdCursor(offerFrame)
	UIStyle.border(offerFrame, 4)
	local offerGradient = Instance.new("UIGradient")
	offerGradient.Rotation = 90
	offerGradient.Color = ColorSequence.new(Color3.fromRGB(255, 120, 215), Color3.fromRGB(120, 50, 200))
	offerGradient.Parent = offerFrame
	offerTitle = Instance.new("TextLabel")
	offerTitle.Position = UDim2.fromOffset(10, 8)
	offerTitle.Size = UDim2.new(1, -60, 0, 28)
	offerTitle.TextXAlignment = Enum.TextXAlignment.Left
	offerTitle.Parent = offerFrame
	UIStyle.text(offerTitle, Color3.fromRGB(255, 240, 120), nil, 3)
	offerText = Instance.new("TextLabel")
	offerText.Position = UDim2.fromOffset(10, 40)
	offerText.Size = UDim2.new(1, -20, 0, 48)
	offerText.TextWrapped = true
	offerText.TextXAlignment = Enum.TextXAlignment.Left
	offerText.Parent = offerFrame
	UIStyle.text(offerText, nil, nil, 1.5)
	local offerTextLimit = Instance.new("UITextSizeConstraint")
	offerTextLimit.MaxTextSize = 17
	offerTextLimit.Parent = offerText

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -8, 0, 8)
	close.Size = UDim2.fromOffset(40, 40)
	close.BackgroundColor3 = UIStyle.Colors.Close
	close.Parent = offerFrame
	UIStyle.text(close)
	UIStyle.border(close, 3)
	close.Text = "X"
	close.Activated:Connect(hideOffer)
	UIPlatform.Feedback.button(close)

	offerBuy = Instance.new("TextButton")
	offerBuy.AnchorPoint = Vector2.new(0.5, 1)
	offerBuy.Position = UDim2.new(0.5, 0, 1, -8)
	offerBuy.Size = UDim2.new(1, -20, 0, 44)
	offerBuy.BackgroundColor3 = UIStyle.Colors.Robux
	offerBuy.Parent = offerFrame
	UIStyle.text(offerBuy)
	UIStyle.border(offerBuy, 3)
	local buyPad = Instance.new("UIPadding")
	buyPad.PaddingTop = UDim.new(0, 6)
	buyPad.PaddingBottom = UDim.new(0, 6)
	buyPad.Parent = offerBuy
	local offerBuyScale = Instance.new("UIScale")
	offerBuyScale.Parent = offerBuy
	offerBuy.Activated:Connect(function()
		local key = offerKey
		if key then
			pop(offerBuyScale, 0.8, 0.3)
			buy(key)
			hideOffer()
		end
	end)

	MonetizationShop.build(gui, {
		onBuy = buy,
		onOpen = function()
			play(clickSound)
			hideOffer()
			requestState() -- cash pack amounts follow the zoo's income
		end,
	})

	-- Nothing to buy on screen until the quiet start is over.
	MonetizationQuickBuy.build({ onBuy = buy })
	MonetizationQuickBuy.refresh(state)
	local quietLeft = MonetizationConfig.Offers.QuietSeconds - (os.clock() - startedAt)
	if quietLeft > 0 then
		MonetizationQuickBuy.setBlocked("Quiet", true)
		task.delay(quietLeft, function()
			MonetizationQuickBuy.setBlocked("Quiet", false)
			requestState() -- fresh cash pack amounts for the captions
		end)
	end
end

function MonetizationController.init(_initial: Types.InitialState)
	buyRemote = Remotes.event("MonetizationBuy")
	stateFunction = Remotes.func("GetMonetizationState")
	buildGui()

	Remotes.event("MonetizationState").OnClientEvent:Connect(applyState)
	Remotes.event("MonetizationStock").OnClientEvent:Connect(function(key: any, left: any)
		if typeof(key) == "string" and typeof(left) == "number" then
			state.Stock[key] = left
			MonetizationShop.refresh(state)
		end
	end)
	Remotes.event("MonetizationNotice").OnClientEvent:Connect(function(text: any, ok: any)
		if typeof(text) == "string" then
			showNotice(text, ok == true)
			if ok == true then
				play(buySound)
			end
		end
	end)
	Remotes.event("MonetizationOffer").OnClientEvent:Connect(function(kind: any, key: any)
		if typeof(kind) == "string" and typeof(key) == "string" then
			showOffer(kind, key)
		end
	end)

	-- The blue Robux shop on the plaza opens the same panel as the SHOP button; each kiosk
	-- around the plot buys its one item straight away (Roblox still asks to confirm).
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
		if prompt.Name == "RobuxShopPrompt" then
			MonetizationShop.open(nil)
		elseif prompt.Name == "RobuxKioskPrompt" then
			local key = prompt:GetAttribute("ProductKey")
			if typeof(key) == "string" then
				buy(key)
			end
		end
	end)

	requestState()
	task.spawn(function()
		while gui.Parent do
			task.wait(1)
			refreshTimers()
			MonetizationShop.tick()
			MonetizationQuickBuy.tick()
		end
	end)
end

return MonetizationController
