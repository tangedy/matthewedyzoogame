-- The phone WASH button: a round button sitting right above the jump button, a little
-- bigger than jump. A button, not a joystick: nothing on it moves with the thumb. Hold it to spray; let go to stop. The water locks
-- onto the mud (CleaningController picks the patch), so the camera is free while washing:
-- drag the thumb that holds WASH and the view turns just like a swipe on the free screen
-- (past a small dead zone, so a still thumb never jitters it, and eased over a few frames
-- so uneven touch updates never make it stutter). Another finger on the free screen turns
-- it too.
--
-- The touch that starts on a GUI button is sunk, so the default camera never sees it.
-- This module turns the camera itself, right after the camera script runs, by rotating
-- Camera.CFrame around Camera.Focus. The Classic camera reads its look direction from
-- Camera.CFrame each frame, so the turn sticks. CleaningController puts touch players on
-- Classic.
--
-- Sizes here are physical pixels, matched to the engine jump button. The gui is
-- excluded from ResponsiveScale, like TouchGui, so the two stay lined up.
--
--   WashButton.start(onHold)   onHold(true) when the finger lands, onHold(false) on release
--   WashButton.setEnabled(on)  shows it for touch input, hides it otherwise
--   WashButton.setBlocked(on)  hides it while a cutscene owns the camera
--   WashButton.setReady(on)    an animal is waiting to be washed: full colour, glowing ring,
--                              and a HOLD! hint until the first press. Otherwise it fades
--                              so it stays out of the way.
--   WashButton.isHeld()        a finger is holding it

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Feedback = require(script.Parent.Feedback)

local WashButton = {}

local player = Players.LocalPlayer

-- The engine's own jump button layout (TouchJump), used until the real one is found.
local SMALL_SCREEN_SIDE = 500
local GAP = 12 -- between the top of jump and the bottom of WASH
local SIZE_OVER_JUMP = 1.1
local MIN_SIZE = 76

local WATER_TOP = Color3.fromRGB(120, 220, 255)
local WATER_BOTTOM = Color3.fromRGB(30, 120, 230)
local HELD_TOP = Color3.fromRGB(170, 240, 255)
local HELD_BOTTOM = Color3.fromRGB(60, 160, 255)
local RIM = Color3.fromRGB(255, 255, 255)
local IDLE_FADE = 0.45

-- Look speed in radians per pixel of drag, close to a normal camera swipe.
local LOOK_SPEED = Vector2.new(0.014, 0.0095)
local MAX_PITCH = math.rad(80) -- the default camera's limit
local FIRST_PERSON_DISTANCE = 0.6
local DEAD_ZONE = 8 -- px the thumb moves before the camera starts turning
local LOOK_EASE = 30 -- per second: how fast the camera catches up with the thumb

local gui: ScreenGui
local button: ImageButton
local face: Frame
local faceGradient: UIGradient
local pressScale: UIScale
local ring: Frame
local ringStroke: UIStroke
local drop: TextLabel
local label: TextLabel
local rim: UIStroke
local innerStroke: UIStroke
local fade: NumberValue
local hint: TextLabel

local onHold: ((boolean) -> ())? = nil
local enabled = false
local blocked = false
local ready = false
local hintArmed = false
local activeTouch: InputObject? = nil
local startPosition = Vector2.zero
local lastPosition = Vector2.zero
local looking = false -- the thumb has left the dead zone this hold
local pendingLook = Vector2.zero -- thumb drag the camera has not caught up with yet
local jumpConns: { RBXScriptConnection } = {}

local function corner(parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = parent
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "MobileControls"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Under every menu (their dimmers block it while open), over the HUD.
	gui.DisplayOrder = 5
	gui:SetAttribute("UIPlatformExclude", true)
	gui.Enabled = false

	-- The button is transparent: the face, rim and text are children so the press scale
	-- and the ready ring can move separately.
	button = Instance.new("ImageButton")
	button.Name = "Wash"
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.BackgroundTransparency = 1
	button.Image = ""
	button.AutoButtonColor = false
	button.Selectable = false
	button.Parent = gui
	pressScale = Instance.new("UIScale")
	pressScale.Parent = button

	-- Ready ring: breathes around the button while an animal is waiting.
	ring = Instance.new("Frame")
	ring.Name = "ReadyRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(1.12, 1.12)
	ring.BackgroundTransparency = 1
	ring.Parent = button
	corner(ring)
	ringStroke = Instance.new("UIStroke")
	ringStroke.Color = RIM
	ringStroke.Thickness = 3
	ringStroke.Transparency = 1
	ringStroke.Parent = ring

	face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = Color3.new(1, 1, 1)
	face.ZIndex = 2
	face.Parent = button
	corner(face)
	faceGradient = Instance.new("UIGradient")
	faceGradient.Rotation = 90
	faceGradient.Color = ColorSequence.new(WATER_TOP, WATER_BOTTOM)
	faceGradient.Parent = face
	-- Cartoon rim: white inside, black outside, like the rest of the HUD.
	rim = Instance.new("UIStroke")
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Color = Color3.new(0, 0, 0)
	rim.Thickness = 4
	rim.Parent = face
	local inner = Instance.new("Frame")
	inner.Name = "InnerRim"
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.new(1, -8, 1, -8)
	inner.BackgroundTransparency = 1
	inner.ZIndex = 2
	inner.Parent = face
	corner(inner)
	innerStroke = Instance.new("UIStroke")
	innerStroke.Color = RIM
	innerStroke.Thickness = 3
	innerStroke.Transparency = 0.25
	innerStroke.Parent = inner

	drop = Instance.new("TextLabel")
	drop.Name = "Drop"
	drop.AnchorPoint = Vector2.new(0.5, 0.5)
	drop.Position = UDim2.fromScale(0.5, 0.3)
	drop.Size = UDim2.fromScale(0.42, 0.3)
	drop.Text = "💦"
	drop.ZIndex = 3
	drop.Parent = face
	UIStyle.text(drop, nil, nil, 0)

	label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.66)
	label.Size = UDim2.fromScale(0.78, 0.3)
	label.Text = "WASH"
	label.ZIndex = 3
	label.Parent = face
	UIStyle.text(label, nil, nil, 2.5)

	-- "HOLD!" bubble above the button, the first time an animal is waiting.
	hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 0, -6)
	hint.Size = UDim2.fromScale(1.1, 0.34)
	hint.Text = "HOLD!"
	hint.Visible = false
	hint.ZIndex = 5
	hint.Parent = button
	UIStyle.text(hint, Color3.fromRGB(255, 240, 120), nil, 2.5)

	-- One number drives the idle fade of every piece of the face.
	fade = Instance.new("NumberValue")
	fade.Value = IDLE_FADE
	fade.Changed:Connect(function(value)
		face.BackgroundTransparency = value
		rim.Transparency = value
		innerStroke.Transparency = 0.25 + 0.75 * value
		label.TextTransparency = value * 0.6
		drop.TextTransparency = value
	end)
	face.BackgroundTransparency = IDLE_FADE

	gui.Parent = player:WaitForChild("PlayerGui")
end

local function findJump(): (ScreenGui?, Instance?, GuiObject?)
	local touchGui = player.PlayerGui:FindFirstChild("TouchGui")
	if not (touchGui and touchGui:IsA("ScreenGui")) then
		return nil, nil, nil
	end
	local frame = touchGui:FindFirstChild("TouchControlFrame")
	local jump = frame and frame:FindFirstChild("JumpButton")
	if jump and jump:IsA("GuiObject") then
		return touchGui, frame, jump
	end
	return touchGui, frame, nil
end

-- Jump button centre and height in this gui's coordinates, or the engine default
-- (TouchJump's own numbers) if it is not up yet.
local function jumpRect(): (Vector2, number)
	local _, _, jump = findJump()
	if jump and jump.AbsoluteSize.X > 0 then
		return jump.AbsolutePosition + jump.AbsoluteSize / 2, jump.AbsoluteSize.Y
	end
	local screen = gui.AbsoluteSize
	if math.min(screen.X, screen.Y) <= SMALL_SCREEN_SIDE then
		return Vector2.new(screen.X - 95 + 35, screen.Y - 90 + 35), 70
	end
	return Vector2.new(screen.X - 170 + 60, screen.Y - 210 + 60), 120
end

-- Centred over jump, kept on screen when it is bigger than jump.
local function place()
	if not button then
		return
	end
	local center, jumpSize = jumpRect()
	local size = math.max(MIN_SIZE, math.floor(jumpSize * SIZE_OVER_JUMP))
	local x = math.min(center.X, gui.AbsoluteSize.X - size / 2 - 4)
	button.Size = UDim2.fromOffset(size, size)
	button.Position = UDim2.fromOffset(x, center.Y - jumpSize / 2 - GAP)
end

-- Follows the jump button as the engine builds, moves or resizes it. Until a link in
-- TouchGui > TouchControlFrame > JumpButton exists, waits on its parent.
local function watchJump()
	for _, conn in jumpConns do
		conn:Disconnect()
	end
	table.clear(jumpConns)
	local touchGui, frame, jump = findJump()
	if touchGui then
		-- Same inset rules as TouchGui, so both report AbsolutePosition from one origin.
		gui.IgnoreGuiInset = touchGui.IgnoreGuiInset
		gui.ScreenInsets = touchGui.ScreenInsets
	end
	if jump then
		table.insert(jumpConns, jump:GetPropertyChangedSignal("AbsolutePosition"):Connect(place))
		table.insert(jumpConns, jump:GetPropertyChangedSignal("AbsoluteSize"):Connect(place))
	else
		local parent = frame or touchGui
		if parent then
			table.insert(
				jumpConns,
				parent.ChildAdded:Connect(function()
					task.defer(watchJump)
				end)
			)
		end
	end
	place()
end

local function setHeldLook(held: boolean)
	local info = TweenInfo.new(if held then 0.08 else 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	-- Solid while held, even when nothing is waiting to be washed.
	TweenService:Create(fade, info, { Value = if held or ready then 0 else IDLE_FADE }):Play()
	faceGradient.Color = if held
		then ColorSequence.new(HELD_TOP, HELD_BOTTOM)
		else ColorSequence.new(WATER_TOP, WATER_BOTTOM)
	if held then
		ringStroke.Transparency = 1
	end
end

local function release()
	if not activeTouch then
		return
	end
	activeTouch = nil
	TweenService:Create(pressScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
	setHeldLook(false)
	if onHold then
		onHold(false)
	end
end

local function press(input: InputObject)
	if activeTouch or not enabled or blocked then
		return
	end
	activeTouch = input
	startPosition = Vector2.new(input.Position.X, input.Position.Y)
	lastPosition = startPosition
	looking = false
	pendingLook = Vector2.zero
	hintArmed = false
	hint.Visible = false
	TweenService:Create(pressScale, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Scale = 0.92,
	}):Play()
	setHeldLook(true)
	Feedback.play("click")
	if onHold then
		onHold(true)
	end
end

-- After the camera script: turn by this frame's thumb drag around the focus point. The
-- drag is read straight from the held finger's InputObject every frame, so it never
-- depends on move events reaching us for a touch that a button captured.
local function applyLook(dt: number)
	local touch = activeTouch
	if not touch then
		pendingLook = Vector2.zero
		return
	end
	local position = Vector2.new(touch.Position.X, touch.Position.Y)
	if not looking then
		if (position - startPosition).Magnitude < DEAD_ZONE then
			return
		end
		looking = true
	end
	pendingLook += position - lastPosition
	lastPosition = position
	-- Ease toward the thumb: a frame with no touch update still turns a little, so the
	-- view glides instead of stepping.
	local delta = pendingLook * (1 - math.exp(-LOOK_EASE * dt))
	pendingLook -= delta
	if delta.Magnitude < 0.01 then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera or camera.CameraType ~= Enum.CameraType.Custom then
		return
	end
	local look = camera.CFrame.LookVector
	local yaw = math.atan2(-look.X, -look.Z) - delta.X * LOOK_SPEED.X
	local pitch = math.clamp(math.asin(math.clamp(look.Y, -1, 1)) - delta.Y * LOOK_SPEED.Y, -MAX_PITCH, MAX_PITCH)
	local rotation = CFrame.fromOrientation(pitch, yaw, 0)
	local focus = camera.Focus.Position
	local distance = (camera.CFrame.Position - focus).Magnitude
	if distance < FIRST_PERSON_DISTANCE then
		camera.CFrame = CFrame.new(camera.CFrame.Position) * rotation
	else
		camera.CFrame = CFrame.new(focus) * rotation * CFrame.new(0, 0, distance)
	end
end

local function refresh()
	if not gui then
		return
	end
	local show = enabled and not blocked
	gui.Enabled = show
	if not show then
		release()
	end
end

function WashButton.start(callback: (boolean) -> ())
	onHold = callback
	build()

	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and input.UserInputState == Enum.UserInputState.Begin then
			press(input)
		end
	end)
	-- The end is tracked on UserInputService, not the button: the thumb leaves the button
	-- as it drags, and the water keeps going until it lifts.
	UserInputService.InputEnded:Connect(function(input)
		if input == activeTouch then
			release()
		end
	end)
	UserInputService.WindowFocusReleased:Connect(release)
	RunService:BindToRenderStep("WashLook", Enum.RenderPriority.Camera.Value + 1, applyLook)
	-- Backs up InputEnded in case a lift is missed: the finger's own InputObject says when
	-- it is gone.
	RunService.Heartbeat:Connect(function()
		local touch = activeTouch
		if
			touch
			and (touch.UserInputState == Enum.UserInputState.End or touch.UserInputState == Enum.UserInputState.Cancel)
		then
			release()
		end
	end)

	-- Idle life: the droplet bobs; while an animal waits, the ring breathes and the
	-- HOLD! hint bounces.
	RunService.RenderStepped:Connect(function()
		if not gui.Enabled or activeTouch then
			return
		end
		local t = os.clock()
		drop.Position = UDim2.fromScale(0.5, 0.3 + math.sin(t * 2.4) * 0.025)
		drop.Rotation = math.sin(t * 1.7) * 6
		if ready then
			local pulse = (math.sin(t * 4) + 1) / 2
			ringStroke.Transparency = 0.25 + 0.5 * pulse
			ring.Size = UDim2.fromScale(1.12 + 0.12 * pulse, 1.12 + 0.12 * pulse)
		else
			ringStroke.Transparency = 1
		end
		hint.Visible = ready and hintArmed
		if hint.Visible then
			hint.Position = UDim2.new(0.5, 0, 0, -6 - math.abs(math.sin(t * 5)) * 8)
		end
	end)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	player.PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "TouchGui" then
			task.defer(watchJump)
		end
	end)
	watchJump()
	refresh()
end

function WashButton.setEnabled(on: boolean)
	enabled = on
	refresh()
	if on then
		watchJump()
	end
end

function WashButton.setBlocked(on: boolean)
	if blocked == on then
		return
	end
	blocked = on
	refresh()
end

function WashButton.setReady(on: boolean)
	if ready == on or not gui then
		return
	end
	ready = on
	if on then
		hintArmed = true
	end
	local solid = on or activeTouch ~= nil
	TweenService:Create(fade, TweenInfo.new(0.25), { Value = if solid then 0 else IDLE_FADE }):Play()
end

function WashButton.isHeld(): boolean
	return activeTouch ~= nil
end

function WashButton.isEnabled(): boolean
	return enabled and not blocked
end

return WashButton
