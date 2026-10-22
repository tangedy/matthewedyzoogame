-- Animal selection, spawning, scripted movement, celebration, carrying, and disposal.
-- Movement functions yield; BayService runs them inside the bay's thread so that
-- cancelling the thread (owner left) stops them with nothing left connected.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local AnimalBuilder = require(script.Parent.AnimalBuilder)
local DirtRenderer = require(script.Parent.DirtRenderer)
local Hooks = require(script.Parent.Hooks)
local MutationPayout = require(script.Parent.MutationPayout)

local AnimalService = {}

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

-- First animal of a session is deterministic; later ones come from the weighted pool of
-- species the player's hose has the clean power to wash.
function AnimalService.pickNext(isFirst: boolean, toolTier: number, player: Player?): string
	if isFirst then
		return AnimalConfig.FirstAnimal
	end
	local tool = ToolConfig[toolTier]
	local power = if tool then tool.CleaningPower else 0
	local pool = {}
	for key, def in AnimalConfig.Animals do
		if
			def.RequiredToolTier <= toolTier
			and def.SpawnWeight > 0
			and not def.Limited
			and CleanPower.canClean(power, def.Rarity)
			and AnimalBuilder.has(def.TemplateName)
		then
			table.insert(pool, key)
		end
	end
	table.sort(pool)
	return weightedPick(pool, function(key)
		local weight = AnimalConfig.Animals[key].SpawnWeight
		return if player then math.max(0, Hooks.apply("SpawnWeight", weight, player, key)) else weight
	end) or AnimalConfig.FirstAnimal
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

local function addNameplate(model: Model, animalKey: string, mutationKey: string, maxDistance: number)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local def = AnimalConfig.Animals[animalKey]
	UIStyle.nameplate(head, {
		Name = def.DisplayName,
		Rarity = def.Rarity,
		Mutation = mutationKey,
		IncomePerSecond = income(animalKey, mutationKey),
	}, maxDistance)
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

function AnimalService.spawn(animalKey: string, mutationKey: string, jobId: string, at: CFrame, parent: Instance)
	local def = AnimalConfig.Animals[animalKey]
	local model, patches = AnimalBuilder.build(def.TemplateName, { Mutation = mutationKey, Rarity = def.Rarity })
	model:SetAttribute("JobId", jobId)
	model:SetAttribute("AnimalKey", animalKey)
	DirtRenderer.setGrime(model, 0) -- arrives filthy
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

	addNameplate(model, animalKey, mutationKey, 80)

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

-- Linear walk with a small bob. Yields until arrival; always ends exactly at `target`.
function AnimalService.moveTo(model: Model, target: CFrame, duration: number)
	local start = model:GetPivot()
	local elapsed = 0
	while elapsed < duration and model.Parent do
		elapsed += task.wait()
		local t = math.min(elapsed / duration, 1)
		local bob = math.abs(math.sin(elapsed * 10)) * 0.25
		model:PivotTo(start:Lerp(target, t) + Vector3.new(0, bob, 0))
	end
	if model.Parent then
		model:PivotTo(target) -- fallback placement if the walk was cut short
	end
end

-- Happy hop + sparkle + sound. Yields for GameConfig.CelebrationDuration.
function AnimalService.celebrate(model: Model)
	local body = model:FindFirstChild("Body")
	if body then
		local sparkle = body:FindFirstChild("Sparkle") :: ParticleEmitter?
		local sound = body:FindFirstChild("CompleteSound") :: Sound?
		if sparkle then
			sparkle:Emit(40)
		end
		if sound then
			sound:Play()
		end
	end

	-- "Squeaky clean!" pops above the animal for the length of the celebration.
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "CleanBanner"
		billboard.Size = UDim2.fromOffset(220, 50)
		billboard.StudsOffset = Vector3.new(0, 3.5, 0)
		billboard.MaxDistance = 80
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = "Squeaky clean!"
		label.TextScaled = true
		label.Font = Enum.Font.FredokaOne
		label.TextColor3 = Color3.fromRGB(150, 230, 255)
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.fromRGB(20, 60, 110)
		label.Parent = billboard
		billboard.Parent = head
		task.delay(GameConfig.CelebrationDuration, function()
			billboard:Destroy()
		end)
	end

	local base = model:GetPivot()
	local duration = GameConfig.CelebrationDuration
	local elapsed = 0
	while elapsed < duration and model.Parent do
		elapsed += task.wait()
		local hop = math.abs(math.sin(elapsed / duration * math.pi * 2)) * 1.5
		model:PivotTo(base + Vector3.new(0, hop, 0))
	end
	if model.Parent then
		model:PivotTo(base)
	end
end

function AnimalService.destroy(model: Model?)
	if model then
		model:Destroy()
	end
end

return AnimalService
