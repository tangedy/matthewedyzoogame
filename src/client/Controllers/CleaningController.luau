-- Input, aiming, and local spray effects. Sends CleaningIntent at a fixed cadence while
-- spraying; the server decides what actually gets cleaned.
--
-- Desktop: hold left mouse, aim with the pointer. Gamepad: hold R2, aim with the reticle.
-- Touch, two ways:
--   * Hold the WASH button above jump (UI/WashButton). The water locks onto the mud, and
--     another finger on the free screen turns the camera as usual.
--   * Scrub: put a finger on the free screen over an animal being washed and rub it, like a
--     car wash game. The camera stays locked while that finger is down and the water goes
--     wherever the finger is. A drag that starts off an animal turns the camera as usual.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local WashTool = require(ReplicatedStorage.Shared.WashTool)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local GearLadder = require(ReplicatedStorage.Shared.GearLadder)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIPlatform = require(script.Parent.Parent.UI)
local WashButton = require(script.Parent.Parent.UI.WashButton)

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

-- How each tier feels to wash with. The sponge and brush are hand tools: no jet, just suds
-- (and bristle flecks) where they scrub, with squelch / scratch sounds. The hoses get
-- stronger from there: a limp, dribbling garden hose, a tight hissing power washer, a wide
-- foam jet, and a thick roaring fire hose that shakes the camera.
type SoundLayer = { Id: string, Speed: number, Volume: number }
type Feel = {
	Beam: boolean,
	Width0: number,
	Width1: number,
	Transparency: number, -- beam transparency at the nozzle
	Color: Color3,
	Splash: number, -- splash speed multiplier
	SplashRate: number,
	Mist: number, -- mist rate while on target
	Foam: number, -- foam rate while on target
	Drops: number, -- screen droplet multiplier
	Dribble: boolean, -- water falling straight off the nozzle
	Bristles: boolean,
	Shake: number, -- camera shake in degrees while spraying
	Loops: { SoundLayer },
	Tick: (SoundLayer & { Every: number })?,
}

local SOUND = "rbxasset://sounds/"
local SHAKE_SECONDS = 0.35
local FEEL: { [number]: Feel } = {
	{
		Beam = false,
		Width0 = 0,
		Width1 = 0,
		Transparency = 1,
		Color = Color3.fromRGB(240, 250, 255),
		Splash = 0.35,
		SplashRate = 25,
		Mist = 0,
		Foam = 40,
		Drops = 0.25,
		Dribble = false,
		Bristles = false,
		Shake = 0,
		Loops = { { Id = SOUND .. "action_swim.mp3", Speed = 1.25, Volume = 0.12 } },
		Tick = { Id = SOUND .. "splat.wav", Speed = 1.4, Volume = 0.25, Every = 0.32 },
	},
	{
		Beam = false,
		Width0 = 0,
		Width1 = 0,
		Transparency = 1,
		Color = Color3.fromRGB(240, 250, 255),
		Splash = 0.45,
		SplashRate = 35,
		Mist = 0,
		Foam = 30,
		Drops = 0.35,
		Dribble = false,
		Bristles = true,
		Shake = 0,
		Loops = { { Id = SOUND .. "action_footsteps_plastic.mp3", Speed = 1.9, Volume = 0.4 } },
		Tick = { Id = SOUND .. "grass.mp3", Speed = 1.5, Volume = 0.18, Every = 0.22 },
	},
	{
		Beam = true,
		Width0 = 0.18,
		Width1 = 0.45,
		Transparency = 0.35,
		Color = Color3.fromRGB(170, 225, 255),
		Splash = 0.6,
		SplashRate = 45,
		Mist = 20,
		Foam = 10,
		Drops = 0.6,
		Dribble = true,
		Bristles = false,
		Shake = 0,
		Loops = { { Id = SOUND .. "impact_water.mp3", Speed = 0.8, Volume = 0.22 } },
	},
	{
		Beam = true,
		Width0 = 0.22,
		Width1 = 0.7,
		Transparency = 0.05,
		Color = Color3.fromRGB(200, 240, 255),
		Splash = 1.3,
		SplashRate = 120,
		Mist = 70,
		Foam = 14,
		Drops = 1,
		Dribble = false,
		Bristles = false,
		Shake = 0.15,
		Loops = {
			{ Id = SOUND .. "impact_water.mp3", Speed = 1.25, Volume = 0.3 },
			{ Id = SOUND .. "Rocket whoosh 01.wav", Speed = 1.6, Volume = 0.18 },
		},
	},
	{
		Beam = true,
		Width0 = 0.5,
		Width1 = 2.2,
		Transparency = 0.1,
		Color = Color3.fromRGB(255, 225, 245),
		Splash = 1.1,
		SplashRate = 90,
		Mist = 60,
		Foam = 70,
		Drops = 1.2,
		Dribble = false,
		Bristles = false,
		Shake = 0.2,
		Loops = {
			{ Id = SOUND .. "action_swim.mp3", Speed = 0.85, Volume = 0.35 },
			{ Id = SOUND .. "Rocket whoosh 01.wav", Speed = 1.0, Volume = 0.22 },
		},
	},
	{
		Beam = true,
		Width0 = 0.75,
		Width1 = 2.6,
		Transparency = 0,
		Color = Color3.fromRGB(185, 230, 255),
		Splash = 1.8,
		SplashRate = 180,
		Mist = 130,
		Foam = 20,
		Drops = 1.6,
		Dribble = false,
		Bristles = false,
		Shake = 0.45,
		Loops = {
			{ Id = SOUND .. "impact_water.mp3", Speed = 0.6, Volume = 0.5 },
			{ Id = SOUND .. "action_falling.mp3", Speed = 0.7, Volume = 0.45 },
		},
	},
}

local cleaningIntent = Remotes.event("CleaningIntent")

local jobId: string? = nil
local washing = false
local bayName: string? = nil
local range = GearLadder.get(1).Range

local mouseHeld, touchHeld, padHeld = false, false, false
-- The finger scrubbing an animal on the free screen, and the camera turn held while it is down.
local scrubTouch: InputObject? = nil
local scrubRotation = CFrame.identity
local FIRST_PERSON_DISTANCE = 0.6
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
local loopSounds: { Sound } = {}
local tickSound: Sound
local nextTickAt = 0
local feel: Feel = FEEL[1]
local dribble: ParticleEmitter
local bristles: ParticleEmitter
local dribbleAttachment: Attachment?
local fallbackNozzle: Attachment? = nil
local reticle: Frame

type Drop = { frame: Frame, pos: Vector2, vel: Vector2, age: number, life: number, size: number }
local dropLayer: Frame
local dropPool: { Frame } = {}
local drops: { Drop } = {}
local dropCarry = 0
local sprayActive = false
local sprayStartedAt = 0 -- os.clock() when the current spray began
local sprayOnTarget = false
local sprayScreenPoint = Vector2.zero
local random = Random.new()
-- Reused every frame; only the exclusion list changes.
local sprayParams = RaycastParams.new()
sprayParams.FilterType = Enum.RaycastFilterType.Exclude

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

local function ownedBay(): Instance?
	local bays = Workspace:FindFirstChild("WashBays")
	if bayName and bays then
		local named = bays:FindFirstChild(bayName)
		if named then
			return named
		end
	end
	if not bays then
		return nil
	end
	for _, bay in bays:GetChildren() do
		if bay:GetAttribute("OwnerUserId") == player.UserId then
			bayName = bay.Name
			return bay
		end
	end
	return nil
end

local function currentAnimal(): Model?
	local bay = ownedBay()
	local animal = bay and bay:FindFirstChild("Animal")
	if not (animal and animal:IsA("Model")) then
		return nil
	end
	local id = animal:GetAttribute("JobId")
	if typeof(id) ~= "string" then
		return nil
	end
	-- Named Animal only while a wash is active. Trust that over a snapshot that has
	-- not arrived yet, or the hose stays quiet in the player's hand.
	jobId = id
	washing = true
	return animal
end

-- The opening shot locks the hose. Once its gui is gone, a late server attribute must
-- not keep the spray off: the server drops the lock when the timer is up.
local function cutsceneLocked(): boolean
	if player:GetAttribute("InCutscene") ~= true then
		return false
	end
	local gui = player:FindFirstChild("PlayerGui")
	return gui ~= nil and gui:FindFirstChild("SpawnCutscene") ~= nil
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

-- Nearest dirty patch to the reticle in screen space, within `radius`, that the server would
-- accept: the camera can see it (the server checks the camera ray, not one from the nozzle,
-- so the top and back of a tall animal count) and it is within the hose's reach of the player.
local function findAssistTarget(
	camera: Camera,
	animal: Model,
	rootPosition: Vector3,
	screenPoint: Vector2,
	params: RaycastParams,
	radius: number
): BasePart?
	local patches = animal:FindFirstChild("DirtPatches")
	if not patches then
		return nil
	end
	local viewport = camera.ViewportSize
	local best: BasePart?, bestDist = nil, math.min(viewport.X, viewport.Y) * radius
	for _, patch in patches:GetChildren() do
		if patch:IsA("BasePart") and patch.CanQuery then
			local projected, onScreen = camera:WorldToViewportPoint(patch.Position)
			local d = (Vector2.new(projected.X, projected.Y) - screenPoint).Magnitude
			if onScreen and d < bestDist then
				local eye = camera.CFrame.Position
				local toPatch = patch.Position - eye
				local facing = patch.CFrame.RightVector:Dot(-toPatch.Unit) > GameConfig.PatchFacingDot
				if facing and (patch.Position - rootPosition).Magnitude <= range + GameConfig.AimReachSlack then
					local hit = Workspace:Raycast(eye, toPatch.Unit * (toPatch.Magnitude + 2), params)
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

-- WASH on touch: the hose holds onto one patch until it is clean, then moves to the next.
-- It aims from the camera, the same check the server runs for the mouse: any mud the
-- player can see and the hose can reach counts, the top and back of a tall animal too.
-- Turning the camera never moves the stream while the patch stays in view. A new patch is
-- the one nearest the reticle; own animal first, a neighbour's wash only when nothing of
-- ours is in reach.
local lockedPatch: BasePart? = nil
local lockedWorld: Vector3? = nil -- where the reticle follows on screen, every frame
local NEIGHBOUR_PENALTY = 100000

local function patchReachable(
	patch: BasePart,
	model: Model,
	eye: Vector3,
	rootPosition: Vector3,
	params: RaycastParams
): boolean
	if patch.Parent == nil or not patch.CanQuery or not patch:IsDescendantOf(model) then
		return false
	end
	-- The server allows Range + AimReachSlack from the player; keep half the slack spare.
	if (patch.Position - rootPosition).Magnitude > range + GameConfig.AimReachSlack * 0.5 then
		return false
	end
	local toPatch = patch.Position - eye
	if toPatch.Magnitude < 0.01 then
		return false
	end
	-- The server only washes a patch facing the spray; the far side of a small animal can sit
	-- within SprayRadius of the hit and still never take water.
	if patch.CFrame.RightVector:Dot(-toPatch.Unit) <= GameConfig.PatchFacingDot then
		return false
	end
	local hit = Workspace:Raycast(eye, toPatch.Unit * (toPatch.Magnitude + 2), params)
	return hit ~= nil
		and hit.Instance:IsDescendantOf(model)
		and (hit.Position - patch.Position).Magnitude <= GameConfig.SprayRadius
end

local function lockOnPatch(
	camera: Camera,
	rootPosition: Vector3,
	screenPoint: Vector2,
	params: RaycastParams
): (BasePart?, Model?)
	local eye = camera.CFrame.Position
	local held = lockedPatch
	if held then
		local model = washingAnimalFrom(held)
		if model and patchReachable(held, model, eye, rootPosition, params) then
			return held, model
		end
		lockedPatch = nil
	end
	local bays = Workspace:FindFirstChild("WashBays")
	if not bays then
		return nil, nil
	end
	local viewport = camera.ViewportSize
	local offScreen = viewport.Magnitude
	local bestPart: BasePart?, bestModel: Model?, bestScore = nil, nil, math.huge
	for _, bay in bays:GetChildren() do
		local model = bay:FindFirstChild("Animal")
		local patches = model and model:FindFirstChild("DirtPatches")
		if model and model:IsA("Model") and patches and typeof(model:GetAttribute("JobId")) == "string" then
			local penalty = if model:GetAttribute("JobId") == jobId then 0 else NEIGHBOUR_PENALTY
			for _, patch in patches:GetChildren() do
				if patch:IsA("BasePart") then
					local projected, onScreen = camera:WorldToViewportPoint(patch.Position)
					local score = if onScreen
						then (Vector2.new(projected.X, projected.Y) - screenPoint).Magnitude
						else offScreen + (patch.Position - rootPosition).Magnitude
					score += penalty
					if score < bestScore and patchReachable(patch, model, eye, rootPosition, params) then
						bestPart, bestModel, bestScore = patch, model, score
					end
				end
			end
		end
	end
	lockedPatch = bestPart
	return bestPart, bestModel
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
	table.insert(loopSounds, spraySound)
	local second = spraySound:Clone()
	second.Name = "SprayLayer"
	second.Parent = SoundService
	table.insert(loopSounds, second)
	tickSound = Instance.new("Sound")
	tickSound.Name = "ScrubTick"
	tickSound.Parent = SoundService

	-- Brush tier: little bristle and grime flecks thrown off where it scrubs.
	bristles = Instance.new("ParticleEmitter")
	bristles.Enabled = false
	bristles.Rate = 30
	bristles.Lifetime = NumberRange.new(0.3, 0.6)
	bristles.Speed = NumberRange.new(3, 6)
	bristles.SpreadAngle = Vector2.new(80, 80)
	bristles.Acceleration = Vector3.new(0, -25, 0)
	bristles.Size = NumberSequence.new(0.18, 0.05)
	bristles.Color = ColorSequence.new(Color3.fromRGB(150, 110, 70), Color3.fromRGB(245, 240, 225))
	bristles.Parent = impactAttachment

	-- Garden hose tier: water that just drips off the nozzle, so the hose feels weak.
	dribble = Instance.new("ParticleEmitter")
	dribble.Enabled = false
	dribble.Rate = 24
	dribble.Lifetime = NumberRange.new(0.4, 0.6)
	dribble.Speed = NumberRange.new(0.5, 1.5)
	dribble.SpreadAngle = Vector2.new(15, 15)
	dribble.Acceleration = Vector3.new(0, -40, 0)
	dribble.Size = NumberSequence.new(0.16, 0.08)
	dribble.Transparency = NumberSequence.new(0.2, 0.8)
	dribble.Color = ColorSequence.new(SPRAY_COLOR)
end

-- Sounds and look for this tier's spray. The beam itself is set in applyTier.
local function setSprayAudio(playing: boolean)
	for index, sound in loopSounds do
		local layer = feel.Loops[index]
		if playing and layer then
			if sound.SoundId ~= layer.Id then
				sound:Stop()
				sound.SoundId = layer.Id
			end
			sound.PlaybackSpeed = layer.Speed
			sound.Volume = layer.Volume
			if not sound.IsPlaying then
				sound:Play()
			end
		elseif sound.IsPlaying then
			sound:Stop()
		end
	end
	local tick = feel.Tick
	if playing and tick and os.clock() >= nextTickAt then
		nextTickAt = os.clock() + tick.Every * (0.8 + random:NextNumber() * 0.4)
		tickSound.SoundId = tick.Id
		tickSound.PlaybackSpeed = tick.Speed * (0.9 + random:NextNumber() * 0.2)
		tickSound.Volume = tick.Volume
		tickSound:Play()
	end
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
		dropCarry += dt * (if sprayOnTarget then DROP_RATE_ON_TARGET else DROP_RATE_IDLE) * feel.Drops
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

-- A finger landing here belongs to a button or the move stick, not the free screen.
local function overControl(position: Vector3): boolean
	local playerGui = player:FindFirstChild("PlayerGui") :: PlayerGui?
	if not playerGui then
		return false
	end
	for _, object in playerGui:GetGuiObjectsAtPosition(position.X, position.Y) do
		if object.Visible and (object:IsA("GuiButton") or string.find(object.Name, "Thumbstick") ~= nil) then
			return true
		end
	end
	return false
end

local function endScrub()
	scrubTouch = nil
end

-- A free-screen finger that lands on an animal being washed scrubs it instead of turning
-- the camera. Not while WASH is held: then every free finger looks around.
local function tryScrub(input: InputObject, processed: boolean)
	if processed or scrubTouch or touchHeld or not WashButton.isEnabled() or cutsceneLocked() then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Touch or overControl(input.Position) then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera or camera.CameraType ~= Enum.CameraType.Custom then
		return
	end
	local ray = camera:ScreenPointToRay(input.Position.X, input.Position.Y)
	sprayParams.FilterDescendantsInstances = characterExclusions()
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, sprayParams)
	if hit and washingAnimalFrom(hit.Instance) then
		scrubTouch = input
		scrubRotation = camera.CFrame.Rotation
	end
end

-- Runs right after the camera script and puts back the turn it had when the scrub began,
-- so the scrubbing finger never moves the view. Zoom and walking still work: the camera
-- keeps its current distance and follows the character's focus. The Classic camera reads
-- its look direction from Camera.CFrame each frame, so the hold sticks.
local function holdScrubLook()
	local touch = scrubTouch
	if not touch then
		return
	end
	if touch.UserInputState == Enum.UserInputState.End or touch.UserInputState == Enum.UserInputState.Cancel then
		endScrub()
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera or camera.CameraType ~= Enum.CameraType.Custom then
		return
	end
	local focus = camera.Focus.Position
	local distance = (camera.CFrame.Position - focus).Magnitude
	if distance < FIRST_PERSON_DISTANCE then
		camera.CFrame = CFrame.new(camera.CFrame.Position) * scrubRotation
	else
		camera.CFrame = CFrame.new(focus) * scrubRotation * CFrame.new(0, 0, distance)
	end
end

local function bindInput()
	-- Mouse and R2 through the action map. Touch gets the WASH button instead of the
	-- engine's action button, because a held engine button cannot steer the camera.
	UIPlatform.ActionMap.bindTemplate("Spray", onSpray)
	WashButton.start(function(down)
		touchHeld = down
		-- WASH takes over the aim; the scrubbing finger goes back to being a free finger.
		if down then
			endScrub()
		end
	end)
	UserInputService.InputBegan:Connect(tryScrub)
	UserInputService.InputEnded:Connect(function(input)
		if input == scrubTouch then
			endScrub()
		end
	end)
	RunService:BindToRenderStep("ScrubLook", Enum.RenderPriority.Camera.Value + 1, holdScrubLook)
	local appliedTouch: boolean? = nil
	local function applyMode(touch: boolean)
		if touch == appliedTouch then
			return
		end
		appliedTouch = touch
		WashButton.setEnabled(touch)
		-- The touch camera is set to Classic by the server (ServerBootstrap); clients can't set it.
		if not touch then
			endScrub()
		end
		reticle.Size = if touch then UDim2.fromOffset(26, 26) else UDim2.fromOffset(18, 18)
		-- The hose re-equips itself, so its hotbar slot only covers the screen on a phone.
		task.spawn(function()
			for _ = 1, 10 do
				if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, not touch) then
					return
				end
				task.wait(1)
			end
		end)
	end
	-- Any touch screen gets WASH, whatever input the device prefers: plenty of tablets (and
	-- any with a keyboard case) report keyboard and mouse, and a finger never sends the
	-- mouse click that mode listens for, so without the button they could not spray at all.
	local function wantsWash(profile: UIPlatform.Profile): boolean
		return profile.inputMode == "Touch" or UserInputService.TouchEnabled
	end
	applyMode(wantsWash(UIPlatform.get()))
	UIPlatform.onChanged(function(profile)
		applyMode(wantsWash(profile))
	end)
	-- Losing focus mid-hold shouldn't leave the hose stuck on. Cancel covers most cases.
	UserInputService.WindowFocusReleased:Connect(function()
		mouseHeld, touchHeld, padHeld = false, false, false
		endScrub()
	end)
end

-- Spraying an animal the hose is too weak for: a game-show "eh-ehhh". A short blip, then a
-- longer, lower one, cut from one buzzer sample. Repeats at most every BUZZ_GAP while held.
local BUZZ_GAP = 1.4
local lastBuzz = 0

local function buzzClip(length: number, pitch: number)
	local s = Instance.new("Sound")
	s.SoundId = GameConfig.Sounds.Buzzer
	s.Volume = 0.35
	s.PlaybackSpeed = pitch
	s.PlaybackRegionsEnabled = true
	s.PlaybackRegion = NumberRange.new(0, length)
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
	task.delay(2, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function buzz()
	local now = os.clock()
	if now - lastBuzz < BUZZ_GAP then
		return
	end
	lastBuzz = now
	buzzClip(0.14, 1)
	task.delay(0.2, buzzClip, 0.5, 0.9)
end

local function stopEffects()
	beam.Enabled = false
	splash.Enabled = false
	bristles.Enabled = false
	dribble.Enabled = false
	setSprayAudio(false)
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
	local locked = cutsceneLocked()
	WashButton.setBlocked(locked)
	WashButton.setReady(washing and jobId ~= nil and player:GetAttribute("CleanBlocked") ~= true)
	if not camera or not root or locked then
		endScrub()
		stopEffects()
		return
	end

	-- Where the player is pointing on screen. Touch and gamepad aim with a fixed reticle placed
	-- above the character (the camera centers on the character, which would block the view).
	local shiftLock = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	local assisted = touchHeld or padHeld or UIPlatform.get().inputMode ~= "KeyboardMouse"
	local viewport = camera.ViewportSize
	local scrub = scrubTouch
	-- Touch positions leave out the top bar; the reticle and the ray use the whole viewport.
	local screenPoint = if scrub
		then Vector2.new(scrub.Position.X, scrub.Position.Y) + GuiService:GetGuiInset()
		elseif assisted then Vector2.new(viewport.X / 2, viewport.Y * GameConfig.CenterAimHeight)
		elseif shiftLock then viewport / 2
		else UserInputService:GetMouseLocation()

	local params = sprayParams
	params.FilterDescendantsInstances = characterExclusions()

	local origin = root.Position + GameConfig.NozzleOffset

	local ray = camera:ViewportPointToRay(screenPoint.X, screenPoint.Y)
	local camHit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	local target = if camHit then camHit.Position else ray.Origin + ray.Direction * 1000
	local aimed = if camHit then washingAnimalFrom(camHit.Instance) else nil
	local animal = aimed or currentAnimal()
	local aimJob = if aimed then aimed:GetAttribute("JobId") :: string else nil
	local helping = typeof(aimJob) == "string" and aimJob ~= jobId

	-- Aim assist (touch/gamepad only): the reticle is free aim. Only when it sits just off an
	-- animal does it nudge onto the nearest dirty patch the hose can reach (a neighbor's wash
	-- too), so the player can still pick the top or the back by pointing at it.
	local assistRadius = if touchHeld then GameConfig.TouchAimAssistRadius else GameConfig.AimAssistRadius
	local assistUsed = false
	if touchHeld then
		-- The water holds onto the mud; the camera is free to look around.
		local patch, model = lockOnPatch(camera, root.Position, screenPoint, params)
		if patch and model then
			assistUsed = true
			animal = model
			aimJob = model:GetAttribute("JobId") :: string
			helping = aimJob ~= jobId
			target = patch.Position
		else
			-- No mud in reach: spray ahead of the character, still not where the camera looks.
			local ahead = root.CFrame.LookVector * Vector3.new(1, 0, 1)
			local forward = if ahead.Magnitude > 0.01 then ahead.Unit else Vector3.new(0, 0, -1)
			target = origin + (forward - Vector3.new(0, 0.3, 0)).Unit * range
			animal = currentAnimal()
			aimJob = nil
			helping = false
		end
		lockedWorld = target
		local projected, onScreen = camera:WorldToViewportPoint(target)
		screenPoint = Vector2.new(projected.X, projected.Y)
		reticle.Visible = onScreen and projected.Z > 0
	else
		lockedPatch = nil
		lockedWorld = nil
		reticle.Visible = true
	end
	if assisted and not aimed and not touchHeld then
		local bays = Workspace:FindFirstChild("WashBays")
		local bestPart: BasePart? = nil
		local bestModel: Model? = nil
		local bestDist = math.huge
		if bays then
			for _, bay in bays:GetChildren() do
				local model = bay:FindFirstChild("Animal")
				if model and model:IsA("Model") and typeof(model:GetAttribute("JobId")) == "string" then
					local assist = findAssistTarget(camera, model, root.Position, screenPoint, params, assistRadius)
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
	-- WASH on touch aims from the camera at the locked patch. With no mud in reach it sprays
	-- ahead of the character from the nozzle (no aimOrigin).
	local aimOrigin: Vector3? = if touchHeld then (if lockedPatch then camera.CFrame.Position else nil) else ray.Origin
	local aimVector = target - (aimOrigin or origin)
	local aimDirection = if aimVector.Magnitude > 0.01 then aimVector.Unit else ray.Direction
	local cameraOnAnimal = not touchHeld and camHit ~= nil and animal ~= nil and camHit.Instance:IsDescendantOf(animal)
	local cursorOnAnimal = animal ~= nil and (assistUsed or cameraOnAnimal)
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

	if not (mouseHeld or touchHeld or padHeld or scrub) then
		stopEffects()
		return
	end
	-- The hose isn't strong enough for this rarity. The prompt offers Let Go / Clean Now.
	-- Helping on someone else's animal is not blocked by the local bay's gate.
	if player:GetAttribute("CleanBlocked") == true and not helping then
		stopEffects()
		if onTarget then
			buzz() -- only when actually aiming at the animal
		end
		return
	end

	impactPart.CFrame = CFrame.new(impact)
	local nozzle = getNozzle(root)
	beam.Attachment0 = nozzle
	beam.Enabled = feel.Beam
	splash.Enabled = sprayHit ~= nil or onTarget
	splash.Rate = if onTarget then feel.SplashRate else feel.SplashRate * 0.5
	foam.Enabled = onTarget and feel.Foam > 0
	foam.Rate = feel.Foam
	mist.Enabled = onTarget and feel.Mist > 0
	mist.Rate = feel.Mist
	bristles.Enabled = onTarget and feel.Bristles
	if dribbleAttachment ~= nozzle then
		dribbleAttachment = nozzle
		dribble.Parent = nozzle
	end
	dribble.Enabled = feel.Dribble
	if not sprayActive then
		sprayStartedAt = os.clock()
	end
	sprayActive = true
	sprayOnTarget = onTarget
	sprayScreenPoint = screenPoint
	setSprayAudio(true)

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

-- Range drives aiming (a sub-tier can stretch it); the tier's feel sets the jet, particles and sounds.
local function applyTier(tier: number, _name: string?, level: number?)
	local tool = GearLadder.get(tier, level)
	range = tool.Range
	feel = FEEL[tool.Tier] or FEEL[1]
	if beam then
		beam.Width0 = feel.Width0
		beam.Width1 = feel.Width1
		beam.Color = ColorSequence.new(feel.Color)
		beam.Transparency = NumberSequence.new(feel.Transparency, math.min(1, feel.Transparency + 0.4))
		splash.Speed = NumberRange.new(5 * feel.Splash, 9 * feel.Splash)
		mist.Color = ColorSequence.new(Color3.fromRGB(235, 248, 255), feel.Color)
	end
	for _, sound in loopSounds do
		sound:Stop()
	end
end

-- WASH's reticle sits on the locked mud. The aim runs on Heartbeat, before the camera moves
-- this frame, so the reticle is placed again here after it, or it would trail the view.
local function followLock()
	local world = lockedWorld
	local camera = Workspace.CurrentCamera
	if not (touchHeld and world and camera) then
		return
	end
	local projected, onScreen = camera:WorldToViewportPoint(world)
	local point = Vector2.new(projected.X, projected.Y)
	reticle.Visible = onScreen and projected.Z > 0
	reticle.Position = UDim2.fromOffset(point.X, point.Y)
	sprayScreenPoint = point
end

-- A short kick when the stronger hoses start spraying, fading out over SHAKE_SECONDS,
-- applied after the camera has moved.
local function shakeCamera()
	if not sprayActive or feel.Shake <= 0 then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local age = os.clock() - sprayStartedAt
	if age >= SHAKE_SECONDS then
		return
	end
	local fade = 1 - age / SHAKE_SECONDS
	local amount = math.rad(feel.Shake) * 2.2 * fade * fade
	local t = os.clock() * 40
	camera.CFrame *= CFrame.Angles(math.sin(t) * amount, math.cos(t * 1.3) * amount, 0)
end

function CleaningController.init(initial: Types.InitialState)
	buildEffects()
	applyTier(initial.ToolTier, initial.ToolName, initial.ToolUpgrade)
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
	-- After ScrubLook, which would otherwise put the camera back over the shake.
	RunService:BindToRenderStep("SprayShake", Enum.RenderPriority.Camera.Value + 2, shakeCamera)
	RunService:BindToRenderStep("WashReticle", Enum.RenderPriority.Camera.Value + 3, followLock)
end

return CleaningController
