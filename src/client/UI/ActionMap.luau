-- ContextActionService bindings. Touch preferred-input gets the engine's virtual
-- button; keyboard, mouse, and gamepad do not get a second on-screen control.
--
-- Sprint and Interact are fully specified and left unbound. Binding them would
-- take LeftShift from the character controller and E / ButtonX from ProximityPrompts.
-- Call bindTemplate when a feature is ready to own that action.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local DeviceProfile = require(script.Parent.DeviceProfile)

local ActionMap = {}

export type ActionCallback = (state: Enum.UserInputState, input: InputObject?) -> Enum.ContextActionResult?

export type ActionSpec = {
	name: string,
	title: string,
	keyboardMouse: { Enum.KeyCode | Enum.UserInputType },
	gamepad: { Enum.KeyCode },
	touch: boolean,
	touchPosition: { [DeviceProfile.FormFactor]: UDim2 }?,
	touchSize: { [DeviceProfile.FormFactor]: UDim2 }?,
	image: string?,
	priority: number?,
	ignoreGuiClicks: boolean?,
	callback: ActionCallback?,
}

local DEFAULT_PRIORITY = 2000

local function square(pixels: number): UDim2
	return UDim2.fromOffset(pixels, pixels)
end

-- Positions assume the engine button's center anchor. Spray sits above the
-- jump button. Interact stacks above Spray. Sprint sits above the thumbstick.
ActionMap.Templates = {
	Spray = {
		name = "Spray",
		title = "Spray",
		keyboardMouse = { Enum.UserInputType.MouseButton1 },
		gamepad = { Enum.KeyCode.ButtonR2 },
		touch = true,
		ignoreGuiClicks = true,
		priority = DEFAULT_PRIORITY,
		touchPosition = {
			Mobile = UDim2.new(1, -85, 1, -175),
			-- Tablet jump buttons are larger than the phone one. -210 sits on top of them.
			Tablet = UDim2.new(1, -130, 1, -300),
			PC = UDim2.new(1, -130, 1, -300),
		},
		touchSize = {
			Mobile = square(76),
			Tablet = square(92),
			PC = square(92),
		},
	} :: ActionSpec,
	Interact = {
		name = "Interact",
		title = "Use",
		keyboardMouse = { Enum.KeyCode.E },
		gamepad = { Enum.KeyCode.ButtonX },
		touch = true,
		ignoreGuiClicks = true,
		priority = DEFAULT_PRIORITY + 100,
		touchPosition = {
			Mobile = UDim2.new(1, -85, 1, -265),
			Tablet = UDim2.new(1, -130, 1, -410),
			PC = UDim2.new(1, -130, 1, -410),
		},
		touchSize = {
			Mobile = square(64),
			Tablet = square(80),
			PC = square(80),
		},
	} :: ActionSpec,
	Sprint = {
		name = "Sprint",
		title = "Sprint",
		keyboardMouse = { Enum.KeyCode.LeftShift },
		gamepad = { Enum.KeyCode.ButtonL3 },
		touch = true,
		ignoreGuiClicks = true,
		priority = DEFAULT_PRIORITY,
		touchPosition = {
			Mobile = UDim2.new(0, 90, 1, -190),
			Tablet = UDim2.new(0, 130, 1, -230),
			PC = UDim2.new(0, 130, 1, -230),
		},
		touchSize = {
			Mobile = square(64),
			Tablet = square(80),
			PC = square(80),
		},
	} :: ActionSpec,
}

local bindings: { [string]: ActionSpec } = {}
local mounted: { [string]: boolean } = {}
local held: { [string]: boolean } = {}

local appliedInput: DeviceProfile.InputMode? = nil
local appliedForm: DeviceProfile.FormFactor? = nil

local function pointerOnActiveGui(): boolean
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui or not playerGui:IsA("PlayerGui") then
		return false
	end
	local location = UserInputService:GetMouseLocation()
	for _, object in playerGui:GetGuiObjectsAtPosition(location.X, location.Y) do
		-- Active is true on buttons and text boxes, false on decorative frames.
		if object.Active and object.Visible then
			return true
		end
	end
	return false
end

local function inputsFor(spec: ActionSpec, mode: DeviceProfile.InputMode): { Enum.KeyCode | Enum.UserInputType }
	-- A touch can also synthesize MouseButton1. Binding both double-fires Spray.
	if mode == "Touch" then
		return {}
	end
	local inputs = table.clone(spec.keyboardMouse)
	for _, key in spec.gamepad do
		table.insert(inputs, key)
	end
	return inputs
end

local function dispatch(spec: ActionSpec, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if
		state == Enum.UserInputState.Begin
		and spec.ignoreGuiClicks
		and input.UserInputType == Enum.UserInputType.MouseButton1
		and pointerOnActiveGui()
	then
		return Enum.ContextActionResult.Pass
	end

	if state == Enum.UserInputState.Begin then
		held[spec.name] = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		held[spec.name] = false
	else
		return Enum.ContextActionResult.Pass
	end

	local result = if spec.callback then spec.callback(state, input) else nil
	if result then
		return result
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function layoutButton(spec: ActionSpec)
	local factor = appliedForm or "Mobile"
	local position = if spec.touchPosition then spec.touchPosition[factor] else nil
	local size = if spec.touchSize then spec.touchSize[factor] else nil

	local function apply(): boolean
		if position then
			ContextActionService:SetPosition(spec.name, position)
		end
		local button = ContextActionService:GetButton(spec.name)
		if button == nil then
			return false
		end
		if size then
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Size = size
		end
		return true
	end

	if not apply() then
		-- GetButton is occasionally nil until the touch control gui mounts.
		task.defer(function()
			if mounted[spec.name] and appliedInput == "Touch" then
				apply()
			end
		end)
	end
end

local function mount(spec: ActionSpec)
	local mode = appliedInput
	if not mode then
		return
	end
	local showTouch = mode == "Touch" and spec.touch == true
	local inputs = inputsFor(spec, mode)
	local priority = spec.priority or DEFAULT_PRIORITY
	ContextActionService:BindActionAtPriority(
		spec.name,
		function(_actionName: string, state: Enum.UserInputState, input: InputObject)
			return dispatch(spec, state, input)
		end,
		showTouch,
		priority,
		table.unpack(inputs)
	)
	mounted[spec.name] = true
	if showTouch then
		ContextActionService:SetTitle(spec.name, spec.title)
		if spec.image ~= nil and spec.image ~= "" then
			ContextActionService:SetImage(spec.name, spec.image)
		end
		layoutButton(spec)
	end
end

local function releaseIfHeld(spec: ActionSpec)
	if not held[spec.name] then
		return
	end
	held[spec.name] = false
	if spec.callback then
		spec.callback(Enum.UserInputState.Cancel, nil)
	end
end

local function unmount(spec: ActionSpec)
	releaseIfHeld(spec)
	if mounted[spec.name] then
		ContextActionService:UnbindAction(spec.name)
		mounted[spec.name] = nil
	end
end

local function remount(spec: ActionSpec)
	unmount(spec)
	mount(spec)
end

local function copySpec(template: ActionSpec): ActionSpec
	local copy = table.clone(template)
	copy.keyboardMouse = table.clone(template.keyboardMouse)
	copy.gamepad = table.clone(template.gamepad)
	if template.touchPosition then
		copy.touchPosition = table.clone(template.touchPosition)
	end
	if template.touchSize then
		copy.touchSize = table.clone(template.touchSize)
	end
	return copy
end

function ActionMap.bind(spec: ActionSpec): () -> ()
	local previous = bindings[spec.name]
	if previous then
		unmount(previous)
	end
	bindings[spec.name] = spec
	if appliedInput then
		mount(spec)
	end
	return function()
		if bindings[spec.name] ~= spec then
			return
		end
		unmount(spec)
		bindings[spec.name] = nil
	end
end

function ActionMap.bindTemplate(name: string, callback: ActionCallback, overrides: { [string]: any }?): () -> ()
	local template = ActionMap.Templates[name]
	if not template then
		error(`Unknown UI action "{name}"`, 2)
	end
	local spec = copySpec(template)
	spec.callback = callback
	if overrides then
		for key, value in overrides do
			(spec :: any)[key] = value
		end
	end
	return ActionMap.bind(spec)
end

function ActionMap.applyProfile(profile: DeviceProfile.Profile)
	local inputChanged = profile.inputMode ~= appliedInput
	local formChanged = profile.formFactor ~= appliedForm
	appliedInput = profile.inputMode
	appliedForm = profile.formFactor
	if inputChanged then
		for _, spec in bindings do
			remount(spec)
		end
	elseif formChanged and appliedInput == "Touch" then
		for _, spec in bindings do
			layoutButton(spec)
		end
	end
end

return ActionMap
