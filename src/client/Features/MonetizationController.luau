-- Client side of Monetization: keeps the shop's state from the server, shows active boost
-- timers next to the cash, the server's contextual offers (small and dismissible), purchase
-- notices, and auto-opens the Cash tab after repeated "Not enough cash" hose buys (at most
-- CashAutoOpenMax times a session). Nothing here decides a price or a grant: BUY only sends
-- a product key, and offers / auto-opens never show in a session's first QuietSeconds.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local MonetizationShop = require(script.Parent.MonetizationShop)

type ShopState = MonetizationConfig.ShopState

local player = Players.LocalPlayer

local MonetizationController = {}

local OK_COLOR = Color3.fromRGB(130, 255, 140)
local ERROR_COLOR = Color3.fromRGB(255, 130, 120)

local startedAt = os.clock()
local state: ShopState = {
	SoapEndsAt = 0,
	LuckyLeft = 0,
	Passes = {},
	Once = {},
	Stock = {},
	Cash = {},
	Unavailable = {},
	TestMode = false,
	PendingAnimals = 0,
}

local gui: ScreenGui
local soapPill: TextLabel
local luckyPill: TextLabel
local notice: TextLabel
local noticeScale: UIScale
local noticeToken = 0
local offerFrame: Frame
local offerTitle: TextLabel
local offerText: TextLabel
local offerBuy: TextButton
local offerKey: string? = nil
local offerToken = 0
local failedHoseBuys = 0
local autoOpens = 0
local coins = 0
local toolTier = 1
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

local function refreshTimers()
	local soapLeft = state.SoapEndsAt - Workspace:GetServerTimeNow()
	setPill(soapPill, if state.SoapEndsAt > 0 and soapLeft > 0 then `SOAP 2X {clock(soapLeft)}` else nil)
	setPill(luckyPill, if state.LuckyLeft > 0 then `LUCKY: {state.LuckyLeft} LEFT` else nil)
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
	CalmTreat = "It's about to shake!",
	SuperSoap = "Big job? Wash 2x faster!",
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
	offerText.Text = `{product.DisplayName}: {product.Description}`
	offerBuy.Text = `BUY {product.Robux} ROBUX`
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

-- Cash-pack auto-open ----------------------------------------------------------------------

local function onHoseBuyFailed()
	failedHoseBuys += 1
	local cfg = MonetizationConfig.Offers
	if
		failedHoseBuys % cfg.CashAutoOpenEvery == 0
		and autoOpens < cfg.CashAutoOpenMax
		and not quiet()
		and not MonetizationShop.isOpen()
	then
		autoOpens += 1
		MonetizationShop.open("Cash")
	end
end

-- Waits for a child without a timeout and without the "infinite yield" warning (the core
-- hose shop may be renamed or never built; then this thread just stays parked).
local function waitChild(parent: Instance, name: string): Instance
	while true do
		local child = parent:FindFirstChild(name)
		if child then
			return child
		end
		parent.ChildAdded:Wait()
	end
end

-- Best effort: catches hose buys the core ShopController refuses locally (no PurchaseResult is
-- sent then). Coupled to ShopController's private names ("Shop" / "ShopPanel" / "Buy for");
-- the PurchaseResult listener stays the primary signal.
local function watchHoseShop()
	local panel = waitChild(waitChild(player:WaitForChild("PlayerGui"), "Shop"), "ShopPanel")
	for _, child in panel:GetChildren() do
		if child:IsA("TextButton") then
			child.Activated:Connect(function()
				local nextTool = ToolConfig[toolTier + 1]
				if string.sub(child.Text, 1, 7) == "Buy for" and nextTool and coins < nextTool.Price then
					onHoseBuyFailed()
				end
			end)
		end
	end
end

-- Build -------------------------------------------------------------------------------------

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "Monetization"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 31 -- above the index dim, so SHOP still clicks while the index is open
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	clickSound = sound("rbxasset://sounds/electronicpingshort.wav", 0.5)
	buySound = sound("rbxasset://sounds/electronicpingshort.wav", 0.5)

	-- Right of the INDEX / SHOP buttons, just under the cash
	local timers = Instance.new("Frame")
	timers.Name = "BoostTimers"
	timers.AnchorPoint = Vector2.new(0, 0.5)
	timers.Position = UDim2.new(0, 196, 0.5, 14)
	timers.Size = UDim2.fromOffset(160, 76)
	timers.BackgroundTransparency = 1
	timers.Parent = gui
	local timerList = Instance.new("UIListLayout")
	timerList.Padding = UDim.new(0, 8)
	timerList.SortOrder = Enum.SortOrder.LayoutOrder
	timerList.Parent = timers
	soapPill = pill(1, Color3.fromRGB(60, 160, 255))
	luckyPill = pill(2, Color3.fromRGB(230, 170, 20))

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
	close.BackgroundColor3 = Color3.fromRGB(230, 70, 70)
	close.Parent = offerFrame
	UIStyle.text(close)
	UIStyle.border(close, 3)
	close.Text = "X"
	close.Activated:Connect(hideOffer)

	offerBuy = Instance.new("TextButton")
	offerBuy.AnchorPoint = Vector2.new(0.5, 1)
	offerBuy.Position = UDim2.new(0.5, 0, 1, -8)
	offerBuy.Size = UDim2.new(1, -20, 0, 44)
	offerBuy.BackgroundColor3 = Color3.fromRGB(70, 210, 90)
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
end

function MonetizationController.init(initial: Types.InitialState)
	coins = initial.Coins
	toolTier = initial.ToolTier
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

	-- Failed hose purchases. The server answers "Not enough cash" through PurchaseResult, but the
	-- hose shop usually refuses locally without asking it, so taps on its Buy button while short
	-- of cash count too (same affordability check as ShopController).
	Remotes.event("PurchaseResult").OnClientEvent:Connect(function(success: boolean, message: string)
		if not success and typeof(message) == "string" and string.find(message, "^Not enough cash") then
			onHoseBuyFailed()
		end
	end)
	Remotes.event("CoinsChanged").OnClientEvent:Connect(function(value: number)
		coins = value
	end)
	Remotes.event("WashCompleted").OnClientEvent:Connect(function(_jobId: string, _reward: number, value: number)
		coins = value
	end)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(value: number)
		toolTier = value
	end)
	task.spawn(watchHoseShop)

	requestState()
	task.spawn(function()
		while gui.Parent do
			task.wait(1)
			refreshTimers()
			MonetizationShop.tick()
		end
	end)
end

return MonetizationController
