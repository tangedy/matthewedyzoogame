-- Cross-platform UI. ClientBootstrap calls start() before any controller builds a gui.
--
--   get()        current form factor, input mode, viewport, and scale
--   onChanged()  fires when the form factor, input mode, or scale actually changes
--   ActionMap    ContextActionService bindings (Spray is live; Sprint and Interact are templates)
--   constrain()  UIAspectRatioConstraint / UISizeConstraint on a frame, not on the ScreenGui
--   setExcluded()  opt a viewport-pixel ScreenGui out of ResponsiveScale
--   Layout       per-device HUD placement (phone, touch tablet, desktop) and the left rail
--   Feedback     hover / press / release motion and click sound for buttons
--   Icons        custom drawn HUD icons (no emoji, no uploaded images)
--   WorldLabels  shrinks billboards over animals and pens on small screens

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ActionMap = require(script.ActionMap)
local Constraints = require(script.Constraints)
local DeviceProfile = require(script.DeviceProfile)
local Feedback = require(script.Feedback)
local Icons = require(script.Icons)
local Layout = require(script.Layout)
local ScaleDriver = require(script.ScaleDriver)
local WorldLabels = require(script.WorldLabels)

local UIPlatform = {}

UIPlatform.ActionMap = ActionMap
UIPlatform.Layout = Layout
UIPlatform.Feedback = Feedback
UIPlatform.Icons = Icons
UIPlatform.WorldLabels = WorldLabels

export type FormFactor = DeviceProfile.FormFactor
export type InputMode = DeviceProfile.InputMode
export type Profile = DeviceProfile.Profile
export type ConstraintSpec = Constraints.Spec
export type LayoutSpec = Layout.Spec

local listeners: { (Profile) -> () } = {}
local snapshot: Profile? = nil
local started = false
local viewportConn: RBXScriptConnection? = nil
local playerGui: PlayerGui? = nil

local function nearlySame(a: Profile, b: Profile): boolean
	return a.formFactor == b.formFactor and a.inputMode == b.inputMode and math.abs(a.scale - b.scale) < 0.004
end

local function writeAttributes(profile: Profile)
	local gui = playerGui
	if not gui then
		return
	end
	gui:SetAttribute("UIFormFactor", profile.formFactor)
	gui:SetAttribute("UIInputMode", profile.inputMode)
	gui:SetAttribute("UIScale", profile.scale)
end

local function fire(profile: Profile)
	-- Clone so a listener can disconnect itself without skipping the next one.
	for _, listener in table.clone(listeners) do
		local ok, err = pcall(listener, profile)
		if not ok then
			warn(`[UIPlatform] {err}`)
		end
	end
end

local function publish(immediate: boolean)
	local nextProfile = DeviceProfile.capture()
	local previous = snapshot
	snapshot = nextProfile
	-- Immediate on the first publish so the HUD does not lerp in from scale 1.
	-- applyProfile is cheap when the input mode did not change, and it has to run
	-- even when get() already primed an identical snapshot before start().
	ScaleDriver.setTarget(nextProfile.scale, immediate)
	ActionMap.applyProfile(nextProfile)
	Layout.apply(nextProfile)
	writeAttributes(nextProfile)
	if previous and nearlySame(previous, nextProfile) then
		return
	end
	fire(nextProfile)
end

local scheduled = false
local function markDirty()
	if scheduled then
		return
	end
	scheduled = true
	-- ViewportSize and PreferredInput often change together. One publish per frame.
	task.defer(function()
		scheduled = false
		publish(false)
	end)
end

local function bindCamera(camera: Camera?)
	if viewportConn then
		viewportConn:Disconnect()
		viewportConn = nil
	end
	if camera then
		viewportConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(markDirty)
	end
end

function UIPlatform.get(): Profile
	if not snapshot then
		snapshot = DeviceProfile.capture()
	end
	return snapshot
end

-- Does not replay the current profile. Read get() for that.
function UIPlatform.onChanged(listener: (Profile) -> ()): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

function UIPlatform.constrain(object: GuiObject, spec: ConstraintSpec)
	Constraints.apply(object, spec)
end

function UIPlatform.setExcluded(gui: ScreenGui, excluded: boolean)
	if excluded then
		gui:SetAttribute(ScaleDriver.EXCLUDE_ATTRIBUTE, true)
	else
		gui:SetAttribute(ScaleDriver.EXCLUDE_ATTRIBUTE, nil)
	end
end

function UIPlatform.start()
	if started then
		return
	end
	started = true
	playerGui = ScaleDriver.start()
	if playerGui then
		WorldLabels.start(playerGui)
	end
	UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(markDirty)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bindCamera(Workspace.CurrentCamera)
		markDirty()
	end)
	bindCamera(Workspace.CurrentCamera)
	publish(true)
end

return UIPlatform
