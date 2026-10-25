-- Where the HUD's fixed pieces sit for each form factor. Every number is in design
-- units: ResponsiveScale multiplies them, so a phone at scale 0.55 draws a 68-unit
-- button about 37px tall.
--
-- Phones are laid out around the thumbs. The bottom-left is the thumbstick, the
-- bottom-right is jump and WASH, so cash and the menu rail move to the top-left and
-- toasts sit low in the middle. Tablets and desktops keep the original layout.
--
--   Layout.get()          the spec for the current profile
--   Layout.watch(fn)      calls fn(spec) now and whenever the form factor or input changes
--   Layout.rail(b, order) stacks a left-rail button (INDEX, DAILY, SHOP) by order,
--                         skipping hidden ones, across ScreenGuis

local DeviceProfile = require(script.Parent.DeviceProfile)

local Layout = {}

export type Spec = {
	key: string,
	wallet: { anchor: Vector2, position: UDim2, size: Vector2, cashHeight: number },
	rail: { anchor: Vector2, x: number, top: UDim, step: number, size: Vector2 },
	boostTimers: { anchor: Vector2, position: UDim2 },
	invite: { anchor: Vector2, position: UDim2 },
	dataWarning: UDim2,
	toastLift: number, -- bottom-centre hint line, above the controls
	bannerLift: number, -- bottom-centre button rows (carry PUT DOWN / SELL)
}

-- Desktop and keyboard tablets: the layout the HUD was first built at.
local DESKTOP: Spec = {
	key = "Desktop",
	wallet = {
		anchor = Vector2.new(0, 1),
		position = UDim2.new(0, 16, 1, -16),
		size = Vector2.new(380, 150),
		cashHeight = 110,
	},
	rail = { anchor = Vector2.new(0, 0.5), x = 16, top = UDim.new(0.5, 14), step = 48, size = Vector2.new(170, 42) },
	boostTimers = { anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 196, 0.5, 14) },
	invite = { anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -16, 0.5, 70) },
	dataWarning = UDim2.new(0, 16, 0.5, 140),
	toastLift = 140,
	bannerLift = 190,
}

-- Touch tablets: the jump button and thumbstick are large, so the bottom rows lift.
local TABLET_TOUCH: Spec = table.clone(DESKTOP)
TABLET_TOUCH.key = "TabletTouch"
TABLET_TOUCH.wallet = table.clone(DESKTOP.wallet)
TABLET_TOUCH.wallet.position = UDim2.new(0, 16, 1, -190)
TABLET_TOUCH.invite = { anchor = Vector2.new(1, 0), position = UDim2.new(1, -16, 0, 64) }
TABLET_TOUCH.toastLift = 260
TABLET_TOUCH.bannerLift = 260

-- Phones, landscape or portrait. A landscape phone at scale 0.55 is about 600 units
-- tall under the top bar. The wallet and rail use the top 340; the rest is thumb room.
-- Rail buttons are 68 tall so the drawn target stays near 40px.
local PHONE: Spec = {
	key = "Phone",
	wallet = {
		anchor = Vector2.new(0, 0),
		position = UDim2.fromOffset(16, 4),
		size = Vector2.new(300, 100),
		cashHeight = 72,
	},
	rail = { anchor = Vector2.new(0, 0), x = 16, top = UDim.new(0, 112), step = 76, size = Vector2.new(176, 68) },
	boostTimers = { anchor = Vector2.new(0, 0), position = UDim2.fromOffset(204, 112) },
	invite = { anchor = Vector2.new(1, 0), position = UDim2.new(1, -16, 0, 12) },
	dataWarning = UDim2.fromOffset(330, 10),
	toastLift = 28,
	bannerLift = 24,
}

local current: Spec = DESKTOP
local watchers: { (Spec) -> () } = {}

type RailEntry = { button: GuiObject, order: number }
local railEntries: { RailEntry } = {}

local function specFor(profile: DeviceProfile.Profile): Spec
	if profile.formFactor == "Mobile" then
		return PHONE
	elseif profile.inputMode == "Touch" then
		return TABLET_TOUCH
	end
	return DESKTOP
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
		if button.Visible then
			slot += 1
		end
	end
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
function Layout.rail(button: GuiObject, order: number)
	table.insert(railEntries, { button = button, order = order })
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
