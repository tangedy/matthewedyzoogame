-- Where the HUD's fixed pieces sit. Every number is in design units: ResponsiveScale
-- multiplies them, so a phone at scale 0.55 draws a 90-unit button about 50px wide.
--
-- Every touch device, phone or tablet, gets one layout built around the thumbs:
--
--   top left      cash and income, then a narrow column of square icon buttons
--                 (INDEX, DAILY, SHOP). Narrow, so the thumbstick area stays clear.
--   right side    2x Cash Forever, the invite box, then the quick-buy column (MonetizationQuickBuy)
--   bottom left   nothing: the thumbstick
--   bottom right  jump
--   bottom centre one hint line, and the carry PUT DOWN / SELL row
--
-- Keyboard and gamepad keep the original desktop layout, with text buttons.
--
--   Layout.get()                the spec for the current profile
--   Layout.watch(fn)            calls fn(spec) now and whenever the spec changes
--   Layout.rail(b, order, icon) stacks a left-rail button by order, skipping hidden
--                               ones, across ScreenGuis. icon is a UI/Icons name: on
--                               top of a caption in compact mode, left of the text otherwise.

local DeviceProfile = require(script.Parent.DeviceProfile)
local Icons = require(script.Parent.Icons)

local Layout = {}

export type Spec = {
	key: string,
	wallet: { anchor: Vector2, position: UDim2, size: Vector2, cashHeight: number },
	rail: { anchor: Vector2, x: number, top: UDim, step: number, size: Vector2, compact: boolean },
	boostTimers: { anchor: Vector2, position: UDim2 },
	-- One-tap Robux buys on the right. size is each square button; gap leaves room for the
	-- price chip that hangs off its bottom edge (a column) or between buttons (a row).
	quickBuy: { anchor: Vector2, position: UDim2, size: number, gap: number, row: boolean },
	-- The wide 2x Cash Forever button, straight above the invite box and the same size.
	cashForever: { anchor: Vector2, position: UDim2 },
	invite: { anchor: Vector2, position: UDim2 },
	dataWarning: UDim2,
	-- Full-screen menus (Robux shop, index, daily). columns: shop grid columns, nil = by width.
	panel: { scale: Vector2, maxSize: Vector2, columns: number? },
	toastLift: number, -- bottom-centre hint line, above the controls
	bannerLift: number, -- bottom-centre button rows (carry PUT DOWN / SELL)
	carryButton: Vector2, -- each of those buttons
}

local DESKTOP: Spec = {
	key = "Desktop",
	wallet = {
		anchor = Vector2.new(0, 1),
		position = UDim2.new(0, 16, 1, -16),
		size = Vector2.new(380, 150),
		cashHeight = 110,
	},
	rail = {
		anchor = Vector2.new(0, 0.5),
		x = 16,
		top = UDim.new(0.5, 14),
		step = 48,
		size = Vector2.new(170, 42),
		compact = false,
	},
	boostTimers = { anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 196, 0.5, 14) },
	-- Bottom up: the invite box, 2x Cash Forever right on top of it, then the quick-buy
	-- column grows up from above that, under the player list.
	quickBuy = { anchor = Vector2.new(1, 1), position = UDim2.new(1, -16, 0.5, -46), size = 72, gap = 20, row = false },
	cashForever = { anchor = Vector2.new(1, 1), position = UDim2.new(1, -16, 0.5, 31) },
	invite = { anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -16, 0.5, 70) },
	dataWarning = UDim2.new(0, 16, 0.5, 140),
	panel = { scale = Vector2.new(0.94, 0.86), maxSize = Vector2.new(680, 480), columns = nil },
	toastLift = 140,
	bannerLift = 190,
	carryButton = Vector2.new(170, 44),
}

-- A landscape phone at scale 0.5 is about 660 units tall under the top bar. Cash and
-- the icon column end near 360; the column is 84 wide (about 42px drawn), so a thumb
-- landing anywhere right of it or below it reaches the thumbstick. Menus fill nearly
-- the whole screen, and the shop is two columns.
local TOUCH: Spec = {
	key = "Touch",
	wallet = {
		anchor = Vector2.new(0, 0),
		position = UDim2.fromOffset(16, 4),
		size = Vector2.new(240, 78),
		cashHeight = 56,
	},
	rail = {
		anchor = Vector2.new(0, 0),
		x = 16,
		top = UDim.new(0, 90),
		step = 92,
		size = Vector2.new(84, 84),
		compact = true,
	},
	boostTimers = { anchor = Vector2.new(0, 0), position = UDim2.fromOffset(112, 90) },
	-- Top down the right edge: 2x Cash Forever, the invite box, then the quick-buy column.
	-- On a 380px-tall landscape phone, WASH (on top of jump) starts about 288 units (144px)
	-- down; one 76 button with its price chip ends near 237, so the column stays clear of
	-- it. Keep QuickBuy at one.
	quickBuy = { anchor = Vector2.new(1, 0), position = UDim2.new(1, -16, 0, 150), size = 76, gap = 18, row = false },
	cashForever = { anchor = Vector2.new(1, 0), position = UDim2.new(1, -16, 0, 8) },
	invite = { anchor = Vector2.new(1, 0), position = UDim2.new(1, -16, 0, 78) },
	dataWarning = UDim2.fromOffset(270, 10),
	panel = { scale = Vector2.new(0.96, 0.95), maxSize = Vector2.new(1120, 640), columns = 2 },
	toastLift = 28,
	bannerLift = 24,
	-- About 40px tall drawn at phone scale: a thumb-sized target, not a 20px strip.
	carryButton = Vector2.new(210, 84),
}

local current: Spec = DESKTOP
local watchers: { (Spec) -> () } = {}

type RailEntry = { button: GuiButton, order: number, icon: string?, iconFrame: Frame? }
local railEntries: { RailEntry } = {}

local ICON_SHARE = 0.58 -- top part of a compact button that holds the icon

local function specFor(profile: DeviceProfile.Profile): Spec
	if profile.inputMode == "Touch" or profile.formFactor == "Mobile" then
		return TOUCH
	end
	return DESKTOP
end

-- Compact: icon on top, the button's own text shrinks to a caption underneath.
-- Wide: icon in a square on the left, text beside it.
-- The button's UIPadding moves its text and also its children, so the icon's position
-- takes the padding back off (offsets: the rail size is in fixed design units).
local function styleEntry(entry: RailEntry, compact: boolean, size: Vector2)
	local button = entry.button
	local height = size.Y
	local padTop, padLeft = 0, 0
	local pad = button:FindFirstChildOfClass("UIPadding")
	if pad then
		if pad:GetAttribute("RailTop") == nil then
			pad:SetAttribute("RailTop", pad.PaddingTop.Offset)
			pad:SetAttribute("RailLeft", pad.PaddingLeft.Offset)
		end
		padTop = pad:GetAttribute("RailTop") :: number
		padLeft = pad:GetAttribute("RailLeft") :: number
		if entry.icon then
			if compact then
				padTop = math.floor(height * ICON_SHARE)
			else
				padLeft = height - 4
			end
		end
		pad.PaddingTop = UDim.new(0, padTop)
		pad.PaddingLeft = UDim.new(0, padLeft)
	end
	if not entry.icon then
		return
	end
	if not entry.iconFrame then
		local holder = Instance.new("Frame")
		holder.Name = "RailIcon"
		holder.BackgroundTransparency = 1
		holder.ZIndex = button.ZIndex + 1
		holder.Parent = button
		Icons.make(entry.icon, holder, { outline = 2.5 })
		entry.iconFrame = holder
	end
	local holder = entry.iconFrame :: Frame
	if compact then
		local side = math.floor(height * (ICON_SHARE - 0.08))
		holder.AnchorPoint = Vector2.new(0.5, 0)
		holder.Position = UDim2.new(0.5, 0, 0, math.floor(height * 0.07) - padTop)
		holder.Size = UDim2.fromOffset(side, side)
	else
		holder.AnchorPoint = Vector2.new(0, 0.5)
		holder.Position = UDim2.new(0, 6 - padLeft, 0.5, 0)
		holder.Size = UDim2.fromOffset(height - 10, height - 10)
	end
end

local function restackRail()
	table.sort(railEntries, function(a, b)
		return a.order < b.order
	end)
	local rail = current.rail
	local slot = 0
	for _, entry in railEntries do
		local button = entry.button
		button.AnchorPoint = rail.anchor
		button.Size = UDim2.fromOffset(rail.size.X, rail.size.Y)
		button.Position = UDim2.new(0, rail.x, rail.top.Scale, rail.top.Offset + slot * rail.step)
		styleEntry(entry, rail.compact, rail.size)
		if button.Visible then
			slot += 1
		end
	end
end

-- Sizes a full-screen menu panel from the spec, and keeps it sized when the spec changes.
-- Its UISizeConstraint is reused (or made) so there is only one cap on it. desktop keeps
-- a panel's own original desktop size; touch always uses the shared full-screen size.
function Layout.panel(panel: GuiObject, desktop: { scale: Vector2, maxSize: Vector2 }?)
	local cap = panel:FindFirstChildOfClass("UISizeConstraint")
	if not cap then
		local created = Instance.new("UISizeConstraint")
		created.Parent = panel
		cap = created
	end
	local constraint = cap :: UISizeConstraint
	Layout.watch(function(spec)
		local size = if spec.key == "Desktop" and desktop then desktop else spec.panel
		panel.Size = UDim2.fromScale(size.scale.X, size.scale.Y)
		constraint.MaxSize = size.maxSize
	end)
end

-- A panel's X is ~20px on a phone, and the panel fills the screen, so there is little dim
-- around it to tap either. On touch, an invisible target covers the panel's top-right
-- corner down to the bottom of the X (the header, never the tabs or content under it).
local CLOSE_TARGET_WIDTH = 120
function Layout.closeTarget(button: GuiButton, onClose: () -> ())
	local panel = button.Parent
	if not panel or not panel:IsA("GuiObject") then
		return
	end
	local target = Instance.new("TextButton")
	target.Name = "CloseTarget"
	target.AnchorPoint = Vector2.new(1, 0)
	target.Position = UDim2.fromScale(1, 0)
	target.BackgroundTransparency = 1
	target.Text = ""
	target.Selectable = false
	target.ZIndex = button.ZIndex + 1
	target.Parent = panel
	local function size()
		local width = math.max(CLOSE_TARGET_WIDTH, button.Size.X.Offset - button.Position.X.Offset)
		target.Size = UDim2.fromOffset(width, button.Position.Y.Offset + button.Size.Y.Offset + 4)
	end
	button:GetPropertyChangedSignal("Size"):Connect(size)
	size()
	target.Activated:Connect(onClose)
	Layout.watch(function(spec)
		target.Visible = spec.key == "Touch"
	end)
end

-- The design-unit size of a scaled object: AbsoluteSize is screen pixels after
-- ResponsiveScale, and offsets inside it are design units before it.
function Layout.designSize(object: GuiObject): Vector2
	local gui = object:FindFirstAncestorOfClass("ScreenGui")
	local scale = gui and gui:FindFirstChild("ResponsiveScale")
	local factor = if scale and scale:IsA("UIScale") and scale.Scale > 0.05 then scale.Scale else 1
	return object.AbsoluteSize / factor
end

function Layout.get(): Spec
	return current
end

-- Called by UIPlatform on every profile publish. Cheap when nothing moved.
function Layout.apply(profile: DeviceProfile.Profile)
	local nextSpec = specFor(profile)
	if nextSpec == current then
		return
	end
	current = nextSpec
	restackRail()
	for _, watcher in table.clone(watchers) do
		local ok, err = pcall(watcher, current)
		if not ok then
			warn(`[UILayout] {err}`)
		end
	end
end

function Layout.watch(watcher: (Spec) -> ()): () -> ()
	table.insert(watchers, watcher)
	watcher(current)
	return function()
		local index = table.find(watchers, watcher)
		if index then
			table.remove(watchers, index)
		end
	end
end

-- The rail owns Position, Size and AnchorPoint of these buttons. A button that hides
-- gives its slot to the next one.
function Layout.rail(button: GuiButton, order: number, icon: string?)
	table.insert(railEntries, { button = button, order = order, icon = icon })
	button:GetPropertyChangedSignal("Visible"):Connect(restackRail)
	button.Destroying:Connect(function()
		for index, entry in railEntries do
			if entry.button == button then
				table.remove(railEntries, index)
				break
			end
		end
		restackRail()
	end)
	restackRail()
end

return Layout
