-- One-tap Robux buys on the right of the screen, like Steal a Brainrot's "x2 Speed"
-- button: a short column down the right side of square icon buttons (MonetizationConfig.QuickBuy), each with a
-- price chip hanging off its bottom edge. A tap sends the key straight to the server, so
-- Roblox's own purchase dialog is the only confirm step.
--
-- Kept out of the way on purpose: two buttons (three at most on desktop), its own ScreenGui under every menu
-- (a menu's dimmer covers it), hidden for the session's first Offers.QuietSeconds and while
-- a contextual offer is up (that popup sits in the same right-hand spot on desktop).
-- A game pass hides once owned and the first QuickBuyBackup key takes its slot.
-- 2x Cash Forever (QuickBuyWide) is its own wide button, the invite box's size, straight
-- above it; it hides once owned and with the column.
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
	DoubleCash = "FOREVER",
}
local ACTIVE_COLOR = Color3.fromRGB(255, 230, 120)
local CHIP_HEIGHT = 22

local column: Frame
local wide: TextButton? = nil
local wideOwned = false
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
	if wide then
		wide.Visible = column.Visible and not wideOwned
	end
end

-- Same size and look as the invite box (FriendLuck): icon on the left, name over the price.
local function makeWide(gui: ScreenGui, key: string): TextButton?
	local pass = MonetizationConfig.PassesByKey[key]
	if not pass then
		warn(`[QuickBuy] unknown pass {key}`)
		return nil
	end
	local button = Instance.new("TextButton")
	button.Name = key
	button.Text = ""
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.new(1, 1, 1)
	button.Size = UDim2.fromOffset(200, 62)
	button.Parent = gui
	UIStyle.border(button, 3)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = button
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(pass.Color, shade(pass.Color, 0.5))
	gradient.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button
	UIPlatform.Feedback.button(button)

	local iconHolder = Instance.new("Frame")
	iconHolder.AnchorPoint = Vector2.new(0, 0.5)
	iconHolder.Position = UDim2.new(0, 6, 0.5, 0)
	iconHolder.Size = UDim2.fromOffset(50, 50)
	iconHolder.BackgroundTransparency = 1
	iconHolder.Parent = button
	Icons.make(MonetizationShop.iconFor(key), iconHolder, { outline = 2.5 })

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(60, 5)
	title.Size = UDim2.new(1, -66, 0, 30)
	title.TextWrapped = true
	title.Text = string.upper(pass.DisplayName)
	title.Parent = button
	UIStyle.text(title, ACTIVE_COLOR, nil, 2.5)

	local robux = Instance.new("Frame")
	robux.Position = UDim2.new(0, 60, 1, -24)
	robux.Size = UDim2.fromOffset(18, 18)
	robux.BackgroundTransparency = 1
	robux.Parent = button
	Icons.make("Robux", robux, { outline = 1.5 })
	local price = Instance.new("TextLabel")
	price.Position = UDim2.new(0, 82, 1, -24)
	price.Size = UDim2.new(1, -88, 0, 18)
	price.TextXAlignment = Enum.TextXAlignment.Left
	price.Text = tostring(pass.Robux)
	price.Parent = button
	UIStyle.text(price, nil, nil, 1.5)

	button.Activated:Connect(function()
		pop(scale, 0.9, 0.25)
		callbacks.onBuy(key)
	end)
	return button
end

local function makeEntry(key: string, order: number): Entry?
	local product: { Robux: number, Color: Color3 }? = MonetizationConfig.ProductsByKey[key]
		or MonetizationConfig.PassesByKey[key]
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

-- Whether this entry could be bought right now (an owned pass or an unsellable item can't).
local function buyable(key: string, state: ShopState): boolean
	if MonetizationConfig.PassesByKey[key] then
		return not state.Passes[key]
	end
	return not state.Unavailable[key]
end

local function refreshEntry(entry: Entry, state: ShopState)
	local pass = MonetizationConfig.PassesByKey[entry.Key]
	if pass then
		entry.Price.Text = tostring(pass.Robux)
		entry.Caption.Text = CAPTIONS[entry.Key] or string.upper(pass.DisplayName)
		entry.Caption.TextColor3 = ACTIVE_COLOR
		return
	end
	local product = MonetizationConfig.ProductsByKey[entry.Key]
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

	local keys = table.clone(MonetizationConfig.QuickBuy)
	table.move(MonetizationConfig.QuickBuyBackup, 1, #MonetizationConfig.QuickBuyBackup, #keys + 1, keys)
	for order, key in keys do
		local entry = makeEntry(key, order)
		if entry then
			entry.Button.Visible = order <= #MonetizationConfig.QuickBuy
			table.insert(entries, entry)
		end
	end

	wide = makeWide(gui, MonetizationConfig.QuickBuyWide)

	UIPlatform.Layout.watch(function(spec)
		if wide then
			wide.AnchorPoint = spec.cashForever.anchor
			wide.Position = spec.cashForever.position
		end
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
			local wideScale = wide and wide:FindFirstChildOfClass("UIScale")
			if wideScale then
				pop(wideScale, 0.5, 0.4)
			end
		end
	end
end

function MonetizationQuickBuy.refresh(state: ShopState)
	lastState = state
	wideOwned = state.Passes[MonetizationConfig.QuickBuyWide] == true
	if column then
		refreshVisible()
	end
	-- The first #QuickBuy buyable entries show, in order; backups fill in behind owned passes.
	local slots = #MonetizationConfig.QuickBuy
	for _, entry in entries do
		local show = slots > 0 and buyable(entry.Key, state)
		entry.Button.Visible = show
		if show then
			slots -= 1
			refreshEntry(entry, state)
		end
	end
end

-- Once a second, for the running-boost countdowns.
function MonetizationQuickBuy.tick()
	if column and column.Visible and lastState then
		MonetizationQuickBuy.refresh(lastState)
	end
end

return MonetizationQuickBuy
