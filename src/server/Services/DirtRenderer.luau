-- Visual representation of dirt. Everything that changes how dirt LOOKS lives here, so a
-- decal or texture-mask approach can replace it without touching cleaning or reward logic.
-- Runs on the server; property changes replicate to every client.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local DirtRenderer = {}

local MIN_SCALE = 0.45 -- a nearly clean patch shrinks to this fraction of its size
local MAX_FADE = 0.55 -- and becomes this transparent
local MUD_COLOR = Color3.fromRGB(110, 80, 50)
local GRIME = 0.5 -- how far a filthy animal's colour is pulled toward mud

local function fadeSplats(patch: BasePart, transparency: number)
	for _, splat in patch:GetChildren() do
		if splat:IsA("BasePart") then
			splat.Transparency = transparency
		end
	end
end

-- fraction: remaining dirt in [0, 1]
function DirtRenderer.setAmount(patch: BasePart, fraction: number)
	local base = (patch:GetAttribute("BaseDiameter") or patch.Size.Y) :: number
	local d = base * (MIN_SCALE + (1 - MIN_SCALE) * fraction)
	patch.Size = Vector3.new(patch.Size.X, d, d)
	patch.Transparency = (1 - fraction) * MAX_FADE
	-- Splatters wash off first, so progress shows even on a half-cleaned patch.
	fadeSplats(patch, math.clamp((1 - fraction) * 2, 0, 1))
	patch:SetAttribute("Dirt", fraction)
end

-- A burst of mud chunks and a squelch where a patch came off.
local function mudBurst(position: Vector3, normal: Vector3)
	local attachment = Instance.new("Attachment")
	attachment.WorldCFrame = CFrame.lookAt(position, position + normal)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.SpreadAngle = Vector2.new(50, 50)
	emitter.Speed = NumberRange.new(6, 11)
	emitter.Acceleration = Vector3.new(0, -40, 0)
	emitter.Lifetime = NumberRange.new(0.4, 0.7)
	emitter.Size = NumberSequence.new(0.35, 0.1)
	emitter.Color = ColorSequence.new(MUD_COLOR)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.Parent = attachment
	local sound = Instance.new("Sound")
	sound.SoundId = GameConfig.Sounds.PatchClear
	sound.PlaybackSpeed = 1.5
	sound.Volume = 0.45
	sound.Parent = attachment
	attachment.Parent = Workspace.Terrain
	emitter:Emit(14)
	sound:Play()
	Debris:AddItem(attachment, 1.5)
end

-- Fully cleaned: burst, fade out, then remove so it no longer blocks spray or shows in hints.
function DirtRenderer.clear(patch: BasePart)
	patch:SetAttribute("Dirt", 0)
	patch.CanQuery = false
	if patch.Parent then
		mudBurst(patch.Position, patch.CFrame.RightVector) -- RightVector is the surface normal
	end
	fadeSplats(patch, 1)
	local tween = TweenService:Create(patch, TweenInfo.new(0.2), { Transparency = 1 })
	tween.Completed:Once(function()
		patch:Destroy()
	end)
	tween:Play()
end

-- Tints the whole animal from muddy (progress 0) to its true colours (progress 1), so the
-- dirty-to-clean transformation is obvious at a glance. Patches stay the spatial source of truth.
function DirtRenderer.setGrime(model: Model, progress: number)
	local grime = GRIME * (1 - math.clamp(progress, 0, 1))
	for _, part in model:GetChildren() do
		local clean = part:GetAttribute("CleanColor")
		if part:IsA("BasePart") and typeof(clean) == "Color3" then
			part.Color = clean:Lerp(MUD_COLOR, grime)
		end
	end
end

return DirtRenderer
