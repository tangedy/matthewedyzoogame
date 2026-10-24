-- Input, aiming, and local spray effects. Sends CleaningIntent at a fixed cadence while
-- spraying; the server decides what actually gets cleaned.
--
-- Desktop: hold left mouse, aim with the pointer. Gamepad: hold R2, aim with the reticle.
-- Touch: hold the native Spray button (ContextActionService), aim with the center reticle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local WashTool = require(ReplicatedStorage.Shared.WashTool)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIPlatform = require(script.Parent.Parent.UI)

local player = Players.LocalPlayer

local CleaningController = {}

local SPRAY_COLOR = Color3.fromRGB(170, 225, 255)
-- Screen droplets: flat GUI drops that burst from the aim point while spraying.
local DROP_POOL_SIZE = 90
local DROP_RATE_ON_TARGET = 55 -- per second
local DROP_RATE_IDLE = 22
local DROP_GRAVITY = 1100 -- px/s²
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
local foam: ParticleEmitter
local mist: ParticleEmitter
local beam: Beam
local spraySound: Sound
local fallbackNozzle: Attachment? = nil
local reticle: Frame

type Drop = { frame: Frame, pos: Vector2, vel: Vector2, age: number, life: number, size: number }
local dropLayer: Frame
local dropPool: { Frame } = {}
local drops: { Drop } = {}
local dropCarry = 0
local sprayActive = false
local sprayOnTarget = false
local sprayScreenPoint = Vector2.zero
local random = Random.new()

local function getRoot(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getNozzle(root: BasePart): Attachment
	local character = player.Character
	local hose = WashTool.find(character)
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

-- The animal currently being washed, when the hit is part of one. Used so a spray
-- aimed at a neighbor's bay cleans that job instead of only the local one.
local function washingAnimalFrom(inst: Instance?): Model?
	local current = inst
	while current and current ~= Workspace do
		if current:IsA("Model") and current.Name == "Animal" and typeof(current:GetAttribute("JobId")) == "string" then
			return current
		end
		current = current.Parent
	end
	return nil
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

-- Nearest dirty patch to the reticle in screen space, within AimAssistRadius, that the
-- server's own ray from the nozzle would hit (patch itself or the body right next to it).
local function findAssistTarget(
	camera: Camera,
	animal: Model,
	origin: Vector3,
	screenPoint: Vector2,
	params: RaycastParams
): BasePart?
	local patches = animal:FindFirstChild("DirtPatches")
	if not patches then
		return nil
	end
	local viewport = camera.ViewportSize
	local best: BasePart?, bestDist = nil, math.min(viewport.X, viewport.Y) * GameConfig.AimAssistRadius
	for _, patch in patches:GetChildren() do
		if patch:IsA("BasePart") and patch.CanQuery then
			local projected, onScreen = camera:WorldToViewportPoint(patch.Position)
			local d = (Vector2.new(projected.X, projected.Y) - screenPoint).Magnitude
			if onScreen and d < bestDist then
				local toPatch = patch.Position - origin
				if toPatch.Magnitude <= range then
					local hit = Workspace:Raycast(origin, toPatch.Unit * range, params)
					if
						hit
						and hit.Instance:IsDescendantOf(animal)
						and (hit.Position - patch.Position).Magnitude <= GameConfig.SprayRadius
					then
						best, bestDist = patch, d
					end
				end
			end
		end
	end
	return best
end

local HINT_MUD = Color3.fromRGB(92, 64, 40)
local HINT_GLOW = Color3.fromRGB(255, 200, 60)

-- Remaining mud pulses yellow (local-only change; the server never sets patch color later).
-- The Highlight also shows patches through the body so hidden ones are easy to find.
local function pulseHint(animal: Model?)
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 5)
	if hintHighlight then
		hintHighlight.FillTransparency = 0.55 + 0.25 * pulse
	end
	local patches = animal and animal:FindFirstChild("DirtPatches")
	if not patches then
		return
	end
	for _, patch in patches:GetChildren() do
		if patch:IsA("BasePart") then
			local color = HINT_MUD:Lerp(HINT_GLOW, 0.35 + 0.5 * pulse)
			patch.Material = Enum.Material.Neon
			patch.Color = color
			for _, splat in patch:GetChildren() do
				if splat:IsA("BasePart") then
					splat.Material = Enum.Material.Neon
					splat.Color = color
				end
			end
		end
	end
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

	-- Soap bubbles where the spray lands on the animal
	foam = Instance.new("ParticleEmitter")
	foam.Enabled = false
	foam.Rate = 18
	foam.Lifetime = NumberRange.new(0.8, 1.4)
	foam.Speed = NumberRange.new(1, 2.5)
	foam.SpreadAngle = Vector2.new(180, 180)
	foam.Acceleration = Vector3.new(0, 2, 0)
	foam.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.7, 0.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	foam.Transparency = NumberSequence.new(0.2, 0.6)
	foam.Color = ColorSequence.new(Color3.fromRGB(240, 250, 255))
	foam.LightEmission = 0.2
	foam.Parent = impactAttachment

	-- Soft clouds of mist billowing off the animal where the water hits.
	mist = Instance.new("ParticleEmitter")
	mist.Enabled = false
	mist.Rate = 60
	mist.Lifetime = NumberRange.new(0.6, 1.2)
	mist.Speed = NumberRange.new(1.5, 4.5)
	mist.SpreadAngle = Vector2.new(180, 180)
	mist.Acceleration = Vector3.new(0, 1.5, 0)
	mist.Drag = 3
	mist.Rotation = NumberRange.new(0, 360)
	mist.RotSpeed = NumberRange.new(-40, 40)
	mist.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 3.4),
	})
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	mist.Color = ColorSequence.new(Color3.fromRGB(235, 248, 255), SPRAY_COLOR)
	mist.LightEmission = 0.35
	mist.LightInfluence = 0.6
	mist.Parent = impactAttachment

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

local function onSpray(state: Enum.UserInputState, input: InputObject?)
	if state == Enum.UserInputState.Cancel or input == nil then
		mouseHeld, touchHeld, padHeld = false, false, false
		return
	end
	if state ~= Enum.UserInputState.Begin and state ~= Enum.UserInputState.End then
		return
	end
	local down = state == Enum.UserInputState.Begin
	if input.KeyCode == Enum.KeyCode.ButtonR2 then
		padHeld = down
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseHeld = down
	else
		touchHeld = down
	end
end

local function buildReticle()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SprayControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- GUI coordinates == viewport coordinates
	-- The reticle is placed in viewport pixels. ResponsiveScale would move it off the aim point.
	gui:SetAttribute("UIPlatformExclude", true)
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Under the reticle so the drops never hide the aim point.
	dropLayer = Instance.new("Frame")
	dropLayer.Name = "Droplets"
	dropLayer.Size = UDim2.fromScale(1, 1)
	dropLayer.BackgroundTransparency = 1
	dropLayer.Parent = gui
	for _ = 1, DROP_POOL_SIZE do
		local drop = Instance.new("Frame")
		drop.AnchorPoint = Vector2.new(0.5, 0.5)
		drop.BackgroundColor3 = SPRAY_COLOR
		drop.BorderSizePixel = 0
		drop.Visible = false
		drop.Parent = dropLayer
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = drop
		-- A bright top edge so each drop reads as glassy water, not a dot.
		local shine = Instance.new("UIGradient")
		shine.Rotation = 90
		shine.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(120, 200, 255))
		shine.Parent = drop
		table.insert(dropPool, drop)
	end

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
end

local function spawnDrop()
	local frame = table.remove(dropPool)
	if not frame then
		return
	end
	-- Burst outward from the aim point with an upward kick, then fall.
	local angle = random:NextNumber(0, math.pi * 2)
	local speed = random:NextNumber(110, if sprayOnTarget then 340 else 230)
	local vel = Vector2.new(math.cos(angle), math.sin(angle)) * speed - Vector2.new(0, random:NextNumber(60, 200))
	local start = sprayScreenPoint + Vector2.new(math.cos(angle), math.sin(angle)) * random:NextNumber(4, 14)
	table.insert(drops, {
		frame = frame,
		pos = start,
		vel = vel,
		age = 0,
		life = random:NextNumber(0.35, 0.65),
		size = random:NextNumber(6, if sprayOnTarget then 15 else 10),
	})
	frame.Visible = true
end

local function updateDrops(dt: number)
	if sprayActive then
		dropCarry += dt * (if sprayOnTarget then DROP_RATE_ON_TARGET else DROP_RATE_IDLE)
		while dropCarry >= 1 do
			dropCarry -= 1
			spawnDrop()
		end
	else
		dropCarry = 0
	end
	for i = #drops, 1, -1 do
		local drop = drops[i]
		drop.age += dt
		local t = drop.age / drop.life
		if t >= 1 then
			drop.frame.Visible = false
			table.insert(dropPool, drop.frame)
			table.remove(drops, i)
			continue
		end
		drop.vel += Vector2.new(0, DROP_GRAVITY * dt)
		drop.pos += drop.vel * dt
		-- Stretch along the direction of travel, like a falling drop.
		local stretch = 1 + math.min(drop.vel.Magnitude / 500, 1)
		local size = drop.size * (1 - 0.35 * t)
		drop.frame.Position = UDim2.fromOffset(drop.pos.X, drop.pos.Y)
		drop.frame.Size = UDim2.fromOffset(size, size * stretch)
		drop.frame.Rotation = math.deg(math.atan2(drop.vel.Y, drop.vel.X)) - 90
		drop.frame.BackgroundTransparency = 0.15 + 0.85 * t * t
	end
end

local function bindInput()
	-- Native touch button on phones; mouse and R2 everywhere else. No second Spray button.
	UIPlatform.ActionMap.bindTemplate("Spray", onSpray)
	-- Losing focus mid-hold shouldn't leave the hose stuck on. Cancel covers most cases.
	UserInputService.WindowFocusReleased:Connect(function()
		mouseHeld, touchHeld, padHeld = false, false, false
	end)
end

local function stopEffects()
	beam.Enabled = false
	splash.Enabled = false
	foam.Enabled = false
	mist.Enabled = false
	sprayActive = false
	if spraySound.IsPlaying then
		spraySound:Stop()
	end
end

local function onHeartbeat()
	local camera = Workspace.CurrentCamera
	local root = getRoot()
	if not camera or not root or player:GetAttribute("InCutscene") == true then
		stopEffects()
		return
	end

	-- Where the player is pointing on screen. Touch and gamepad aim with a fixed reticle placed
	-- above the character (the camera centers on the character, which would block the view).
	local shiftLock = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	local assisted = touchHeld or padHeld or UIPlatform.get().inputMode ~= "KeyboardMouse"
	local viewport = camera.ViewportSize
	local screenPoint = if assisted
		then Vector2.new(viewport.X / 2, viewport.Y * GameConfig.CenterAimHeight)
		elseif shiftLock then viewport / 2
		else UserInputService:GetMouseLocation()

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = characterExclusions()

	local origin = root.Position + GameConfig.NozzleOffset

	local ray = camera:ViewportPointToRay(screenPoint.X, screenPoint.Y)
	local camHit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	local target = if camHit then camHit.Position else ray.Origin + ray.Direction * 1000
	local aimed = if camHit then washingAnimalFrom(camHit.Instance) else nil
	local animal = aimed or currentAnimal()
	local aimJob = if aimed then aimed:GetAttribute("JobId") :: string else nil
	local helping = typeof(aimJob) == "string" and aimJob ~= jobId

	-- Aim assist (touch/gamepad only): if the reticle isn't on an animal, snap to the nearest
	-- dirty patch on screen that the hose can actually reach, including a neighbor's wash.
	local assistUsed = false
	if assisted and not aimed then
		local bays = Workspace:FindFirstChild("WashBays")
		local bestPart: BasePart? = nil
		local bestModel: Model? = nil
		local bestDist = math.huge
		if bays then
			for _, bay in bays:GetChildren() do
				local model = bay:FindFirstChild("Animal")
				if model and model:IsA("Model") and typeof(model:GetAttribute("JobId")) == "string" then
					local assist = findAssistTarget(camera, model, origin, screenPoint, params)
					if assist then
						local projected = camera:WorldToViewportPoint(assist.Position)
						local distance = (Vector2.new(projected.X, projected.Y) - screenPoint).Magnitude
						if distance < bestDist then
							bestPart = assist
							bestModel = model
							bestDist = distance
						end
					end
				end
			end
		end
		if bestPart and bestModel then
			assistUsed = true
			animal = bestModel
			aimJob = bestModel:GetAttribute("JobId") :: string
			helping = aimJob ~= jobId
			target = bestPart.Position
			local projected = camera:WorldToViewportPoint(bestPart.Position)
			screenPoint = Vector2.new(projected.X, projected.Y)
		end
	end
	reticle.Position = UDim2.fromOffset(screenPoint.X, screenPoint.Y)

	-- Same nozzle origin and range check the server uses
	local toTarget = target - origin
	if toTarget.Magnitude < 0.01 then
		stopEffects()
		return
	end
	local direction = toTarget.Unit
	-- The spray lands wherever the cursor is on the animal, whichever side the player stands
	-- on, as long as the hose can reach it. The server checks the same camera ray.
	local aimOrigin = ray.Origin
	local aimVector = target - aimOrigin
	local aimDirection = if aimVector.Magnitude > 0.01 then aimVector.Unit else ray.Direction
	local cursorOnAnimal = animal ~= nil and (assistUsed or (camHit ~= nil and camHit.Instance:IsDescendantOf(animal)))
	local inReach = toTarget.Magnitude <= range + GameConfig.AimReachSlack
	local sprayHit = Workspace:Raycast(origin, direction * range, params)
	local impact = if sprayHit then sprayHit.Position else origin + direction * range
	local onTarget = sprayHit ~= nil and animal ~= nil and sprayHit.Instance:IsDescendantOf(animal)
	if cursorOnAnimal and inReach then
		impact = target
		onTarget = true
	end
	local stroke = reticle:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if onTarget then RETICLE_ON_TARGET else RETICLE_IDLE
	end

	if hintActive then
		pulseHint(animal)
	end

	if not (mouseHeld or touchHeld or padHeld) then
		stopEffects()
		return
	end
	-- The hose isn't strong enough for this rarity. The prompt offers Let Go / Clean Now.
	-- Helping on someone else's animal is not blocked by the local bay's gate.
	if player:GetAttribute("CleanBlocked") == true and not helping then
		stopEffects()
		return
	end

	impactPart.CFrame = CFrame.new(impact)
	beam.Attachment0 = getNozzle(root)
	beam.Enabled = true
	splash.Enabled = sprayHit ~= nil or onTarget
	foam.Enabled = onTarget
	mist.Enabled = onTarget
	splash.Rate = if onTarget then 110 else 60
	sprayActive = true
	sprayOnTarget = onTarget
	sprayScreenPoint = screenPoint
	if not spraySound.IsPlaying then
		spraySound:Play()
	end

	local now = os.clock()
	local sendId = if helping then aimJob else jobId
	local maySend = if helping then true else washing
	if maySend and typeof(sendId) == "string" and now - lastSendAt >= 1 / GameConfig.RequestRateHz then
		lastSendAt = now
		cleaningIntent:FireServer(sendId, aimDirection, aimOrigin)
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

-- Range drives aiming; higher tiers also get a visibly thicker spray.
local function applyTier(tier: number)
	local tool = ToolConfig[tier] or ToolConfig[1]
	range = tool.Range
	if beam then
		beam.Width1 = 0.9 + 0.35 * (tool.Tier - 1)
		beam.Width0 = 0.25 + 0.1 * (tool.Tier - 1)
	end
end

function CleaningController.init(initial: Types.InitialState)
	buildEffects()
	applyTier(initial.ToolTier)
	buildReticle()
	bindInput()
	applyBay(initial.Bay)

	Remotes.event("BayStateChanged").OnClientEvent:Connect(applyBay)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(applyTier)
	Remotes.event("CleaningProgressChanged").OnClientEvent
		:Connect(function(id: string, _progress: number, showHint: boolean)
			if id == jobId then
				setHint(showHint)
			end
		end)
	RunService.Heartbeat:Connect(onHeartbeat)
	RunService.RenderStepped:Connect(updateDrops)
end

return CleaningController
