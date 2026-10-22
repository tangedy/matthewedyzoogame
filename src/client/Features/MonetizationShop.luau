-- The Robux shop's UI, Steal a Brainrot style: a big pink SHOP button under INDEX and a
-- tabbed panel (Boosts / Cash / Passes / Limited) of chunky cards with a bouncy BUY button.
-- Pure view: MonetizationController owns the state and sends purchases to the server.
-- Part of the Monetization feature (no init of its own).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

type ShopState = MonetizationConfig.ShopState

type Card = {
	Key: string, -- the product or pass this card shows (Super Soap swaps to its intro product)
	Tab: string,
	Order: number,
	Frame: Frame,
	Name: TextLabel,
	Description: TextLabel,
	Status: TextLabel,
	Price: TextLabel,
	Buy: TextButton,
	BuyScale: UIScale,
	Rarity: TextLabel?,
}

export type Callbacks = {
	onBuy: (key: string) -> (),
	onOpen: () -> (),
}

local MonetizationShop = {}

local BUY_COLOR = Color3.fromRGB(70, 210, 90)
local DISABLED_COLOR = Color3.fromRGB(120, 120, 130)
local OWNED_COLOR = Color3.fromRGB(255, 190, 40)
local TAB_COLOR = Color3.fromRGB(70, 60, 110)
local TAB_ACTIVE_COLOR = Color3.fromRGB(255, 90, 200)

local panel: Frame
local panelScale: UIScale
local shopButton: TextButton
local grid: ScrollingFrame
local gridLayout: UIGridLayout
local testLabel: TextLabel
local tabButtons: { [string]: TextButton } = {}
local cards: { Card } = {}
local currentTab = MonetizationConfig.Tabs[1]
local lastState: ShopState? = nil
local callbacks: Callbacks

local function pop(scale: UIScale, from: number, seconds: number)
	scale.Scale = from
	TweenService:Create(scale, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function textLabel(parent: Instance, props: { [string]: any }, color: Color3?, thickness: number?): TextLabel
	local l = Instance.new("TextLabel")
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	UIStyle.text(l, color, nil, thickness)
	return l
end

local function chunkyButton(parent: Instance, color: Color3, text: string): (TextButton, UIScale)
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = color
	button.AutoButtonColor = true
	button.Parent = parent
	UIStyle.text(button, nil, nil, 2.5)
	UIStyle.border(button, 3)
	button.Text = text
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button
	return button, scale
end

local function shade(color: Color3, factor: number): Color3
	return Color3.new(color.R * factor, color.G * factor, color.B * factor)
end

-- Cards ----------------------------------------------------------------------------------

local function makeCard(key: string, tab: string, order: number, color: Color3): Card
	local frame = Instance.new("Frame")
	frame.LayoutOrder = order
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.Parent = grid
	UIStyle.border(frame, 3)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(color, shade(color, 0.45))
	gradient.Parent = frame

	local name = textLabel(frame, { Position = UDim2.fromOffset(8, 6), Size = UDim2.new(1, -16, 0, 28) }, nil, 3)
	local rarity: TextLabel? = nil
	local product = MonetizationConfig.ProductsByKey[key]
	local species = product and product.Species
	if species and AnimalConfig.Animals[species] then
		rarity = textLabel(frame, { Position = UDim2.fromOffset(8, 34), Size = UDim2.new(1, -16, 0, 18) })
		UIStyle.rarity(rarity :: TextLabel, AnimalConfig.Animals[species].Rarity)
	end
	local descTop = if rarity then 54 else 36
	local description = textLabel(frame, {
		Position = UDim2.fromOffset(10, descTop),
		Size = UDim2.new(1, -20, 0, 92 - descTop),
		TextWrapped = true,
	}, nil, 1.5)
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 17
	limit.Parent = description
	local status = textLabel(frame, { Position = UDim2.fromOffset(8, 94), Size = UDim2.new(1, -16, 0, 24) })
	local price = textLabel(frame, {
		Position = UDim2.fromOffset(8, 120),
		Size = UDim2.new(1, -16, 0, 24),
	}, Color3.fromRGB(120, 255, 170))
	local buy, buyScale = chunkyButton(frame, BUY_COLOR, "BUY")
	buy.AnchorPoint = Vector2.new(0.5, 1)
	buy.Position = UDim2.new(0.5, 0, 1, -8)
	buy.Size = UDim2.new(1, -24, 0, 42)

	local card: Card = {
		Key = key,
		Tab = tab,
		Order = order,
		Frame = frame,
		Name = name,
		Description = description,
		Status = status,
		Price = price,
		Buy = buy,
		BuyScale = buyScale,
		Rarity = rarity,
	}
	buy.Activated:Connect(function()
		pop(card.BuyScale, 0.8, 0.35)
		if buy.BackgroundColor3 == BUY_COLOR then
			callbacks.onBuy(card.Key)
		end
	end)
	table.insert(cards, card)
	return card
end

-- One card's text and button for the current state.
local function refreshCard(card: Card, state: ShopState)
	local buyable = true
	local buyText = "BUY"
	local statusText = ""
	local statusColor = Color3.new(1, 1, 1)
	local pass = MonetizationConfig.PassesByKey[card.Key]
	local product = MonetizationConfig.ProductsByKey[card.Key]
	-- Super Soap shows its cheaper intro product until that has been used.
	if product and product.IntroKey and not state.Once[product.IntroKey] then
		card.Key = product.IntroKey
		product = MonetizationConfig.ProductsByKey[product.IntroKey]
	elseif product and product.OncePerPlayer and state.Once[product.Key] then
		for _, other in MonetizationConfig.Products do
			if other.IntroKey == product.Key then
				card.Key = other.Key
				product = other
				break
			end
		end
	end

	local info: { DisplayName: string, Description: string, Robux: number } = if product
		then product
		else pass :: MonetizationConfig.Pass
	card.Name.Text = info.DisplayName
	card.Description.Text = info.Description
	card.Price.Text = `{info.Robux} ROBUX`

	if pass then
		if state.Passes[pass.Key] then
			buyable = false
			buyText = "OWNED"
			statusText = "OWNED"
			statusColor = OWNED_COLOR
		end
	elseif product then
		if product.Kind == "SuperSoap" and state.SoapEndsAt > 0 then
			statusText = `ACTIVE {clock(state.SoapEndsAt - Workspace:GetServerTimeNow())}`
			statusColor = Color3.fromRGB(150, 230, 255)
		elseif product.Kind == "LuckySoap" and state.LuckyLeft > 0 then
			statusText = `ACTIVE: {state.LuckyLeft} LEFT`
			statusColor = Color3.fromRGB(255, 220, 90)
		elseif product.Kind == "Cash" then
			statusText = `+{UIStyle.formatMoney(state.Cash[product.Key] or 0)}`
			statusColor = UIStyle.CashColor
		elseif product.Kind == "Limited" then
			local left = state.Stock[product.Key]
			if state.Unavailable[product.Key] then
				buyable = false
				buyText = "SOON"
				statusText = "COMING SOON"
			elseif left and left <= 0 then
				buyable = false
				buyText = "SOLD OUT"
				statusText = "SOLD OUT"
				statusColor = Color3.fromRGB(255, 110, 110)
			elseif left then
				statusText = `{left} / {product.Stock or 0} LEFT`
				statusColor = Color3.fromRGB(255, 230, 120)
			else
				statusText = "CHECKING STOCK..."
			end
			if state.PendingAnimals > 0 and buyable then
				statusText = `{state.PendingAnimals} waiting for cache space`
			end
		end
	end
	card.Status.Text = statusText
	card.Status.TextColor3 = statusColor
	card.Buy.Text = buyText
	card.Buy.BackgroundColor3 = if buyable then BUY_COLOR elseif buyText == "OWNED" then OWNED_COLOR else DISABLED_COLOR
end

local function relayout()
	local width = grid.AbsoluteSize.X - 10
	local columns = math.clamp(math.floor(width / 200), 1, 3)
	local cellWidth = math.floor((width - (columns - 1) * 10) / columns)
	gridLayout.CellSize = UDim2.fromOffset(math.max(cellWidth, 140), 206)
end

local function showTab(tab: string)
	currentTab = tab
	for name, button in tabButtons do
		button.BackgroundColor3 = if name == tab then TAB_ACTIVE_COLOR else TAB_COLOR
	end
	for _, card in cards do
		card.Frame.Visible = card.Tab == tab
	end
	grid.CanvasPosition = Vector2.zero
end

-- Build ------------------------------------------------------------------------------------

function MonetizationShop.build(gui: ScreenGui, handlers: Callbacks)
	callbacks = handlers

	-- Under the INDEX button, left side
	local button, buttonScale = chunkyButton(gui, MonetizationConfig.ShopColor, "SHOP")
	shopButton = button
	shopButton.Name = "ShopButton"
	shopButton.AnchorPoint = Vector2.new(0, 0.5)
	shopButton.Position = UDim2.new(0, 16, 0.5, 62)
	shopButton.Size = UDim2.fromOffset(170, 44)
	shopButton.BackgroundColor3 = Color3.new(1, 1, 1)
	local buttonGradient = Instance.new("UIGradient")
	buttonGradient.Rotation = 90
	buttonGradient.Color = ColorSequence.new(Color3.fromRGB(255, 110, 210), Color3.fromRGB(150, 60, 255))
	buttonGradient.Parent = shopButton
	shopButton.Activated:Connect(function()
		pop(buttonScale, 0.85, 0.3)
		if panel.Visible then
			MonetizationShop.close()
		else
			MonetizationShop.open(nil)
		end
	end)
	-- A gentle bounce now and then so the button reads as tappable.
	task.spawn(function()
		while shopButton.Parent do
			task.wait(8)
			if not panel.Visible then
				pop(buttonScale, 1.12, 0.5)
			end
		end
	end)

	panel = Instance.new("Frame")
	panel.Name = "ShopPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.94, 0.86)
	panel.BackgroundColor3 = UIStyle.PanelColor
	panel.BackgroundTransparency = 0.04
	panel.Visible = false
	panel.ZIndex = 5
	panel.Parent = gui
	UIStyle.border(panel, 4)
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(680, 480)
	constraint.Parent = panel
	panelScale = Instance.new("UIScale")
	panelScale.Parent = panel

	local title = textLabel(panel, {
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(0.5, 0, 0, 42),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "SHOP",
	}, MonetizationConfig.ShopColor, 3.5)
	local titleShine = Instance.new("UIGradient")
	titleShine.Rotation = 90
	titleShine.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(255, 160, 230))
	titleShine.Parent = title

	local close, closeScale = chunkyButton(panel, Color3.fromRGB(230, 70, 70), "X")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -10, 0, 8)
	close.Size = UDim2.fromOffset(44, 44)
	close.Activated:Connect(function()
		pop(closeScale, 0.8, 0.2)
		MonetizationShop.close()
	end)

	local tabs = Instance.new("Frame")
	tabs.Position = UDim2.fromOffset(12, 58)
	tabs.Size = UDim2.new(1, -24, 0, 42)
	tabs.BackgroundTransparency = 1
	tabs.Parent = panel
	local tabList = Instance.new("UIListLayout")
	tabList.FillDirection = Enum.FillDirection.Horizontal
	tabList.Padding = UDim.new(0, 8)
	tabList.SortOrder = Enum.SortOrder.LayoutOrder
	tabList.Parent = tabs
	for i, tab in MonetizationConfig.Tabs do
		local tabButton, tabScale = chunkyButton(tabs, TAB_COLOR, string.upper(tab))
		tabButton.LayoutOrder = i
		tabButton.Size = UDim2.new(1 / #MonetizationConfig.Tabs, -6, 1, 0)
		tabButton.Activated:Connect(function()
			pop(tabScale, 0.85, 0.25)
			showTab(tab)
		end)
		tabButtons[tab] = tabButton
	end

	grid = Instance.new("ScrollingFrame")
	grid.Position = UDim2.fromOffset(12, 108)
	grid.Size = UDim2.new(1, -24, 1, -142)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.CanvasSize = UDim2.new()
	grid.Parent = panel
	local gridPad = Instance.new("UIPadding")
	gridPad.PaddingTop = UDim.new(0, 4)
	gridPad.PaddingLeft = UDim.new(0, 4)
	gridPad.Parent = grid
	gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellPadding = UDim2.fromOffset(10, 10)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	testLabel = textLabel(panel, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -24, 0, 22),
		Text = "TEST MODE: purchases are simulated, no Robux are spent",
		Visible = false,
	}, Color3.fromRGB(255, 230, 120))

	for _, product in MonetizationConfig.Products do
		if not product.OncePerPlayer then -- intro products appear on their full-price card
			makeCard(product.Key, product.Tab, product.Order, product.Color)
		end
	end
	for _, pass in MonetizationConfig.Passes do
		makeCard(pass.Key, "Passes", pass.Order, pass.Color)
	end
	relayout()
	showTab(currentTab)
end

function MonetizationShop.refresh(state: ShopState)
	lastState = state
	testLabel.Visible = state.TestMode
	for _, card in cards do
		refreshCard(card, state)
	end
end

-- Only the timers change every second; cheap enough to redo the visible cards.
function MonetizationShop.tick()
	if panel.Visible and lastState then
		MonetizationShop.refresh(lastState)
	end
end

function MonetizationShop.isOpen(): boolean
	return panel.Visible
end

function MonetizationShop.open(tab: string?)
	if tab then
		showTab(tab)
	end
	if not panel.Visible then
		panel.Visible = true
		pop(panelScale, 0.6, 0.4)
		callbacks.onOpen()
	end
end

function MonetizationShop.close()
	panel.Visible = false
end

return MonetizationShop
