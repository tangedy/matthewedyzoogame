-- Tension UI and local effects (server side: src/server/Features/Tension).
--
--   Patience bar  just under the wash card: mood pill, orange-to-red meter, wander-off timer
--                 for Mythic and rarer animals. Flashes and shakes below 20% ("DON'T LET IT
--                 SHAKE!"), turns blue while a Calm Treat is active. Hidden when not washing.
--   Mud splat     brown blotches over the whole screen that drip and fade, when a shake hits you.
--   Fling         the server picks the velocity; this client applies it to its own character
--                 (characters are client-owned physics) with a short ragdoll tumble.
--   Camera shake  for anyone near a shake.
--
-- Nothing here decides anything: patience, shakes and flings all come from the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TensionConfig = require(ReplicatedStorage.Shared.FeatureConfig.TensionConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local TensionController = {}

local ROW_Y = 162 -- just under the HUD's wash card (y 8..158)
local ROW_WIDTH = 380
local ROW_HEIGHT = 28
local MOOD_WIDTH = 104
local TIMER_WIDTH = 104
local GAP = 6
local MAX_FLING_SPEED = 250
local MAX_RAGDOLL_SECONDS = 3
local WANDER_WARN_SECONDS = 15

local MOOD_TEXT: { [string]: string } = { Calm = "CALM", Ticklish = "TICKLISH", Grumpy = "GRUMPY" }
local MOOD_COLOR: { [string]: Color3 } = {
	Calm = Color3.fromRGB(120, 255, 120),
	Ticklish = Color3.fromRGB(255, 140, 220),
	Grumpy = Color3.fromRGB(255, 80, 60),
}
local FULL_COLOR = Color3.fromRGB(255, 175, 40)
local EMPTY_COLOR = Color3.fromRGB(235, 40, 30)
local CALM_COLOR = Color3.fromRGB(110, 210, 255)
local WARN_TEXT_COLOR = Color3.fromRGB(255, 235, 90)

type Snapshot = {
	JobId: string,
	Mood: string,
	Patience: number,
	Calm: number,
	Wander: number?,
	Event: string?,
	Ended: boolean?,
}

local gui: ScreenGui
local row: Frame
local rowScale: UIScale
local moodLabel: TextLabel
local bar: Frame
local barStroke: UIStroke?
local barFill: Frame
local barGradient: UIGradient
local barLabel: TextLabel
local timerPill: Frame
local timerLabel: TextLabel
local popLabel: TextLabel
local popScale: UIScale
local splatGui: ScreenGui

local current: Snapshot? = nil
local calmEndsAt = 0
local wanderEndsAt: number? = nil
local wasLow = false
local rng = Random.new()

local function textLabel(parent: Instance, props: { [string]: any }, color: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	for key, value in props do
		(label :: any)[key] = value
	end
	label.Parent = parent
	UIStyle.text(label, color)
	return label
end

local function pill(parent: Instance, props: { [string]: any }): Frame
	local frame = Instance.new("Frame")
	for key, value in props do
		(frame :: any)[key] = value
	end
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	frame.BackgroundTransparency = 0.15
	frame.Parent = parent
	UIStyle.border(frame, 3)
	return frame
end

local function playLocal(id: string, speed: number, volume: number)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.PlaybackSpeed = speed
	sound.Volume = volume
	sound.Parent = SoundService
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
	task.delay(5, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "Tension"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	row = Instance.new("Frame")
	row.Name = "PatienceRow"
	row.AnchorPoint = Vector2.new(0.5, 0)
	row.Position = UDim2.new(0.5, 0, 0, ROW_Y)
	row.Size = UDim2.fromOffset(ROW_WIDTH, ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.Visible = false
	row.Parent = gui
	rowScale = Instance.new("UIScale")
	rowScale.Parent = row

	local moodPill = pill(row, { Size = UDim2.new(0, MOOD_WIDTH, 1, 0) })
	moodLabel = textLabel(moodPill, { Position = UDim2.fromOffset(6, 2), Size = UDim2.new(1, -12, 1, -4) })

	bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(MOOD_WIDTH + GAP, 0)
	bar.Size = UDim2.new(1, -(MOOD_WIDTH + GAP), 1, 0)
	bar.BackgroundColor3 = Color3.fromRGB(70, 50, 35)
	bar.ClipsDescendants = true
	bar.Parent = row
	UIStyle.border(bar, 3)
	barStroke = bar:FindFirstChildOfClass("UIStroke")
	barFill = Instance.new("Frame")
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.BackgroundColor3 = Color3.new(1, 1, 1)
	barFill.Parent = bar
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 12)
	fillCorner.Parent = barFill
	barGradient = Instance.new("UIGradient")
	barGradient.Rotation = 90
	barGradient.Parent = barFill
	barLabel = textLabel(bar, { Position = UDim2.fromOffset(6, 2), Size = UDim2.new(1, -12, 1, -4), ZIndex = 2 })

	timerPill = pill(row, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, TIMER_WIDTH, 1, 0),
		Visible = false,
	})
	timerLabel = textLabel(timerPill, { Position = UDim2.fromOffset(6, 2), Size = UDim2.new(1, -12, 1, -4) })

	-- Center: "MUD SHAKE!" / "CALMED!" / "IT WANDERED OFF!"
	popLabel = textLabel(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.33),
		Size = UDim2.fromOffset(440, 64),
		Visible = false,
	})
	local popStroke = popLabel:FindFirstChildOfClass("UIStroke")
	if popStroke then
		popStroke.Thickness = 4
	end
	popScale = Instance.new("UIScale")
	popScale.Parent = popLabel

	splatGui = Instance.new("ScreenGui")
	splatGui.Name = "TensionSplat"
	splatGui.ResetOnSpawn = false
	splatGui.IgnoreGuiInset = true
	splatGui.DisplayOrder = 5 -- over the HUD
	splatGui.Parent = gui.Parent
end

local function bounce(scale: UIScale, from: number, seconds: number)
	scale.Scale = from
	TweenService:Create(scale, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

local popToken = 0
local function showPop(text: string, color: Color3)
	popToken += 1
	local token = popToken
	popLabel.Text = text
	popLabel.TextColor3 = color
	popLabel.TextTransparency = 0
	popLabel.Visible = true
	bounce(popScale, 0.3, 0.4)
	task.delay(1.4, function()
		if popToken ~= token then
			return
		end
		local tween = TweenService:Create(popLabel, TweenInfo.new(0.5), { TextTransparency = 1 })
		tween.Completed:Once(function()
			if popToken == token then
				popLabel.Visible = false
			end
		end)
		tween:Play()
	end)
end

local function formatClock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function hide()
	current = nil
	wanderEndsAt = nil
	wasLow = false
	row.Visible = false
	row.Position = UDim2.new(0.5, 0, 0, ROW_Y)
end

local function applySnapshot(snapshot: Snapshot)
	local now = os.clock()
	local isNew = current == nil or (current :: Snapshot).JobId ~= snapshot.JobId
	current = snapshot
	calmEndsAt = now + snapshot.Calm
	wanderEndsAt = if snapshot.Wander then now + snapshot.Wander else nil

	if isNew then
		wasLow = false
		row.Visible = true
		bounce(rowScale, 0.6, 0.45)
		barFill.Size = UDim2.fromScale(snapshot.Patience, 1)
		moodLabel.Text = MOOD_TEXT[snapshot.Mood] or string.upper(snapshot.Mood)
		moodLabel.TextColor3 = MOOD_COLOR[snapshot.Mood] or Color3.new(1, 1, 1)
	end
	local timed = snapshot.Wander ~= nil
	timerPill.Visible = timed
	bar.Size = UDim2.new(1, -(MOOD_WIDTH + GAP + (if timed then TIMER_WIDTH + GAP else 0)), 1, 0)

	-- Glide between server updates so the meter drains smoothly.
	TweenService:Create(barFill, TweenInfo.new(TensionConfig.StateSendInterval, Enum.EasingStyle.Linear), {
		Size = UDim2.fromScale(snapshot.Patience, 1),
	}):Play()

	local calmed = snapshot.Calm > 0
	local low = snapshot.Patience < TensionConfig.LowFraction and not calmed
	local base = if calmed then CALM_COLOR else EMPTY_COLOR:Lerp(FULL_COLOR, snapshot.Patience)
	barGradient.Color = ColorSequence.new(base:Lerp(Color3.new(1, 1, 1), 0.35), base)
	if low and not wasLow then
		playLocal(TensionConfig.Sounds.Warning, 0.7, 0.6)
		bounce(rowScale, 1.25, 0.35)
	end
	wasLow = low
	if not low then
		barLabel.TextColor3 = Color3.new(1, 1, 1)
	end

	local event = snapshot.Event
	if event == "Shake" then
		showPop("MUD SHAKE!", Color3.fromRGB(200, 140, 80))
		bounce(rowScale, 1.3, 0.4)
	elseif event == "Calmed" then
		showPop("CALMED!", CALM_COLOR)
		bounce(rowScale, 1.2, 0.4)
	end
end

local function onState(snapshot: any)
	if typeof(snapshot) ~= "table" or typeof(snapshot.JobId) ~= "string" then
		return
	end
	local valid = typeof(snapshot.Patience) == "number"
		and typeof(snapshot.Calm) == "number"
		and typeof(snapshot.Mood) == "string"
		and (snapshot.Wander == nil or typeof(snapshot.Wander) == "number")
	if not valid then
		return
	end
	if snapshot.Ended then
		if current and (current :: Snapshot).JobId == snapshot.JobId then
			hide()
		end
		if snapshot.Event == "WanderedOff" then
			showPop("IT WANDERED OFF!", Color3.fromRGB(255, 90, 70))
			playLocal(TensionConfig.Sounds.Fling, 0.8, 0.6)
		end
		return
	end
	applySnapshot(snapshot :: Snapshot)
end

-- Text, flashing and jitter, every frame while the bar is up.
local function render()
	local snapshot = current
	if not snapshot then
		return
	end
	local now = os.clock()
	local calmSeconds = calmEndsAt - now
	local flash = (math.sin(now * 14) + 1) / 2
	if calmSeconds > 0 then
		barLabel.Text = `CALMED {math.ceil(calmSeconds)}s`
		barLabel.TextColor3 = Color3.new(1, 1, 1)
	elseif wasLow then
		barLabel.Text = "DON'T LET IT SHAKE!"
		barLabel.TextColor3 = Color3.new(1, 1, 1):Lerp(WARN_TEXT_COLOR, flash)
	else
		barLabel.Text = "PATIENCE"
	end
	if barStroke then
		barStroke.Color = if wasLow
			then Color3.new(0, 0, 0):Lerp(Color3.fromRGB(255, 40, 30), flash)
			else Color3.new(0, 0, 0)
	end
	row.Position = if wasLow
		then UDim2.new(0.5, rng:NextInteger(-3, 3), 0, ROW_Y + rng:NextInteger(-2, 2))
		else UDim2.new(0.5, 0, 0, ROW_Y)

	local endsAt = wanderEndsAt
	if endsAt then
		local left = endsAt - now
		if calmSeconds > 0 then
			-- Frozen while calmed; the server sends the real value when it resumes.
			wanderEndsAt = now + math.max(left, 0)
			left = math.max(left, 0)
		end
		timerLabel.Text = `LEAVES {formatClock(left)}`
		timerLabel.TextColor3 = if left <= WANDER_WARN_SECONDS
			then Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 60, 50), flash)
			else Color3.new(1, 1, 1)
	end
end

-- Brown blotches that pop onto the screen, drip, then fade.
local function splat()
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local short = math.min(viewport.X, viewport.Y)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.Parent = splatGui

	local tint = Instance.new("Frame")
	tint.Size = UDim2.fromScale(1, 1)
	tint.BackgroundColor3 = TensionConfig.MudColors[1]
	tint.BackgroundTransparency = 0.35
	tint.BorderSizePixel = 0
	tint.Parent = holder
	TweenService:Create(tint, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()

	local colors = TensionConfig.MudColors
	local function round(frame: Frame)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = frame
	end
	local function blob(parent: Instance, size: number, position: UDim2, color: Color3): Frame
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = position
		frame.Size = UDim2.fromOffset(size, size * rng:NextNumber(0.8, 1.15))
		frame.BackgroundColor3 = color
		frame.BorderSizePixel = 0
		frame.Rotation = rng:NextNumber(0, 360)
		frame.Parent = parent
		round(frame)
		return frame
	end

	for _ = 1, rng:NextInteger(9, 14) do
		local size = short * rng:NextNumber(0.14, 0.38)
		local color = colors[rng:NextInteger(1, #colors)]
		local main = blob(holder, size, UDim2.fromScale(rng:NextNumber(0.05, 0.95), rng:NextNumber(0.05, 0.9)), color)
		local scale = Instance.new("UIScale")
		scale.Scale = 0
		scale.Parent = main
		for _ = 1, rng:NextInteger(2, 4) do -- smaller flecks around the edge
			local angle = rng:NextNumber(0, math.pi * 2)
			local reach = rng:NextNumber(0.55, 0.8)
			blob(
				main,
				size * rng:NextNumber(0.15, 0.35),
				UDim2.fromScale(0.5 + math.cos(angle) * reach, 0.5 + math.sin(angle) * reach),
				color
			)
		end
		-- The drip runs down the screen, so it lives on the holder, not the rotated blob.
		local drip = Instance.new("Frame")
		drip.AnchorPoint = Vector2.new(0.5, 0)
		drip.Position = main.Position
		drip.Size = UDim2.fromOffset(size * rng:NextNumber(0.12, 0.22), 0)
		drip.BackgroundColor3 = color
		drip.BorderSizePixel = 0
		drip.ZIndex = 0
		drip.Parent = holder
		round(drip)
		local delay = rng:NextNumber(0, 0.12)
		TweenService:Create(
			scale,
			TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, delay),
			{ Scale = 1 }
		):Play()
		TweenService
			:Create(drip, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay + 0.2), {
				Size = UDim2.fromOffset(drip.Size.X.Offset, size * rng:NextNumber(0.7, 1.5)),
			})
			:Play()
	end

	task.delay(1.4, function()
		local fade = TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		for _, item in holder:GetDescendants() do
			if item:IsA("Frame") and item ~= tint then
				TweenService:Create(item, fade, { BackgroundTransparency = 1 }):Play()
			end
		end
		task.delay(1.5, function()
			holder:Destroy()
		end)
	end)
end

-- Camera shake: a decaying jitter applied after the camera scripts each frame.
local SHAKE_BINDING = "TensionCameraShake"
local shakeEndsAt = 0
local shakeSeconds = 1
local shakeIntensity = 0
local shakeBound = false

local function shakeCamera(intensity: number, seconds: number)
	local now = os.clock()
	if now >= shakeEndsAt then
		shakeIntensity = 0
	end
	shakeIntensity = math.max(shakeIntensity, intensity)
	shakeSeconds = math.max(seconds, 0.05)
	shakeEndsAt = now + shakeSeconds
	if shakeBound then
		return
	end
	shakeBound = true
	RunService:BindToRenderStep(SHAKE_BINDING, Enum.RenderPriority.Camera.Value + 1, function()
		local t = os.clock()
		local camera = Workspace.CurrentCamera
		if t >= shakeEndsAt or not camera then
			RunService:UnbindFromRenderStep(SHAKE_BINDING)
			shakeBound = false
			return
		end
		local k = (shakeEndsAt - t) / shakeSeconds * shakeIntensity
		local angle = math.rad(2.5) * k
		camera.CFrame *= CFrame.new(math.noise(t * 30, 3.1) * 0.4 * k, math.noise(t * 30, 7.7) * 0.4 * k, 0) * CFrame.Angles(
			math.noise(t * 25, 1.3) * angle,
			math.noise(t * 25, 5.9) * angle,
			0
		)
	end)
end

-- The server already chose the velocity; this only applies it to our own character.
local flingToken = 0
local function onFling(velocity: any, ragdollSeconds: any, withSplat: any)
	if typeof(velocity) ~= "Vector3" or typeof(ragdollSeconds) ~= "number" then
		return
	end
	local speed = velocity.Magnitude
	if speed ~= speed or speed == math.huge or ragdollSeconds ~= ragdollSeconds then
		return
	end
	if speed > MAX_FLING_SPEED then
		velocity = velocity.Unit * MAX_FLING_SPEED
	end
	local seconds = math.clamp(ragdollSeconds, 0, MAX_RAGDOLL_SECONDS)

	if withSplat == true then
		splat()
		shakeCamera(1.4, 0.8)
	else
		shakeCamera(0.8, 0.4)
	end
	playLocal(TensionConfig.Sounds.Fling, rng:NextNumber(0.95, 1.1), 0.7)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return
	end
	flingToken += 1
	local token = flingToken
	humanoid.PlatformStand = true -- limp tumble while airborne
	root.AssemblyLinearVelocity = velocity
	root.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * 10
	task.delay(seconds, function()
		if flingToken ~= token or not humanoid.Parent or humanoid.Health <= 0 then
			return
		end
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)
end

local function onCameraShake(intensity: any, seconds: any)
	if typeof(intensity) ~= "number" or typeof(seconds) ~= "number" then
		return
	end
	if intensity ~= intensity or seconds ~= seconds then
		return
	end
	shakeCamera(math.clamp(intensity, 0, 2), math.clamp(seconds, 0, 3))
end

function TensionController.init(_initial: Types.InitialState)
	buildGui()
	RunService.RenderStepped:Connect(render)

	-- Wait for the remotes off the startup path, so a missing server feature can't stall
	-- the controllers started after this one.
	task.spawn(function()
		Remotes.event("TensionState").OnClientEvent:Connect(onState)
		Remotes.event("TensionFling").OnClientEvent:Connect(onFling)
		Remotes.event("TensionCameraShake").OnClientEvent:Connect(onCameraShake)
		Remotes.event("BayStateChanged").OnClientEvent:Connect(function(bay: Types.BaySnapshot?)
			local snapshot = current
			if snapshot and (not bay or bay.State ~= "Washing" or bay.JobId ~= snapshot.JobId) then
				hide()
			end
		end)

		local devCommand = Remotes.event("TensionDev")
		UserInputService.InputBegan:Connect(function(input, processed)
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.K then
				devCommand:FireServer("shake")
			elseif input.KeyCode == Enum.KeyCode.L then
				devCommand:FireServer("wander")
			end
		end)
	end)
end

return TensionController
