-- Form factor comes from the camera viewport. Input mode comes from PreferredInput.
-- TouchEnabled / KeyboardEnabled / GamepadEnabled are intentionally not read: those
-- stay true on hybrid devices and must not decide layout.

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DeviceProfile = {}

export type FormFactor = "Mobile" | "Tablet" | "PC"
export type InputMode = "Touch" | "KeyboardMouse" | "Gamepad"

export type Profile = {
	formFactor: FormFactor,
	inputMode: InputMode,
	viewport: Vector2,
	scale: number,
}

-- Width bands from the layout spec. Equal to the edge belongs to the wider class:
-- 600 and 1024 are Tablet, anything wider than 1024 is PC.
local MOBILE_MAX_WIDTH = 600
local TABLET_MAX_WIDTH = 1024

-- Offset HUD (cash, wash card, toasts) was authored for a 1280-wide desktop view.
-- The scale curve is continuous in viewport size. A per-profile multiplier would
-- step the HUD up or down the moment a resize crossed 600 or 1024.
local DESIGN = Vector2.new(1280, 720)
local NARROW_WIDTH = 360
local SCALE_AT_NARROW = 0.62

-- A very short window shrinks a little further. ^0.8 keeps that drop gentle.
local READABILITY_EXPONENT = 0.8

-- Guard rails only. The curve already lands inside these for a normal resize,
-- so crossing a width band does not pop. Mobile stays capped under desktop size.
local SCALE_LIMITS: { [FormFactor]: { min: number, max: number } } = {
	Mobile = { min = 0.55, max = 0.8 },
	Tablet = { min = 0.55, max = 0.95 },
	PC = { min = 0.55, max = 1 },
}

local FALLBACK_VIEWPORT = Vector2.new(1280, 720)
local MIN_VIEWPORT_AXIS = 50

-- A landscape phone is 700-930 wide but under 500 tall. By width alone it reads as a
-- tablet, and the tablet layout puts controls in the top half of a 390px-tall screen.
-- So a touch screen whose short side is under PHONE_MAX_SHORT_SIDE is always Mobile.
-- A short desktop window keeps the width rule.
local PHONE_MAX_SHORT_SIDE = 500

function DeviceProfile.formFactor(viewport: Vector2, inputMode: InputMode?): FormFactor
	local width = viewport.X
	if inputMode == "Touch" and math.min(viewport.X, viewport.Y) < PHONE_MAX_SHORT_SIDE then
		return "Mobile"
	end
	if width < MOBILE_MAX_WIDTH then
		return "Mobile"
	elseif width <= TABLET_MAX_WIDTH then
		return "Tablet"
	end
	return "PC"
end

function DeviceProfile.inputMode(): InputMode
	local preferred = UserInputService.PreferredInput
	if preferred == Enum.PreferredInput.Touch then
		return "Touch"
	elseif preferred == Enum.PreferredInput.Gamepad then
		return "Gamepad"
	end
	return "KeyboardMouse"
end

function DeviceProfile.viewport(): Vector2
	local camera = Workspace.CurrentCamera
	local size = if camera then camera.ViewportSize else FALLBACK_VIEWPORT
	-- The camera reports a zero size for a moment while it is being created.
	if size.X < MIN_VIEWPORT_AXIS or size.Y < MIN_VIEWPORT_AXIS then
		return FALLBACK_VIEWPORT
	end
	return size
end

local function smoothstep(t: number): number
	return t * t * (3 - 2 * t)
end

function DeviceProfile.scaleFor(viewport: Vector2, formFactor: FormFactor): number
	local widthT = math.clamp((viewport.X - NARROW_WIDTH) / (DESIGN.X - NARROW_WIDTH), 0, 1)
	local widthScale = SCALE_AT_NARROW + (1 - SCALE_AT_NARROW) * smoothstep(widthT)
	-- Height is a second axis, not a second profile. Full-height windows stay on widthScale.
	local heightFit = math.clamp(viewport.Y / DESIGN.Y, 0.45, 1)
	local limits = SCALE_LIMITS[formFactor]
	return math.clamp(widthScale * heightFit ^ READABILITY_EXPONENT, limits.min, limits.max)
end

function DeviceProfile.capture(): Profile
	local viewport = DeviceProfile.viewport()
	local inputMode = DeviceProfile.inputMode()
	local formFactor = DeviceProfile.formFactor(viewport, inputMode)
	return {
		formFactor = formFactor,
		inputMode = inputMode,
		viewport = viewport,
		scale = DeviceProfile.scaleFor(viewport, formFactor),
	}
end

return DeviceProfile
