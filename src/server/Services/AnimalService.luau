-- Animal selection, spawning, scripted movement, celebration, and disposal.
-- Movement functions yield; BayService runs them inside the bay's thread so that
-- cancelling the thread (owner left) stops them with nothing left connected.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local AnimalBuilder = require(script.Parent.AnimalBuilder)

local AnimalService = {}

local rng = Random.new()

-- First animal of a session is deterministic; later ones come from the weighted pool
-- of animals the player's tool tier can handle.
function AnimalService.pickNext(isFirst: boolean, toolTier: number): string
	if isFirst then
		return AnimalConfig.FirstAnimal
	end
	local total = 0
	local pool = {}
	for key, def in AnimalConfig.Animals do
		if def.RequiredToolTier <= toolTier and AnimalBuilder.has(def.TemplateName) then
			total += def.SelectionWeight
			table.insert(pool, { key = key, weight = def.SelectionWeight })
		end
	end
	table.sort(pool, function(a, b)
		return a.key < b.key
	end)
	local roll = rng:NextNumber(0, total)
	for _, entry in pool do
		roll -= entry.weight
		if roll <= 0 then
			return entry.key
		end
	end
	return AnimalConfig.FirstAnimal
end

function AnimalService.spawn(animalKey: string, jobId: string, at: CFrame, parent: Instance)
	local def = AnimalConfig.Animals[animalKey]
	local model, patches = AnimalBuilder.build(def.TemplateName)
	model:SetAttribute("JobId", jobId)
	model:SetAttribute("AnimalKey", animalKey)
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

	model.Parent = parent
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
