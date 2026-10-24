-- Legendary and rarer walk-ins get a reveal (RarityFanfare has the per-tier numbers). On every
-- client near it: a light beam drops out of the sky onto the animal, rings race across the
-- ground, sparkles burst, the model flashes in the tier colour, a stamp pops over it and the
-- fanfare plays. Secret dims, then lightning strikes first.
-- The bay's owner also gets a screen stamp, a colour flash and a camera shake.
-- Afterward a soft pillar of light stays over the animal while it waits in line or is being
-- washed, so a rare one stands out from across the map.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityFanfare = require(ReplicatedStorage.Shared.RarityFanfare)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local RareReveal = {}

local SEE_DISTANCE = 300 -- studs from the camera for the world effects
local SKY_HEIGHT = 140
local PILLAR_HEIGHT = 45
local WAITING_NAMES = { QueuedAnimal = true, Animal = true } -- still in line or on the wash
local SPARKLE_TEX = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds"
local SHAKE_STEP = "RareRevealShake"

local screen: ScreenGui
local bannerToken = 0
local shakeUntil, shakeAmount, shakeLength = 0, 0, 1

local function hueNow(offset: number?): Color3
	return Color3.fromHSV((os.clock() * 0.5 + (offset or 0)) % 1, 0.6, 1)
end

local function colorOf(style: RarityFanfare.Style, offset: number?): Color3
	return if style.Rainbow then hueNow(offset) else style.Color
end

local function anchor(position: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.WorldPosition = position
	a.Parent = Workspace.Terrain
	return a
end

-- Where the animal is now: its feet and its middle. Falls back to where it spawned.
local function spotOf(model: Model?, fallback: Vector3): (Vector3, Vector3, number)
	if model and model.Parent then
		local box, size = model:GetBoundingBox()
		local feet = Vector3.new(box.Position.X, box.Position.Y - size.Y / 2, box.Position.Z)
		return feet, box.Position, math.max(size.X, size.Z)
	end
	return fallback, fallback + Vector3.new(0, 2, 0), 4
end

local function beam(
	top: Attachment,
	bottom: Attachment,
	width: number,
	color: Color3,
	transparency: NumberSequence
): Beam
	local b = Instance.new("Beam")
	b.Attachment0 = bottom
	b.Attachment1 = top
	b.Width0 = width
	b.Width1 = width
	b.FaceCamera = true
	b.LightEmission = 1
	b.LightInfluence = 0
	b.Segments = 1
	b.Color = ColorSequence.new(color)
	b.Transparency = transparency
	b.Parent = bottom
	return b
end

local function ring(at: Vector3, color: Color3, size: number, delay: number)
	task.delay(delay, function()
		local p = Instance.new("Part")
		p.Name = "RevealRing"
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Transparency = 0.1
		p.Size = Vector3.new(0.15, 2, 2)
		p.CFrame = CFrame.new(at + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
		p.Parent = Workspace
		TweenService:Create(p, TweenInfo.new(0.7, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.15, size, size),
			Transparency = 1,
		}):Play()
		task.delay(0.8, p.Destroy, p)
	end)
end

local function burst(at: Attachment, props: { [string]: any }, count: number)
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.Rate = 0
	e.LightEmission = 1
	e.LightInfluence = 0
	for key, value in props do
		(e :: any)[key] = value
	end
	e.Parent = at
	e:Emit(count)
end

-- Jagged neon bolt from the sky to the animal, gone in a flicker.
local function lightning(to: Vector3, color: Color3, rng: Random)
	local points = { to + Vector3.new(rng:NextNumber(-12, 12), 70, rng:NextNumber(-12, 12)) }
	for i = 1, 6 do
		local t = i / 7
		local p = points[1]:Lerp(to, t)
		table.insert(points, p + Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-3, 3)))
	end
	table.insert(points, to)
	local folder = Instance.new("Folder")
	folder.Name = "RevealBolt"
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local seg = Instance.new("Part")
		seg.Anchored = true
		seg.CanCollide = false
		seg.CanQuery = false
		seg.CanTouch = false
		seg.CastShadow = false
		seg.Material = Enum.Material.Neon
		seg.Color = color
		seg.Size = Vector3.new(0.35, 0.35, (b - a).Magnitude)
		seg.CFrame = CFrame.lookAt((a + b) / 2, b)
		seg.Parent = folder
	end
	folder.Parent = Workspace
	task.delay(0.08, function()
		for _, seg in folder:GetChildren() do
			(seg :: BasePart).Transparency = 0.7
		end
	end)
	task.delay(0.14, function()
		for _, seg in folder:GetChildren() do
			(seg :: BasePart).Transparency = 0
		end
	end)
	task.delay(0.3, folder.Destroy, folder)
end

-- A soft pillar of light over the animal for as long as it waits in line or is being washed.
local function pillar(model: Model, style: RarityFanfare.Style)
	local feet = spotOf(model, model:GetPivot().Position)
	local bottom = anchor(feet)
	local top = anchor(feet + Vector3.new(0, PILLAR_HEIGHT, 0))
	local glow = beam(
		top,
		bottom,
		3,
		colorOf(style),
		NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(0.6, 0.85),
			NumberSequenceKeypoint.new(1, 1),
		})
	)
	glow.Width1 = 1.5
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		if not model.Parent or not WAITING_NAMES[model.Name] then
			connection:Disconnect()
			bottom:Destroy()
			top:Destroy()
			return
		end
		local at = spotOf(model, bottom.WorldPosition)
		bottom.WorldPosition = at
		top.WorldPosition = at + Vector3.new(0, PILLAR_HEIGHT, 0)
		local pulse = 2.6 + math.sin(os.clock() * 3) * 0.6
		glow.Width0 = pulse
		if style.Rainbow then
			glow.Color = ColorSequence.new(hueNow())
		end
	end)
end

-- Beam, rings, sparkles, flash and the floating stamp, for everyone near the animal.
local function worldReveal(model: Model?, rarityKey: string, style: RarityFanfare.Style, fallback: Vector3)
	local rng = Random.new()
	local feet, middle, width = spotOf(model, fallback)
	local strikeDelay = 0
	if style.Dark then
		-- Secret: a dark puff swallows the spot, then lightning, then the beam.
		local puff = anchor(middle)
		burst(puff, {
			Texture = SMOKE_TEX,
			Color = ColorSequence.new(Color3.fromRGB(40, 10, 70), Color3.fromRGB(5, 0, 10)),
			LightEmission = 0,
			Size = NumberSequence.new(3, 8),
			Transparency = NumberSequence.new(0.2, 1),
			Lifetime = NumberRange.new(1, 1.6),
			Speed = NumberRange.new(2, 5),
			SpreadAngle = Vector2.new(180, 180),
		}, 30)
		task.delay(3, puff.Destroy, puff)
		for i = 0, 2 do
			task.delay(0.15 + i * 0.16, lightning, feet, Color3.fromRGB(220, 190, 255), rng)
		end
		strikeDelay = 0.55
	end

	task.delay(strikeDelay, function()
		feet, middle, width = spotOf(model, fallback)
		local bottom = anchor(feet)
		local top = anchor(feet + Vector3.new(0, SKY_HEIGHT, 0))
		local outer = beam(
			top,
			bottom,
			0.5,
			colorOf(style),
			NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(0.7, 0.5),
				NumberSequenceKeypoint.new(1, 1),
			})
		)
		local core = beam(top, bottom, 0.2, style.Glow, NumberSequence.new(0, 0.6))
		local flash = Instance.new("PointLight")
		flash.Color = colorOf(style)
		flash.Range = 30
		flash.Brightness = 10
		flash.Parent = bottom

		-- Sparkles off the body, fire for Mythic, confetti for Farm God.
		local spray = anchor(middle)
		burst(spray, {
			Texture = SPARKLE_TEX,
			Color = if style.Rainbow
				then ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
					ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 230, 60)),
					ColorSequenceKeypoint.new(0.66, Color3.fromRGB(80, 220, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 100, 255)),
				})
				else ColorSequence.new(style.Glow, style.Color),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.4),
				NumberSequenceKeypoint.new(0.3, 1.3),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Lifetime = NumberRange.new(0.9, 1.6),
			Speed = NumberRange.new(10, 22),
			SpreadAngle = Vector2.new(180, 180),
			Acceleration = Vector3.new(0, -8, 0),
			Drag = 2,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-200, 200),
		}, style.Particles)
		if rarityKey == "Mythic" then
			burst(spray, {
				Texture = "rbxasset://textures/particles/fire_main.dds",
				Color = ColorSequence.new(Color3.fromRGB(255, 220, 90), Color3.fromRGB(255, 50, 20)),
				Size = NumberSequence.new(2.5, 0.5),
				Transparency = NumberSequence.new(0.2, 1),
				Lifetime = NumberRange.new(0.6, 1),
				Speed = NumberRange.new(6, 12),
				SpreadAngle = Vector2.new(180, 180),
				Acceleration = Vector3.new(0, 10, 0),
			}, 40)
		end

		for i = 1, style.Rings do
			ring(feet, colorOf(style, i * 0.2), math.max(width * 3, 16) + i * 6, (i - 1) * 0.14)
		end

		if model and model.Parent then
			local highlight = Instance.new("Highlight")
			highlight.FillColor = colorOf(style)
			highlight.OutlineColor = style.Glow
			highlight.FillTransparency = 0.2
			highlight.OutlineTransparency = 0
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Parent = model
			TweenService:Create(highlight, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				FillTransparency = 1,
				OutlineTransparency = 1,
			}):Play()
			task.delay(1.5, highlight.Destroy, highlight)

			local head = model:FindFirstChild("Head")
			if head and head:IsA("BasePart") then
				local stamp = Instance.new("BillboardGui")
				stamp.Name = "RevealStamp"
				stamp.Size = UDim2.fromOffset(300, 70)
				stamp.MaxDistance = SEE_DISTANCE
				stamp.AlwaysOnTop = true
				stamp.StudsOffset = Vector3.new(0, head.Size.Y / 2 + 6, 0)
				local label = Instance.new("TextLabel")
				label.AnchorPoint = Vector2.new(0.5, 0.5)
				label.Position = UDim2.fromScale(0.5, 0.5)
				label.Size = UDim2.fromScale(0.1, 0.1)
				label.Rotation = -12
				label.Parent = stamp
				UIStyle.rarity(label, rarityKey)
				label.Text = style.Title
				stamp.Parent = head
				TweenService:Create(label, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Size = UDim2.fromScale(1, 1),
					Rotation = 0,
				}):Play()
				task.delay(2.2, function()
					TweenService:Create(label, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
				end)
				task.delay(2.7, stamp.Destroy, stamp)
			end
		end

		-- The beam swells, follows the animal, then thins away.
		local started = os.clock()
		local connection: RBXScriptConnection
		connection = RunService.Heartbeat:Connect(function()
			local t = os.clock() - started
			local at = spotOf(model, bottom.WorldPosition)
			bottom.WorldPosition = at
			top.WorldPosition = at + Vector3.new(0, SKY_HEIGHT, 0)
			local open = math.min(t / 0.18, 1)
			local close = math.clamp((t - 1.1) / 0.9, 0, 1)
			local w = math.max(width, 3) * 1.4 * open * (1 - close * close)
			outer.Width0, outer.Width1 = w, w * 0.6
			core.Width0, core.Width1 = w * 0.35, w * 0.2
			flash.Brightness = 10 * (1 - math.min(t / 0.8, 1))
			if style.Rainbow then
				outer.Color = ColorSequence.new(hueNow())
				flash.Color = hueNow()
			end
			if t > 2.1 then
				connection:Disconnect()
				bottom:Destroy()
				top:Destroy()
			end
		end)
		task.delay(3, spray.Destroy, spray)
	end)
end

-- The owner's screen: a colour flash, a stamp with the animal's name, and a camera shake.
local function screenReveal(rarityKey: string, mutationKey: string, species: string?, style: RarityFanfare.Style)
	bannerToken += 1
	local token = bannerToken
	for _, child in screen:GetChildren() do
		child:Destroy()
	end

	local delay = 0
	if style.Dark then
		local dark = Instance.new("Frame")
		dark.Size = UDim2.fromScale(1, 1)
		dark.BackgroundColor3 = Color3.new(0, 0, 0)
		dark.BackgroundTransparency = 1
		dark.BorderSizePixel = 0
		dark.Parent = screen
		TweenService:Create(dark, TweenInfo.new(0.25), { BackgroundTransparency = 0.6 }):Play()
		task.delay(0.55, function()
			TweenService:Create(dark, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
			task.delay(0.7, dark.Destroy, dark)
		end)
		delay = 0.55
	end

	task.delay(delay, function()
		if token ~= bannerToken then
			return
		end
		local flash = Instance.new("Frame")
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = colorOf(style)
		flash.BackgroundTransparency = 0.7
		flash.BorderSizePixel = 0
		flash.Parent = screen
		TweenService:Create(flash, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
		task.delay(0.7, flash.Destroy, flash)

		-- A glowing band across the middle, the tier stamp on it, the animal's name under it.
		local band = Instance.new("Frame")
		band.AnchorPoint = Vector2.new(0.5, 0.5)
		band.Position = UDim2.fromScale(0.5, 0.32)
		band.Size = UDim2.fromScale(0, 0.2)
		band.BackgroundColor3 = if style.Dark then Color3.new(0, 0, 0) else colorOf(style)
		band.BorderSizePixel = 0
		band.Parent = screen
		local fadeEdges = Instance.new("UIGradient")
		fadeEdges.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, 0.65),
			NumberSequenceKeypoint.new(0.75, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		})
		fadeEdges.Parent = band
		TweenService:Create(band, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(1.2, 0.2),
		}):Play()

		local title = Instance.new("TextLabel")
		title.AnchorPoint = Vector2.new(0.5, 0.5)
		title.Position = UDim2.fromScale(0.5, 0.29)
		title.Size = UDim2.fromScale(0.05, 0.02)
		title.Rotation = -10
		title.ZIndex = 2
		title.Parent = screen
		UIStyle.rarity(title, rarityKey)
		title.Text = style.Title
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = 72
		constraint.Parent = title
		TweenService:Create(title, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(0.55, 0.1),
			Rotation = 0,
		}):Play()

		local def = species and AnimalConfig.Animals[species]
		local mutation = MutationConfig.ByKey[mutationKey]
		local name = if def then def.DisplayName else "animal"
		if mutation and mutationKey ~= MutationConfig.Default then
			name = `{mutation.DisplayName} {name}`
		end
		local sub = Instance.new("TextLabel")
		sub.AnchorPoint = Vector2.new(0.5, 0.5)
		sub.Position = UDim2.fromScale(0.5, 0.385)
		sub.Size = UDim2.fromScale(0.5, 0.05)
		sub.ZIndex = 2
		sub.Parent = screen
		UIStyle.text(sub, Color3.new(1, 1, 1))
		sub.Text = `A {name} is walking in!`
		sub.TextTransparency = 1
		TweenService:Create(sub, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()

		-- Wobble while it holds, then everything lifts away and fades.
		local started = os.clock()
		local connection: RBXScriptConnection
		connection = RunService.RenderStepped:Connect(function()
			local t = os.clock() - started
			if token ~= bannerToken or t > 2.8 then
				connection:Disconnect()
				return
			end
			if t > 0.45 then
				title.Rotation = math.sin(t * 6) * 3
			end
			if style.Rainbow then
				band.BackgroundColor3 = hueNow()
			end
		end)
		task.delay(2.2, function()
			if token ~= bannerToken then
				return
			end
			local out = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(title, out, {
				Position = UDim2.fromScale(0.5, 0.2),
				TextTransparency = 1,
			}):Play()
			TweenService:Create(sub, out, { TextTransparency = 1 }):Play()
			TweenService:Create(band, out, { BackgroundTransparency = 1 }):Play()
			task.delay(0.6, function()
				if token == bannerToken then
					for _, child in screen:GetChildren() do
						child:Destroy()
					end
				end
			end)
		end)

		shakeAmount = style.Shake
		shakeLength = 0.7
		shakeUntil = os.clock() + shakeLength
	end)
end

local function onArrival(model: Model?, rarityKey: string, mutationKey: string, bay: Instance?)
	if typeof(rarityKey) ~= "string" then
		return
	end
	local style = RarityFanfare.style(rarityKey)
	if not style then
		return
	end
	local mine = bay ~= nil and bay:GetAttribute("OwnerUserId") == player.UserId
	local fallback = if model and model.Parent
		then model:GetPivot().Position
		elseif bay and bay:IsA("Model") then bay:GetPivot().Position
		else Vector3.zero
	local camera = Workspace.CurrentCamera
	local near = camera ~= nil and (camera.CFrame.Position - fallback).Magnitude <= SEE_DISTANCE

	if near or mine then
		worldReveal(model, rarityKey, style, fallback)
		if model and model.Parent then
			pillar(model, style)
		end
	end
	if mine then
		-- Flat, so the owner hears all of it wherever their camera is.
		RarityFanfare.play(SoundService, rarityKey, 0.8)
		local species = model and model:GetAttribute("AnimalKey")
		screenReveal(rarityKey, mutationKey, if typeof(species) == "string" then species else nil, style)
	elseif near then
		local body = model and model:FindFirstChild("Body")
		if body then
			RarityFanfare.play(body, rarityKey)
		end
	end
end

function RareReveal.init(_initial: any)
	screen = Instance.new("ScreenGui")
	screen.Name = "RareReveal"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 50
	screen.Parent = player:WaitForChild("PlayerGui")

	Remotes.event("RareArrival").OnClientEvent:Connect(onArrival)

	-- Camera shake after the camera has moved this frame, so it never fights the controls.
	RunService:BindToRenderStep(SHAKE_STEP, Enum.RenderPriority.Camera.Value + 1, function()
		local left = shakeUntil - os.clock()
		local camera = Workspace.CurrentCamera
		if left <= 0 or not camera then
			return
		end
		local strength = shakeAmount * (left / shakeLength)
		local t = os.clock() * 40
		camera.CFrame = camera.CFrame
			* CFrame.new(math.noise(t, 0.3) * strength, math.noise(0.7, t) * strength, 0)
			* CFrame.Angles(0, 0, math.noise(t, t * 0.5) * strength * 0.05)
	end)
end

return RareReveal
