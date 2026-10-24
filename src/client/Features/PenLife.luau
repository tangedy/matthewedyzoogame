-- Pen life: animals in pens wander around inside the fence and play idle animations (look
-- around, graze, tail wag, a happy hop, a dry-off shake, a nap). Client only: the server keeps
-- every pen animal parked on its pen's Slot, and each client moves the parts locally, so
-- nothing replicates and prompts, pads and saves never see it.
--
-- Each animal's rest pose is read once, relative to its pivot, and split into groups: ground
-- (the aura ring stays flat on the floor), body, head (head, neck and everything in front of
-- the neck base), tail and legs. Every frame each nearby animal is posed from that and the
-- whole set is moved with one BulkMoveTo. Animals far from the camera freeze where they are;
-- those past NEAR_DISTANCE are posed every FAR_EVERY frames, and those behind the camera wait.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AnimalGait = require(ReplicatedStorage.Shared.AnimalGait)
local AnimalSounds = require(ReplicatedStorage.Shared.AnimalSounds)

local player = Players.LocalPlayer

local PenLife = {}

local SCAN_SECONDS = 1
local ACTIVE_DISTANCE = 160 -- studs from the camera
local NEAR_DISTANCE = 70 -- closer than this, posed every frame
local FAR_EVERY = 3 -- frames between poses further out (staggered per animal)
local BEHIND_MARGIN = 20 -- studs behind the camera plane before an animal stops being posed
local WALL_MARGIN = 0.6 -- kept clear of the fence
local TURN_SPEED = math.rad(200) -- radians per second
local LEG_SWING = math.rad(28)
local NOTICE_DISTANCE = 14 -- the local player this close gets looked at (and sometimes a hop)
local CROWDED_YAW = 0.35 -- radians either way, for animals too long to turn round in their pen
local CALL_DISTANCE = 45 -- pen animals only call out this close to the camera
local CALL_GAP = 6 -- seconds between calls from any pen, so a full zoo isn't a din
local DROPLETS = ColorSequence.new(Color3.fromRGB(200, 235, 255), Color3.fromRGB(120, 200, 255))

local GROUND, BODY, HEAD, TAIL = 0, 1, 2, 3
local LEG = 10 -- group LEG + i swings with leg i

type Leg = { Hip: Vector3, Phase: number }
type Rig = {
	Parts: { BasePart },
	Rest: { CFrame }, -- pivot space
	Group: { number },
	Legs: { Leg },
	NeckBase: Vector3,
	TailBase: Vector3,
	HasHead: boolean,
	HasTail: boolean,
	HalfX: number, -- footprint half extents at rest
	HalfZ: number,
	LegLength: number,
	Stride: number,
}
type Life = {
	Model: Model,
	Pen: Model,
	Slot: BasePart,
	Floor: BasePart,
	Rig: Rig,
	Rng: Random,
	HomeY: number, -- the pivot's height above the slot
	X: number, -- slot space
	Z: number,
	Yaw: number,
	State: string,
	Clock: number, -- seconds into the current state
	Length: number, -- seconds the current state lasts
	TargetX: number,
	TargetZ: number,
	TargetYaw: number,
	Travelled: number,
	Gait: number, -- 0 standing .. 1 walking, eased so legs never snap
	HeadYaw: number,
	HeadPitch: number,
	Sink: number,
	Wag: number, -- tail wag strength, eased
	WagUntil: number,
	LookSide: number,
	Napped: number, -- os.clock() of the last nap
	Zzz: BillboardGui?,
	Droplets: ParticleEmitter?,
	Pending: number, -- seconds not yet stepped (far animals step every few frames)
	Stagger: number,
}

local lives: { [Model]: Life } = {}
local lastCall = 0

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Exponential ease toward a target, frame-rate independent.
local function approach(current: number, target: number, rate: number, dt: number): number
	return lerp(current, target, 1 - math.exp(-rate * dt))
end

local function wrapAngle(angle: number): number
	return (angle + math.pi) % (2 * math.pi) - math.pi
end

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Half extents of a part's box in the frame its rest CFrame is given in.
local function extents(rest: CFrame, size: Vector3): Vector3
	local half = size / 2
	local r, u, l = rest.RightVector, rest.UpVector, rest.LookVector
	return Vector3.new(
		math.abs(r.X) * half.X + math.abs(u.X) * half.Y + math.abs(l.X) * half.Z,
		math.abs(r.Y) * half.X + math.abs(u.Y) * half.Y + math.abs(l.Y) * half.Z,
		math.abs(r.Z) * half.X + math.abs(u.Z) * half.Y + math.abs(l.Z) * half.Z
	)
end

local function isLegPart(part: BasePart): boolean
	return part.Name == "Hoof" or part.Name == "Foot" or part:GetAttribute("LegPart") == true
end

-- Reads the rest pose. Must run while the model still stands where the server put it.
local function buildRig(model: Model): Rig?
	local pivot = model:GetPivot()
	local parts: { BasePart } = {}
	local rest: { CFrame } = {}
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			table.insert(parts, inst)
			table.insert(rest, pivot:ToObjectSpace(inst.CFrame))
		end
	end
	if #parts == 0 then
		return nil
	end

	local rig: Rig = {
		Parts = parts,
		Rest = rest,
		Group = table.create(#parts, BODY),
		Legs = {},
		NeckBase = Vector3.zero,
		TailBase = Vector3.zero,
		HasHead = false,
		HasTail = false,
		HalfX = 0.5,
		HalfZ = 0.5,
		LegLength = 0,
		Stride = 1.2,
	}

	local body = model:FindFirstChild("Body")
	local head = model:FindFirstChild("Head")
	local neck = model:FindFirstChild("Neck")
	local bodyRest = if body and body:IsA("BasePart") then pivot:ToObjectSpace(body.CFrame) else nil
	local headRest = if head and head:IsA("BasePart") then pivot:ToObjectSpace(head.CFrame) else nil
	local bodyFront, bodyBack, bodyTop = 0, 0, 0
	if bodyRest and body and body:IsA("BasePart") then
		local e = extents(bodyRest, body.Size)
		bodyFront = bodyRest.Position.Z - e.Z
		bodyBack = bodyRest.Position.Z + e.Z
		bodyTop = bodyRest.Position.Y + e.Y
	end

	-- Legs first: their hips are the swing pivots, and feet join the nearest leg.
	local legIndexOf: { [BasePart]: number } = {}
	for i, part in parts do
		if part.Name == "Leg" then
			local r = rest[i]
			rig.LegLength = math.max(rig.LegLength, part.Size.Y)
			table.insert(rig.Legs, { Hip = (r * CFrame.new(0, part.Size.Y / 2, 0)).Position, Phase = 0 })
			legIndexOf[part] = #rig.Legs
			rig.Group[i] = LEG + #rig.Legs
		end
	end
	for _, leg in rig.Legs do
		local front = leg.Hip.Z < (if bodyRest then bodyRest.Position.Z else 0)
		local left = leg.Hip.X < 0
		leg.Phase = if #rig.Legs == 2 then (if left then 0 else math.pi) elseif front == left then 0 else math.pi
	end
	rig.Stride = math.max(rig.LegLength * 2.2, 1.2)

	-- Ahead of the body's front face (and above its belly) is head: eyes, ears, beaks, horns.
	-- Upright animals (penguins) have the head on top, so they get no separate head.
	local headMinY = 0
	if headRest and bodyRest and head and head:IsA("BasePart") and headRest.Position.Z < bodyFront + 0.05 then
		rig.HasHead = true
		if neck and neck:IsA("BasePart") then
			local neckRest = pivot:ToObjectSpace(neck.CFrame)
			rig.NeckBase = (neckRest * CFrame.new(0, -neck.Size.Y / 2, 0)).Position
		else
			rig.NeckBase = Vector3.new(0, math.min(bodyTop, headRest.Position.Y), bodyFront)
		end
		-- Down to just under the jaw (beards, snouts), or the neck's foot for manes.
		local headBottom = headRest.Position.Y - extents(headRest, head.Size).Y
		headMinY = math.min(headBottom - 0.5, rig.NeckBase.Y - 0.2)
	end

	local tailNearest = math.huge
	for i, part in parts do
		local c = rest[i].Position
		if part.Name == "AuraRing" or part.Name == "AuraBase" then
			rig.Group[i] = GROUND
		elseif legIndexOf[part] then
			continue
		elseif isLegPart(part) then
			local best, bestDist = nil, math.huge
			for index, leg in rig.Legs do
				local d = Vector2.new(c.X - leg.Hip.X, c.Z - leg.Hip.Z).Magnitude
				if d < bestDist then
					best, bestDist = index, d
				end
			end
			if best then
				rig.Group[i] = LEG + best
			end
		elseif string.sub(part.Name, 1, 4) == "Tail" then
			rig.Group[i] = TAIL
			rig.HasTail = true
			if c.Z < tailNearest then
				tailNearest = c.Z
				rig.TailBase = Vector3.new(0, c.Y, math.min(bodyBack, c.Z))
			end
		elseif rig.HasHead and (part == head or part == neck or (c.Z < rig.NeckBase.Z and c.Y > headMinY)) then
			rig.Group[i] = HEAD
		end
		if rig.Group[i] ~= GROUND then
			local e = extents(rest[i], part.Size)
			rig.HalfX = math.max(rig.HalfX, math.abs(c.X) + e.X)
			rig.HalfZ = math.max(rig.HalfZ, math.abs(c.Z) + e.Z)
		end
	end
	return rig
end

-- Where the animal may stand, in slot space, and whether it has room to turn round.
local function bounds(life: Life): (number, number, number, number, boolean)
	local floorInSlot = life.Slot.CFrame:ToObjectSpace(life.Floor.CFrame)
	local f = extents(floorInSlot, life.Floor.Size)
	local c = floorInSlot.Position
	local rig = life.Rig
	local radius = math.sqrt(rig.HalfX * rig.HalfX + rig.HalfZ * rig.HalfZ)
	local free = radius + WALL_MARGIN <= math.min(f.X, f.Z)
	local rx = if free then radius else rig.HalfX + math.sin(CROWDED_YAW) * rig.HalfZ
	local rz = if free then radius else rig.HalfZ
	local minX, maxX = c.X - f.X + WALL_MARGIN + rx, c.X + f.X - WALL_MARGIN - rx
	local minZ, maxZ = c.Z - f.Z + WALL_MARGIN + rz, c.Z + f.Z - WALL_MARGIN - rz
	if minX > maxX or not free then
		minX, maxX = 0, 0 -- too long to turn round: it only shuffles forward and back
	end
	if minZ > maxZ then
		minZ, maxZ = 0, 0
	end
	return minX, maxX, minZ, maxZ, free
end

local function clampYaw(life: Life, yaw: number): number
	local _, _, _, _, free = bounds(life)
	return if free then yaw else math.clamp(wrapAngle(yaw), -CROWDED_YAW, CROWDED_YAW)
end

-- Somewhere new in the pen, as far as it can find from any penmate.
local function pickTarget(life: Life): (number, number)
	local minX, maxX, minZ, maxZ = bounds(life)
	local bestX, bestZ, bestScore = life.X, life.Z, -math.huge
	for _ = 1, 6 do
		local x = life.Rng:NextNumber(minX, maxX)
		local z = life.Rng:NextNumber(minZ, maxZ)
		local score = math.min(Vector2.new(x - life.X, z - life.Z).Magnitude, 6)
		for other, otherLife in lives do
			if other ~= life.Model and otherLife.Pen == life.Pen then
				local d = Vector2.new(x - otherLife.TargetX, z - otherLife.TargetZ).Magnitude
				score += math.min(d, 8) * 1.5
			end
		end
		if score > bestScore then
			bestX, bestZ, bestScore = x, z, score
		end
	end
	return bestX, bestZ
end

-- The local player's position in this animal's slot space, when they are close.
local function nearbyPlayer(life: Life): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local here = life.Slot.CFrame * Vector3.new(life.X, 0, life.Z)
	if (root.Position - here).Magnitude > NOTICE_DISTANCE then
		return nil
	end
	return life.Slot.CFrame:PointToObjectSpace(root.Position)
end

-- Yaw (slot space) that faces a point. The model faces -Z.
local function yawToward(life: Life, x: number, z: number): number
	local dx, dz = x - life.X, z - life.Z
	return math.atan2(-dx, -dz)
end

local function setZzz(life: Life, on: boolean)
	if on and not life.Zzz then
		local head = life.Model:FindFirstChild("Head")
		if not head or not head:IsA("BasePart") then
			return
		end
		local gui = Instance.new("BillboardGui")
		gui.Name = "NapZzz"
		gui.Size = UDim2.fromOffset(70, 40)
		gui.StudsOffset = Vector3.new(0.8, head.Size.Y / 2 + 1, 0)
		gui.MaxDistance = 70
		gui.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(220, 235, 255)
		label.TextStrokeTransparency = 0.2
		label.TextStrokeColor3 = Color3.fromRGB(40, 50, 90)
		label.Text = "z"
		label.Parent = gui
		gui.Parent = head
		life.Zzz = gui
	elseif not on and life.Zzz then
		life.Zzz:Destroy()
		life.Zzz = nil
	end
end

local function shakeDroplets(life: Life)
	if not life.Droplets then
		local body = life.Model:FindFirstChild("Body")
		if not body or not body:IsA("BasePart") then
			return
		end
		local e = Instance.new("ParticleEmitter")
		e.Name = "ShakeDroplets"
		e.Enabled = false
		e.Rate = 0
		e.Color = DROPLETS
		e.LightEmission = 0.3
		e.Size = NumberSequence.new(0.25, 0)
		e.Transparency = NumberSequence.new(0.1, 0.6)
		e.Lifetime = NumberRange.new(0.4, 0.7)
		e.Speed = NumberRange.new(6, 10)
		e.SpreadAngle = Vector2.new(70, 20)
		e.EmissionDirection = Enum.NormalId.Right
		e.Shape = Enum.ParticleEmitterShape.Box
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		e.Acceleration = Vector3.new(0, -30, 0)
		e.Parent = body
		life.Droplets = e
	end
	local e = life.Droplets :: ParticleEmitter
	e.EmissionDirection = Enum.NormalId.Right
	e:Emit(10)
	e.EmissionDirection = Enum.NormalId.Left
	e:Emit(10)
end

-- Now and then a nearby animal calls out as it hops or looks round. One call at a time
-- across every pen.
local function maybeCall(life: Life)
	local camera = Workspace.CurrentCamera
	local head = life.Model:FindFirstChild("Head") or life.Model:FindFirstChild("Body")
	local species = life.Model:GetAttribute("AnimalKey")
	if
		not camera
		or not head
		or typeof(species) ~= "string"
		or os.clock() - lastCall < CALL_GAP
		or (life.Slot.Position - camera.CFrame.Position).Magnitude > CALL_DISTANCE
		or life.Rng:NextNumber() > 0.5
	then
		return
	end
	lastCall = os.clock()
	AnimalSounds.play(species, head, 0.6)
end

local function enter(life: Life, state: string, length: number)
	life.State = state
	life.Clock = 0
	life.Length = length
	setZzz(life, state == "Nap")
	if state == "Hop" or state == "Look" then
		maybeCall(life)
	end
end

-- Weighted pick of what to do next.
local function nextState(life: Life)
	local rng = life.Rng
	local rig = life.Rig
	local seen = nearbyPlayer(life)
	if seen and rng:NextNumber() < 0.4 then
		life.TargetYaw = clampYaw(life, yawToward(life, seen.X, seen.Z))
		life.TargetX, life.TargetZ = life.X, life.Z
		enter(life, if rng:NextNumber() < 0.5 then "Hop" else "Turn", 0.9)
		life.WagUntil = os.clock() + 2.5
		return
	end
	local options = {
		{ "Walk", 34 },
		{ "Stand", 18 },
		{ "Look", 12 },
		{ "Graze", if rig.HasHead then 12 else 0 },
		{ "Hop", 5 },
		{ "Shake", 5 },
		{ "Nap", if os.clock() - life.Napped > 40 and rig.LegLength > 0 then 4 else 0 },
	}
	local total = 0
	for _, option in options do
		total += option[2]
	end
	local roll = rng:NextNumber(0, total)
	local pick = "Stand"
	for _, option in options do
		roll -= option[2]
		if roll <= 0 then
			pick = option[1]
			break
		end
	end

	if pick == "Walk" then
		life.TargetX, life.TargetZ = pickTarget(life)
		if Vector2.new(life.TargetX - life.X, life.TargetZ - life.Z).Magnitude < 0.8 then
			-- No room to walk: turn on the spot instead.
			life.TargetYaw = clampYaw(life, life.Yaw + rng:NextNumber(-1.2, 1.2))
			enter(life, "Turn", 1.2)
		else
			life.TargetYaw = clampYaw(life, yawToward(life, life.TargetX, life.TargetZ))
			enter(life, "Walk", 12)
		end
	elseif pick == "Look" then
		life.LookSide = if rng:NextNumber() < 0.5 then -1 else 1
		if rig.HasHead then
			enter(life, "Look", rng:NextNumber(2.4, 3.4))
		else
			life.TargetYaw = clampYaw(life, life.Yaw + life.LookSide * rng:NextNumber(0.5, 1.2))
			enter(life, "Turn", 1.2)
		end
	elseif pick == "Graze" then
		enter(life, "Graze", rng:NextNumber(3, 5.5))
	elseif pick == "Hop" then
		life.TargetYaw = life.Yaw
		enter(life, "Hop", 0.9)
		life.WagUntil = os.clock() + 2
	elseif pick == "Shake" then
		enter(life, "Shake", 0.9)
		shakeDroplets(life)
	elseif pick == "Nap" then
		life.Napped = os.clock()
		enter(life, "Nap", rng:NextNumber(7, 12))
	else
		enter(life, "Stand", rng:NextNumber(1.5, 4))
		if rng:NextNumber() < 0.35 then
			life.WagUntil = os.clock() + rng:NextNumber(1, 2.5)
		end
	end
end

local function turnToward(life: Life, dt: number): number
	local diff = wrapAngle(life.TargetYaw - life.Yaw)
	local step = math.clamp(diff, -TURN_SPEED * dt, TURN_SPEED * dt)
	life.Yaw += step
	return math.abs(diff - step)
end

-- Advances the behaviour and returns the body offset (bob, pitch, roll) for this frame.
local function step(life: Life, dt: number): (number, number, number)
	local rig = life.Rig
	life.Clock += dt
	local t = life.Clock
	local state = life.State
	local bob, pitch, roll = 0, 0, 0
	local walking = false
	local headYaw, headPitch, sink = 0, 0, 0
	local scale = math.max(rig.LegLength, 0.6)

	if state == "Walk" then
		local left = turnToward(life, dt)
		if left < 0.5 then
			local dx, dz = life.TargetX - life.X, life.TargetZ - life.Z
			local dist = math.sqrt(dx * dx + dz * dz)
			local speed = math.clamp(rig.Stride * 1.5, 1.6, 4)
			local move = math.min(dist, speed * dt * (1 - left))
			if dist > 1e-3 then
				life.X += dx / dist * move
				life.Z += dz / dist * move
				life.Travelled += move
			end
			walking = true
			if dist - move < 0.05 then
				enter(life, "Stand", life.Rng:NextNumber(1, 3))
			end
		end
	elseif state == "Turn" then
		if turnToward(life, dt) < 0.02 and t > 0.3 then
			enter(life, "Stand", life.Rng:NextNumber(0.8, 2))
		end
	elseif state == "Look" then
		-- One side, the other, then back to the middle.
		local u = t / life.Length
		local side = life.LookSide
		local angle = if u < 0.4
			then side * smooth(u / 0.15)
			elseif u < 0.8 then side * lerp(1, -1, smooth((u - 0.4) / 0.15))
			else -side * (1 - smooth((u - 0.8) / 0.15))
		headYaw = angle * 0.6
		headPitch = math.sin(t * 1.3) * 0.06
	elseif state == "Graze" then
		local down = smooth(t / 0.5) * (1 - smooth((t - life.Length + 0.5) / 0.5))
		headPitch = -0.55 * down + math.sin(t * 9) * 0.05 * down
		headYaw = math.sin(t * 0.7) * 0.15 * down
	elseif state == "Hop" then
		turnToward(life, dt)
		local u = t / life.Length
		local hop = math.abs(math.sin(u * math.pi * 2))
		bob = hop * math.clamp(scale * 0.5, 0.4, 1)
		pitch = math.cos(u * math.pi * 4) * 0.08 * hop
	elseif state == "Shake" then
		local fade = 1 - t / life.Length
		roll = math.sin(t * 42) * 0.14 * fade
		headYaw = -math.sin(t * 42) * 0.25 * fade
	elseif state == "Nap" then
		local down = smooth(t / 0.9) * (1 - smooth((t - life.Length + 0.9) / 0.9))
		sink = rig.LegLength * 0.6 * down
		headPitch = -0.22 * down
		bob = math.sin(t * 1.6) * 0.05 * down
		if life.Zzz then
			local label = life.Zzz:FindFirstChildOfClass("TextLabel")
			if label then
				label.Text = ({ "z", "z z", "z z Z" })[math.floor(t / 0.6) % 3 + 1]
			end
		end
	else
		-- Standing: a slow breath.
		bob = math.sin(t * 2.2) * 0.025
	end

	if life.State == state and t >= life.Length then
		nextState(life)
	end

	life.Gait = approach(life.Gait, if walking then 1 else 0, 10, dt)
	if walking then
		bob += math.abs(math.sin(life.Travelled / rig.Stride * math.pi * 2)) * math.min(0.15, scale * 0.12)
	end
	life.HeadYaw = approach(life.HeadYaw, headYaw, 8, dt)
	life.HeadPitch = approach(life.HeadPitch, headPitch, 8, dt)
	life.Sink = sink
	life.Wag = approach(life.Wag, if os.clock() < life.WagUntil or walking then 1 else 0, 5, dt)
	return bob - sink, pitch, roll
end

local parts: { BasePart } = {}
local frames: { CFrame } = {}

local function pose(life: Life, bob: number, pitch: number, roll: number)
	local rig = life.Rig
	local base = life.Slot.CFrame * CFrame.new(life.X, life.HomeY, life.Z) * CFrame.Angles(0, life.Yaw, 0)
	local body = base * CFrame.new(0, bob, 0) * CFrame.Angles(pitch, 0, roll)
	local nb = rig.NeckBase
	local head = body
		* CFrame.new(nb)
		* CFrame.Angles(0, life.HeadYaw, 0)
		* CFrame.Angles(life.HeadPitch, 0, 0)
		* CFrame.new(-nb)
	local tb = rig.TailBase
	local wag = math.sin(os.clock() * 11) * 0.35 * life.Wag
	local tail = body * CFrame.new(tb) * CFrame.Angles(0, wag, 0) * CFrame.new(-tb)
	local legs: { CFrame } = {}
	local cycle = life.Travelled / rig.Stride * math.pi * 2
	for i, leg in rig.Legs do
		local angle = math.sin(cycle + leg.Phase) * LEG_SWING * life.Gait
		legs[i] = body * CFrame.new(leg.Hip) * CFrame.Angles(angle, 0, 0) * CFrame.new(-leg.Hip)
	end
	for i, part in rig.Parts do
		local group = rig.Group[i]
		local frame = if group == GROUND
			then base
			elseif group == HEAD then head
			elseif group == TAIL then tail
			elseif group >= LEG then legs[group - LEG] or body
			else body
		table.insert(parts, part)
		table.insert(frames, frame * rig.Rest[i])
	end
end

local function track(model: Model, pen: Model)
	if CollectionService:HasTag(model, AnimalGait.TAG) then
		return -- WalkReplay is walking it; picked up on a later scan once it stands on its slot
	end
	local slot = pen:FindFirstChild("Slot")
	local floor = pen:FindFirstChild("Floor")
	if not slot or not slot:IsA("BasePart") or not floor or not floor:IsA("BasePart") then
		return
	end
	-- Rest offsets are taken against the slot the server parked it on.
	local home = slot.CFrame:ToObjectSpace(model:GetPivot())
	if Vector2.new(home.X, home.Z).Magnitude > 0.5 then
		return
	end
	local rig = buildRig(model)
	if not rig then
		return
	end
	local rng = Random.new()
	local life: Life = {
		Model = model,
		Pen = pen,
		Slot = slot,
		Floor = floor,
		Rig = rig,
		Rng = rng,
		HomeY = home.Y,
		X = home.X,
		Z = home.Z,
		Yaw = 0,
		State = "Stand",
		Clock = 0,
		Length = rng:NextNumber(0.5, 3), -- staggered so a row of pens doesn't move in step
		TargetX = home.X,
		TargetZ = home.Z,
		TargetYaw = 0,
		Travelled = 0,
		Gait = 0,
		HeadYaw = 0,
		HeadPitch = 0,
		Sink = 0,
		Wag = 0,
		WagUntil = 0,
		LookSide = 1,
		Napped = os.clock() - rng:NextNumber(0, 40),
		Zzz = nil,
		Droplets = nil,
		Pending = 0,
		Stagger = rng:NextInteger(0, FAR_EVERY * 2 - 1), -- spread for low detail too
	}
	-- The server parks it on the slot's own facing, which is yaw 0.
	local look = home.LookVector
	life.Yaw = math.atan2(-look.X, -look.Z)
	life.TargetYaw = life.Yaw
	lives[model] = life
end

-- Stops animating it and, if it is still around, stands it back on its slot at rest so a
-- later look at it reads a clean rest pose.
local function untrack(model: Model)
	local life = lives[model]
	if not life then
		return
	end
	lives[model] = nil
	setZzz(life, false)
	if life.Droplets then
		life.Droplets:Destroy()
	end
	local home = life.Slot.CFrame * CFrame.new(0, life.HomeY, 0)
	for i, part in life.Rig.Parts do
		if part.Parent then
			part.CFrame = home * life.Rig.Rest[i]
		end
	end
end

local function scan()
	for model, life in lives do
		if model.Parent ~= life.Pen or not life.Pen:IsDescendantOf(Workspace) then
			untrack(model)
		end
	end
	local bays = Workspace:FindFirstChild("WashBays")
	if not bays then
		return
	end
	for _, bay in bays:GetChildren() do
		local zoo = bay:FindFirstChild("Zoo")
		if not zoo then
			continue
		end
		for _, pen in zoo:GetChildren() do
			if not pen:IsA("Model") then
				continue
			end
			for _, child in pen:GetChildren() do
				if child.Name == "ZooAnimal" and child:IsA("Model") and not lives[child] then
					track(child, pen)
				end
			end
		end
	end
end

-- Low detail (Performance, on slow machines): fewer animals animated, and less often.
local activeDistance, nearDistance, farEvery = ACTIVE_DISTANCE, NEAR_DISTANCE, FAR_EVERY
function PenLife.setLowDetail(low: boolean)
	activeDistance = if low then ACTIVE_DISTANCE * 0.5 else ACTIVE_DISTANCE
	nearDistance = if low then NEAR_DISTANCE * 0.5 else NEAR_DISTANCE
	farEvery = if low then FAR_EVERY * 2 else FAR_EVERY
end

-- For WalkReplay: stop animating this animal and stand it at rest before a walk starts.
function PenLife.release(model: Model)
	untrack(model)
end

function PenLife.init(_initial: any)
	task.spawn(function()
		while true do
			local ok, err = pcall(scan)
			if not ok then
				warn(`[PenLife] scan failed: {err}`)
			end
			task.wait(SCAN_SECONDS)
		end
	end)

	local frame = 0
	RunService.Heartbeat:Connect(function(dt: number)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local eye = camera.CFrame.Position
		local look = camera.CFrame.LookVector
		frame += 1
		table.clear(parts)
		table.clear(frames)
		for model, life in lives do
			if not model.Parent or not life.Slot.Parent then
				continue
			end
			local offset = life.Slot.Position - eye
			local distance = offset.Magnitude
			if distance > activeDistance or offset:Dot(look) < -BEHIND_MARGIN then
				life.Pending = 0
				continue
			end
			life.Pending += dt
			if distance > nearDistance and (frame + life.Stagger) % farEvery ~= 0 then
				continue
			end
			local bob, pitch, roll = step(life, math.min(life.Pending, 0.1))
			life.Pending = 0
			pose(life, bob, pitch, roll)
		end
		if #parts > 0 then
			Workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end)
end

return PenLife
