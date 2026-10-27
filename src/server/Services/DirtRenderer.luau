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

local SKIN_THIN = 0.3 -- flakes still on a nearly clean skin tile are this transparent

-- A skin tile is one solid part until it is sprayed, then breaks into its flakes, so an
-- animal nobody is washing (or a queued one) costs one part per tile, not dozens.
local function breakTile(patch: BasePart): { BasePart }
	local flakes: { BasePart } = {}
	for _, flake in patch:GetChildren() do
		if flake:IsA("BasePart") then
			table.insert(flakes, flake)
		end
	end
	if #flakes > 0 then
		return flakes
	end
	local nA = (patch:GetAttribute("FlakesA") or 2) :: number
	local nB = (patch:GetAttribute("FlakesB") or 2) :: number
	local size = patch.Size
	local flakeA, flakeB = size.Y / nA, size.Z / nB
	for i = 1, nA do
		for j = 1, nB do
			local flake = Instance.new("Part")
			flake.Name = "Flake"
			flake.Anchored = true
			flake.CanCollide = false
			flake.CanTouch = false
			flake.CanQuery = false -- cosmetic: the spray hits the tile
			flake.CastShadow = false
			flake.Size = Vector3.new(size.X, flakeA + 0.005, flakeB + 0.005) -- a hair of overlap: no seams
			flake.CFrame = patch.CFrame
				* CFrame.new(0, -size.Y / 2 + (i - 0.5) * flakeA, -size.Z / 2 + (j - 0.5) * flakeB)
			flake.Color = patch.Color
			flake.Material = patch.Material
			flake:SetAttribute("Order", math.random()) -- wash-off order when there's no spray point
			flake.Parent = patch
			table.insert(flakes, flake)
		end
	end
	patch.Transparency = 1
	return flakes
end

-- Back to one solid part: a whole tile (restored) or a clean one (hidden).
local function mendTile(patch: BasePart, transparency: number)
	for _, flake in patch:GetChildren() do
		if flake:IsA("BasePart") then
			flake:Destroy()
		end
	end
	patch.Transparency = transparency
end

-- Skin tiles (AnimalBuilder) keep one flake per share of their dirt. Flakes go nearest the
-- spray first, so the mud wipes off where the water lands; without a spray point (auto-wash)
-- they go in their own random order. The flakes left thin out as the tile washes.
local function setSkin(patch: BasePart, fraction: number, sprayAt: Vector3?)
	if fraction >= 1 then
		mendTile(patch, 0)
		return
	end
	local flakes = breakTile(patch)
	local rank: { [BasePart]: number } = {}
	for _, flake in flakes do
		rank[flake] = if sprayAt
			then (flake.Position - sprayAt).Magnitude
			else (flake:GetAttribute("Order") or 0) :: number
	end
	table.sort(flakes, function(a, b)
		local aGone, bGone = a.Transparency >= 1, b.Transparency >= 1
		if aGone ~= bGone then
			return aGone -- washed-off flakes stay off, so they count first
		end
		return rank[a] < rank[b]
	end)
	local gone = #flakes - math.ceil(fraction * #flakes - 1e-6)
	local thin = (1 - fraction) * SKIN_THIN
	for i, flake in flakes do
		flake.Transparency = if i <= gone then 1 else thin
	end
end

-- fraction: remaining dirt in [0, 1]. sprayAt: where the water hit, when it was sprayed.
function DirtRenderer.setAmount(patch: BasePart, fraction: number, sprayAt: Vector3?)
	if patch:GetAttribute("Skin") then
		setSkin(patch, fraction, sprayAt)
		patch:SetAttribute("Dirt", fraction)
		return
	end
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

-- Fully cleaned: pop (swell then vanish) with a burst. The part is hidden, not destroyed, so
-- `restore` can bring it back (an animal shaking mud on). `progress` sets the chime pitch.
function DirtRenderer.clear(patch: BasePart, progress: number?)
	patch:SetAttribute("Dirt", 0)
	patch.CanQuery = false
	if patch.Parent then
		popBurst(patch.Position, patch.CFrame.RightVector, progress or 0) -- RightVector is the surface normal
	end
	if patch:GetAttribute("Skin") then
		-- The last flakes go with the burst (no tween, so a restore right after can't be undone by one).
		mendTile(patch, 1)
		return
	end
	fadeSplats(patch, 1)
	local swell = patch.Size * Vector3.new(1, 1.35, 1.35)
	local tween = TweenService:Create(patch, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = swell,
		Transparency = 1,
	})
	tween.Completed:Once(function()
		if patch:GetAttribute("Dirt") == 0 then
			patch.Size = patch.Size / Vector3.new(1, 1.35, 1.35) -- undo the swell for a later restore
		end
	end)
	tween:Play()
end

-- Back to fully dirty (see CleaningService.redirty).
function DirtRenderer.restore(patch: BasePart)
	patch.CanQuery = true
	DirtRenderer.setAmount(patch, 1)
end

-- Grime moves in GRIME_STEPS steps. Spraying calls setGrime up to 15 times a second per
-- sprayer, and every call rewrote (and replicated) the colour of every body part; a step
-- this small is not visible, so unchanged steps are skipped.
local GRIME_STEPS = 40
local appliedStep: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- Tints the whole animal from muddy (progress 0) to its true colours (progress 1), so the
-- dirty-to-clean transformation is obvious at a glance. Patches stay the spatial source of truth.
function DirtRenderer.setGrime(model: Model, progress: number)
	local step = math.round(math.clamp(progress, 0, 1) * GRIME_STEPS)
	if appliedStep[model] == step then
		return
	end
	appliedStep[model] = step
	local grime = GRIME * (1 - step / GRIME_STEPS)
	for _, part in model:GetChildren() do
		local clean = part:GetAttribute("CleanColor")
		if part:IsA("BasePart") and typeof(clean) == "Color3" then
			part.Color = clean:Lerp(MUD_COLOR, grime)
		end
	end
end

return DirtRenderer
