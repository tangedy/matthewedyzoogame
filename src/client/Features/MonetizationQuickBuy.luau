-- One-tap Robux buys on the right of the screen, like Steal a Brainrot's "x2 Speed"
-- button: a short column (a row under the invite box on touch) of square icon buttons (MonetizationConfig.QuickBuy), each with a
-- price chip hanging off its bottom edge. A tap sends the key straight to the server, so
-- Roblox's own purchase dialog is the only confirm step.
--
-- Kept out of the way on purpose: three buttons at most, its own ScreenGui under every menu
-- (a menu's dimmer covers it), hidden for the session's first Offers.QuietSeconds and while
-- a contextual offer is up (that popup sits in the same right-hand spot on desktop).
-- Pure view, like MonetizationShop: MonetizationController owns the state and the buy call.
-- Part of the Monetization feature (no init of its own).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local MonetizationShop = require(script.Parent.MonetizationShop)
local UIPlatform = require(script.Parent.Parent.UI)

local Icons = UIPlatform.Icons

type ShopState = MonetizationConfig.ShopState

export type Callbacks = {
	onBuy: (key: string) -> (),
}

type Entry = {
	Key: string,
	Button: TextButton,
	Scale: UIScale,
	Caption: TextLabel,
	Price: TextLabel,
}

local MonetizationQuickBuy = {}

-- Short captions under the icon. Cash packs show what they pay right now instead.
local CAPTIONS: { [string]: string } = {
	SpeedBoost = "2X SPEED",
	AutoCollect = "AUTO CASH",
}
local ACTIVE_COLOR = Color3.fromRGB(255, 230, 120)
local CHIP_HEIGHT = 22

local column: Frame
local entries: { Entry } = {}
local blocked: { [string]: boolean } = {}
local lastState: ShopState? = nil
local callbacks: Callbacks

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local hours = s // 3600
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, (s % 3600) // 60, s % 60)
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

local function shade(color: Color3, factor: number): Color3
	return Color3.new(color.R * factor, color.G * factor, color.B * factor)
end

local function pop(scale: UIScale, from: number, seconds: number)
	scale.Scale = from
	TweenService:Create(scale, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

local function refreshVisible()
	column.Visible = next(blocked) == nil
end

local function makeEntry(key: string, order: number): Entry?
	local product = MonetizationConfig.ProductsByKey[key]
	if not product then
		warn(`[QuickBuy] unknown product {key}`)
		return nil
	end
	local button = Instance.new("TextButton")
	button.Name = key
	button.LayoutOrder = order
	button.Text = ""
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.new(1, 1, 1)
	button.Parent = column
	UIStyle.border(button, 3)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(product.Color, shade(product.Color, 0.5))
	gradient.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button
	UIPlatform.Feedback.button(button)

	local iconHolder = Instance.new("Frame")
	iconHolder.AnchorPoint = Vector2.new(0.5, 0)
	iconHolder.Position = UDim2.fromScale(0.5, 0.06)
	iconHolder.Size = UDim2.fromScale(0.62, 0.52)
	iconHolder.BackgroundTransparency = 1
	iconHolder.Parent = button
	Icons.make(MonetizationShop.iconFor(key), iconHolder, { outline = 2.5 })

	local caption = Instance.new("TextLabel")
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.fromScale(0.5, 0.58)
	caption.Size = UDim2.fromScale(0.92, 0.2)
	caption.Parent = button
	UIStyle.text(caption, nil, nil, 1.5)

	-- Price chip: hangs off the bottom edge so the button itself stays all icon.
	local chip = Instance.new("Frame")
	chip.AnchorPoint = Vector2.new(0.5, 0.5)
	chip.Position = UDim2.new(0.5, 0, 1, -2)
	chip.Size = UDim2.new(0.96, 0, 0, CHIP_HEIGHT)
	chip.BackgroundColor3 = UIStyle.Colors.Robux
	chip.ZIndex = 3
	chip.Parent = button
	UIStyle.border(chip, 2)
	local robux = Instance.new("Frame")
	robux.AnchorPoint = Vector2.new(0, 0.5)
	robux.Position = UDim2.new(0, 3, 0.5, 0)
	robux.Size = UDim2.fromOffset(CHIP_HEIGHT - 4, CHIP_HEIGHT - 4)
	robux.BackgroundTransparency = 1
	robux.ZIndex = 4
	robux.Parent = chip
	Icons.make("Robux", robux, { outline = 1.5 })
	local price = Instance.new("TextLabel")
	price.Position = UDim2.fromOffset(CHIP_HEIGHT, 2)
	price.Size = UDim2.new(1, -CHIP_HEIGHT - 4, 1, -4)
	price.ZIndex = 4
	price.Text = tostring(product.Robux)
	price.Parent = chip
	UIStyle.text(price, nil, nil, 1.5)

	local entry: Entry = { Key = key, Button = button, Scale = scale, Caption = caption, Price = price }
	button.Activated:Connect(function()
		pop(scale, 0.85, 0.3)
		callbacks.onBuy(entry.Key)
	end)
	return entry
end

local function refreshEntry(entry: Entry, state: ShopState)
	local product = MonetizationConfig.ProductsByKey[entry.Key]
	entry.Button.Visible = not state.Unavailable[entry.Key]
	entry.Price.Text = tostring(product.Robux)
	local now = Workspace:GetServerTimeNow()
	local endsAt = if product.Kind == "SpeedBoost"
		then state.SpeedEndsAt or 0
		elseif product.Kind == "AutoCollect" then state.AutoCollectEndsAt
		else 0
	if endsAt > now then
		-- Running: show the time left (buying again stacks more on).
		entry.Caption.Text = clock(endsAt - now)
		entry.Caption.TextColor3 = ACTIVE_COLOR
	elseif product.Kind == "Cash" then
		local amount = state.Cash[entry.Key]
		entry.Caption.Text = if amount then `+{UIStyle.formatMoney(amount)}` else "CASH"
		entry.Caption.TextColor3 = UIStyle.CashColor
	else
		entry.Caption.Text = CAPTIONS[product.Kind] or string.upper(product.DisplayName)
		entry.Caption.TextColor3 = Color3.new(1, 1, 1)
	end
end

function MonetizationQuickBuy.build(handlers: Callbacks)
	callbacks = handlers
	local gui = Instance.new("ScreenGui")
	gui.Name = "QuickBuy"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 4 -- under every menu and its dimmer
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	column = Instance.new("Frame")
	column.Name = "Column"
	column.BackgroundTransparency = 1
	column.AutomaticSize = Enum.AutomaticSize.XY
	column.Parent = gui
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.Parent = column
	-- Room under the last button for its price chip.
	local pad = Instance.new("UIPadding")
	pad.PaddingBottom = UDim.new(0, CHIP_HEIGHT // 2 + 2)
	pad.Parent = column

	for order, key in MonetizationConfig.QuickBuy do
		local entry = makeEntry(key, order)
		if entry then
			table.insert(entries, entry)
		end
	end

	UIPlatform.Layout.watch(function(spec)
		local slot = spec.quickBuy
		column.AnchorPoint = slot.anchor
		column.Position = slot.position
		column.Size = UDim2.fromOffset(0, 0)
		list.FillDirection = if slot.row then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
		list.Padding = UDim.new(0, slot.gap)
		for _, entry in entries do
			entry.Button.Size = UDim2.fromOffset(slot.size, slot.size)
		end
	end)
	refreshVisible()
end

-- Hides the column while any reason holds (each caller uses its own reason name).
function MonetizationQuickBuy.setBlocked(reason: string, isBlocked: boolean)
	blocked[reason] = if isBlocked then true else nil
	if column then
		local wasVisible = column.Visible
		refreshVisible()
		if column.Visible and not wasVisible then
			for _, entry in entries do
				pop(entry.Scale, 0.5, 0.4)
			end
		end
	end
end

function MonetizationQuickBuy.refresh(state: ShopState)
	lastState = state
	for _, entry in entries do
		refreshEntry(entry, state)
	end
end

-- Once a second, for the running-boost countdowns.
function MonetizationQuickBuy.tick()
	if column and column.Visible and lastState then
		MonetizationQuickBuy.refresh(lastState)
	end
end

return MonetizationQuickBuy
