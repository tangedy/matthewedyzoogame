-- Input, aiming, and local spray effects. Sends CleaningIntent at a fixed cadence while
-- spraying; the server decides what actually gets cleaned.
--
-- Desktop: hold left mouse, aim with the pointer. Gamepad: hold R2, aim with the reticle.
-- Touch: hold the SPRAY button, aim with the center-screen reticle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local player = Players.LocalPlayer

local CleaningController = {}

local SPRAY_COLOR = Color3.fromRGB(170, 225, 255)
local RETICLE_IDLE = Color3.fromRGB(255, 255, 255)
local RETICLE_ON_TARGET = Color3.fromRGB(120, 255, 140)

local cleaningIntent = Remotes.event("CleaningIntent")

local jobId: string? = nil
local washing = false
local bayName: string? = nil
local range = ToolConfig[1].Range

local mouseHeld, touchHeld, padHeld = false, false, false
local lastSendAt = 0
local hintActive = false
local hintHighlight: Highlight? = nil

-- Reused effect instances (never created per frame)
local impactPart: Part
local impactAttachment: Attachment
local splash: ParticleEmitter
local beam: Beam
local spraySound: Sound
local fallbackNozzle: Attachment? = nil
local reticle: Frame

local function isTouchUI(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local function getRoot(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getNozzle(root: BasePart): Attachment
	local character = player.Character
	local hose = character and character:FindFirstChild("Hose")
	local nozzle = hose and hose:FindFirstChild("Nozzle")
	if nozzle and nozzle:IsA("Attachment") then
		return nozzle
	end
	if not fallbackNozzle or fallbackNozzle.Parent ~= root then
		local a = Instance.new("Attachment")
		a.Name = "SprayFallbackNozzle"
		a.Position = GameConfig.NozzleOffset
		a.Parent = root
		fallbackNozzle = a
	end
	return fallbackNozzle :: Attachment
end

local function currentAnimal(): Model?
	if not bayName then
		return nil
	end
	local bays = Workspace:FindFirstChild("WashBays")
	local bay = bays and bays:FindFirstChild(bayName)
	local animal = bay and bay:FindFirstChild("Animal")
	if animal and animal:IsA("Model") and animal:GetAttribute("JobId") == jobId then
		return animal
	end
	return nil
end

local function characterExclusions(): { Instance }
	local list: { Instance } = { impactPart }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

local function setHint(active: boolean)
	hintActive = active
	if not active then
		if hintHighlight then
			hintHighlight.Enabled = false
		end
		return
	end
	local animal = currentAnimal()
	local patches = animal and animal:FindFirstChild("DirtPatches")
	if not patches then
		return
	end
	if not hintHighlight or hintHighlight.Parent ~= patches then
		local h = Instance.new("Highlight")
		h.FillColor = Color3.fromRGB(255, 220, 80)
		h.OutlineColor = Color3.fromRGB(255, 255, 255)
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Adornee = patches
		h.Parent = patches -- local child of the server model; dies with it
		hintHighlight = h
	end
	(hintHighlight :: Highlight).Enabled = true
end

local function buildEffects()
	impactPart = Instance.new("Part")
	impactPart.Name = "SprayImpact"
	impactPart.Anchored = true
	impactPart.CanCollide = false
	impactPart.CanQuery = false
	impactPart.CanTouch = false
	impactPart.Transparency = 1
	impactPart.Size = Vector3.new(0.2, 0.2, 0.2)
	impactPart.Parent = Workspace

	impactAttachment = Instance.new("Attachment")
	impactAttachment.Parent = impactPart

	splash = Instance.new("ParticleEmitter")
	splash.Enabled = false
	splash.Rate = 60
	splash.Lifetime = NumberRange.new(0.25, 0.45)
	splash.Speed = NumberRange.new(5, 9)
	splash.SpreadAngle = Vector2.new(70, 70)
	splash.Acceleration = Vector3.new(0, -30, 0)
	splash.Size = NumberSequence.new(0.35, 0.05)
	splash.Transparency = NumberSequence.new(0.1, 1)
	splash.Color = ColorSequence.new(SPRAY_COLOR)
	splash.LightEmission = 0.4
	splash.Parent = impactAttachment

	beam = Instance.new("Beam")
	beam.Enabled = false
	beam.Attachment1 = impactAttachment
	beam.Width0 = 0.25
	beam.Width1 = 0.9
	beam.FaceCamera = true
	beam.Segments = 8
	beam.Color = ColorSequence.new(SPRAY_COLOR)
	beam.Transparency = NumberSequence.new(0.15, 0.55)
	beam.LightEmission = 0.5
	beam.Parent = impactPart

	spraySound = Instance.new("Sound")
	spraySound.Name = "SpraySound"
	spraySound.SoundId = GameConfig.Sounds.Spray
	spraySound.Looped = true
	spraySound.Volume = 0.35
	spraySound.Parent = SoundService
end

local function buildControls()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SprayControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- GUI coordinates == viewport coordinates
	gui.Parent = player:WaitForChild("PlayerGui")

	reticle = Instance.new("Frame")
	reticle.Name = "Reticle"
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(18, 18)
	reticle.BackgroundTransparency = 1
	reticle.Parent = gui
	local ring = Instance.new("UIStroke")
	ring.Thickness = 2.5
	ring.Color = RETICLE_IDLE
	ring.Parent = reticle
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = reticle

	-- Large hold button above the jump button, away from the movement thumbstick.
	local button = Instance.new("TextButton")
	button.Name = "SprayButton"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -30, 1, -225)
	button.Size = UDim2.fromOffset(115, 115)
	button.BackgroundColor3 = Color3.fromRGB(60, 150, 230)
	button.BackgroundTransparency = 0.15
	button.Text = "SPRAY"
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.FredokaOne
	button.TextSize = 26
	button.AutoButtonColor = false
	button.Visible = UserInputService.TouchEnabled
	button.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local function press(down: boolean)
		touchHeld = down
		button.BackgroundTransparency = if down then 0 else 0.15
	end
	button.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			press(true)
		end
	end)
	button.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			press(false)
		end
	end)
end

local function bindInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseHeld = true
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			padHeld = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseHeld = false
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			padHeld = false
		end
	end)
	-- Losing focus mid-hold shouldn't leave the hose stuck on.
	UserInputService.WindowFocusReleased:Connect(function()
		mouseHeld, touchHeld, padHeld = false, false, false
	end)
end

local function stopEffects()
	beam.Enabled = false
	splash.Enabled = false
	if spraySound.IsPlaying then
		spraySound:Stop()
	end
end

local function onHeartbeat()
	local camera = Workspace.CurrentCamera
	local root = getRoot()
	if not camera or not root then
		stopEffects()
		return
	end

	-- Where the player is pointing on screen
	local useCenter = touchHeld
		or padHeld
		or isTouchUI()
		or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	local screenPoint = if useCenter then camera.ViewportSize / 2 else UserInputService:GetMouseLocation()
	reticle.Position = UDim2.fromOffset(screenPoint.X, screenPoint.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = characterExclusions()

	local ray = camera:ViewportPointToRay(screenPoint.X, screenPoint.Y)
	local camHit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	local target = if camHit then camHit.Position else ray.Origin + ray.Direction * 1000

	-- Same nozzle origin and range check the server uses
	local origin = root.Position + GameConfig.NozzleOffset
	local toTarget = target - origin
	if toTarget.Magnitude < 0.01 then
		stopEffects()
		return
	end
	local direction = toTarget.Unit
	local sprayHit = Workspace:Raycast(origin, direction * range, params)
	local impact = if sprayHit then sprayHit.Position else origin + direction * range

	local animal = currentAnimal()
	local onTarget = sprayHit ~= nil and animal ~= nil and sprayHit.Instance:IsDescendantOf(animal)
	local stroke = reticle:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if onTarget then RETICLE_ON_TARGET else RETICLE_IDLE
	end

	if hintActive and hintHighlight then
		hintHighlight.FillTransparency = 0.55 + 0.25 * math.sin(os.clock() * 5)
	end

	if not (mouseHeld or touchHeld or padHeld) then
		stopEffects()
		return
	end

	impactPart.CFrame = CFrame.new(impact)
	beam.Attachment0 = getNozzle(root)
	beam.Enabled = true
	splash.Enabled = sprayHit ~= nil
	if not spraySound.IsPlaying then
		spraySound:Play()
	end

	local now = os.clock()
	if washing and jobId and now - lastSendAt >= 1 / GameConfig.RequestRateHz then
		lastSendAt = now
		cleaningIntent:FireServer(jobId, direction)
	end
end

local function applyBay(bay: Types.BaySnapshot?)
	if not bay then
		return
	end
	bayName = bay.BayName
	if bay.JobId ~= jobId then
		setHint(false)
	end
	jobId = bay.JobId
	washing = bay.State == "Washing"
	if not washing then
		setHint(false)
	end
end

function CleaningController.init(initial: Types.InitialState)
	range = (ToolConfig[initial.ToolTier] or ToolConfig[1]).Range
	buildEffects()
	buildControls()
	bindInput()
	applyBay(initial.Bay)

	Remotes.event("BayStateChanged").OnClientEvent:Connect(applyBay)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(tier: number)
		range = (ToolConfig[tier] or ToolConfig[1]).Range
	end)
	Remotes.event("CleaningProgressChanged").OnClientEvent
		:Connect(function(id: string, _progress: number, showHint: boolean)
			if id == jobId then
				setHint(showHint)
			end
		end)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return CleaningController
