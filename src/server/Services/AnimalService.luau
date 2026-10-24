-- Animal selection, spawning, scripted movement, celebration, carrying, and disposal.
-- Movement functions yield; BayService runs them inside the bay's thread so that
-- cancelling the thread (owner left) stops them with nothing left connected.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local AnimalBuilder = require(script.Parent.AnimalBuilder)
local CleanGateService = require(script.Parent.CleanGateService)
local DirtRenderer = require(script.Parent.DirtRenderer)
local Hooks = require(script.Parent.Hooks)
local MutationPayout = require(script.Parent.MutationPayout)

local AnimalService = {}

export type SpawnLook = {
	Scale: number?,
	Name: string?,
	Income: number?,
	Rarity: string?,
}

local rng = Random.new()

-- Entries with weight 0 (e.g. Limited animals) are never picked.
local function weightedPick<T>(entries: { T }, weightOf: (T) -> number): T?
	local weights = {}
	local total = 0
	for i, entry in entries do
		weights[i] = math.max(0, weightOf(entry))
		total += weights[i]
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber(0, total)
	local last: T? = nil
	for i, entry in entries do
		if weights[i] > 0 then
			last = entry
			roll -= weights[i]
			if roll <= 0 then
				return entry
			end
		end
	end
	return last
end

-- A random walk-in species of one rarity (the opening washes use this). Never a Limited one.
function AnimalService.randomOfRarity(rarityKey: string): string
	local pool = {}
	for key, def in AnimalConfig.Animals do
		if
			def.Rarity == rarityKey
			and def.SpawnWeight > 0
			and not def.Limited
			and AnimalBuilder.has(def.TemplateName)
		then
			table.insert(pool, key)
		end
	end
	table.sort(pool)
	if #pool == 0 then
		return AnimalConfig.FallbackAnimal
	end
	return pool[rng:NextInteger(1, #pool)]
end

-- Walk-ins come from the weighted pool of species the player's hose has the clean power to
-- wash. Rarities that still need Clean Now are mixed in by CleanGateService, with their
-- chance taken from Common.
function AnimalService.pickNext(toolTier: number, player: Player?): string
	local tool = ToolConfig[toolTier]
	local base = if tool then tool.CleaningPower else 0
	local power = if player then CleanGateService.washPower(player, toolTier) else base
	local weights: { [string]: number } = {}
	for key, def in AnimalConfig.Animals do
		-- Tool tier is the usual gate. Super Soap can also wash the next tier, and those
		-- animals join the normal pool instead of the Clean Now chances.
		local unlocked = def.RequiredToolTier <= toolTier and CleanPower.canClean(base, def.Rarity)
		if
			(unlocked or CleanPower.canClean(power, def.Rarity))
			and def.SpawnWeight > 0
			and not def.Limited
			and AnimalBuilder.has(def.TemplateName)
		then
			local weight = def.SpawnWeight
			weights[key] = if player then math.max(0, Hooks.apply("SpawnWeight", weight, player, key)) else weight
		end
	end
	if player then
		weights = CleanGateService.mix(player, weights, power)
	end
	local pool = {}
	for key in weights do
		table.insert(pool, key)
	end
	table.sort(pool)
	return weightedPick(pool, function(key)
		return weights[key]
	end) or AnimalConfig.FallbackAnimal
end

-- Weighted mutation roll, then LiveOps may replace it (hidden gold/rainbow odds, events).
-- The very first animal of a brand-new profile stays Normal; that rule lives in the hook.
function AnimalService.pickMutation(isFirst: boolean, player: Player?): string
	local key = MutationConfig.Default
	if not isFirst then
		local picked = weightedPick(MutationConfig.List, function(m)
			return if player then math.max(0, Hooks.apply("MutationWeight", m.Weight, player, m.Key)) else m.Weight
		end)
		key = if picked then picked.Key else MutationConfig.Default
	end
	if player then
		local override = Hooks.apply("MutationPick", key, player, isFirst)
		if typeof(override) == "string" and MutationConfig.ByKey[override] then
			return override
		end
	end
	return key
end

local function income(animalKey: string, mutationKey: string): number
	return AnimalConfig.Animals[animalKey].Income * MutationPayout.multiplier(mutationKey)
end

local function addNameplate(
	model: Model,
	animalKey: string,
	mutationKey: string,
	maxDistance: number,
	look: SpawnLook?,
	needs: string?
)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local def = AnimalConfig.Animals[animalKey]
	UIStyle.nameplate(head, {
		Name = if look and look.Name then look.Name else def.DisplayName,
		Rarity = if look and look.Rarity then look.Rarity else def.Rarity,
		Mutation = mutationKey,
		IncomePerSecond = if look and look.Income then look.Income else income(animalKey, mutationKey),
		Needs = needs,
	}, maxDistance)
end

-- Display scale for this species at the wash and in a pen (GameConfig.BodyScale).
function AnimalService.bodyScale(animalKey: string): number
	local def = AnimalConfig.Animals[animalKey]
	local scale = def and GameConfig.BodyScale[def.BodyClass]
	return if typeof(scale) == "number" and scale > 0 then scale else 1
end

-- Scales a model to its pen size (penned) or back to its built size, shrinking it further
-- when it is longer than maxLength (the cache). Records the result as RestScale.
function AnimalService.resize(model: Model, scale: number, maxLength: number?)
	model:ScaleTo(1)
	local target = scale
	if maxLength then
		local _, size = model:GetBoundingBox()
		local length = math.max(size.X, size.Z)
		if length * target > maxLength then
			target = maxLength / length
		end
	end
	model:SetAttribute("RestScale", target)
	if math.abs(target - 1) > 1e-3 then
		model:ScaleTo(target)
	end
end

-- A clean, idle animal for a pen or the cache.
function AnimalService.buildZooAnimal(animalKey: string, mutationKey: string): Model
	local def = AnimalConfig.Animals[animalKey]
	local model = AnimalBuilder.build(def.TemplateName, { Mutation = mutationKey, Rarity = def.Rarity, Clean = true })
	model:SetAttribute("AnimalKey", animalKey)
	DirtRenderer.setGrime(model, 1)
	addNameplate(model, animalKey, mutationKey, 60)
	return model
end

-- The animal in the player's left hand at full size, tipped nose-up at Cache.CarryTilt degrees,
-- its rear resting at the hand. Welded to the root part (not the hand) so the walk animation
-- doesn't swing a cow around.
function AnimalService.buildCarryModel(animalKey: string, mutationKey: string, hand: BasePart): Model
	local model = AnimalService.buildZooAnimal(animalKey, mutationKey)
	model.Name = "CarriedAnimal"
	-- The rarity aura's ground ring belongs on the ground, not tipped up in a hand.
	for _, name in { "AuraRing", "AuraBase" } do
		local part = model:FindFirstChild(name)
		if part then
			part:Destroy()
		end
	end
	local character = hand.Parent :: Model
	local anchor = (character:FindFirstChild("HumanoidRootPart") or hand) :: BasePart
	local root = model.PrimaryPart :: BasePart

	local boxCFrame, size = model:GetBoundingBox()
	local center = model:GetPivot():PointToObjectSpace(boxCFrame.Position)
	local rear = center + Vector3.new(0, -size.Y / 2, size.Z / 2) -- rear-bottom, model space (faces -Z)
	local grip = anchor.CFrame * CFrame.new(-1.6, -0.6, -1.2) -- where the left hand holds it
	local tilt = CFrame.Angles(math.rad(GameConfig.Cache.CarryTilt), 0, 0)
	model:PivotTo(CFrame.new(grip.Position) * anchor.CFrame.Rotation * tilt * CFrame.new(-rear))

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.Massless = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			if part ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = root
	weld.Parent = root
	model.Parent = character
	return model
end

-- Sold or swapped out: a puff of sparkles, then gone.
function AnimalService.poof(model: Model)
	local body = model:FindFirstChild("Body")
	if body and body:IsA("BasePart") then
		local attachment = Instance.new("Attachment")
		attachment.WorldPosition = body.Position
		local emitter = Instance.new("ParticleEmitter")
		emitter.Enabled = false
		emitter.Speed = NumberRange.new(4, 8)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Lifetime = NumberRange.new(0.5, 0.9)
		emitter.Size = NumberSequence.new(0.8, 0)
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
		emitter.Parent = attachment
		attachment.Parent = Workspace.Terrain
		emitter:Emit(25)
		Debris:AddItem(attachment, 1.5)
	end
	model:Destroy()
end

-- Cash burst and chime when a collect pad pays out.
function AnimalService.collectEffect(pad: BasePart)
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = pad.Position
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Speed = NumberRange.new(5, 9)
	emitter.SpreadAngle = Vector2.new(30, 30)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(0, -25, 0)
	emitter.Lifetime = NumberRange.new(0.6, 0.9)
	emitter.Size = NumberSequence.new(0.5, 0.2)
	emitter.Color = ColorSequence.new(UIStyle.CashColor)
	emitter.Parent = attachment
	local sound = Instance.new("Sound")
	sound.SoundId = GameConfig.Sounds.Complete
	sound.PlaybackSpeed = 1.4
	sound.Volume = 0.5
	sound.Parent = attachment
	attachment.Parent = Workspace.Terrain
	emitter:Emit(18)
	sound:Play()
	Debris:AddItem(attachment, 1.5)
end

function AnimalService.spawn(
	animalKey: string,
	mutationKey: string,
	jobId: string,
	at: CFrame,
	parent: Instance,
	look: SpawnLook?
)
	local def = AnimalConfig.Animals[animalKey]
	local model, patches = AnimalBuilder.build(def.TemplateName, { Mutation = mutationKey, Rarity = def.Rarity })
	model:SetAttribute("JobId", jobId)
	model:SetAttribute("AnimalKey", animalKey)
	DirtRenderer.setGrime(model, 0) -- arrives filthy
	local scale = if look and look.Scale and look.Scale > 0 then look.Scale else AnimalService.bodyScale(animalKey)
	if math.abs(scale - 1) > 1e-3 then
		model:SetAttribute("RestScale", scale)
		model:ScaleTo(scale)
	end
	model:PivotTo(at)

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "Sparkle"
	sparkle.Enabled = false
	sparkle.Rate = 0
	sparkle.Lifetime = NumberRange.new(0.6, 1.0)
	sparkle.Speed = NumberRange.new(6, 10)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Size = NumberSequence.new(0.5, 0)
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 250, 200), Color3.fromRGB(150, 220, 255))
	sparkle.LightEmission = 1
	sparkle.Parent = model:FindFirstChild("Body")

	local sound = Instance.new("Sound")
	sound.Name = "CompleteSound"
	sound.SoundId = GameConfig.Sounds.Complete
	sound.Volume = 0.6
	sound.Parent = model:FindFirstChild("Body")

	addNameplate(model, animalKey, mutationKey, 80, look, CleanPower.gearNeeded(def.Rarity, def.RequiresSoap))

	model.Parent = parent

	-- Rarer tiers and any mutation get a reveal as they walk in.
	local rarity = RarityConfig.ByKey[def.Rarity]
	local mutated = mutationKey ~= MutationConfig.Default
	if rarity.Order > 2 or mutated then
		sparkle.Color = ColorSequence.new(rarity.Color) -- the completion sparkle keeps this colour too
		sparkle:Emit(10 * rarity.Order)
		local reveal = Instance.new("Sound")
		reveal.SoundId = GameConfig.Sounds.Complete
		reveal.PlaybackSpeed = 0.8 + rarity.Order * 0.1
		reveal.Volume = 0.7
		reveal.Parent = model:FindFirstChild("Body")
		reveal:Play()
		Debris:AddItem(reveal, 3)
	end
	return model, patches
end

-- Walk cycle. Each leg (and the hoof or foot under it) swings from the hip while the model
-- moves; diagonal pairs step together, and two-legged animals alternate. Poses are written
-- relative to the pivot every frame, so nothing drifts, and the rest pose comes back at the end.
type LegPose = { Parts: { BasePart }, Rest: { CFrame }, Hip: Vector3, Phase: number }
type Gait = { Legs: { LegPose }, Stride: number, Swing: number, Heavy: boolean, Scale: number }

local BIG_BODIES = { Giant = true, Gargantuan = true }
-- The rest pose is read once per model and size, so two overlapping walks can't record a
-- mid-swing leg as the rest pose.
local gaits: { [Model]: Gait } = setmetatable({}, { __mode = "k" }) :: any

local function gaitOf(model: Model): Gait?
	local cached = gaits[model]
	if cached and math.abs(cached.Scale - model:GetScale()) < 1e-4 then
		return cached
	end
	local pivot = model:GetPivot()
	local legs: { BasePart } = {}
	for _, child in model:GetChildren() do
		if child.Name == "Leg" and child:IsA("BasePart") then
			table.insert(legs, child)
		end
	end
	if #legs == 0 then
		return nil
	end
	-- Hooves, feet, paws, toes and socks: anything tagged LegPart, plus the older names.
	local feet: { BasePart } = {}
	for _, child in model:GetChildren() do
		if
			child:IsA("BasePart")
			and (child:GetAttribute("LegPart") == true or child.Name == "Hoof" or child.Name == "Foot")
		then
			table.insert(feet, child)
		end
	end
	local poses: { LegPose } = {}
	local legLength = 0
	for _, leg in legs do
		local rest = pivot:ToObjectSpace(leg.CFrame)
		local hip = (rest * CFrame.new(0, leg.Size.Y / 2, 0)).Position
		legLength = math.max(legLength, leg.Size.Y)
		local front = rest.Position.Z < 0
		local left = rest.Position.X < 0
		local phase = if #legs == 2 then (if left then 0 else math.pi) elseif front == left then 0 else math.pi
		local pose: LegPose = { Parts = { leg }, Rest = { rest }, Hip = hip, Phase = phase }
		table.insert(poses, pose)
	end
	-- Each foot part swings with the leg it is closest to.
	for _, foot in feet do
		local footRest = pivot:ToObjectSpace(foot.CFrame)
		local best: LegPose? = nil
		local bestDist = math.huge
		for _, pose in poses do
			local offset = footRest.Position - pose.Rest[1].Position
			local dist = Vector2.new(offset.X, offset.Z).Magnitude
			if dist < bestDist then
				best, bestDist = pose, dist
			end
		end
		if best and bestDist < math.max(best.Parts[1].Size.X, best.Parts[1].Size.Z) * 2.5 then
			table.insert(best.Parts, foot)
			table.insert(best.Rest, footRest)
		end
	end
	local key = model:GetAttribute("AnimalKey")
	local def = if typeof(key) == "string" then AnimalConfig.Animals[key] else nil
	local gait: Gait = {
		Legs = poses,
		Stride = math.max(legLength * 2.2, 1.2),
		Swing = math.rad(32),
		Heavy = def ~= nil and BIG_BODIES[def.BodyClass] == true,
		Scale = model:GetScale(),
	}
	gaits[model] = gait
	return gait
end

local function poseLegs(model: Model, gait: Gait, travelled: number)
	local pivot = model:GetPivot()
	local cycle = travelled / gait.Stride * math.pi * 2
	for _, leg in gait.Legs do
		local angle = math.sin(cycle + leg.Phase) * gait.Swing
		local swing = CFrame.new(leg.Hip) * CFrame.Angles(angle, 0, 0) * CFrame.new(-leg.Hip)
		for i, part in leg.Parts do
			part.CFrame = pivot * swing * leg.Rest[i]
		end
	end
end

local function restLegs(model: Model, gait: Gait)
	local pivot = model:GetPivot()
	for _, leg in gait.Legs do
		for i, part in leg.Parts do
			part.CFrame = pivot * leg.Rest[i]
		end
	end
end

-- Big animals bob slowly and heavily: a thud per step instead of a hop.
local function stepBob(gait: Gait?, travelled: number, amplitude: number): number
	if gait and gait.Heavy then
		return math.abs(math.sin(travelled / gait.Stride * math.pi * 2)) * amplitude * 2
	end
	return 0
end

-- Right-angle walk. The animal turns in place at each corner, then walks straight to the
-- next point without spinning on the way. Yields until the last point.
function AnimalService.walkCorners(model: Model, points: { CFrame }, secondsEach: number, bobHeight: number?)
	local gait = gaitOf(model)
	local travelled = 0
	for _, target in points do
		if not model.Parent then
			return
		end
		local here = model:GetPivot().Position
		local flat = Vector3.new(target.Position.X - here.X, 0, target.Position.Z - here.Z)
		if flat.Magnitude < 0.4 then
			continue
		end
		local dir = flat.Unit
		local turnFrom = model:GetPivot()
		local elapsed = 0
		while elapsed < 0.28 and model.Parent do
			elapsed += task.wait()
			local t = math.min(elapsed / 0.28, 1)
			local pos = turnFrom.Position
			model:PivotTo(turnFrom:Lerp(CFrame.lookAt(pos, pos + dir), t))
		end
		local bobAmp = bobHeight or 0.25
		local startPos = model:GetPivot().Position
		local goal = Vector3.new(target.Position.X, startPos.Y, target.Position.Z)
		local span = (goal - startPos).Magnitude
		local startTravel = travelled
		elapsed = 0
		while elapsed < secondsEach and model.Parent do
			elapsed += task.wait()
			local t = math.min(elapsed / secondsEach, 1)
			travelled = startTravel + span * t
			local bob = if gait and gait.Heavy
				then stepBob(gait, travelled, bobAmp)
				else math.abs(math.sin(elapsed * 10)) * bobAmp
			local pos = startPos:Lerp(goal, t) + Vector3.new(0, bob, 0)
			model:PivotTo(CFrame.lookAt(pos, pos + dir))
			if gait then
				poseLegs(model, gait, travelled)
			end
		end
		if model.Parent then
			model:PivotTo(CFrame.lookAt(goal, goal + dir))
		end
	end
	if gait and model.Parent then
		restLegs(model, gait)
	end
end

-- Two quick hops and a SOLD! sign. Yields until the hop finishes.
function AnimalService.sold(model: Model)
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "SoldBanner"
		billboard.Size = UDim2.fromOffset(180, 48)
		billboard.StudsOffset = Vector3.new(0, 3.2, 0)
		billboard.MaxDistance = 80
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = "SOLD!"
		label.TextScaled = true
		label.Font = Enum.Font.FredokaOne
		label.TextColor3 = UIStyle.CashColor
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.fromRGB(40, 70, 20)
		label.Parent = billboard
		billboard.Parent = head
		Debris:AddItem(billboard, 1.2)
	end
	local body = model:FindFirstChild("Body")
	local sound = body and body:FindFirstChild("CompleteSound")
	if sound and sound:IsA("Sound") then
		sound.PlaybackSpeed = 1.35
		sound:Play()
	end
	local base = model:GetPivot()
	local elapsed = 0
	local duration = 0.7
	while elapsed < duration and model.Parent do
		elapsed += task.wait()
		local hop = math.abs(math.sin(elapsed / duration * math.pi * 2)) * 1.1
		model:PivotTo(base + Vector3.new(0, hop, 0))
	end
	if model.Parent then
		model:PivotTo(base)
	end
end

-- Linear walk with a small bob. Yields until arrival; always ends exactly at `target`.
function AnimalService.moveTo(model: Model, target: CFrame, duration: number)
	local gait = gaitOf(model)
	local start = model:GetPivot()
	local span = (target.Position - start.Position).Magnitude
	local elapsed = 0
	while elapsed < duration and model.Parent do
		elapsed += task.wait()
		local t = math.min(elapsed / duration, 1)
		local bob = if gait and gait.Heavy
			then stepBob(gait, span * t, 0.25)
			else math.abs(math.sin(elapsed * 10)) * 0.25
		model:PivotTo(start:Lerp(target, t) + Vector3.new(0, bob, 0))
		if gait then
			poseLegs(model, gait, span * t)
		end
	end
	if model.Parent then
		model:PivotTo(target) -- fallback placement if the walk was cut short
		if gait then
			restLegs(model, gait)
		end
	end
end

local CONFETTI = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 120)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 210, 60)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 230, 120)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(70, 200, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 110, 255)),
})

local function burst(parent: Instance, props: { [string]: any }, count: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.LightEmission = 0.6
	for key, value in props do
		(emitter :: any)[key] = value
	end
	emitter.Parent = parent
	emitter:Emit(count)
	Debris:AddItem(emitter, 3)
end

-- A flat neon ring that races out across the ground and fades.
local function shockwave(at: Vector3, color: Color3)
	local ring = Instance.new("Part")
	ring.Name = "CleanShockwave"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.15
	ring.Size = Vector3.new(0.2, 3, 3)
	ring.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace
	TweenService:Create(ring, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, 20, 20),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.6)
end

-- Three rising notes from the completion sound.
local function chime(parent: Instance)
	for i, speed in { 1, 1.26, 1.5 } do
		task.delay((i - 1) * 0.09, function()
			if not parent.Parent then
				return
			end
			local note = Instance.new("Sound")
			note.SoundId = GameConfig.Sounds.Complete
			note.PlaybackSpeed = speed
			note.Volume = 0.45 + i * 0.1
			note.Parent = parent
			note:Play()
			Debris:AddItem(note, 2)
		end)
	end
end

local function easeOutBack(t: number): number
	local c = 1.70158
	return 1 + (c + 1) * (t - 1) ^ 3 + c * (t - 1) ^ 2
end

-- Squash, spinning hop with a size pop, confetti at the top, shockwave and bubbles on the
-- landing, a smaller bounce, then a settle. Yields for GameConfig.CelebrationDuration.
function AnimalService.celebrate(model: Model)
	local body = model:FindFirstChild("Body")
	local sparkleColor = ColorSequence.new(Color3.fromRGB(150, 230, 255))
	if body then
		local sparkle = body:FindFirstChild("Sparkle") :: ParticleEmitter?
		if sparkle then
			sparkleColor = sparkle.Color
			sparkle:Emit(70)
		end
		chime(body)
	end

	-- White glint that fades as the animal shows off its clean coat.
	local flash = Instance.new("Highlight")
	flash.FillColor = Color3.new(1, 1, 1)
	flash.OutlineColor = Color3.fromRGB(150, 230, 255)
	flash.FillTransparency = 0.15
	flash.OutlineTransparency = 0
	flash.DepthMode = Enum.HighlightDepthMode.Occluded
	flash.Parent = model
	TweenService:Create(flash, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.8)

	-- "Squeaky clean!" springs in above the animal for the length of the celebration.
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "CleanBanner"
		billboard.Size = UDim2.fromOffset(240, 56)
		billboard.MaxDistance = 80
		-- The clean meter is gone by now, so this takes its row above the nameplate.
		UIStyle.overhead(billboard, head, UIStyle.Overhead.Banner)
		local label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromScale(0.2, 0.2)
		label.BackgroundTransparency = 1
		label.Text = "Squeaky clean!"
		label.TextScaled = true
		label.Font = UIStyle.Font
		label.TextColor3 = Color3.fromRGB(150, 230, 255)
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.fromRGB(20, 60, 110)
		label.Rotation = -8
		label.Parent = billboard
		billboard.Parent = head
		TweenService:Create(label, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(1, 1),
			Rotation = 0,
		}):Play()
		Debris:AddItem(billboard, GameConfig.CelebrationDuration)
	end

	local base = model:GetPivot()
	local _, extents = model:GetBoundingBox()
	local ground = base.Position - Vector3.new(0, extents.Y / 2, 0)
	local duration = GameConfig.CelebrationDuration
	local restAttr = model:GetAttribute("RestScale")
	local rest = if typeof(restAttr) == "number" and restAttr > 0 then restAttr else 1
	-- Phase ends, as fractions of the duration.
	local squashEnd, hopEnd, landEnd, bounceEnd = 0.08, 0.45, 0.55, 0.78
	local confettiDone, landDone = false, false
	local elapsed = 0
	while elapsed < duration and model.Parent do
		elapsed += task.wait()
		local t = math.min(elapsed / duration, 1)
		local height, spin, scale = 0, 0, 1
		if t < squashEnd then
			scale = 1 - 0.12 * (t / squashEnd) -- wind up
		elseif t < hopEnd then
			local u = (t - squashEnd) / (hopEnd - squashEnd)
			height = math.sin(u * math.pi) * 3.2
			spin = easeOutBack(u) * math.pi * 2
			scale = 0.88 + 0.32 * math.sin(u * math.pi)
			if u > 0.5 and not confettiDone and body then
				confettiDone = true
				burst(body, {
					Color = CONFETTI,
					Size = NumberSequence.new(0.35, 0.2),
					Lifetime = NumberRange.new(1.2, 1.8),
					Speed = NumberRange.new(16, 26),
					SpreadAngle = Vector2.new(55, 55),
					EmissionDirection = Enum.NormalId.Top,
					Acceleration = Vector3.new(0, -32, 0),
					Drag = 1.5,
					Rotation = NumberRange.new(0, 360),
					RotSpeed = NumberRange.new(-300, 300),
					LightEmission = 0.2,
				}, 60)
			end
		elseif t < landEnd then
			local u = (t - hopEnd) / (landEnd - hopEnd)
			spin = math.pi * 2
			scale = 1 - 0.14 * math.sin(u * math.pi) -- landing squash
			if not landDone then
				landDone = true
				shockwave(ground + Vector3.new(0, 0.15, 0), Color3.fromRGB(150, 230, 255))
				if body then
					burst(body, {
						Color = sparkleColor,
						Size = NumberSequence.new({
							NumberSequenceKeypoint.new(0, 0.2),
							NumberSequenceKeypoint.new(0.3, 0.9),
							NumberSequenceKeypoint.new(1, 0),
						}),
						Transparency = NumberSequence.new(0.25, 1),
						Lifetime = NumberRange.new(0.8, 1.4),
						Speed = NumberRange.new(5, 11),
						SpreadAngle = Vector2.new(180, 180),
						Acceleration = Vector3.new(0, 6, 0),
						Drag = 2,
					}, 40)
				end
			end
		elseif t < bounceEnd then
			local u = (t - landEnd) / (bounceEnd - landEnd)
			spin = math.pi * 2
			height = math.sin(u * math.pi) * 1.1
			scale = 1 + 0.08 * math.sin(u * math.pi)
		else
			-- Happy wiggle while it settles.
			local u = (t - bounceEnd) / (1 - bounceEnd)
			spin = math.pi * 2 + math.sin(u * math.pi * 4) * math.rad(12) * (1 - u)
		end
		model:ScaleTo(scale * rest)
		model:PivotTo(base * CFrame.new(0, height, 0) * CFrame.Angles(0, spin, 0))
	end
	if model.Parent then
		model:ScaleTo(rest)
		model:PivotTo(base)
	end
end

function AnimalService.destroy(model: Model?)
	if model then
		model:Destroy()
	end
end

return AnimalService
