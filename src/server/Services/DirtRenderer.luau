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

-- A burst of mud chunks, a few sparkles, a squelch and a chime where a patch popped off.
-- The chime climbs in pitch as the wash nears 100%, so finishing feels like a crescendo.
local function popBurst(position: Vector3, normal: Vector3, progress: number)
	local attachment = Instance.new("Attachment")
	attachment.WorldCFrame = CFrame.lookAt(position, position + normal)
	local mud = Instance.new("ParticleEmitter")
	mud.Enabled = false
	mud.EmissionDirection = Enum.NormalId.Front
	mud.SpreadAngle = Vector2.new(55, 55)
	mud.Speed = NumberRange.new(8, 14)
	mud.Acceleration = Vector3.new(0, -45, 0)
	mud.Lifetime = NumberRange.new(0.4, 0.7)
	mud.Size = NumberSequence.new(0.4, 0.1)
	mud.Color = ColorSequence.new(MUD_COLOR)
	mud.Rotation = NumberRange.new(0, 360)
	mud.Parent = attachment
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Enabled = false
	sparkle.EmissionDirection = Enum.NormalId.Front
	sparkle.SpreadAngle = Vector2.new(80, 80)
	sparkle.Speed = NumberRange.new(3, 6)
	sparkle.Lifetime = NumberRange.new(0.3, 0.5)
	sparkle.Size = NumberSequence.new(0.45, 0)
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 255, 220), Color3.fromRGB(170, 230, 255))
	sparkle.LightEmission = 1
	sparkle.Parent = attachment
	local squelch = Instance.new("Sound")
	squelch.SoundId = GameConfig.Sounds.PatchClear
	squelch.PlaybackSpeed = 1.4
	squelch.Volume = 0.35
	squelch.Parent = attachment
	local chime = Instance.new("Sound")
	chime.SoundId = GameConfig.Sounds.Complete
	chime.PlaybackSpeed = 1.1 + math.clamp(progress, 0, 1) * 0.9
	chime.Volume = 0.25
	chime.Parent = attachment
	attachment.Parent = Workspace.Terrain
	mud:Emit(16)
	sparkle:Emit(8)
	squelch:Play()
	chime:Play()
	Debris:AddItem(attachment, 1.5)
end

-- Fully cleaned: pop (swell then vanish) with a burst, then remove so it no longer blocks
-- spray or shows in hints. `progress` is the animal's overall progress, for the chime pitch.
function DirtRenderer.clear(patch: BasePart, progress: number?)
	patch:SetAttribute("Dirt", 0)
	patch.CanQuery = false
	if patch.Parent then
		popBurst(patch.Position, patch.CFrame.RightVector, progress or 0) -- RightVector is the surface normal
	end
	fadeSplats(patch, 1)
	local swell = patch.Size * Vector3.new(1, 1.35, 1.35)
	local tween = TweenService:Create(patch, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = swell,
		Transparency = 1,
	})
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
