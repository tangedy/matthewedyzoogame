-- Tension: animals have moods and a patience meter while they're being washed.
--
--   Calm      stands still.
--   Ticklish  squirms on the spot every second or two.
--   Grumpy    below 40% patience, rears back and lunges at the nearest player, flinging them.
--
-- Patience drains while the wash runs. When it empties the animal SHAKES: part of the clean
-- area gets muddy again (CleaningService.redirty), mud explodes from it, and every character
-- within the shake radius is flung and splatted, owner or not. Patience then refills partway.
-- Mythic and rarer animals also have a wander-off timer: at zero the animal walks off unpaid
-- (BayService.abandonWash).
--
-- Everything is decided here. Clients only receive results: the owner gets the meter
-- (TensionState), flung players are told to fling themselves (characters are client-owned
-- physics) and show the mud splat (TensionFling), and onlookers get a camera shake
-- (TensionCameraShake). The only client -> server remote is a Studio/owner debug command.
--
-- Hooks: listens to WashStarted / WashCompleted / CalmTreat (player, seconds) and fires
-- PatienceLow (player, jobId, fraction) once per wash.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local TensionConfig = require(ReplicatedStorage.Shared.FeatureConfig.TensionConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Services = script.Parent.Parent.Services
local BayService = require(Services.BayService)
local CleaningService = require(Services.CleaningService)
local EconomyService = require(Services.EconomyService)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

type AnimKind = "Squirm" | "Lunge" | "Shake"

type Anim = {
	Kind: AnimKind,
	T: number,
	Duration: number,
	Yaw: number, -- squirm
	Roll: number,
	Shift: number,
	Direction: Vector3, -- lunge: flat unit vector toward the target
	Fired: boolean, -- lunge hit check / shake explosion done
}

type State = {
	Player: Player,
	JobId: string,
	Species: string,
	Model: Model,
	Bay: Instance?,
	Base: CFrame, -- the wash spot; every pose is an offset from here
	Profile: TensionConfig.Profile,
	Patience: number, -- seconds left
	LowFired: boolean,
	WanderLeft: number?, -- seconds, nil when this animal never wanders off
	Anim: Anim?,
	NextSquirm: number,
	LungeCooldown: number,
	SendIn: number,
	CheckIn: number,
	Event: string?, -- one-shot event sent with the next update
}

-- Payload of TensionState (server -> owner); nil fields are omitted on the wire.
export type TensionSnapshot = {
	JobId: string,
	Mood: string,
	Patience: number, -- 0..1
	Calm: number, -- seconds of Calm Treat left
	Wander: number?, -- seconds until it walks off
	Event: string?, -- "Shake" | "Lunge" | "Calmed" | "WanderedOff"
	Ended: boolean?,
}

local Tension = {}

local JOB_CHECK_INTERVAL = 0.25
local DEV_COMMAND_INTERVAL = 0.3

local states: { [Player]: State } = {}
-- Seconds of Calm Treat banked per player. Only counts down while an animal is actually
-- tense, so a treat bought between washes (or during grace) waits for the next one.
local calmLeft: { [Player]: number } = {}
local sessionStarted: { [Player]: boolean } = {} -- has had their first animal this session
local lastDevAt: { [Player]: number } = {}
local rng = Random.new()

local stateRemote: RemoteEvent
local flingRemote: RemoteEvent
local cameraRemote: RemoteEvent
local announcement: RemoteEvent

local function isDeveloper(player: Player): boolean
	return RunService:IsStudio() or (game.CreatorId ~= 0 and player.UserId == game.CreatorId)
end

local function isFiniteNumber(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Seconds a wash would take spraying one patch at a time with this player's hose (an upper
-- bound; CleaningService removes `power` from every patch a spray hits).
local function expectedWashSeconds(player: Player, species: string, mutation: string?): number
	local def = AnimalConfig.Animals[species]
	local multiplier = Hooks.apply("WashTimeMultiplier", def.WashTimeMultiplier, player, species, mutation)
	if not isFiniteNumber(multiplier) then
		multiplier = def.WashTimeMultiplier
	end
	local tool = EconomyService.getTool(player) or ToolConfig[1]
	local power = Hooks.apply("CleaningPower", tool.CleaningPower, player)
	if not isFiniteNumber(power) or power <= 0 then
		power = tool.CleaningPower
	end
	return GameConfig.BaseWashSeconds * ToolConfig[1].CleaningPower * math.max(0.05, multiplier) / power
end

-- Rarity defaults with the species override on top, then patience and the wander-off timer
-- sized from the expected wash time. Limited (bought) animals never wander off.
local function profileFor(player: Player, species: string, mutation: string?): TensionConfig.Profile?
	local def = AnimalConfig.Animals[species]
	if not def then
		return nil
	end
	local profile = table.clone(TensionConfig.ByRarity[def.Rarity] or TensionConfig.ByRarity.Common)
	local override = TensionConfig.BySpecies[species]
	if override then
		for key, value in override :: { [string]: any } do
			(profile :: any)[key] = value
		end
	end
	if def.Limited then
		profile.WanderOffSeconds = 0
	end
	local expected = expectedWashSeconds(player, species, mutation)
	local cap = math.max(1, profile.PatienceSeconds)
	profile.PatienceSeconds =
		math.clamp(expected * profile.PatienceFactor + profile.PatienceSlack, math.min(profile.MinPatience, cap), cap)
	if profile.WanderOffSeconds > 0 then
		local wanderCap = profile.WanderOffSeconds
		profile.WanderOffSeconds = math.clamp(
			expected * TensionConfig.WanderFactor,
			math.min(TensionConfig.MinWanderSeconds, wanderCap),
			wanderCap
		)
	end
	return profile
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function send(state: State)
	local snapshot: TensionSnapshot = {
		JobId = state.JobId,
		Mood = state.Profile.Mood,
		Patience = math.clamp(state.Patience / state.Profile.PatienceSeconds, 0, 1),
		Calm = calmLeft[state.Player] or 0,
		Wander = state.WanderLeft,
		Event = state.Event,
	}
	state.Event = nil
	state.SendIn = TensionConfig.StateSendInterval
	stateRemote:FireClient(state.Player, snapshot)
end

local function endState(player: Player, event: string?)
	local state = states[player]
	if not state then
		return
	end
	states[player] = nil
	if state.Anim and state.Model.Parent then
		state.Model:PivotTo(state.Base)
	end
	if player.Parent then
		local snapshot: TensionSnapshot = {
			JobId = state.JobId,
			Mood = state.Profile.Mood,
			Patience = 1,
			Calm = 0,
			Event = event,
			Ended = true,
		}
		stateRemote:FireClient(player, snapshot)
	end
end

-- Tells a client to fling its own character away from `from` (and splat its screen with mud).
-- The server picks the velocity.
local function fling(
	player: Player,
	root: BasePart,
	from: Vector3,
	strength: number,
	up: number,
	ragdoll: number,
	splat: boolean
)
	local offset = (root.Position - from) * Vector3.new(1, 0, 1)
	local direction = if offset.Magnitude > 0.05
		then offset.Unit
		else CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0).LookVector
	flingRemote:FireClient(player, direction * strength + Vector3.yAxis * up, ragdoll, splat)
end

local function playSound(parent: Instance, id: string, speed: number, volume: number)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.PlaybackSpeed = speed
	sound.Volume = volume
	sound.RollOffMaxDistance = 120
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 4)
end

local function mudColor(): Color3
	local colors = TensionConfig.MudColors
	return colors[rng:NextInteger(1, #colors)]
end

-- The money shot: a burst of mud from the animal and splats left on the ground around it.
local function mudExplosion(state: State, center: Vector3, radius: number)
	local shake = TensionConfig.Shake
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = center
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Speed = NumberRange.new(radius * 1.4, radius * 2.6)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -70, 0)
	emitter.Drag = 1.2
	emitter.Lifetime = NumberRange.new(0.7, 1.3)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 0.6),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(TensionConfig.MudColors[1], TensionConfig.MudColors[2])
	emitter.LightInfluence = 1
	emitter.Parent = attachment
	attachment.Parent = Workspace.Terrain
	emitter:Emit(math.floor(shake.Particles * math.max(1, radius / 12)))
	playSound(attachment, TensionConfig.Sounds.Shake, 0.55, 1.4)
	playSound(attachment, TensionConfig.Sounds.Shake, 0.8, 0.9)
	Debris:AddItem(attachment, 3)

	local parent = state.Bay
	if not parent or not parent.Parent then
		return
	end
	local groundY = state.Base.Position.Y
	for _ = 1, shake.Puddles do
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = rng:NextNumber(radius * 0.25, radius * 0.85)
		local size = rng:NextNumber(1.5, 3.5)
		local puddle = Instance.new("Part")
		puddle.Name = "MudSplat"
		puddle.Shape = Enum.PartType.Cylinder
		puddle.Size = Vector3.new(0.12, size, size)
		puddle.CFrame = CFrame.new(
			center.X + math.cos(angle) * distance,
			groundY + 0.08,
			center.Z + math.sin(angle) * distance
		) * CFrame.Angles(0, 0, math.pi / 2)
		puddle.Color = mudColor()
		puddle.Material = Enum.Material.SmoothPlastic
		puddle.Anchored = true
		puddle.CanCollide = false
		puddle.CanQuery = false
		puddle.CanTouch = false
		puddle.CastShadow = false
		puddle.Parent = parent
		TweenService:Create(
			puddle,
			TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, shake.PuddleSeconds),
			{ Transparency = 1 }
		):Play()
		Debris:AddItem(puddle, shake.PuddleSeconds + 1.2)
	end
end

local function explode(state: State)
	local profile = state.Profile
	local shake = TensionConfig.Shake
	CleaningService.redirty(state.JobId, profile.ShakeRedirty)
	local box = state.Model:GetBoundingBox()
	local center = box.Position
	mudExplosion(state, center, profile.ShakeRadius)

	local shakeRange = profile.ShakeRadius * shake.CameraShakeRange
	local flung: { [Player]: boolean } = {}
	for _, other in Players:GetPlayers() do
		local root = rootOf(other)
		if not root then
			continue
		end
		local distance = (root.Position - center).Magnitude
		if distance <= profile.ShakeRadius then
			local falloff = 1 - (1 - shake.MinFalloff) * (distance / profile.ShakeRadius)
			fling(other, root, center, profile.Knockback * falloff, profile.KnockUp, shake.RagdollSeconds, true)
			flung[other] = true
		elseif distance <= shakeRange then
			local intensity = shake.CameraShakeIntensity * (1 - distance / shakeRange)
			cameraRemote:FireClient(other, intensity, shake.CameraShakeSeconds)
		end
	end
	-- Anyone spraying this animal ragdolls too, even if the hose reached from outside the burst.
	for _, helper in CleaningService.assistants(state.JobId) do
		if flung[helper] then
			continue
		end
		local root = rootOf(helper)
		if root then
			fling(helper, root, center, profile.Knockback, profile.KnockUp, shake.RagdollSeconds, true)
		end
	end
	state.Patience = profile.PatienceSeconds * TensionConfig.RefillFraction
	state.Event = "Shake"
end

-- Distance from a point to the animal's bounding box (0 inside it).
local function distanceToModel(model: Model, point: Vector3): number
	local cframe, size = model:GetBoundingBox()
	local p = cframe:PointToObjectSpace(point)
	local half = size / 2
	local clamped = Vector3.new(
		math.clamp(p.X, -half.X, half.X),
		math.clamp(p.Y, -half.Y, half.Y),
		math.clamp(p.Z, -half.Z, half.Z)
	)
	return (p - clamped).Magnitude
end

local function lungeHit(state: State)
	local lunge = TensionConfig.Lunge
	local from = state.Model:GetPivot().Position
	for _, other in Players:GetPlayers() do
		local root = rootOf(other)
		if root and distanceToModel(state.Model, root.Position) <= lunge.HitDistance then
			fling(other, root, from, lunge.Knockback, lunge.KnockUp, lunge.RagdollSeconds, false)
		end
	end
end

local function nearestTarget(state: State): Vector3?
	local origin = state.Base.Position
	local best: Vector3? = nil
	local bestDistance = TensionConfig.Lunge.Range
	for _, other in Players:GetPlayers() do
		local root = rootOf(other)
		if root then
			local flat = (root.Position - origin) * Vector3.new(1, 0, 1)
			if flat.Magnitude < bestDistance and flat.Magnitude > 0.05 then
				bestDistance = flat.Magnitude
				best = flat.Unit
			end
		end
	end
	return best
end

local function newAnim(kind: AnimKind, duration: number): Anim
	return {
		Kind = kind,
		T = 0,
		Duration = duration,
		Yaw = 0,
		Roll = 0,
		Shift = 0,
		Direction = Vector3.zero,
		Fired = false,
	}
end

-- A red "!" over the head for the wind-up, so the lunge is always telegraphed.
local function exclaim(model: Model, seconds: number)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TensionExclaim"
	billboard.Size = UDim2.fromOffset(60, 60)
	UIStyle.overhead(billboard, head, UIStyle.Overhead.Callout)
	billboard.MaxDistance = 80
	billboard.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "!"
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.TextColor3 = Color3.fromRGB(255, 60, 50)
	label.TextStrokeTransparency = 0
	label.Parent = billboard
	billboard.Parent = head
	Debris:AddItem(billboard, seconds)
end

local function startLunge(state: State, direction: Vector3)
	local lunge = TensionConfig.Lunge
	local anim = newAnim("Lunge", lunge.WindUp + lunge.Strike + lunge.Hold + lunge.Return)
	anim.Direction = direction
	state.Anim = anim
	state.LungeCooldown = anim.Duration + rng:NextNumber(lunge.CooldownMin, lunge.CooldownMax)
	state.Event = "Lunge"
	exclaim(state.Model, lunge.WindUp + lunge.Strike)
	local body = state.Model:FindFirstChild("Body")
	if body then
		playSound(body, TensionConfig.Sounds.WindUp, 0.6, 0.9)
	end
end

local function startSquirm(state: State)
	local squirm = TensionConfig.Squirm
	local anim = newAnim("Squirm", squirm.Duration)
	local function signed(max: number): number
		return (if rng:NextNumber() < 0.5 then -1 else 1) * rng:NextNumber(max * 0.5, max)
	end
	anim.Yaw = math.rad(signed(squirm.MaxYawDegrees))
	anim.Roll = math.rad(signed(squirm.MaxRollDegrees))
	anim.Shift = signed(squirm.MaxShift)
	state.Anim = anim
end

local function startShake(state: State)
	state.Anim = newAnim("Shake", TensionConfig.Shake.Duration)
end

-- Pose for the current animation frame, as an offset from the wash spot.
local function animOffset(state: State, anim: Anim): CFrame
	local t = anim.T
	if anim.Kind == "Squirm" then
		local p = t / anim.Duration
		local wave = math.sin(p * math.pi * 3) * (1 - p)
		return CFrame.new(anim.Shift * wave, 0, 0) * CFrame.Angles(0, anim.Yaw * wave, anim.Roll * wave)
	elseif anim.Kind == "Lunge" then
		local lunge = TensionConfig.Lunge
		local amount
		local tremble = 0
		if t < lunge.WindUp then
			local p = t / lunge.WindUp
			amount = -lunge.RearBack * math.sin(p * math.pi / 2)
			tremble = math.rad(3) * math.sin(t * 60)
		elseif t < lunge.WindUp + lunge.Strike then
			local p = (t - lunge.WindUp) / lunge.Strike
			amount = -lunge.RearBack + (lunge.Distance + lunge.RearBack) * p
		elseif t < lunge.WindUp + lunge.Strike + lunge.Hold then
			amount = lunge.Distance
		else
			local p = math.clamp((t - lunge.WindUp - lunge.Strike - lunge.Hold) / lunge.Return, 0, 1)
			amount = lunge.Distance * (1 - p)
		end
		local localDirection = state.Base:VectorToObjectSpace(anim.Direction)
		return CFrame.new(localDirection * amount) * CFrame.Angles(0, tremble, 0)
	else
		local shake = TensionConfig.Shake
		local p = t / anim.Duration
		local yaw = math.rad(shake.WiggleDegrees) * math.sin(t * shake.WiggleHz * math.pi * 2) * (1 - p)
		local hop = math.abs(math.sin(p * math.pi)) * 0.6
		return CFrame.new(0, hop, 0) * CFrame.Angles(0, yaw, 0)
	end
end

local function stepAnim(state: State, dt: number)
	local anim = state.Anim
	if not anim then
		return
	end
	anim.T += dt
	if anim.Kind == "Shake" and not anim.Fired and anim.T >= TensionConfig.Shake.ExplodeAt then
		anim.Fired = true
		explode(state)
	elseif anim.Kind == "Lunge" and not anim.Fired then
		local lunge = TensionConfig.Lunge
		if anim.T >= lunge.WindUp + lunge.Strike then
			anim.Fired = true
			lungeHit(state)
		end
	end
	if anim.T >= anim.Duration then
		state.Anim = nil
		state.Model:PivotTo(state.Base)
	else
		state.Model:PivotTo(state.Base * animOffset(state, anim))
	end
end

local function wanderOff(player: Player, state: State)
	local def = AnimalConfig.Animals[state.Species]
	endState(player, "WanderedOff")
	if not BayService.abandonWash(player) then
		return
	end
	local lines = TensionConfig.WanderOffLines
	local line = lines[rng:NextInteger(1, #lines)]
	local name = if def then def.DisplayName else "animal"
	announcement:FireClient(player, (string.gsub(line, "{name}", name)), if def then def.Rarity else "Common")
end

local function stepState(player: Player, state: State, dt: number)
	if not player.Parent or not state.Model.Parent then
		endState(player)
		return
	end
	state.CheckIn -= dt
	if state.CheckIn <= 0 then
		state.CheckIn = JOB_CHECK_INTERVAL
		local job = CleaningService.getActiveJob(player)
		if not job or job.Id ~= state.JobId then
			endState(player)
			return
		end
	end

	-- Hose isn't strong enough: the player is choosing Let Go or Clean Now. The animal waits.
	if CleaningService.isBlocked(player) then
		state.SendIn -= dt
		if state.SendIn <= 0 then
			send(state)
		end
		return
	end

	local profile = state.Profile
	local anim = state.Anim
	local shaking = anim ~= nil and anim.Kind == "Shake"
	local banked = calmLeft[player]
	local calm = banked ~= nil
	if banked then
		local left = banked - dt
		if left > 0 then
			calmLeft[player] = left
		else
			calmLeft[player] = nil
		end
	end
	if not calm and not shaking then
		state.Patience = math.max(0, state.Patience - dt)
		if state.WanderLeft then
			state.WanderLeft = math.max(0, state.WanderLeft - dt)
		end
	end

	if state.WanderLeft == 0 then
		wanderOff(player, state)
		return
	end

	local fraction = state.Patience / profile.PatienceSeconds
	if not state.LowFired and fraction < TensionConfig.LowFraction then
		state.LowFired = true
		Hooks.fire("PatienceLow", player, state.JobId, fraction)
	end

	if state.Patience <= 0 and not shaking then
		startShake(state)
	elseif not anim and not calm then -- a calmed animal stays still
		if profile.Mood == "Ticklish" then
			state.NextSquirm -= dt
			if state.NextSquirm <= 0 then
				state.NextSquirm = rng:NextNumber(TensionConfig.Squirm.IntervalMin, TensionConfig.Squirm.IntervalMax)
				startSquirm(state)
			end
		elseif profile.Mood == "Grumpy" then
			state.LungeCooldown -= dt
			if state.LungeCooldown <= 0 and fraction < TensionConfig.Lunge.BelowFraction then
				local direction = nearestTarget(state)
				if direction then
					startLunge(state, direction)
				else
					state.LungeCooldown = 0.5 -- nobody in reach; look again shortly
				end
			end
		end
	end
	stepAnim(state, dt)

	state.SendIn -= dt
	if state.SendIn <= 0 or state.Event then
		send(state)
	end
end

local function step(dt: number)
	for player, state in states do
		stepState(player, state, dt)
	end
end

local function startState(
	player: Player,
	jobId: string,
	species: string,
	mutation: string?,
	model: Model,
	bay: Instance?
)
	local profile = profileFor(player, species, mutation)
	if not profile then
		return
	end
	endState(player)
	local state: State = {
		Player = player,
		JobId = jobId,
		Species = species,
		Model = model,
		Bay = bay,
		Base = model:GetPivot(),
		Profile = profile,
		Patience = profile.PatienceSeconds,
		LowFired = false,
		WanderLeft = if profile.WanderOffSeconds > 0 then profile.WanderOffSeconds else nil,
		Anim = nil,
		NextSquirm = rng:NextNumber(TensionConfig.Squirm.IntervalMin, TensionConfig.Squirm.IntervalMax),
		LungeCooldown = 0,
		SendIn = 0,
		CheckIn = JOB_CHECK_INTERVAL,
		Event = nil,
	}
	states[player] = state
	send(state)
end

local function onWashStarted(player: Player, info: Hooks.WashInfo)
	if typeof(info) ~= "table" or typeof(info.JobId) ~= "string" or typeof(info.Model) ~= "Instance" then
		return
	end
	-- Never on the first animal of a session, and not until the player knows the basics.
	local firstOfSession = not sessionStarted[player]
	sessionStarted[player] = true
	if firstOfSession then
		return
	end
	local data = PlayerDataService.get(player)
	if not data or data.LifetimeAnimalsWashed < TensionConfig.GraceWashes then
		return
	end
	if CleaningService.isBlocked(player) then
		return
	end
	startState(player, info.JobId, info.Species, info.Mutation, info.Model, info.Bay)
end

-- A Calm Treat freezes patience (and the wander-off timer). Bought treats stack, up to a cap,
-- and are banked until the player is washing a tense animal.
local function onCalmTreat(player: any, seconds: any)
	if
		typeof(player) ~= "Instance"
		or not player:IsA("Player")
		or not player.Parent
		or not isFiniteNumber(seconds)
		or seconds <= 0
	then
		return
	end
	calmLeft[player] = math.min((calmLeft[player] or 0) + seconds, TensionConfig.MaxCalmSeconds)
	local state = states[player]
	if state then
		state.Event = "Calmed"
	end
end

-- Studio / place owner only: "shake" empties patience now, "wander" skips the wander-off
-- timer to 5 s. Both start tension on the current wash even inside the grace period.
local function onDevCommand(player: Player, action: any)
	if not isDeveloper(player) or typeof(action) ~= "string" then
		return
	end
	local now = os.clock()
	local last = lastDevAt[player]
	if last and now - last < DEV_COMMAND_INTERVAL then
		return
	end
	lastDevAt[player] = now
	if action ~= "shake" and action ~= "wander" then
		return
	end
	local state = states[player]
	if not state then
		local job = CleaningService.getActiveJob(player)
		local species = job and job.Model:GetAttribute("AnimalKey")
		if not job or typeof(species) ~= "string" then
			return
		end
		local mutation = job.Model:GetAttribute("Mutation")
		startState(
			player,
			job.Id,
			species,
			if typeof(mutation) == "string" then mutation else nil,
			job.Model,
			job.Model.Parent
		)
		state = states[player]
		if not state then
			return
		end
	end
	if action == "shake" then
		state.Patience = 0
	else
		state.WanderLeft = math.min(state.WanderLeft or 5, 5)
	end
end

-- For other features (e.g. Monetization): true while this player's current wash has tension
-- running, i.e. a Calm Treat would take effect right now rather than being banked.
function Tension.isActive(player: Player): boolean
	return states[player] ~= nil
end

function Tension.init()
	stateRemote = Remotes.event("TensionState")
	flingRemote = Remotes.event("TensionFling")
	cameraRemote = Remotes.event("TensionCameraShake")
	announcement = Remotes.event("Announcement")
	Remotes.event("TensionDev").OnServerEvent:Connect(onDevCommand)

	Hooks.on("WashStarted", onWashStarted)
	Hooks.on("WashCompleted", function(player: Player, info: Hooks.WashInfo)
		local state = states[player]
		if state and typeof(info) == "table" and info.JobId == state.JobId then
			endState(player) -- before the celebration hop reads the pivot
		end
	end)
	Hooks.on("CalmTreat", onCalmTreat)

	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(player)
		endState(player)
		calmLeft[player] = nil
		sessionStarted[player] = nil
		lastDevAt[player] = nil
	end)
	if RunService:IsStudio() then
		print("[Dev] K makes the washing animal shake. L skips its wander-off timer to 5 s.")
	end
end

return Tension
