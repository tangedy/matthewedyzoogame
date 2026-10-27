-- Builds animals: real models from ServerStorage.AnimalTemplates when a modeler has supplied
-- one, otherwise block placeholders generated here, so the game runs with no art assets.
--
-- Template contract (placeholders follow it; real models must too):
--   Model (PrimaryPart = Root, pivot on the ground under the body, facing -Z)
--   ├── Root          invisible pivot part
--   ├── Body, Head    collidable, queryable body parts (spray must hit these or a patch)
--   ├── ...           other parts; CanQuery = false for anything that shouldn't block spray
--   └── DirtPatches   Model of Parts. Placeholders generate these; real models author them
--                     (any BasePart, ideally a thin disc on the surface) and get ids assigned.
--
-- Patches are only placed on surfaces a standing player can spray: sides, rump, head sides,
-- and top faces low enough to hit from above (see MAX_TOP_PATCH_HEIGHT).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local RAINBOW_RING_TAG = UIStyle.RainbowRingTag

local AnimalBuilder = {}

export type PatchInfo = { Id: string, Part: BasePart }

export type BuildOptions = {
	Mutation: string?, -- MutationConfig key; changes colours (Gold, Diamond, Rainbow)
	Rarity: string?, -- RarityConfig key; Zoo God and Secret animals get an aura
	Clean: boolean?, -- no dirt patches (pens, cache, carried)
	Seed: number?, -- unused since the mud skin has no randomness; kept so callers still type-check
}

type Spec = {
	BodySize: Vector3, -- X = width, Y = height, Z = length
	LegHeight: number,
	LegCount: number?, -- 4 (default) or 2 for birds
	LegThickness: number?,
	LegColor: Color3?,
	HeadSize: Vector3,
	HeadLift: number?, -- extra height for the head above the default
	HeadOnTop: boolean?, -- upright animals (penguin): head sits on top of the body
	Neck: Vector3?, -- long necks (llama, horse): neck part size; the head sits on top
	NeckTilt: number?, -- radians the neck leans forward from its base (the head stays level)
	HeadPosition: Vector3?, -- explicit head centre; overrides HeadLift/HeadOnTop (hero models)
	SkipRump: boolean?, -- no rump patches: a tail, tail fan or dorsal plates cover that face
	CenterZ: boolean?, -- shift every part so the footprint (snout to tail tip) is centred on the pivot
	BodyColor: Color3,
	HeadColor: Color3,
	BodyMaterial: Enum.Material,
	PatchCell: number?, -- target studs per patch; smaller animals use smaller cells
	Decorate: (model: Model, body: BasePart, head: BasePart, spec: Spec) -> (),
}

local MUD_COLOR = Color3.fromRGB(118, 82, 50) -- the Mud material renders darker than its colour
local DEFAULT_PATCH_CELL = 1.5
local PATCH_THICKNESS = 0.12
-- The mud skin: each face is tiled edge to edge, and each tile (one patch) is split into
-- flakes about this size, which wash off one by one (DirtRenderer).
local SKIN_LIFT = 0.02 -- skin centre above the surface; its outer face is SKIN_LIFT + PATCH_THICKNESS / 2 out
local FLAKE_SIZE = 0.3
local MAX_FLAKES = 6 -- per side of a tile
-- Top faces higher than this (studs above ground) are skipped: a standing player's nozzle
-- sits about 4.5 studs up, and a top face can only be hit from above it.
local MAX_TOP_PATCH_HEIGHT = 4.3

local function makePart(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanTouch = false
	part.Parent = parent
	return part
end

-- Decorations never block spray or collide. Tiny ones (eyes, nostrils, claws) cast no
-- shadow: invisible at that size, and every shadow caster costs a draw on each client.
local SHADOWLESS_SIZE = 0.6
local function decoration(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = makePart(name, size, cframe, color, parent)
	part.CanCollide = false
	part.CanQuery = false
	if math.max(size.X, size.Y, size.Z) < SHADOWLESS_SIZE then
		part.CastShadow = false
	end
	return part
end

-- Plain black block eyes, a little taller than wide. Never tinted by grime or rarity.
local EYE_BLACK = Color3.fromRGB(12, 12, 15)
-- `sides` puts them on the head's side faces instead (horses, zebras, donkeys).
local function addEyes(head: BasePart, parent: Instance, sides: boolean?)
	local s = head.Size
	local eyeSize = math.clamp(s.Y * 0.22, 0.25, 0.55)
	for _, side in { -1, 1 } do
		local eye = if sides
			then decoration(
				"Eye",
				Vector3.new(0.08, eyeSize * 0.9, eyeSize * 0.6),
				head.CFrame * CFrame.new(side * (s.X / 2 + 0.03), s.Y * 0.2, -s.Z * 0.22),
				EYE_BLACK,
				parent
			)
			else decoration(
				"Eye",
				Vector3.new(eyeSize * 0.6, eyeSize * 0.9, 0.08),
				head.CFrame * CFrame.new(side * s.X * 0.28, s.Y * 0.15, -s.Z / 2 - 0.03),
				EYE_BLACK,
				parent
			)
		eye:SetAttribute("NoGrime", true)
	end
end

local PINK = Color3.fromRGB(255, 175, 185)
local PINK_DARK = Color3.fromRGB(235, 130, 150)
local ORANGE = Color3.fromRGB(255, 160, 40)
local WHITE = Color3.new(1, 1, 1)
local INK = Color3.fromRGB(20, 20, 25)
local IVORY = Color3.fromRGB(250, 244, 225)
local GILT = Color3.fromRGB(255, 200, 70)

-- Hero-model building blocks -------------------------------------------------------------
-- Everything below makes decorations (never queryable or collidable) as direct children of
-- the model, so grime tinting and mutation recolouring reach them.

local MAX_FLAIR_RATE = 20 -- species particle emitters stay modest
local SPARKLE_TEX = "rbxasset://textures/particles/sparkles_main.dds"
local FIRE_TEX = "rbxasset://textures/particles/fire_main.dds"
local SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds"

local function shaped(part: Part, shape: Enum.PartType): Part
	part.Shape = shape
	return part
end

-- Kept for the hero models that ask for a "ball": the roster is blocky, so it is a cube a
-- little smaller than the diameter, which reads as the same mass.
local function ball(name: string, diameter: number, cframe: CFrame, color: Color3, parent: Instance): Part
	local size = diameter * 0.88
	return decoration(name, Vector3.new(size, size, size), cframe, color, parent)
end

-- Cylinder whose axis runs along the frame's Y axis (legs, bones, horns).
local function rod(
	name: string,
	length: number,
	diameter: number,
	cframe: CFrame,
	color: Color3,
	parent: Instance
): Part
	return shaped(
		decoration(
			name,
			Vector3.new(length, diameter, diameter),
			cframe * CFrame.Angles(0, 0, math.rad(90)),
			color,
			parent
		),
		Enum.PartType.Cylinder
	)
end

-- Cylinder whose axis runs along the frame's Z axis: a flat disc when thin (eyes, ears),
-- a log when long (rounded backs and bellies).
local function disc(
	name: string,
	diameter: number,
	thickness: number,
	cframe: CFrame,
	color: Color3,
	parent: Instance
): Part
	return shaped(
		decoration(
			name,
			Vector3.new(thickness, diameter, diameter),
			cframe * CFrame.Angles(0, math.rad(90), 0),
			color,
			parent
		),
		Enum.PartType.Cylinder
	)
end

-- A wedge's full faces are its bottom and back (+Z); the slope runs down to the front.
local function wedge(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	return shaped(decoration(name, size, cframe, color, parent), Enum.PartType.Wedge)
end

-- Isosceles triangle in the frame's XY plane, apex up (+Y), base centred on the frame,
-- `thickness` along the frame's Z: two mirrored wedges. Ears, spikes, crests, flame tips.
local function triangle(
	name: string,
	width: number,
	height: number,
	thickness: number,
	cframe: CFrame,
	color: Color3,
	parent: Instance
): { Part }
	local halves = {}
	for _, side in { -1, 1 } do
		table.insert(
			halves,
			wedge(
				name,
				Vector3.new(thickness, height, width / 2),
				cframe * CFrame.new(side * width / 4, height / 2, 0) * CFrame.Angles(0, -side * math.pi / 2, 0),
				color,
				parent
			)
		)
	end
	return halves
end

-- Glowing parts (eyes, fire, plates) keep their colour: no grime, no mutation recolour.
local function glow(part: Part, transparency: number?): Part
	part.Material = Enum.Material.Neon
	part.Transparency = transparency or 0
	part:SetAttribute("NoGrime", true)
	return part
end

local function glowAll(parts: { Part }, transparency: number?): { Part }
	for _, part in parts do
		glow(part, transparency)
	end
	return parts
end

local function anchorAt(part: BasePart, cframe: CFrame, name: string): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = part.CFrame:ToObjectSpace(cframe)
	attachment.Parent = part
	return attachment
end

-- Species flair particles (fire breath, fox-fire, plate sparks). Rate is capped.
local function flair(parent: Instance, name: string, props: { [string]: any }): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.LightEmission = 1
	for key, value in props do
		(emitter :: any)[key] = value
	end
	emitter.Rate = math.min(emitter.Rate, MAX_FLAIR_RATE)
	emitter.Parent = parent
	return emitter
end

local function flameColors(hot: Color3, mid: Color3, cool: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, hot),
		ColorSequenceKeypoint.new(0.45, mid),
		ColorSequenceKeypoint.new(1, cool),
	})
end

local function swell(peak: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, peak * 0.4),
		NumberSequenceKeypoint.new(0.4, peak),
		NumberSequenceKeypoint.new(1, 0),
	})
end

-- Deterministic jitter in [-0.5, 0.5] for hand-placed-looking patterns.
local function wobble(seed: number): number
	return math.clamp(math.noise(seed * 0.731 + 0.1, 0.37, 0.61), -0.5, 0.5)
end

local function legsOf(model: Model): { BasePart }
	local legs = {}
	for _, child in model:GetChildren() do
		if child.Name == "Leg" and child:IsA("BasePart") then
			table.insert(legs, child)
		end
	end
	return legs
end

type ChainOptions = {
	Name: string,
	Start: CFrame, -- segments run along this frame's LookVector
	Count: number,
	Length: number, -- distance between segment centres
	Size: number, -- first segment's diameter
	EndSize: number,
	Turn: Vector2?, -- rotation per segment: X pitches up, Y yaws toward the frame's -X
	Color: Color3,
	EndColor: Color3?,
	Block: boolean?, -- box segments instead of balls
	Aspect: Vector2?, -- box cross-section scale (X, Y), e.g. a flat paddle tail
}

-- A tapering, curving run of overlapping segments: tails, trunks, horns, tusks.
local function chain(opts: ChainOptions, parent: Instance): { Part }
	local cf = opts.Start
	local turn = opts.Turn or Vector2.zero
	local aspect = opts.Aspect or Vector2.one
	local parts = {}
	for i = 1, opts.Count do
		local t = if opts.Count > 1 then (i - 1) / (opts.Count - 1) else 0
		local d = opts.Size + (opts.EndSize - opts.Size) * t
		local color = if opts.EndColor then opts.Color:Lerp(opts.EndColor, t) else opts.Color
		local part = if opts.Block
			then decoration(opts.Name, Vector3.new(d * aspect.X, d * aspect.Y, opts.Length * 1.3), cf, color, parent)
			else ball(opts.Name, d, cf, color, parent)
		table.insert(parts, part)
		cf = cf * CFrame.Angles(turn.X, turn.Y, 0) * CFrame.new(0, 0, -opts.Length)
	end
	return parts
end

-- Frame at `position` looking along `direction` (model space; animals are built at the origin).
local function facing(position: Vector3, direction: Vector3): CFrame
	return CFrame.lookAt(position, position + direction)
end

type EyeStyle = {
	Size: number,
	Spread: number?, -- fraction of head width from the centre line
	Lift: number?, -- fraction of head height above the head centre
	Iris: Color3?, -- nil: a bead eye (just sclera, pupil and shine)
	Sclera: Color3?,
	Slit: boolean?, -- reptile pupil
	Glow: boolean?, -- neon iris
}

-- Plain black block eyes on the head's front face, to match the placeholders. Only Size,
-- Spread and Lift are used; the iris styles are kept so species tables stay unchanged.
local function heroEyes(head: BasePart, parent: Instance, style: EyeStyle)
	local s = head.Size
	local size = style.Size
	local spread = style.Spread or 0.28
	local lift = style.Lift or 0.15
	for _, side in { -1, 1 } do
		local face = head.CFrame * CFrame.new(side * s.X * spread, s.Y * lift, -s.Z / 2)
		local eye = decoration(
			"Eye",
			Vector3.new(size * 0.55, size * 0.8, 0.1),
			face * CFrame.new(0, 0, -0.04),
			EYE_BLACK,
			parent
		)
		eye:SetAttribute("NoGrime", true)
	end
end

type MawStyle = {
	Top: number, -- snout top, relative to the head centre
	Width: number,
	Length: number,
	Height: number,
	Bridge: number, -- height of the sloped nose bridge on top of the snout
	Open: number, -- radians the lower jaw hangs open
	JawHeight: number,
	Fangs: number, -- upper teeth per side
	Skin: Color3,
	Inside: Color3,
	Glow: boolean?, -- glowing mouth (fire, atomic breath)
}

-- Snout, sloped nose, hinged lower jaw, teeth and nostrils for reptile heads. The Head
-- block is the cranium; all of this hangs off its front face, which never carries mud.
-- Returns the mouth opening (looking forward) for breath effects.
local function maw(head: BasePart, parent: Instance, style: MawStyle): CFrame
	local h = head.Size
	local front = -h.Z / 2
	local len, w = style.Length, style.Width
	local bottom = style.Top - style.Height
	local midZ = front - len / 2 + 0.1
	decoration(
		"Snout",
		Vector3.new(w, style.Height, len),
		head.CFrame * CFrame.new(0, bottom + style.Height / 2, midZ),
		style.Skin,
		parent
	)
	wedge(
		"NoseBridge",
		Vector3.new(w, style.Bridge, len),
		head.CFrame * CFrame.new(0, style.Top + style.Bridge / 2, midZ),
		style.Skin,
		parent
	)
	local hinge = head.CFrame * CFrame.new(0, bottom + 0.05, front + 0.1) * CFrame.Angles(-style.Open, 0, 0)
	decoration(
		"Jaw",
		Vector3.new(w - 0.2, style.JawHeight, len),
		hinge * CFrame.new(0, -style.JawHeight / 2, -len / 2),
		style.Skin,
		parent
	)
	local inside = decoration(
		"MouthInside",
		Vector3.new(w - 0.3, 0.35, len - 0.2),
		head.CFrame * CFrame.new(0, bottom - 0.12, midZ),
		style.Inside,
		parent
	)
	if style.Glow then
		glow(inside)
	end
	for _, side in { -1, 1 } do
		for i = 1, style.Fangs do
			local z = 0.3 + (len - 0.45) * (i - 1) / math.max(style.Fangs - 1, 1)
			wedge(
				"Tooth",
				Vector3.new(0.14, 0.3, 0.2),
				head.CFrame * CFrame.new(side * (w / 2 - 0.15), bottom - 0.15, front - z) * CFrame.Angles(0, 0, math.pi),
				IVORY,
				parent
			)
			if i < style.Fangs then
				wedge(
					"Tooth",
					Vector3.new(0.12, 0.22, 0.18),
					hinge * CFrame.new(side * (w / 2 - 0.3), 0.11, -z - 0.2),
					IVORY,
					parent
				)
			end
		end
		local nostril = disc(
			"Nostril",
			0.2,
			0.06,
			head.CFrame * CFrame.new(side * w * 0.22, style.Top - 0.15, front - len + 0.08),
			INK,
			parent
		)
		nostril:SetAttribute("NoGrime", true)
	end
	return head.CFrame * CFrame.new(0, bottom - 0.1, front - len + 0.1)
end

-- Claws pointing forward from a foot whose front edge is at `front` (model-space frame).
local function claws(front: CFrame, count: number, spacing: number, size: Vector3, color: Color3, parent: Instance)
	for i = 1, count do
		local x = (i - (count + 1) / 2) * spacing
		wedge("Claw", size, front * CFrame.new(x, size.Y / 2, -size.Z / 2 + 0.05), color, parent)
	end
end

local function tint(color: Color3, amount: number): Color3
	return if amount >= 0 then color:Lerp(Color3.new(1, 1, 1), amount) else color:Lerp(Color3.new(0, 0, 0), -amount)
end

-- Thin whiskers fanning out from the cheeks.
local function whiskers(model: Model, head: BasePart, color: Color3)
	local h = head.Size
	for _, side in { -1, 1 } do
		for i, tilt in { -0.18, 0.18 } do
			decoration(
				"Whisker",
				Vector3.new(0.9, 0.05, 0.05),
				head.CFrame
					* CFrame.new(side * (h.X / 2 + 0.25), -h.Y * 0.18 + (i - 1.5) * 0.12, -h.Z / 2 + 0.15)
					* CFrame.Angles(0, side * 0.25, tilt * side),
				color,
				model
			)
		end
	end
end

-- Blocky detail kit -----------------------------------------------------------------------
-- Detail goes where mud never sits (head fronts, feet, tails, manes, the top line of tall
-- animals) or lies flush on a muddy face (markings no thicker than PATCH_THICKNESS / 2, so
-- the mud patches still stand proud of them). Everything is a block or a wedge: no balls.

local FLUSH = 0.05 -- markings this thick sit under the mud patches

local function ungrimed(part: Part): Part
	part:SetAttribute("NoGrime", true)
	return part
end

-- A block on the front face of `part` at (x, y) in that face, sticking `size.Z` out of it.
local function onFront(
	model: Model,
	part: BasePart,
	name: string,
	size: Vector3,
	x: number,
	y: number,
	color: Color3
): Part
	return decoration(name, size, part.CFrame * CFrame.new(x, y, -part.Size.Z / 2 - size.Z / 2 + 0.02), color, model)
end

-- A thin plate lying flush on one side face (X = +1 right, -1 left) of `part`.
local function sidePlate(
	model: Model,
	part: BasePart,
	name: string,
	side: number,
	size: Vector2, -- (along Z, along Y)
	y: number,
	z: number,
	color: Color3,
	tilt: number?
): Part
	return decoration(
		name,
		Vector3.new(FLUSH, size.Y, size.X),
		part.CFrame * CFrame.new(side * (part.Size.X / 2 + FLUSH / 2 - 0.01), y, z) * CFrame.Angles(tilt or 0, 0, 0),
		color,
		model
	)
end

local function nostrils(model: Model, part: BasePart, spread: number, y: number, size: number, color: Color3)
	for _, side in { -1, 1 } do
		ungrimed(onFront(model, part, "Nostril", Vector3.new(size, size * 0.75, 0.06), side * spread, y, color))
	end
end

local function mouthLine(model: Model, part: BasePart, width: number, y: number, color: Color3)
	ungrimed(onFront(model, part, "Mouth", Vector3.new(width, 0.08, 0.05), 0, y, color))
	for _, side in { -1, 1 } do
		ungrimed(
			decoration(
				"MouthCorner",
				Vector3.new(0.08, 0.14, 0.05),
				part.CFrame * CFrame.new(side * (width / 2 - 0.02), y + 0.05, -part.Size.Z / 2 - 0.01),
				color,
				model
			)
		)
	end
end

-- Upright ears on the head's top edge, each with a contrasting inner plate.
local function upEars(
	model: Model,
	head: BasePart,
	size: Vector3,
	color: Color3,
	inner: Color3?,
	spread: number,
	out: number,
	back: number,
	tip: Color3?
)
	local h = head.Size
	for _, side in { -1, 1 } do
		local cf = head.CFrame
			* CFrame.new(side * h.X * spread, h.Y / 2 - 0.08, 0.05)
			* CFrame.Angles(-back, 0, -side * out)
			* CFrame.new(0, size.Y / 2, 0)
		decoration("Ear", size, cf, color, model)
		if inner then
			decoration(
				"EarInner",
				Vector3.new(size.X * 0.55, size.Y * 0.7, 0.05),
				cf * CFrame.new(0, -size.Y * 0.08, -size.Z / 2 - 0.02),
				inner,
				model
			)
		end
		if tip then
			decoration(
				"EarTip",
				Vector3.new(size.X + 0.04, size.Y * 0.28, size.Z + 0.04),
				cf * CFrame.new(0, size.Y * 0.37, 0),
				tip,
				model
			)
		end
	end
end

-- Ears hanging off the sides of the head (dogs, cows, goats).
local function sideEars(
	model: Model,
	head: BasePart,
	size: Vector3,
	color: Color3,
	y: number,
	droop: number,
	z: number?
)
	local h = head.Size
	for _, side in { -1, 1 } do
		decoration(
			"Ear",
			size,
			head.CFrame
				* CFrame.new(side * (h.X / 2 + 0.02), y, z or 0.1)
				* CFrame.Angles(0, 0, side * droop)
				* CFrame.new(side * size.X / 2, 0, 0),
			color,
			model
		)
	end
end

-- Leg detail. Tagged LegPart so the walk cycle swings it with the leg it sits on.
local function legPart(part: Part): Part
	part:SetAttribute("LegPart", true)
	return part
end

-- `which` limits it to the "Front" or "Back" legs (animals face -Z, built at the origin).
local function socks(model: Model, color: Color3, fraction: number, which: string?)
	for _, leg in legsOf(model) do
		local front = leg.Position.Z < 0
		if (which == "Front" and not front) or (which == "Back" and front) then
			continue
		end
		local l = leg.Size
		local height = l.Y * fraction
		legPart(
			decoration(
				"Sock",
				Vector3.new(l.X + 0.06, height, l.Z + 0.06),
				leg.CFrame * CFrame.new(0, -l.Y / 2 + height / 2, 0),
				color,
				model
			)
		)
	end
end

local function hooves(model: Model, color: Color3)
	for _, leg in legsOf(model) do
		local l = leg.Size
		local height = math.clamp(l.Y * 0.16, 0.18, 0.45)
		legPart(
			decoration(
				"Hoof",
				Vector3.new(l.X * 1.15, height, l.Z * 1.2),
				leg.CFrame * CFrame.new(0, -l.Y / 2 + height / 2, -l.Z * 0.05),
				color,
				model
			)
		)
		legPart(
			ungrimed(
				decoration(
					"HoofSplit",
					Vector3.new(0.07, height * 0.8, 0.06),
					leg.CFrame * CFrame.new(0, -l.Y / 2 + height * 0.45, -l.Z * 0.65 - 0.02),
					tint(color, -0.45),
					model
				)
			)
		)
	end
end

local function paws(model: Model, color: Color3, toeColor: Color3, toes: number?)
	for _, leg in legsOf(model) do
		local l = leg.Size
		local w = l.X * 1.15
		legPart(
			decoration(
				"Paw",
				Vector3.new(w, 0.26, l.Z * 1.35),
				leg.CFrame * CFrame.new(0, -l.Y / 2 + 0.13, -l.Z * 0.17),
				color,
				model
			)
		)
		local count = toes or 3
		for i = 1, count do
			local x = (i - (count + 1) / 2) * w * 0.3
			legPart(
				ungrimed(
					decoration(
						"Toe",
						Vector3.new(0.06, 0.14, 0.08),
						leg.CFrame * CFrame.new(x + w * 0.15, -l.Y / 2 + 0.16, -l.Z * 0.85 - 0.03),
						toeColor,
						model
					)
				)
			)
		end
	end
end

-- Bird feet: three toes splayed forward and one back.
local function birdFeet(model: Model, color: Color3)
	for _, leg in legsOf(model) do
		local l = leg.Size
		for _, yaw in { -0.45, 0, 0.45 } do
			legPart(
				decoration(
					"Toe",
					Vector3.new(0.14, 0.1, 0.55),
					leg.CFrame * CFrame.new(0, -l.Y / 2 + 0.05, 0) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0, -0.27),
					color,
					model
				)
			)
		end
		legPart(
			decoration(
				"Toe",
				Vector3.new(0.12, 0.09, 0.3),
				leg.CFrame * CFrame.new(0, -l.Y / 2 + 0.05, 0.15),
				color,
				model
			)
		)
	end
end

-- Webbed feet: a flat fan.
local function webFeet(model: Model, color: Color3)
	for _, leg in legsOf(model) do
		local l = leg.Size
		legPart(
			decoration(
				"Foot",
				Vector3.new(0.6, 0.08, 0.6),
				leg.CFrame * CFrame.new(0, -l.Y / 2 + 0.04, -0.2),
				color,
				model
			)
		)
		legPart(
			wedge(
				"FootTip",
				Vector3.new(0.6, 0.08, 0.25),
				leg.CFrame * CFrame.new(0, -l.Y / 2 + 0.04, -0.62),
				color,
				model
			)
		)
	end
end

-- The underside, which never carries mud.
local function bellyPlate(model: Model, body: BasePart, color: Color3, width: number?)
	local b = body.Size
	decoration(
		"Belly",
		Vector3.new(b.X * (width or 0.8), 0.14, b.Z * 0.82),
		body.CFrame * CFrame.new(0, -b.Y / 2 - 0.06, 0),
		color,
		model
	)
end

-- Something on the body's front face (chest), which never carries mud.
local function chest(model: Model, body: BasePart, size: Vector3, y: number, color: Color3): Part
	return onFront(model, body, "Chest", size, 0, y, color)
end

-- A block-segment tail leaving the rump at height `y` (body space), pointing back and
-- curving by `turn` (X pitches it up, Y swings it sideways) each segment.
type TailOptions = {
	Count: number,
	Length: number,
	Size: number,
	EndSize: number,
	Turn: Vector2,
	Color: Color3,
	EndColor: Color3?,
	Y: number?,
	Pitch: number?, -- radians up (+) or down (-) where it leaves the body
	Aspect: Vector2?,
}

local function blockTail(model: Model, body: BasePart, opts: TailOptions): { Part }
	local b = body.Size
	local start = body.CFrame
		* CFrame.new(0, opts.Y or b.Y * 0.3, b.Z / 2 + opts.Length * 0.35)
		* CFrame.Angles(0, math.pi, 0)
		* CFrame.Angles(opts.Pitch or 0, 0, 0)
	return chain({
		Name = "Tail",
		Start = start,
		Count = opts.Count,
		Length = opts.Length,
		Size = opts.Size,
		EndSize = opts.EndSize,
		Turn = opts.Turn,
		Color = opts.Color,
		EndColor = opts.EndColor,
		Block = true,
		Aspect = opts.Aspect,
	}, model)
end

-- A row of tufts or ridge blocks along the body's top centre line (only on animals whose
-- top is too high to carry mud).
local function ridge(
	model: Model,
	part: BasePart,
	count: number,
	size: Vector3,
	color: Color3,
	rise: number?,
	zFrom: number?,
	zTo: number?
)
	local s = part.Size
	local from = zFrom or -s.Z / 2 + size.Z / 2
	local to = zTo or s.Z / 2 - size.Z / 2
	for i = 1, count do
		local t = if count > 1 then (i - 1) / (count - 1) else 0.5
		decoration(
			"Ridge",
			size,
			part.CFrame
				* CFrame.new(
					0,
					s.Y / 2 + size.Y / 2 - 0.05 + (rise or 0) * math.sin(t * math.pi),
					from + (to - from) * t
				),
			color,
			model
		)
	end
end

-- Any triangle in model space from two wedges (wing membranes, frills). `thickness` is the
-- sheet's depth.
local function sheet(
	name: string,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	thickness: number,
	color: Color3,
	parent: Instance
): { Part }
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab)
	if right.Magnitude < 1e-4 then
		return {}
	end
	right = right.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	return {
		wedge(
			name,
			Vector3.new(thickness, height, math.abs(ab:Dot(back))),
			CFrame.fromMatrix((a + b) / 2, right, up, back),
			color,
			parent
		),
		wedge(
			name,
			Vector3.new(thickness, height, math.abs(ac:Dot(back))),
			CFrame.fromMatrix((a + c) / 2, -right, up, -back),
			color,
			parent
		),
	}
end

local SPECS: { [string]: Spec } = {
	Chicken = {
		BodySize = Vector3.new(1.6, 1.5, 2.0),
		LegHeight = 0.8,
		LegCount = 2,
		LegThickness = 0.22,
		LegColor = ORANGE,
		HeadSize = Vector3.new(1.0, 1.1, 1.0),
		HeadLift = 0.9,
		BodyColor = Color3.fromRGB(250, 250, 245),
		HeadColor = Color3.fromRGB(250, 250, 245),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 0.75,
		Decorate = function(model, body, head, _spec)
			local b, h = body.Size, head.Size
			local red = Color3.fromRGB(225, 45, 45)
			local feather = Color3.fromRGB(236, 232, 222)
			-- Beak in two halves, a stepped comb and a wattle.
			onFront(model, head, "Beak", Vector3.new(0.36, 0.18, 0.42), 0, -0.02, ORANGE)
			onFront(model, head, "BeakLow", Vector3.new(0.28, 0.12, 0.3), 0, -0.17, Color3.fromRGB(230, 130, 30))
			for i, step in { { -0.28, 0.3 }, { 0, 0.42 }, { 0.26, 0.34 } } do
				decoration(
					"Comb",
					Vector3.new(0.18, step[2], 0.26),
					head.CFrame * CFrame.new(0, h.Y / 2 + step[2] / 2 - 0.05, step[1]),
					if i == 2 then red else tint(red, -0.1),
					model
				)
			end
			onFront(model, head, "Wattle", Vector3.new(0.18, 0.36, 0.12), 0, -0.42, red)
			-- Folded wings, flush on the body sides, with darker flight feathers.
			for _, side in { -1, 1 } do
				sidePlate(model, body, "Wing", side, Vector2.new(1.3, 0.85), 0.15, 0.15, feather)
				for i = 0, 2 do
					sidePlate(
						model,
						body,
						"Flight",
						side,
						Vector2.new(0.35, 0.5),
						-0.25,
						0.25 + i * 0.32,
						tint(feather, -0.12)
					)
				end
			end
			-- A puffed chest and a fan of tail feathers above the rump.
			chest(model, body, Vector3.new(b.X * 0.8, b.Y * 0.6, 0.25), 0.05, WHITE)
			for i, angle in { -0.4, -0.13, 0.13, 0.4 } do
				decoration(
					"TailFeather",
					Vector3.new(0.26, 1.05, 0.16),
					body.CFrame
						* CFrame.new((i - 2.5) * 0.28, b.Y * 0.5, b.Z / 2 - 0.05)
						* CFrame.Angles(-0.55, 0, angle)
						* CFrame.new(0, 0.4, 0),
					if i % 2 == 0 then feather else WHITE,
					model
				)
			end
			bellyPlate(model, body, feather)
			birdFeet(model, ORANGE)
			addEyes(head, model)
		end,
	},
	Duck = {
		BodySize = Vector3.new(1.7, 1.3, 2.4),
		LegHeight = 0.55,
		LegCount = 2,
		LegThickness = 0.22,
		LegColor = ORANGE,
		HeadSize = Vector3.new(0.95, 1.0, 1.0),
		HeadLift = 1.0,
		BodyColor = Color3.fromRGB(196, 196, 190),
		HeadColor = Color3.fromRGB(35, 125, 70),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 0.75,
		Decorate = function(model, body, head, _spec)
			local b, h = body.Size, head.Size
			local bill = Color3.fromRGB(255, 200, 40)
			local brown = Color3.fromRGB(125, 70, 45)
			-- A wide flat bill with a dark nail and nostrils.
			local upper = onFront(model, head, "Bill", Vector3.new(0.66, 0.18, 0.6), 0, -0.18, bill)
			onFront(model, head, "BillLow", Vector3.new(0.56, 0.1, 0.5), 0, -0.32, Color3.fromRGB(235, 160, 30))
			onFront(model, upper, "BillNail", Vector3.new(0.18, 0.1, 0.06), 0, 0.02, Color3.fromRGB(60, 50, 40))
			for _, side in { -1, 1 } do
				ungrimed(
					decoration(
						"Nostril",
						Vector3.new(0.07, 0.04, 0.12),
						upper.CFrame * CFrame.new(side * 0.12, 0.1, -0.05),
						Color3.fromRGB(80, 60, 30),
						model
					)
				)
			end
			-- White neck ring and a chestnut breast on the front.
			decoration(
				"NeckRing",
				Vector3.new(h.X + 0.06, 0.16, h.Z + 0.06),
				head.CFrame * CFrame.new(0, -h.Y / 2 + 0.08, 0),
				WHITE,
				model
			)
			chest(model, body, Vector3.new(b.X * 0.9, b.Y * 0.75, 0.3), 0.05, brown)
			-- Wings flush on the sides with the blue speculum stripe.
			for _, side in { -1, 1 } do
				sidePlate(model, body, "Wing", side, Vector2.new(1.6, 0.75), 0.18, 0.2, Color3.fromRGB(150, 145, 140))
				sidePlate(model, body, "Speculum", side, Vector2.new(0.7, 0.22), 0.02, 0.5, Color3.fromRGB(60, 90, 220))
			end
			-- A black rump with the curled drake feather, then a white tail.
			decoration(
				"Rump",
				Vector3.new(b.X * 0.7, 0.5, 0.35),
				body.CFrame * CFrame.new(0, b.Y * 0.3, b.Z / 2 + 0.12),
				INK,
				model
			)
			decoration(
				"TailCurl",
				Vector3.new(0.16, 0.4, 0.16),
				body.CFrame * CFrame.new(0, b.Y * 0.62, b.Z / 2 + 0.2) * CFrame.Angles(0.6, 0, 0),
				INK,
				model
			)
			wedge(
				"Tail",
				Vector3.new(b.X * 0.6, 0.35, 0.5),
				body.CFrame * CFrame.new(0, b.Y * 0.2, b.Z / 2 + 0.45) * CFrame.Angles(0.35, math.pi, 0),
				WHITE,
				model
			)
			bellyPlate(model, body, Color3.fromRGB(215, 212, 205))
			webFeet(model, ORANGE)
			addEyes(head, model)
		end,
	},
	Rabbit = {
		BodySize = Vector3.new(1.6, 1.6, 2.2),
		LegHeight = 0.5,
		LegThickness = 0.45,
		HeadSize = Vector3.new(1.3, 1.2, 1.2),
		HeadLift = 0.2,
		BodyColor = Color3.fromRGB(200, 180, 160),
		HeadColor = Color3.fromRGB(200, 180, 160),
		BodyMaterial = Enum.Material.Fabric,
		PatchCell = 0.8,
		Decorate = function(model, body, head, spec)
			local b = body.Size
			local cream = Color3.fromRGB(245, 238, 228)
			upEars(model, head, Vector3.new(0.34, 1.45, 0.16), spec.HeadColor, PINK, 0.24, 0.1, 0.2)
			-- White muzzle with a pink nose, buck teeth and whiskers.
			local snout = onFront(model, head, "Muzzle", Vector3.new(0.7, 0.45, 0.22), 0, -0.25, cream)
			onFront(model, snout, "Nose", Vector3.new(0.22, 0.16, 0.06), 0, 0.14, PINK_DARK)
			onFront(model, snout, "Teeth", Vector3.new(0.22, 0.18, 0.05), 0, -0.24, WHITE)
			ungrimed(
				onFront(model, snout, "Split", Vector3.new(0.03, 0.16, 0.06), 0, -0.24, Color3.fromRGB(200, 200, 200))
			)
			whiskers(model, head, Color3.fromRGB(240, 240, 240))
			-- Cheek puffs and a cream chest.
			for _, side in { -1, 1 } do
				onFront(
					model,
					head,
					"Cheek",
					Vector3.new(0.3, 0.3, 0.12),
					side * 0.42,
					-0.28,
					tint(spec.HeadColor, 0.15)
				)
			end
			chest(model, body, Vector3.new(b.X * 0.6, b.Y * 0.6, 0.15), -0.1, cream)
			-- A fluffy cube-cluster tail.
			for _, offset in { Vector3.new(0, 0.2, 0), Vector3.new(0.15, 0.05, 0.12), Vector3.new(-0.15, 0.05, 0.12) } do
				decoration(
					"Tail",
					Vector3.new(0.48, 0.48, 0.4),
					body.CFrame * CFrame.new(offset + Vector3.new(0, 0.25, b.Z / 2 + 0.15)),
					WHITE,
					model
				)
			end
			-- Big hind feet.
			for _, leg in legsOf(model) do
				local back = leg.Position.Z > 0
				local l = leg.Size
				legPart(
					decoration(
						"Paw",
						Vector3.new(l.X * 1.2, 0.2, if back then 1.0 else 0.55),
						leg.CFrame * CFrame.new(0, -l.Y / 2 + 0.1, if back then -0.25 else -0.1),
						cream,
						model
					)
				)
			end
			bellyPlate(model, body, cream)
			addEyes(head, model)
		end,
	},
	Pig = {
		BodySize = Vector3.new(3.4, 3, 5.5),
		LegHeight = 1.2,
		HeadSize = Vector3.new(2.6, 2.4, 2.4),
		BodyColor = PINK,
		HeadColor = PINK,
		BodyMaterial = Enum.Material.SmoothPlastic,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local snoutColor = Color3.fromRGB(250, 150, 165)
			-- A stubby snout with a rim and two deep nostrils.
			local snout = onFront(model, head, "Snout", Vector3.new(1.3, 0.95, 0.5), 0, -0.35, snoutColor)
			onFront(model, snout, "SnoutRim", Vector3.new(1.1, 0.75, 0.05), 0, 0, tint(snoutColor, 0.12))
			nostrils(model, snout, 0.27, 0, 0.26, Color3.fromRGB(160, 70, 90))
			mouthLine(model, head, 1.0, -h.Y * 0.4, Color3.fromRGB(170, 80, 100))
			-- Ears flopped forward over the eyes' corners.
			for _, side in { -1, 1 } do
				local ear = head.CFrame
					* CFrame.new(side * h.X * 0.32, h.Y / 2 - 0.05, -0.2)
					* CFrame.Angles(-0.9, 0, -side * 0.25)
					* CFrame.new(0, 0.4, 0)
				decoration("Ear", Vector3.new(0.75, 0.85, 0.16), ear, spec.HeadColor, model)
				decoration(
					"EarInner",
					Vector3.new(0.45, 0.55, 0.05),
					ear * CFrame.new(0, -0.05, -0.1),
					PINK_DARK,
					model
				)
				onFront(
					model,
					head,
					"Cheek",
					Vector3.new(0.45, 0.3, 0.08),
					side * 0.85,
					-0.45,
					Color3.fromRGB(255, 150, 170)
				)
			end
			-- A corkscrew tail, a darker belly and split trotters.
			blockTail(model, body, {
				Count = 6,
				Length = 0.22,
				Size = 0.26,
				EndSize = 0.2,
				Turn = Vector2.new(math.rad(55), math.rad(40)),
				Color = PINK_DARK,
				Y = b.Y * 0.25,
				Pitch = math.rad(30),
			})
			chest(model, body, Vector3.new(b.X * 0.7, b.Y * 0.55, 0.12), -0.2, Color3.fromRGB(255, 185, 195))
			bellyPlate(model, body, PINK_DARK, 0.6)
			hooves(model, Color3.fromRGB(200, 110, 125))
			addEyes(head, model)
		end,
	},
	Sheep = {
		BodySize = Vector3.new(3.8, 3.4, 6),
		LegHeight = 1.6,
		LegColor = Color3.fromRGB(70, 60, 60),
		HeadSize = Vector3.new(2, 2.2, 2.4),
		BodyColor = Color3.fromRGB(245, 245, 235),
		HeadColor = Color3.fromRGB(70, 60, 60),
		BodyMaterial = Enum.Material.Fabric,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local wool = spec.BodyColor
			local woolShade = tint(wool, -0.06)
			-- Wool: chunky cubes along the back (too high for mud), a fleece cap and cheek puffs.
			for row = 0, 3 do
				for _, x in { -1, 0, 1 } do
					local size = 1.05 + ((row + x) % 2) * 0.2
					decoration(
						"Wool",
						Vector3.new(size, 0.7, size),
						body.CFrame * CFrame.new(x * 1.15, b.Y / 2 + 0.25, -2.2 + row * 1.45),
						if (row + x) % 2 == 0 then wool else woolShade,
						model
					)
				end
			end
			for _, x in { -0.45, 0.45 } do
				decoration(
					"WoolCap",
					Vector3.new(0.85, 0.55, 0.9),
					head.CFrame * CFrame.new(x, h.Y / 2 + 0.2, 0.15),
					wool,
					model
				)
			end
			decoration(
				"WoolCap",
				Vector3.new(0.8, 0.5, 0.7),
				head.CFrame * CFrame.new(0, h.Y / 2 + 0.35, -0.35),
				woolShade,
				model
			)
			chest(model, body, Vector3.new(b.X * 0.85, b.Y * 0.8, 0.45), 0, woolShade)
			-- Woolly cuffs at the top of each leg.
			for _, leg in legsOf(model) do
				local l = leg.Size
				legPart(
					decoration(
						"WoolCuff",
						Vector3.new(l.X + 0.4, 0.6, l.Z + 0.4),
						leg.CFrame * CFrame.new(0, l.Y / 2 - 0.3, 0),
						wool,
						model
					)
				)
			end
			-- Dark face: ears sticking out sideways, a lighter muzzle, a nose and mouth.
			sideEars(model, head, Vector3.new(0.9, 0.35, 0.5), spec.HeadColor, h.Y * 0.18, -0.25)
			local snout =
				onFront(model, head, "Muzzle", Vector3.new(1.2, 0.8, 0.3), 0, -0.55, Color3.fromRGB(95, 85, 85))
			onFront(model, snout, "Nose", Vector3.new(0.5, 0.25, 0.06), 0, 0.15, INK)
			mouthLine(model, snout, 0.5, -0.2, INK)
			decoration(
				"Tail",
				Vector3.new(0.8, 0.8, 0.7),
				body.CFrame * CFrame.new(0, b.Y * 0.2, b.Z / 2 + 0.3),
				wool,
				model
			)
			hooves(model, INK)
			addEyes(head, model)
		end,
	},
	Goat = {
		BodySize = Vector3.new(2.6, 2.4, 4.2),
		LegHeight = 1.6,
		LegThickness = 0.55,
		HeadSize = Vector3.new(1.5, 1.7, 1.8),
		HeadLift = 0.4,
		BodyColor = Color3.fromRGB(235, 230, 220),
		HeadColor = Color3.fromRGB(235, 230, 220),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.2,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local horn = Color3.fromRGB(150, 135, 115)
			local brown = Color3.fromRGB(150, 110, 80)
			-- Ridged horns curving back over the head.
			for _, side in { -1, 1 } do
				chain({
					Name = "Horn",
					Start = facing(
						(head.CFrame * CFrame.new(side * 0.4, h.Y / 2, -0.1)).Position,
						Vector3.new(side * 0.25, 1, 0.5)
					),
					Count = 5,
					Length = 0.3,
					Size = 0.34,
					EndSize = 0.16,
					Turn = Vector2.new(math.rad(-28), 0),
					Color = horn,
					EndColor = tint(horn, -0.3),
					Block = true,
				}, model)
			end
			sideEars(model, head, Vector3.new(0.8, 0.28, 0.4), spec.HeadColor, h.Y * 0.15, 0.35)
			-- Long face: muzzle, nostrils, a beard, and a brown saddle stripe down the back.
			local snout =
				onFront(model, head, "Muzzle", Vector3.new(1.0, 0.75, 0.45), 0, -0.45, tint(spec.HeadColor, 0.05))
			nostrils(model, snout, 0.22, 0.12, 0.14, Color3.fromRGB(90, 70, 70))
			mouthLine(model, snout, 0.45, -0.22, Color3.fromRGB(110, 90, 85))
			decoration(
				"Beard",
				Vector3.new(0.4, 0.75, 0.3),
				snout.CFrame * CFrame.new(0, -0.7, -0.05),
				Color3.fromRGB(210, 205, 195),
				model
			)
			decoration(
				"Stripe",
				Vector3.new(0.5, 0.08, b.Z * 0.9),
				body.CFrame * CFrame.new(0, b.Y / 2 + 0.03, 0),
				brown,
				model
			)
			for _, side in { -1, 1 } do
				sidePlate(model, body, "Patch", side, Vector2.new(1.4, 1.0), 0.3, 0.6, tint(brown, 0.35))
			end
			-- A cowbell on a red collar, a perky tail and split hooves.
			chest(model, body, Vector3.new(b.X * 0.7, 0.3, 0.12), b.Y * 0.3, Color3.fromRGB(200, 40, 40))
			local bell = chest(model, body, Vector3.new(0.45, 0.5, 0.35), b.Y * 0.05, GILT)
			onFront(model, bell, "Clapper", Vector3.new(0.15, 0.15, 0.06), 0, -0.2, INK)
			blockTail(model, body, {
				Count = 2,
				Length = 0.3,
				Size = 0.35,
				EndSize = 0.25,
				Turn = Vector2.new(math.rad(25), 0),
				Color = spec.BodyColor,
				Y = b.Y * 0.35,
				Pitch = math.rad(50),
			})
			bellyPlate(model, body, tint(spec.BodyColor, 0.1))
			hooves(model, Color3.fromRGB(70, 60, 55))
			addEyes(head, model)
		end,
	},
	Donkey = {
		BodySize = Vector3.new(3.0, 2.8, 5.4),
		LegHeight = 2.0,
		LegThickness = 0.7,
		HeadSize = Vector3.new(1.6, 1.8, 2.6),
		HeadLift = 0.6,
		BodyColor = Color3.fromRGB(140, 135, 135),
		HeadColor = Color3.fromRGB(140, 135, 135),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.3,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local pale = Color3.fromRGB(225, 220, 215)
			local dark = Color3.fromRGB(70, 65, 65)
			-- Tall ears with dark tips, a pale muzzle and eye rings.
			upEars(
				model,
				head,
				Vector3.new(0.4, 1.5, 0.22),
				spec.HeadColor,
				Color3.fromRGB(200, 190, 190),
				0.3,
				0.2,
				0.15,
				dark
			)
			local snout = onFront(model, head, "Muzzle", Vector3.new(1.5, 0.9, 0.3), 0, -0.4, pale)
			nostrils(model, snout, 0.35, 0.12, 0.2, dark)
			mouthLine(model, snout, 0.8, -0.28, dark)
			-- A short stand-up mane, the dark stripe down the back and the shoulder cross.
			ridge(model, head, 3, Vector3.new(0.3, 0.45, 0.6), dark, 0.1, 0.1, h.Z / 2 - 0.2)
			ridge(model, body, 6, Vector3.new(0.3, 0.4, 0.8), dark, 0, -b.Z / 2 + 0.4, -b.Z / 2 + 1.6)
			decoration(
				"Stripe",
				Vector3.new(0.4, 0.06, b.Z * 0.9),
				body.CFrame * CFrame.new(0, b.Y / 2 + 0.03, 0.2),
				dark,
				model
			)
			for _, side in { -1, 1 } do
				sidePlate(model, body, "Cross", side, Vector2.new(0.3, 1.4), 0.6, -1.6, dark)
			end
			-- A tufted tail, pale belly and leg bands.
			local tail = blockTail(model, body, {
				Count = 5,
				Length = 0.4,
				Size = 0.22,
				EndSize = 0.2,
				Turn = Vector2.new(math.rad(-10), 0),
				Color = spec.BodyColor,
				Y = b.Y * 0.4,
				Pitch = math.rad(-40),
			})
			decoration(
				"TailTuft",
				Vector3.new(0.45, 0.7, 0.45),
				tail[#tail].CFrame * CFrame.new(0, 0, -0.4),
				dark,
				model
			)
			chest(model, body, Vector3.new(b.X * 0.6, b.Y * 0.6, 0.15), -0.3, pale)
			bellyPlate(model, body, pale)
			socks(model, pale, 0.25)
			hooves(model, dark)
			addEyes(head, model, true)
		end,
	},
	Cow = {
		BodySize = Vector3.new(4.4, 4, 6.4), -- shorter so the whole cow fits a 12-stud pen
		LegHeight = 2.4,
		HeadSize = Vector3.new(2.8, 2.8, 3),
		BodyColor = Color3.fromRGB(250, 250, 250),
		HeadColor = Color3.fromRGB(250, 250, 250),
		BodyMaterial = Enum.Material.SmoothPlastic,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local black = Color3.fromRGB(30, 30, 30)
			local pink = Color3.fromRGB(240, 175, 180)
			-- Black spots flush on the sides and back, and one over an eye.
			for _, spot in
				{
					{ 1, 0.6, -1.5, 1.8, 2.1 },
					{ 1, -0.5, 1.9, 1.3, 1.6 },
					{ -1, 0.3, 0.4, 2.0, 2.4 },
					{ -1, -0.7, -2.2, 1.0, 1.2 },
				}
			do
				sidePlate(model, body, "Spot", spot[1], Vector2.new(spot[5], spot[4]), spot[2], spot[3], black)
			end
			decoration(
				"Spot",
				Vector3.new(1.6, FLUSH, 1.8),
				body.CFrame * CFrame.new(0.6, b.Y / 2 + 0.01, 0.8),
				black,
				model
			)
			onFront(model, head, "EyeSpot", Vector3.new(1.0, 0.9, 0.04), -h.X * 0.27, h.Y * 0.2, black)
			-- A big pink muzzle with nostrils, curved horns, ears and a forelock tuft.
			local snout = onFront(model, head, "Muzzle", Vector3.new(h.X * 0.85, h.Y * 0.42, 0.5), 0, -h.Y * 0.28, pink)
			nostrils(model, snout, 0.45, 0.1, 0.26, Color3.fromRGB(150, 80, 90))
			mouthLine(model, snout, 1.2, -0.38, Color3.fromRGB(170, 100, 110))
			for _, side in { -1, 1 } do
				chain({
					Name = "Horn",
					Start = facing(
						(head.CFrame * CFrame.new(side * h.X * 0.36, h.Y / 2 - 0.1, 0)).Position,
						Vector3.new(side, 0.4, 0)
					),
					Count = 3,
					Length = 0.32,
					Size = 0.32,
					EndSize = 0.2,
					Turn = Vector2.new(math.rad(30), 0),
					Color = Color3.fromRGB(240, 230, 205),
					EndColor = Color3.fromRGB(120, 110, 95),
					Block = true,
				}, model)
			end
			sideEars(model, head, Vector3.new(0.9, 0.4, 0.6), spec.HeadColor, h.Y * 0.18, -0.2)
			decoration(
				"Forelock",
				Vector3.new(0.9, 0.35, 0.6),
				head.CFrame * CFrame.new(0, h.Y / 2 + 0.1, -0.4),
				black,
				model
			)
			-- A cowbell, udder, tufted tail and dark hooves.
			decoration(
				"Strap",
				Vector3.new(h.X * 0.9, 0.25, 0.25),
				head.CFrame * CFrame.new(0, -h.Y / 2 + 0.1, 0.2),
				Color3.fromRGB(140, 80, 40),
				model
			)
			local bell = decoration(
				"Bell",
				Vector3.new(0.7, 0.75, 0.6),
				head.CFrame * CFrame.new(0, -h.Y / 2 - 0.35, -0.1),
				GILT,
				model
			)
			onFront(model, bell, "Clapper", Vector3.new(0.2, 0.2, 0.06), 0, -0.3, INK)
			decoration(
				"Udder",
				Vector3.new(1.2, 0.5, 1.2),
				body.CFrame * CFrame.new(0, -b.Y / 2 - 0.25, b.Z * 0.25),
				pink,
				model
			)
			for _, x in { -0.35, 0.35 } do
				decoration(
					"Teat",
					Vector3.new(0.16, 0.3, 0.16),
					body.CFrame * CFrame.new(x, -b.Y / 2 - 0.62, b.Z * 0.25),
					tint(pink, -0.1),
					model
				)
			end
			local tail = blockTail(model, body, {
				Count = 5,
				Length = 0.4,
				Size = 0.2,
				EndSize = 0.2,
				Turn = Vector2.new(math.rad(-15), 0),
				Color = spec.BodyColor,
				Y = b.Y * 0.4,
				Pitch = math.rad(-45),
			})
			decoration(
				"TailTuft",
				Vector3.new(0.45, 0.6, 0.45),
				tail[#tail].CFrame * CFrame.new(0, 0, -0.35),
				black,
				model
			)
			bellyPlate(model, body, Color3.fromRGB(235, 235, 235))
			hooves(model, Color3.fromRGB(60, 50, 45))
			addEyes(head, model)
		end,
	},
	Llama = {
		BodySize = Vector3.new(2.8, 2.6, 4.6),
		LegHeight = 2.4,
		LegThickness = 0.6,
		HeadSize = Vector3.new(1.3, 1.4, 1.8),
		Neck = Vector3.new(1.2, 3.0, 1.2),
		BodyColor = Color3.fromRGB(240, 225, 195),
		HeadColor = Color3.fromRGB(240, 225, 195),
		BodyMaterial = Enum.Material.Fabric,
		PatchCell = 1.2,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local neck = model:FindFirstChild("Neck") :: BasePart?
			local fluff = tint(spec.BodyColor, 0.1)
			-- Banana ears curving in, a fluffy top-knot and a split upper lip.
			for _, side in { -1, 1 } do
				chain({
					Name = "Ear",
					Start = facing(
						(head.CFrame * CFrame.new(side * 0.4, h.Y / 2 - 0.05, 0.2)).Position,
						Vector3.new(side * 0.2, 1, 0)
					),
					Count = 3,
					Length = 0.32,
					Size = 0.32,
					EndSize = 0.22,
					Turn = Vector2.new(0, math.rad(side * 18)),
					Color = spec.HeadColor,
					Block = true,
					Aspect = Vector2.new(1, 0.5),
				}, model)
			end
			for _, x in { -0.3, 0.3 } do
				decoration(
					"TopKnot",
					Vector3.new(0.55, 0.45, 0.6),
					head.CFrame * CFrame.new(x, h.Y / 2 + 0.15, -0.2),
					fluff,
					model
				)
			end
			local snout =
				onFront(model, head, "Muzzle", Vector3.new(0.9, 0.6, 0.35), 0, -0.35, tint(spec.HeadColor, -0.05))
			nostrils(model, snout, 0.2, 0.15, 0.13, Color3.fromRGB(110, 90, 80))
			ungrimed(onFront(model, snout, "Lip", Vector3.new(0.05, 0.3, 0.06), 0, -0.1, Color3.fromRGB(150, 120, 100)))
			-- Wool tufts down the front of the neck, and a bright festival blanket with tassels.
			if neck then
				for i = 0, 3 do
					onFront(
						model,
						neck,
						"NeckFluff",
						Vector3.new(1.0, 0.55, 0.25),
						0,
						-1.1 + i * 0.7,
						if i % 2 == 0 then fluff else spec.BodyColor
					)
				end
			end
			local colors = { Color3.fromRGB(230, 60, 90), Color3.fromRGB(255, 190, 40), Color3.fromRGB(60, 170, 220) }
			for i, color in colors do
				decoration(
					"Blanket",
					Vector3.new(b.X + 0.12, 0.12, 0.8),
					body.CFrame * CFrame.new(0, b.Y / 2 + 0.06, -0.8 + (i - 1) * 0.8),
					color,
					model
				)
			end
			for _, side in { -1, 1 } do
				for i = 0, 2 do
					decoration(
						"Tassel",
						Vector3.new(0.18, 0.5, 0.18),
						body.CFrame * CFrame.new(side * (b.X / 2 + 0.1), b.Y / 2 - 0.2, -0.8 + i * 0.8),
						colors[i + 1],
						model
					)
				end
			end
			-- A fluffy tail held up and woolly leg cuffs.
			blockTail(model, body, {
				Count = 3,
				Length = 0.35,
				Size = 0.5,
				EndSize = 0.4,
				Turn = Vector2.new(math.rad(-20), 0),
				Color = fluff,
				Y = b.Y * 0.35,
				Pitch = math.rad(40),
			})
			for _, leg in legsOf(model) do
				local l = leg.Size
				legPart(
					decoration(
						"WoolCuff",
						Vector3.new(l.X + 0.3, 0.6, l.Z + 0.3),
						leg.CFrame * CFrame.new(0, l.Y / 2 - 0.3, 0),
						fluff,
						model
					)
				)
			end
			bellyPlate(model, body, fluff)
			hooves(model, Color3.fromRGB(90, 75, 65))
			addEyes(head, model, true)
		end,
	},
	Horse = {
		BodySize = Vector3.new(3.2, 3.0, 6.4),
		LegHeight = 2.8,
		LegThickness = 0.75,
		HeadSize = Vector3.new(1.4, 1.6, 2.8),
		Neck = Vector3.new(1.4, 2.6, 1.6),
		BodyColor = Color3.fromRGB(150, 95, 55),
		HeadColor = Color3.fromRGB(150, 95, 55),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.4,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local neck = model:FindFirstChild("Neck") :: BasePart?
			local mane = Color3.fromRGB(45, 30, 20)
			-- A long flowing mane down the back of the neck and a forelock over the face.
			if neck then
				local n = neck.Size
				for i = 0, 5 do
					decoration(
						"Mane",
						Vector3.new(0.35, 0.7, 0.55),
						neck.CFrame
							* CFrame.new(if i % 2 == 0 then 0.12 else -0.12, -n.Y / 2 + 0.4 + i * 0.45, n.Z / 2 + 0.15)
							* CFrame.Angles(0.25, 0, 0),
						mane,
						model
					)
				end
			end
			decoration(
				"Forelock",
				Vector3.new(0.5, 0.6, 0.5),
				head.CFrame * CFrame.new(0, h.Y / 2 + 0.05, -h.Z / 2 + 0.6) * CFrame.Angles(-0.4, 0, 0),
				mane,
				model
			)
			-- White blaze down the face, a dark muzzle, ears and a bridle.
			onFront(model, head, "Blaze", Vector3.new(0.35, h.Y * 0.8, 0.04), 0, 0.05, WHITE)
			decoration(
				"Blaze",
				Vector3.new(0.35, FLUSH, h.Z * 0.7),
				head.CFrame * CFrame.new(0, h.Y / 2 + 0.01, -0.3),
				WHITE,
				model
			)
			local snout =
				onFront(model, head, "Muzzle", Vector3.new(h.X + 0.04, 0.8, 0.35), 0, -0.4, Color3.fromRGB(85, 55, 35))
			nostrils(model, snout, 0.3, 0.12, 0.18, INK)
			mouthLine(model, snout, 0.7, -0.25, INK)
			upEars(
				model,
				head,
				Vector3.new(0.35, 0.65, 0.2),
				spec.HeadColor,
				Color3.fromRGB(110, 70, 45),
				0.3,
				0.12,
				0.25
			)
			local strap = Color3.fromRGB(90, 50, 30)
			decoration(
				"Bridle",
				Vector3.new(h.X + 0.08, 0.16, 0.16),
				head.CFrame * CFrame.new(0, -0.15, -h.Z / 2 + 0.55),
				strap,
				model
			)
			decoration(
				"Bridle",
				Vector3.new(h.X + 0.08, 0.16, 0.16),
				head.CFrame * CFrame.new(0, h.Y * 0.3, h.Z / 2 - 0.4),
				strap,
				model
			)
			-- A long flowing tail, white socks on the front legs and dark hooves.
			blockTail(model, body, {
				Count = 6,
				Length = 0.42,
				Size = 0.5,
				EndSize = 0.65,
				Turn = Vector2.new(math.rad(-12), 0),
				Color = mane,
				Y = b.Y * 0.4,
				Pitch = math.rad(10),
				Aspect = Vector2.new(0.7, 1),
			})
			chest(model, body, Vector3.new(b.X * 0.7, b.Y * 0.7, 0.15), 0, tint(spec.BodyColor, 0.08))
			socks(model, WHITE, 0.3, "Front")
			hooves(model, Color3.fromRGB(50, 40, 35))
			addEyes(head, model, true)
		end,
	},
	Dog = {
		BodySize = Vector3.new(2.2, 2.0, 3.6),
		LegHeight = 1.2,
		LegThickness = 0.55,
		HeadSize = Vector3.new(1.6, 1.6, 1.8),
		HeadLift = 0.4,
		BodyColor = Color3.fromRGB(190, 140, 90),
		HeadColor = Color3.fromRGB(190, 140, 90),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.0,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local dark = Color3.fromRGB(110, 70, 40)
			local cream = Color3.fromRGB(245, 230, 205)
			-- Floppy ears, a cream muzzle with a big black nose and a pink tongue out.
			sideEars(model, head, Vector3.new(0.3, 1.0, 0.8), dark, h.Y * 0.2, 0.15, 0.05)
			local snout = onFront(model, head, "Muzzle", Vector3.new(1.0, 0.75, 0.6), 0, -0.35, cream)
			onFront(model, snout, "Nose", Vector3.new(0.45, 0.3, 0.12), 0, 0.2, INK)
			mouthLine(model, snout, 0.6, -0.15, Color3.fromRGB(90, 60, 45))
			onFront(model, snout, "Tongue", Vector3.new(0.3, 0.4, 0.08), 0.12, -0.38, Color3.fromRGB(240, 110, 130))
			decoration(
				"Brow",
				Vector3.new(h.X * 0.85, 0.12, 0.08),
				head.CFrame * CFrame.new(0, h.Y * 0.38, -h.Z / 2 - 0.02),
				dark,
				model
			)
			-- One dark patch over an eye and a saddle on each side.
			onFront(model, head, "EyePatch", Vector3.new(0.6, 0.6, 0.05), h.X * 0.28, h.Y * 0.15, dark)
			for _, side in { -1, 1 } do
				sidePlate(model, body, "Saddle", side, Vector2.new(1.8, 1.0), 0.35, 0.2, dark)
			end
			-- Red collar with a gold tag, a cream chest, white paws, a wagging tail.
			chest(model, body, Vector3.new(b.X * 0.6, b.Y * 0.7, 0.2), -0.1, cream)
			decoration(
				"Collar",
				Vector3.new(h.X + 0.08, 0.28, h.Z * 0.6),
				head.CFrame * CFrame.new(0, -h.Y / 2 + 0.05, 0.3),
				Color3.fromRGB(210, 40, 40),
				model
			)
			local tag = decoration(
				"Tag",
				Vector3.new(0.3, 0.3, 0.08),
				head.CFrame * CFrame.new(0, -h.Y / 2 - 0.2, -0.05),
				GILT,
				model
			)
			ungrimed(tag)
			blockTail(model, body, {
				Count = 4,
				Length = 0.35,
				Size = 0.35,
				EndSize = 0.22,
				Turn = Vector2.new(math.rad(14), 0),
				Color = spec.BodyColor,
				EndColor = cream,
				Y = b.Y * 0.35,
				Pitch = math.rad(40),
			})
			socks(model, cream, 0.3)
			paws(model, cream, Color3.fromRGB(150, 120, 100))
			bellyPlate(model, body, cream)
			addEyes(head, model)
		end,
	},
	Cat = {
		BodySize = Vector3.new(1.8, 1.6, 3.0),
		LegHeight = 1.0,
		LegThickness = 0.42,
		HeadSize = Vector3.new(1.5, 1.4, 1.4),
		HeadLift = 0.35,
		BodyColor = Color3.fromRGB(245, 160, 70),
		HeadColor = Color3.fromRGB(245, 160, 70),
		BodyMaterial = Enum.Material.Fabric,
		PatchCell = 0.85,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local stripe = Color3.fromRGB(200, 100, 35)
			-- Pointy ears with pink insides and white tufts.
			for _, side in { -1, 1 } do
				local base = head.CFrame
					* CFrame.new(side * h.X * 0.3, h.Y / 2 - 0.05, 0.1)
					* CFrame.Angles(0, 0, -side * 0.12)
				triangle("Ear", 0.6, 0.6, 0.18, base, spec.HeadColor, model)
				triangle("EarInner", 0.34, 0.38, 0.05, base * CFrame.new(0, 0.02, -0.1), PINK, model)
			end
			-- White muzzle, pink nose, whiskers and forehead stripes.
			local snout = onFront(model, head, "Muzzle", Vector3.new(0.75, 0.45, 0.2), 0, -0.3, WHITE)
			onFront(model, snout, "Nose", Vector3.new(0.2, 0.14, 0.06), 0, 0.14, PINK_DARK)
			mouthLine(model, snout, 0.35, -0.08, Color3.fromRGB(150, 110, 100))
			whiskers(model, head, WHITE)
			for i = -1, 1 do
				onFront(model, head, "Stripe", Vector3.new(0.1, 0.35, 0.04), i * 0.2, h.Y * 0.35, stripe)
			end
			-- Tabby stripes flush down the sides.
			for i = 0, 3 do
				for _, side in { -1, 1 } do
					sidePlate(model, body, "Stripe", side, Vector2.new(0.22, 1.0), 0.2, -0.9 + i * 0.6, stripe, 0.2)
				end
			end
			-- A bell collar, a long tail curling up, white socks.
			decoration(
				"Collar",
				Vector3.new(h.X + 0.06, 0.18, h.Z * 0.6),
				head.CFrame * CFrame.new(0, -h.Y / 2 + 0.05, 0.3),
				Color3.fromRGB(60, 120, 230),
				model
			)
			ungrimed(
				decoration(
					"Bell",
					Vector3.new(0.22, 0.22, 0.22),
					head.CFrame * CFrame.new(0, -h.Y / 2 - 0.12, -0.05),
					GILT,
					model
				)
			)
			chest(model, body, Vector3.new(b.X * 0.55, b.Y * 0.6, 0.12), -0.1, WHITE)
			blockTail(model, body, {
				Count = 7,
				Length = 0.32,
				Size = 0.3,
				EndSize = 0.24,
				Turn = Vector2.new(math.rad(16), 0),
				Color = spec.BodyColor,
				EndColor = stripe,
				Y = b.Y * 0.3,
				Pitch = math.rad(20),
			})
			socks(model, WHITE, 0.3)
			paws(model, WHITE, PINK)
			bellyPlate(model, body, Color3.fromRGB(255, 220, 180))
			addEyes(head, model)
		end,
	},
	Penguin = {
		BodySize = Vector3.new(2.0, 2.6, 1.8),
		LegHeight = 0.35,
		LegCount = 2,
		LegThickness = 0.4,
		LegColor = ORANGE,
		HeadSize = Vector3.new(1.5, 1.3, 1.5),
		HeadOnTop = true,
		BodyColor = Color3.fromRGB(35, 35, 45),
		HeadColor = Color3.fromRGB(35, 35, 45),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 0.85,
		Decorate = function(model, body, head, _spec)
			local b, h = body.Size, head.Size
			local yellow = Color3.fromRGB(255, 200, 60)
			-- White front in two blocks so it reads rounded, and a white face mask.
			chest(model, body, Vector3.new(b.X * 0.72, b.Y * 0.85, 0.18), -0.1, WHITE)
			chest(model, body, Vector3.new(b.X * 0.5, b.Y * 0.6, 0.28), -0.2, Color3.fromRGB(240, 240, 245))
			onFront(model, head, "Face", Vector3.new(h.X * 0.8, h.Y * 0.7, 0.08), 0, -0.1, WHITE)
			-- Yellow cheek patches, a two-part beak and a little crest.
			for _, side in { -1, 1 } do
				sidePlate(model, head, "Cheek", side, Vector2.new(0.6, 0.45), -0.05, -0.35, yellow)
			end
			local beak = onFront(model, head, "Beak", Vector3.new(0.4, 0.2, 0.45), 0, -0.1, ORANGE)
			onFront(model, head, "BeakLow", Vector3.new(0.3, 0.12, 0.32), 0, -0.25, Color3.fromRGB(230, 130, 30))
			ungrimed(
				onFront(model, beak, "BeakTip", Vector3.new(0.18, 0.1, 0.06), 0, 0.02, Color3.fromRGB(200, 90, 20))
			)
			decoration("Crest", Vector3.new(0.2, 0.3, 0.5), head.CFrame * CFrame.new(0, h.Y / 2 + 0.12, 0), INK, model)
			-- Flippers held out a little, and a short tail.
			for _, side in { -1, 1 } do
				decoration(
					"Flipper",
					Vector3.new(0.2, 1.6, 0.7),
					body.CFrame * CFrame.new(side * (b.X / 2 + 0.12), 0.1, 0) * CFrame.Angles(0, 0, side * 0.3),
					Color3.fromRGB(28, 28, 36),
					model
				)
				decoration(
					"FlipperEdge",
					Vector3.new(0.21, 0.2, 0.72),
					body.CFrame * CFrame.new(side * (b.X / 2 + 0.36), -0.65, 0) * CFrame.Angles(0, 0, side * 0.3),
					WHITE,
					model
				)
			end
			wedge(
				"Tail",
				Vector3.new(0.7, 0.2, 0.5),
				body.CFrame * CFrame.new(0, -b.Y / 2 + 0.15, b.Z / 2 + 0.2) * CFrame.Angles(0, math.pi, 0),
				INK,
				model
			)
			webFeet(model, ORANGE)
			addEyes(head, model)
		end,
	},
	Fox = {
		BodySize = Vector3.new(1.8, 1.6, 3.2),
		LegHeight = 1.0,
		LegThickness = 0.4,
		LegColor = Color3.fromRGB(40, 30, 25),
		HeadSize = Vector3.new(1.5, 1.3, 1.6),
		HeadLift = 0.3,
		BodyColor = Color3.fromRGB(235, 110, 40),
		HeadColor = Color3.fromRGB(235, 110, 40),
		BodyMaterial = Enum.Material.Fabric,
		PatchCell = 0.85,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local dark = Color3.fromRGB(40, 30, 25)
			-- Big pointed ears with black backs, a long white snout and a black nose.
			for _, side in { -1, 1 } do
				local base = head.CFrame
					* CFrame.new(side * h.X * 0.3, h.Y / 2 - 0.05, 0.15)
					* CFrame.Angles(0, 0, -side * 0.1)
				triangle("Ear", 0.65, 0.8, 0.2, base, spec.HeadColor, model)
				triangle("EarInner", 0.36, 0.5, 0.05, base * CFrame.new(0, 0.02, -0.11), WHITE, model)
				triangle("EarBack", 0.66, 0.8, 0.05, base * CFrame.new(0, 0, 0.12), dark, model)
			end
			local snout = onFront(model, head, "Snout", Vector3.new(0.75, 0.5, 0.7), 0, -0.3, WHITE)
			onFront(model, snout, "Nose", Vector3.new(0.26, 0.2, 0.08), 0, 0.15, INK)
			mouthLine(model, snout, 0.4, -0.12, Color3.fromRGB(120, 90, 80))
			for _, side in { -1, 1 } do
				onFront(model, head, "Cheek", Vector3.new(0.42, 0.42, 0.08), side * 0.48, -0.32, WHITE)
				sidePlate(model, head, "CheekSide", side, Vector2.new(0.8, 0.4), -0.35, -0.3, WHITE)
			end
			whiskers(model, head, Color3.fromRGB(60, 50, 45))
			-- White chest bib, and a huge brush tail with a white tip.
			chest(model, body, Vector3.new(b.X * 0.65, b.Y * 0.75, 0.2), -0.05, WHITE)
			local tail = blockTail(model, body, {
				Count = 6,
				Length = 0.45,
				Size = 0.65,
				EndSize = 0.85,
				Turn = Vector2.new(math.rad(9), math.rad(8)),
				Color = spec.BodyColor,
				Y = b.Y * 0.25,
				Pitch = math.rad(15),
			})
			decoration(
				"TailTip",
				Vector3.new(0.8, 0.8, 0.6),
				tail[#tail].CFrame * CFrame.new(0, 0, -0.45),
				WHITE,
				model
			)
			bellyPlate(model, body, WHITE)
			paws(model, dark, Color3.fromRGB(90, 80, 70))
			addEyes(head, model)
		end,
	},
	Zebra = {
		BodySize = Vector3.new(3.0, 2.8, 6.0),
		LegHeight = 2.6,
		LegThickness = 0.7,
		HeadSize = Vector3.new(1.3, 1.5, 2.6),
		Neck = Vector3.new(1.3, 2.4, 1.5),
		BodyColor = Color3.fromRGB(245, 245, 245),
		HeadColor = Color3.fromRGB(245, 245, 245),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.3,
		Decorate = function(model, body, head, _spec)
			local b, h = body.Size, head.Size
			local neck = model:FindFirstChild("Neck") :: BasePart?
			local black = Color3.fromRGB(25, 25, 30)
			-- Bold stripes flush on the body, neck and head, angled like the real thing.
			for i = 0, 7 do
				local z = -b.Z / 2 + 0.5 + i * 0.72
				for _, side in { -1, 1 } do
					sidePlate(
						model,
						body,
						"Stripe",
						side,
						Vector2.new(0.32, b.Y * 0.95),
						0,
						z,
						black,
						-side * 0.15 * (i - 3.5) / 3.5
					)
				end
				decoration(
					"Stripe",
					Vector3.new(b.X + 0.02, FLUSH, 0.32),
					body.CFrame * CFrame.new(0, b.Y / 2 + 0.01, z),
					black,
					model
				)
			end
			if neck then
				for i = 0, 3 do
					for _, side in { -1, 1 } do
						sidePlate(
							model,
							neck,
							"Stripe",
							side,
							Vector2.new(neck.Size.Z + 0.02, 0.28),
							-0.9 + i * 0.6,
							0,
							black
						)
					end
				end
				ridge(model, neck, 5, Vector3.new(0.25, 0.5, 0.35), black, 0, nil, nil)
			end
			for i = 0, 2 do
				for _, side in { -1, 1 } do
					sidePlate(model, head, "Stripe", side, Vector2.new(0.22, h.Y), 0, 0.3 + i * 0.4, black)
				end
			end
			-- Black muzzle, upright ears and a black-and-white tufted tail.
			local snout = onFront(model, head, "Muzzle", Vector3.new(h.X * 0.95, 0.8, 0.3), 0, -0.35, black)
			nostrils(model, snout, 0.3, 0.12, 0.16, Color3.fromRGB(80, 80, 85))
			upEars(model, head, Vector3.new(0.38, 0.8, 0.2), WHITE, PINK, 0.3, 0.2, 0.2, black)
			local tail = blockTail(model, body, {
				Count = 4,
				Length = 0.4,
				Size = 0.2,
				EndSize = 0.2,
				Turn = Vector2.new(math.rad(-10), 0),
				Color = WHITE,
				Y = b.Y * 0.4,
				Pitch = math.rad(-40),
			})
			decoration(
				"TailTuft",
				Vector3.new(0.4, 0.65, 0.4),
				tail[#tail].CFrame * CFrame.new(0, 0, -0.35),
				black,
				model
			)
			socks(model, black, 0.12)
			hooves(model, black)
			addEyes(head, model, true)
		end,
	},
	Panda = {
		BodySize = Vector3.new(3.2, 2.8, 4.4),
		LegHeight = 1.2,
		LegThickness = 1.0,
		LegColor = Color3.fromRGB(25, 25, 30),
		HeadSize = Vector3.new(2.4, 2.2, 2.2),
		HeadLift = 0.4,
		BodyColor = Color3.fromRGB(245, 245, 245),
		HeadColor = Color3.fromRGB(245, 245, 245),
		BodyMaterial = Enum.Material.Fabric,
		PatchCell = 1.1,
		Decorate = function(model, body, head, _spec)
			local b, h = body.Size, head.Size
			local black = Color3.fromRGB(25, 25, 30)
			-- Black shoulder band around the front, round-ish black ears and eye patches.
			for _, side in { -1, 1 } do
				sidePlate(model, body, "Band", side, Vector2.new(1.4, b.Y + 0.02), 0, -b.Z / 2 + 0.7, black)
				decoration(
					"Ear",
					Vector3.new(0.7, 0.6, 0.35),
					head.CFrame * CFrame.new(side * h.X * 0.36, h.Y / 2 + 0.2, 0.2),
					black,
					model
				)
				decoration(
					"EarRim",
					Vector3.new(0.5, 0.25, 0.37),
					head.CFrame * CFrame.new(side * h.X * 0.36, h.Y / 2 + 0.55, 0.2),
					black,
					model
				)
				onFront(model, head, "EyePatch", Vector3.new(0.7, 0.85, 0.05), side * h.X * 0.27, h.Y * 0.1, black)
			end
			decoration(
				"Band",
				Vector3.new(b.X + 0.02, FLUSH, 1.4),
				body.CFrame * CFrame.new(0, b.Y / 2 + 0.01, -b.Z / 2 + 0.7),
				black,
				model
			)
			chest(model, body, Vector3.new(b.X + 0.02, b.Y + 0.02, 0.06), 0, black)
			-- Snout, nose and a bamboo stalk with leaves in its mouth.
			local snout = onFront(model, head, "Muzzle", Vector3.new(1.0, 0.65, 0.4), 0, -0.55, WHITE)
			onFront(model, snout, "Nose", Vector3.new(0.4, 0.25, 0.08), 0, 0.15, black)
			mouthLine(model, snout, 0.5, -0.15, black)
			local green = Color3.fromRGB(90, 180, 70)
			decoration(
				"Bamboo",
				Vector3.new(2.2, 0.2, 0.2),
				snout.CFrame * CFrame.new(0.3, -0.25, -0.1) * CFrame.Angles(0, 0, 0.15),
				green,
				model
			)
			decoration(
				"BambooRing",
				Vector3.new(0.08, 0.24, 0.24),
				snout.CFrame * CFrame.new(0.9, -0.16, -0.1) * CFrame.Angles(0, 0, 0.15),
				tint(green, -0.3),
				model
			)
			wedge(
				"Leaf",
				Vector3.new(0.06, 0.25, 0.6),
				snout.CFrame * CFrame.new(1.25, 0.05, -0.1) * CFrame.Angles(0, 0, -0.6),
				Color3.fromRGB(120, 210, 90),
				model
			)
			decoration(
				"Tail",
				Vector3.new(0.6, 0.5, 0.4),
				body.CFrame * CFrame.new(0, 0.3, b.Z / 2 + 0.2),
				WHITE,
				model
			)
			paws(model, black, Color3.fromRGB(80, 80, 85))
			addEyes(head, model)
		end,
	},
	Lion = {
		BodySize = Vector3.new(3.2, 3.0, 6.0),
		LegHeight = 2.4,
		LegThickness = 0.8,
		HeadSize = Vector3.new(2.4, 2.4, 2.4),
		HeadLift = 0.5,
		BodyColor = Color3.fromRGB(225, 175, 95),
		HeadColor = Color3.fromRGB(225, 175, 95),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.3,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local mane = Color3.fromRGB(150, 80, 30)
			local maneLight = Color3.fromRGB(190, 110, 40)
			-- A big layered mane framing the face (front edge only, so the head sides stay muddy).
			local ring = {
				{ 0, 1, 2.6, 0.7 },
				{ 0, -1, 2.0, 0.6 },
				{ -1, 0, 0.7, 2.4 },
				{ 1, 0, 0.7, 2.4 },
				{ -0.8, 0.8, 0.9, 0.9 },
				{ 0.8, 0.8, 0.9, 0.9 },
				{ -0.8, -0.8, 0.8, 0.8 },
				{ 0.8, -0.8, 0.8, 0.8 },
			}
			for i, piece in ring do
				decoration(
					"Mane",
					Vector3.new(piece[3], piece[4], 0.8),
					head.CFrame * CFrame.new(piece[1] * (h.X / 2 + 0.2), piece[2] * (h.Y / 2 + 0.2), -h.Z / 2 + 0.35),
					if i % 2 == 0 then maneLight else mane,
					model
				)
			end
			-- The mane runs down the chest and over the shoulders (the top is too high for mud).
			chest(model, body, Vector3.new(b.X * 0.85, b.Y * 0.9, 0.5), 0.1, mane)
			ridge(model, body, 3, Vector3.new(b.X * 0.7, 0.45, 0.8), maneLight, 0, -b.Z / 2 + 0.5, -b.Z / 2 + 2)
			-- Muzzle, broad nose, whiskers and small round ears.
			local snout =
				onFront(model, head, "Muzzle", Vector3.new(1.4, 0.8, 0.45), 0, -0.5, Color3.fromRGB(245, 220, 175))
			onFront(model, snout, "Nose", Vector3.new(0.55, 0.32, 0.1), 0, 0.2, Color3.fromRGB(120, 60, 50))
			mouthLine(model, snout, 0.6, -0.2, Color3.fromRGB(110, 70, 50))
			whiskers(model, head, Color3.fromRGB(250, 240, 220))
			upEars(
				model,
				head,
				Vector3.new(0.55, 0.5, 0.25),
				spec.HeadColor,
				Color3.fromRGB(170, 120, 70),
				0.33,
				0.15,
				0
			)
			-- A long tail with a dark tuft, and big paws.
			local tail = blockTail(model, body, {
				Count = 7,
				Length = 0.42,
				Size = 0.26,
				EndSize = 0.22,
				Turn = Vector2.new(math.rad(9), 0),
				Color = spec.BodyColor,
				Y = b.Y * 0.35,
				Pitch = math.rad(-35),
			})
			decoration(
				"TailTuft",
				Vector3.new(0.55, 0.55, 0.7),
				tail[#tail].CFrame * CFrame.new(0, 0, -0.4),
				mane,
				model
			)
			bellyPlate(model, body, Color3.fromRGB(240, 205, 150))
			paws(model, tint(spec.BodyColor, 0.08), Color3.fromRGB(140, 100, 60))
			addEyes(head, model)
		end,
	},
	Hippo = {
		BodySize = Vector3.new(5.0, 3.6, 5.8), -- shorter so the whole hippo fits a 12-stud pen
		LegHeight = 1.4,
		LegThickness = 1.4,
		HeadSize = Vector3.new(3.6, 2.8, 3.4),
		HeadLift = -0.6,
		BodyColor = Color3.fromRGB(150, 130, 165),
		HeadColor = Color3.fromRGB(150, 130, 165),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.6,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local pink = Color3.fromRGB(235, 170, 185)
			-- A wide boxy muzzle, nostrils on top, tusks and a pink mouth line.
			local snout = onFront(
				model,
				head,
				"Muzzle",
				Vector3.new(h.X * 0.95, h.Y * 0.6, 1.0),
				0,
				-h.Y * 0.18,
				tint(spec.HeadColor, 0.06)
			)
			for _, side in { -1, 1 } do
				ungrimed(
					decoration(
						"Nostril",
						Vector3.new(0.32, 0.08, 0.26),
						snout.CFrame * CFrame.new(side * 0.6, snout.Size.Y / 2 + 0.02, -0.2),
						Color3.fromRGB(80, 60, 90),
						model
					)
				)
				wedge(
					"Tusk",
					Vector3.new(0.22, 0.45, 0.22),
					snout.CFrame * CFrame.new(side * 1.1, -snout.Size.Y / 2 - 0.1, -0.35) * CFrame.Angles(math.pi, 0, 0),
					IVORY,
					model
				)
				onFront(model, head, "Cheek", Vector3.new(0.7, 0.45, 0.08), side * 1.2, h.Y * 0.05, pink)
				-- Little ears and eye bumps high on the head.
				decoration(
					"Ear",
					Vector3.new(0.5, 0.45, 0.3),
					head.CFrame * CFrame.new(side * h.X * 0.38, h.Y / 2 + 0.15, 0.6),
					spec.HeadColor,
					model
				)
				decoration(
					"EyeBump",
					Vector3.new(0.7, 0.4, 0.6),
					head.CFrame * CFrame.new(side * h.X * 0.27, h.Y / 2 + 0.1, -h.Z / 2 + 0.5),
					spec.HeadColor,
					model
				)
			end
			mouthLine(model, snout, h.X * 0.8, -snout.Size.Y * 0.25, Color3.fromRGB(190, 110, 130))
			chest(model, body, Vector3.new(b.X * 0.7, b.Y * 0.6, 0.15), -0.4, pink)
			bellyPlate(model, body, pink)
			decoration(
				"Tail",
				Vector3.new(0.3, 0.6, 0.3),
				body.CFrame * CFrame.new(0, 0.4, b.Z / 2 + 0.25) * CFrame.Angles(-0.3, 0, 0),
				spec.BodyColor,
				model
			)
			paws(model, spec.BodyColor, Color3.fromRGB(110, 95, 125), 4)
			addEyes(head, model)
		end,
	},
	Giraffe = {
		BodySize = Vector3.new(3.0, 3.0, 4.8),
		LegHeight = 4.0,
		LegThickness = 0.6,
		HeadSize = Vector3.new(1.2, 1.3, 1.6),
		Neck = Vector3.new(1.1, 5.6, 1.2),
		NeckTilt = math.rad(14),
		BodyColor = Color3.fromRGB(240, 190, 90),
		HeadColor = Color3.fromRGB(240, 190, 90),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.3,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local spot = Color3.fromRGB(165, 95, 40)
			local cream = Color3.fromRGB(250, 230, 185)
			local hoof = Color3.fromRGB(60, 45, 35)
			local neck = model:FindFirstChild("Neck") :: BasePart?

			-- Reticulated patches, painted flush so mud patches still sit on top of them.
			local function paint(part: BasePart, cols: number, rows: number, margin: number, size: number, seed: number)
				local s = part.Size
				for _, side in { -1, 1 } do
					for c = 1, cols do
						for r = 1, rows do
							local k = seed + c * 7 + r * 13 + side * 3
							local z = -s.Z / 2 + margin + (c - 0.5) * (s.Z - 2 * margin) / cols + wobble(k) * 0.25
							local y = -s.Y / 2 + margin + (r - 0.5) * (s.Y - 2 * margin) / rows + wobble(k + 3) * 0.25
							local d = size * (1 + wobble(k + 5) * 0.4)
							decoration(
								"Spot",
								Vector3.new(0.05, d, d * (1 + wobble(k + 9) * 0.3)),
								part.CFrame
									* CFrame.new(side * (s.X / 2 + 0.01), y, z)
									* CFrame.Angles(wobble(k + 11) * 1.2, 0, 0),
								spot,
								model
							)
						end
					end
				end
			end
			paint(body, 4, 3, 0.6, 0.6, 1)
			if neck then
				paint(neck, 1, 5, 0.35, 0.5, 40)
				decoration(
					"Mane",
					Vector3.new(0.25, neck.Size.Y - 0.2, 0.3),
					neck.CFrame * CFrame.new(0, 0.1, neck.Size.Z / 2 + 0.1),
					spot,
					model
				)
			end

			-- Sloping withers behind the neck, and a cream belly.
			wedge(
				"Withers",
				Vector3.new(b.X - 0.3, 0.7, 2.4),
				body.CFrame * CFrame.new(0, b.Y / 2 + 0.35, 0) * CFrame.Angles(0, math.pi, 0),
				spec.BodyColor,
				model
			)
			decoration(
				"Belly",
				Vector3.new(b.X - 0.4, 0.05, b.Z - 0.6),
				body.CFrame * CFrame.new(0, -b.Y / 2 - 0.01, 0),
				cream,
				model
			)

			-- Round legs with knobbly knees, cream socks and dark hooves.
			for _, leg in legsOf(model) do
				local p = leg.Position
				rod("LegRound", leg.Size.Y, 0.9, CFrame.new(p), spec.BodyColor, model)
				ball("Knee", 1.0, CFrame.new(p.X, leg.Size.Y * 0.55, p.Z), spec.BodyColor, model)
				rod("Sock", 1.2, 0.95, CFrame.new(p.X, 1.0, p.Z), cream, model)
				rod("Hoof", 0.4, 1.0, CFrame.new(p.X, 0.2, p.Z), hoof, model)
			end

			local tail = chain({
				Name = "Tail",
				Start = facing(
					(body.CFrame * CFrame.new(0, b.Y / 2 - 0.3, b.Z / 2 + 0.05)).Position,
					Vector3.new(0, -2, 1)
				),
				Count = 4,
				Length = 0.4,
				Size = 0.25,
				EndSize = 0.2,
				Turn = Vector2.new(math.rad(-10), 0),
				Color = spec.BodyColor,
			}, model)
			ball("TailTuft", 0.5, tail[#tail].CFrame * CFrame.new(0, 0, -0.35), hoof, model)

			-- Head: long soft muzzle, ossicones, sideways ears, lashes, and a tongue poking out.
			decoration(
				"Muzzle",
				Vector3.new(1.0, 0.7, 0.9),
				head.CFrame * CFrame.new(0, -0.3, -h.Z / 2 - 0.4),
				cream,
				model
			)
			for _, side in { -1, 1 } do
				local nostril = disc(
					"Nostril",
					0.16,
					0.06,
					head.CFrame * CFrame.new(side * 0.25, -0.1, -h.Z / 2 - 0.86),
					hoof,
					model
				)
				nostril:SetAttribute("NoGrime", true)
				local horn = head.CFrame
					* CFrame.new(side * 0.3, h.Y / 2 + 0.28, 0.35)
					* CFrame.Angles(0, 0, side * -0.15)
				rod("Ossicone", 0.6, 0.22, horn, spot, model)
				ball("OssiconeTip", 0.32, horn * CFrame.new(0, 0.3, 0), hoof, model)
				local ear = decoration(
					"Ear",
					Vector3.new(0.6, 0.28, 0.12),
					head.CFrame
						* CFrame.new(side * (h.X / 2 + 0.25), h.Y * 0.28, h.Z / 2 - 0.1)
						* CFrame.Angles(0, 0, side * 0.3),
					spec.HeadColor,
					model
				)
				decoration(
					"EarInner",
					Vector3.new(0.42, 0.16, 0.05),
					ear.CFrame * CFrame.new(side * 0.04, 0, -0.08),
					PINK,
					model
				)
				local lash = decoration(
					"Lash",
					Vector3.new(0.34, 0.05, 0.05),
					head.CFrame
						* CFrame.new(side * 0.36, h.Y * 0.25 + 0.25, -h.Z / 2 - 0.1)
						* CFrame.Angles(0, 0, side * 0.25),
					INK,
					model
				)
				lash:SetAttribute("NoGrime", true)
			end
			decoration(
				"Mouth",
				Vector3.new(0.6, 0.05, 0.05),
				head.CFrame * CFrame.new(0, -0.45, -h.Z / 2 - 0.86),
				hoof,
				model
			)
			decoration(
				"Tongue",
				Vector3.new(0.18, 0.06, 0.3),
				head.CFrame * CFrame.new(0.2, -0.55, -h.Z / 2 - 0.92) * CFrame.Angles(-0.4, 0, 0),
				Color3.fromRGB(120, 70, 150),
				model
			)
			heroEyes(head, model, { Size = 0.42, Spread = 0.3, Lift = 0.25, Iris = Color3.fromRGB(70, 40, 25) })
		end,
	},
	Elephant = {
		BodySize = Vector3.new(5.6, 4.6, 6.8),
		LegHeight = 2.8,
		LegThickness = 1.2,
		HeadSize = Vector3.new(3.8, 3.8, 2.8),
		HeadLift = -0.2,
		BodyColor = Color3.fromRGB(150, 150, 162),
		HeadColor = Color3.fromRGB(150, 150, 162),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.7,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local skin = spec.BodyColor
			local shade = Color3.fromRGB(122, 122, 136)
			local royal = Color3.fromRGB(190, 30, 70)

			-- Rounded back and a sagging belly: logs tucked inside the box so only the curves
			-- show above and below it. The sides stay flat and clear for mud.
			disc("Back", b.X - 0.4, b.Z - 0.4, body.CFrame * CFrame.new(0, 0.8, 0), skin, model)
			disc("Belly", 4.4, b.Z - 1.8, body.CFrame * CFrame.new(0, -0.8, 0), shade, model)
			-- Zoo God regalia: a royal blanket with gold trim and a jewel, all on the back.
			disc("Blanket", b.X - 0.3, 2.4, body.CFrame * CFrame.new(0, 0.8, 0.3), royal, model)
			for _, dz in { -1.25, 1.25 } do
				disc("Trim", b.X - 0.2, 0.2, body.CFrame * CFrame.new(0, 0.8, 0.3 + dz), GILT, model)
			end
			glow(
				ball(
					"Jewel",
					0.6,
					body.CFrame * CFrame.new(0, 0.8 + (b.X - 0.3) / 2 + 0.15, 0.3),
					Color3.fromRGB(80, 220, 255),
					model
				)
			)

			-- Pillar legs: round, gold anklets, wide pads and ivory toenails.
			for _, leg in legsOf(model) do
				local p = leg.Position
				rod("LegRound", leg.Size.Y, 1.8, CFrame.new(p), skin, model)
				rod("Foot", 0.5, 2.0, CFrame.new(p.X, 0.25, p.Z), shade:Lerp(WHITE, 0.25), model)
				rod("Anklet", 0.3, 1.9, CFrame.new(p.X, 1.0, p.Z), GILT, model)
				for i = -1, 1 do
					local x = i * 0.5
					ball("Toenail", 0.45, CFrame.new(p.X + x, 0.3, p.Z - math.sqrt(1 - x * x) - 0.02), IVORY, model)
				end
			end

			-- Domed forehead (set back so it never covers the eyes) and big round ears behind
			-- the head, swept back so the head sides stay sprayable.
			ball("Forehead", 3.6, head.CFrame * CFrame.new(0, h.Y / 2 - 0.7, 0.5), skin, model)
			for _, side in { -1, 1 } do
				local ear = head.CFrame
					* CFrame.new(side * (h.X / 2 + 0.8), 0.3, h.Z / 2 - 0.2)
					* CFrame.Angles(0, side * math.rad(-12), 0)
				disc("Ear", 3.0, 0.3, ear, skin, model)
				disc("EarInner", 2.2, 0.1, ear * CFrame.new(0, -0.1, -0.2), PINK_DARK:Lerp(skin, 0.5), model)
			end

			-- Trunk hangs down, then curls forward at the tip. Tusks curve up and out.
			local trunk = chain({
				Name = "Trunk",
				Start = head.CFrame * CFrame.new(0, -h.Y * 0.15, -h.Z / 2 - 0.1) * CFrame.Angles(math.rad(-95), 0, 0),
				Count = 5,
				Length = 0.45,
				Size = 1.25,
				EndSize = 0.95,
				Turn = Vector2.new(math.rad(-3), 0),
				Color = skin,
			}, model)
			chain({
				Name = "Trunk",
				Start = trunk[#trunk].CFrame * CFrame.Angles(math.rad(-3), 0, 0) * CFrame.new(0, 0, -0.45),
				Count = 4,
				Length = 0.38,
				Size = 0.9,
				EndSize = 0.65,
				Turn = Vector2.new(math.rad(28), 0),
				Color = skin,
				EndColor = shade,
			}, model)
			for _, side in { -1, 1 } do
				chain({
					Name = "Tusk",
					Start = head.CFrame
						* CFrame.new(side * 0.85, -h.Y * 0.32, -h.Z / 2 + 0.1)
						* CFrame.Angles(math.rad(-35), side * math.rad(-10), 0),
					Count = 4,
					Length = 0.38,
					Size = 0.45,
					EndSize = 0.25,
					Turn = Vector2.new(math.rad(22), 0),
					Color = IVORY,
				}, model)
			end

			-- Gold headdress with a gem between the eyes.
			decoration(
				"Headdress",
				Vector3.new(1.0, 1.0, 0.12),
				head.CFrame * CFrame.new(0, h.Y * 0.3, -h.Z / 2 - 0.05) * CFrame.Angles(0, 0, math.rad(45)),
				GILT,
				model
			)
			glow(
				ball(
					"Gem",
					0.42,
					head.CFrame * CFrame.new(0, h.Y * 0.3, -h.Z / 2 - 0.12),
					Color3.fromRGB(255, 60, 120),
					model
				)
			)
			heroEyes(head, model, { Size = 0.75, Spread = 0.3, Lift = 0.18, Iris = Color3.fromRGB(95, 60, 35) })

			local tail = chain({
				Name = "Tail",
				Start = facing(
					(body.CFrame * CFrame.new(0, b.Y / 2 - 0.5, b.Z / 2 + 0.1)).Position,
					Vector3.new(0, -2.5, 1)
				),
				Count = 4,
				Length = 0.42,
				Size = 0.32,
				EndSize = 0.24,
				Turn = Vector2.new(math.rad(-6), 0),
				Color = shade,
			}, model)
			ball("TailTuft", 0.6, tail[#tail].CFrame * CFrame.new(0, 0, -0.35), Color3.fromRGB(60, 60, 70), model)

			head:SetAttribute("HaloLift", 2.1) -- the Zoo God halo floats clear of the forehead dome
		end,
	},
	Unicorn = {
		BodySize = Vector3.new(3.0, 2.8, 6.0),
		LegHeight = 2.6,
		LegThickness = 0.7,
		HeadSize = Vector3.new(1.3, 1.5, 2.6),
		Neck = Vector3.new(1.3, 2.4, 1.5),
		BodyColor = Color3.fromRGB(250, 245, 255),
		HeadColor = Color3.fromRGB(250, 245, 255),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.3,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local neck = model:FindFirstChild("Neck") :: BasePart?
			local rainbow = {
				Color3.fromRGB(255, 110, 150),
				Color3.fromRGB(255, 180, 90),
				Color3.fromRGB(255, 235, 110),
				Color3.fromRGB(130, 230, 150),
				Color3.fromRGB(110, 190, 255),
				Color3.fromRGB(190, 140, 255),
			}
			-- A gold spiral horn: stacked, twisted, tapering blocks.
			local hornBase = head.CFrame * CFrame.new(0, h.Y / 2 - 0.05, -h.Z / 2 + 0.55) * CFrame.Angles(-0.35, 0, 0)
			for i = 0, 6 do
				local w = 0.42 - i * 0.05
				decoration(
					"Horn",
					Vector3.new(w, 0.32, w),
					hornBase * CFrame.new(0, 0.16 + i * 0.27, 0) * CFrame.Angles(0, i * 0.5, 0),
					if i % 2 == 0 then GILT else Color3.fromRGB(255, 235, 160),
					model
				)
			end
			-- A rainbow mane and forelock, and a matching flowing tail.
			if neck then
				local n = neck.Size
				for i, color in rainbow do
					decoration(
						"Mane",
						Vector3.new(0.4, 0.6, 0.55),
						neck.CFrame
							* CFrame.new(
								if i % 2 == 0 then 0.12 else -0.12,
								-n.Y / 2 + 0.2 + (i - 1) * 0.42,
								n.Z / 2 + 0.15
							)
							* CFrame.Angles(0.25, 0, 0),
						color,
						model
					)
				end
			end
			decoration(
				"Forelock",
				Vector3.new(0.5, 0.5, 0.45),
				head.CFrame * CFrame.new(0, h.Y / 2 + 0.05, -h.Z / 2 + 0.9),
				rainbow[5],
				model
			)
			local tail = blockTail(model, body, {
				Count = 6,
				Length = 0.42,
				Size = 0.55,
				EndSize = 0.7,
				Turn = Vector2.new(math.rad(-12), 0),
				Color = rainbow[1],
				EndColor = rainbow[6],
				Y = b.Y * 0.4,
				Pitch = math.rad(10),
				Aspect = Vector2.new(0.7, 1),
			})
			for i, segment in tail do
				segment.Color = rainbow[(i - 1) % #rainbow + 1]
			end
			-- Soft pink muzzle, ears, star markings on the flanks and golden hooves.
			local snout = onFront(
				model,
				head,
				"Muzzle",
				Vector3.new(h.X + 0.04, 0.75, 0.3),
				0,
				-0.4,
				Color3.fromRGB(255, 215, 235)
			)
			nostrils(model, snout, 0.3, 0.1, 0.15, Color3.fromRGB(200, 140, 170))
			upEars(
				model,
				head,
				Vector3.new(0.35, 0.7, 0.2),
				spec.HeadColor,
				Color3.fromRGB(255, 190, 220),
				0.3,
				0.12,
				0.25
			)
			for _, side in { -1, 1 } do
				for i, offset in { Vector2.new(0.4, 1.6), Vector2.new(-0.3, 2.2), Vector2.new(0.2, 2.6) } do
					ungrimed(
						sidePlate(
							model,
							body,
							"Star",
							side,
							Vector2.new(0.4, 0.4),
							offset.X,
							offset.Y,
							rainbow[i + 2],
							math.rad(45)
						)
					)
				end
			end
			socks(model, Color3.fromRGB(255, 220, 240), 0.2)
			hooves(model, GILT)
			addEyes(head, model, true)
			flair(head, "Sparkle", {
				Texture = SPARKLE_TEX,
				Rate = 6,
				Lifetime = NumberRange.new(0.6, 1),
				Speed = NumberRange.new(0.5, 1),
				SpreadAngle = Vector2.new(180, 180),
				Size = NumberSequence.new(0.35, 0),
				Color = ColorSequence.new(Color3.fromRGB(255, 240, 180)),
			})
			head:SetAttribute("HaloLift", 2.2) -- clear of the horn
		end,
	},
	TRex = {
		BodySize = Vector3.new(3.8, 3.6, 5.2),
		LegHeight = 3.2,
		LegCount = 2,
		LegThickness = 0.9,
		HeadSize = Vector3.new(2.6, 2.3, 2.3),
		HeadPosition = Vector3.new(0, 7.3, -3.4),
		BodyColor = Color3.fromRGB(85, 140, 70),
		HeadColor = Color3.fromRGB(85, 140, 70),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.5,
		SkipRump = true,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local skin = spec.BodyColor
			local deep = Color3.fromRGB(55, 95, 45)
			local belly = Color3.fromRGB(215, 205, 135)

			-- Drumstick thighs tucked under the body, thick shins, three-clawed feet.
			for _, leg in legsOf(model) do
				local p = leg.Position
				ball("Thigh", 2.0, CFrame.new(p.X, 2.6, p.Z + 0.15), skin, model)
				rod("Shin", 1.8, 1.3, CFrame.new(p.X, 1.3, p.Z), skin, model)
				decoration("Foot", Vector3.new(1.3, 0.5, 1.8), CFrame.new(p.X, 0.25, p.Z - 0.3), skin, model)
				claws(CFrame.new(p.X, 0, p.Z - 1.2), 3, 0.42, Vector3.new(0.25, 0.35, 0.5), IVORY, model)
			end

			-- Stripes painted flush on the sides; scutes along the spine; pale chest and belly.
			for _, side in { -1, 1 } do
				for _, z in { -1.5, -0.5, 0.5, 1.5 } do
					decoration(
						"Stripe",
						Vector3.new(0.05, 1.6, 0.32),
						body.CFrame * CFrame.new(side * (b.X / 2 + 0.01), 0.75, z) * CFrame.Angles(0.25, 0, 0),
						deep,
						model
					)
				end
			end
			for i = 0, 4 do
				wedge(
					"Scute",
					Vector3.new(0.35, 0.55, 0.7),
					body.CFrame * CFrame.new(0, b.Y / 2 + 0.2, -1.0 + i * 0.85),
					deep,
					model
				)
			end
			decoration(
				"Chest",
				Vector3.new(b.X - 0.9, b.Y - 1.0, 0.05),
				body.CFrame * CFrame.new(0, -0.3, -b.Z / 2 - 0.01),
				belly,
				model
			)
			decoration(
				"Belly",
				Vector3.new(b.X - 0.6, 0.05, b.Z - 0.8),
				body.CFrame * CFrame.new(0, -b.Y / 2 - 0.01, 0),
				belly,
				model
			)
			ball("NeckBulk", 2.4, body.CFrame * CFrame.new(0, b.Y / 2 - 0.3, -b.Z / 2), skin, model)

			-- The famous tiny arms.
			for _, side in { -1, 1 } do
				local shoulder = body.CFrame * CFrame.new(side * (b.X / 2 - 0.55), -0.1, -b.Z / 2 - 0.2)
				local upper = decoration(
					"Arm",
					Vector3.new(0.42, 0.42, 0.9),
					shoulder * CFrame.Angles(math.rad(-40), 0, 0) * CFrame.new(0, 0, -0.4),
					skin,
					model
				)
				local fore = decoration(
					"Forearm",
					Vector3.new(0.36, 0.36, 0.65),
					upper.CFrame * CFrame.new(0, 0, -0.45) * CFrame.Angles(math.rad(60), 0, 0) * CFrame.new(0, 0, -0.3),
					skin,
					model
				)
				claws(fore.CFrame * CFrame.new(0, -0.1, -0.32), 2, 0.2, Vector3.new(0.1, 0.18, 0.28), IVORY, model)
			end

			maw(head, model, {
				Top = 0,
				Width = 2.0,
				Length = 1.7,
				Height = 0.9,
				Bridge = 0.35,
				Open = 0.2,
				JawHeight = 0.5,
				Fangs = 4,
				Skin = skin,
				Inside = Color3.fromRGB(130, 25, 35),
			})
			heroEyes(
				head,
				model,
				{ Size = 0.6, Spread = 0.3, Lift = 0.33, Iris = Color3.fromRGB(255, 200, 40), Slit = true }
			)
			for _, side in { -1, 1 } do
				decoration(
					"Brow",
					Vector3.new(0.8, 0.2, 0.35),
					head.CFrame
						* CFrame.new(side * 0.78, h.Y / 2 + 0.03, -h.Z / 2 - 0.1)
						* CFrame.Angles(0, 0, side * 0.3),
					deep,
					model
				)
			end

			-- Heavy tail sweeping back and round to one side, so it fits the pen.
			local tail = chain({
				Name = "Tail",
				Start = facing((body.CFrame * CFrame.new(0, 0.4, b.Z / 2 - 0.3)).Position, Vector3.new(0, -0.15, 1)),
				Count = 8,
				Length = 0.62,
				Size = 2.6,
				EndSize = 0.5,
				Turn = Vector2.new(math.rad(-2), math.rad(14)),
				Color = skin,
			}, model)
			for i = 2, 6 do
				local seg = tail[i]
				wedge(
					"Scute",
					Vector3.new(0.3, 0.45, 0.55),
					seg.CFrame * CFrame.new(0, seg.Size.X / 2 - 0.05, 0) * CFrame.Angles(0, math.pi, 0),
					deep,
					model
				)
			end
		end,
	},
	Griffon = {
		BodySize = Vector3.new(3.0, 2.6, 5.2),
		LegHeight = 2.2,
		LegThickness = 0.7,
		HeadSize = Vector3.new(1.7, 1.7, 1.8),
		HeadLift = 0.9,
		BodyColor = Color3.fromRGB(215, 165, 90),
		HeadColor = Color3.fromRGB(250, 250, 245),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.2,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local fur = spec.BodyColor
			local feather = spec.HeadColor
			local talon = Color3.fromRGB(240, 180, 50)
			local beak = Color3.fromRGB(255, 190, 40)
			local wing = Color3.fromRGB(200, 150, 70)
			local wingDark = Color3.fromRGB(130, 85, 45)
			local claw = Color3.fromRGB(45, 40, 35)

			-- Eagle forelegs (scaly, feathered at the top, talons) and lion hind legs (paws).
			for _, leg in legsOf(model) do
				local p = leg.Position
				if p.Z < 0 then
					leg.Color = talon
					ball("LegFeathers", 1.0, CFrame.new(p.X, 2.0, p.Z), feather, model)
					decoration("Foot", Vector3.new(0.8, 0.3, 0.9), CFrame.new(p.X, 0.15, p.Z - 0.15), talon, model)
					claws(CFrame.new(p.X, 0, p.Z - 0.6), 3, 0.28, Vector3.new(0.15, 0.25, 0.4), claw, model)
					claws(
						CFrame.new(p.X, 0, p.Z + 0.3) * CFrame.Angles(0, math.pi, 0),
						1,
						0,
						Vector3.new(0.15, 0.25, 0.35),
						claw,
						model
					)
				else
					ball("Haunch", 1.3, CFrame.new(p.X * 0.9, 1.9, p.Z), fur, model)
					ball("Paw", 1.0, CFrame.new(p.X, 0.4, p.Z - 0.1), fur:Lerp(WHITE, 0.15), model)
				end
			end

			-- Feather ruff where the eagle front meets the lion body.
			ball("Ruff", 1.6, body.CFrame * CFrame.new(0, 0.9, -b.Z / 2 + 0.1), feather, model)
			for i = 0, 2 do
				wedge(
					"ChestFeather",
					Vector3.new(1.6 - i * 0.3, 0.6, 0.35),
					body.CFrame * CFrame.new(0, 0.1 - i * 0.55, -b.Z / 2 - 0.15) * CFrame.Angles(math.pi, 0, 0),
					feather:Lerp(fur, 0.15 * i),
					model
				)
			end

			-- Hooked beak, cere, fierce brows and a swept-back crest.
			decoration(
				"Beak",
				Vector3.new(0.7, 0.45, 0.6),
				head.CFrame * CFrame.new(0, -0.15, -h.Z / 2 - 0.3),
				beak,
				model
			)
			wedge(
				"BeakHook",
				Vector3.new(0.55, 0.5, 0.35),
				head.CFrame * CFrame.new(0, -0.35, -h.Z / 2 - 0.77) * CFrame.Angles(math.pi, 0, 0),
				beak,
				model
			)
			decoration(
				"BeakLower",
				Vector3.new(0.5, 0.18, 0.45),
				head.CFrame * CFrame.new(0, -0.45, -h.Z / 2 - 0.25),
				beak:Lerp(INK, 0.25),
				model
			)
			decoration(
				"Cere",
				Vector3.new(0.75, 0.14, 0.2),
				head.CFrame * CFrame.new(0, 0.1, -h.Z / 2 - 0.1),
				GILT,
				model
			)
			heroEyes(head, model, { Size = 0.5, Spread = 0.3, Lift = 0.25, Iris = Color3.fromRGB(255, 170, 30) })
			for _, side in { -1, 1 } do
				decoration(
					"Brow",
					Vector3.new(0.55, 0.14, 0.2),
					head.CFrame
						* CFrame.new(side * 0.5, h.Y * 0.25 + 0.32, -h.Z / 2 - 0.06)
						* CFrame.Angles(0, 0, side * 0.35),
					Color3.fromRGB(200, 200, 195),
					model
				)
			end
			for i = -1, 1 do
				wedge(
					"Crest",
					Vector3.new(0.22, 0.7 - math.abs(i) * 0.15, 0.9),
					head.CFrame * CFrame.new(i * 0.35, h.Y / 2 + 0.25, h.Z / 2 - 0.35) * CFrame.Angles(0, 0, i * -0.25),
					feather,
					model
				)
			end

			-- Folded wings resting on the back like a raised tent, gold leading edges and long
			-- primaries reaching past the rump. They sit above the body, never over its sides.
			for _, side in { -1, 1 } do
				local root = body.CFrame
					* CFrame.new(side * 0.5, b.Y / 2 + 0.12, -1.4)
					* CFrame.Angles(0, 0, side * math.rad(30))
				decoration("Wing", Vector3.new(2.0, 0.2, 2.2), root * CFrame.new(side * 1.0, 0, 0), wing, model)
				decoration(
					"WingTrim",
					Vector3.new(2.0, 0.24, 0.16),
					root * CFrame.new(side * 1.0, 0.02, -1.1),
					GILT,
					model
				)
				decoration(
					"Wing",
					Vector3.new(2.0, 0.16, 2.0),
					root * CFrame.new(side * 1.05, -0.04, 1.8),
					wing:Lerp(wingDark, 0.4),
					model
				)
				for i = 0, 2 do
					decoration(
						"Primary",
						Vector3.new(0.6, 0.14, 2.4),
						root
							* CFrame.new(side * (0.55 + i * 0.62), -0.06, 3.3 - i * 0.25)
							* CFrame.Angles(0, side * math.rad(-6 * i), 0),
						wingDark,
						model
					)
				end
			end

			local tail = chain({
				Name = "Tail",
				Start = facing(
					(body.CFrame * CFrame.new(0, b.Y / 2 - 0.35, b.Z / 2 + 0.05)).Position,
					Vector3.new(0, -1, 1)
				),
				Count = 6,
				Length = 0.4,
				Size = 0.3,
				EndSize = 0.25,
				Turn = Vector2.new(math.rad(12), 0),
				Color = fur,
			}, model)
			ball("TailTuft", 0.7, tail[#tail].CFrame * CFrame.new(0, 0, -0.4), Color3.fromRGB(110, 60, 25), model)
		end,
	},
	Kitsune = {
		BodySize = Vector3.new(2.2, 2.0, 3.8),
		LegHeight = 1.5,
		LegThickness = 0.5,
		HeadSize = Vector3.new(1.8, 1.6, 1.7),
		HeadLift = 0.5,
		BodyColor = Color3.fromRGB(248, 244, 238),
		HeadColor = Color3.fromRGB(248, 244, 238),
		BodyMaterial = Enum.Material.Fabric,
		PatchCell = 0.95,
		SkipRump = true,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local red = Color3.fromRGB(215, 35, 45)
			local ember = Color3.fromRGB(255, 140, 40)
			local fur = spec.BodyColor
			-- Tall ears with red insides and red tips.
			for _, side in { -1, 1 } do
				local base = head.CFrame
					* CFrame.new(side * h.X * 0.3, h.Y / 2 - 0.05, 0.15)
					* CFrame.Angles(0, 0, -side * 0.12)
				triangle("Ear", 0.75, 1.05, 0.22, base, fur, model)
				triangle("EarInner", 0.42, 0.7, 0.05, base * CFrame.new(0, 0.02, -0.12), red, model)
				triangle("EarTip", 0.33, 0.35, 0.24, base * CFrame.new(0, 0.7, 0), red, model)
			end
			-- A pointed snout, a black nose, and the red shrine markings on brow and cheeks.
			local snout = onFront(model, head, "Snout", Vector3.new(0.8, 0.55, 0.7), 0, -0.3, fur)
			onFront(model, snout, "Nose", Vector3.new(0.28, 0.2, 0.08), 0, 0.17, INK)
			mouthLine(model, snout, 0.4, -0.14, red)
			ungrimed(onFront(model, head, "Mark", Vector3.new(0.18, 0.45, 0.04), 0, h.Y * 0.32, red))
			for _, side in { -1, 1 } do
				ungrimed(onFront(model, head, "Mark", Vector3.new(0.35, 0.1, 0.04), side * 0.5, -0.2, red))
				ungrimed(onFront(model, head, "Mark", Vector3.new(0.25, 0.1, 0.04), side * 0.55, -0.38, red))
				sidePlate(model, body, "Flame", side, Vector2.new(1.6, 0.2), 0.55, -0.3, red, 0.2)
				sidePlate(model, body, "Flame", side, Vector2.new(1.0, 0.16), 0.2, 0.1, red, 0.2)
			end
			-- A thick red rope collar with a gold bell and a ruff of chest fur.
			decoration(
				"Collar",
				Vector3.new(h.X + 0.1, 0.3, h.Z * 0.7),
				head.CFrame * CFrame.new(0, -h.Y / 2 + 0.05, 0.25),
				red,
				model
			)
			for _, side in { -1, 1 } do
				decoration(
					"Tassel",
					Vector3.new(0.16, 0.6, 0.16),
					head.CFrame * CFrame.new(side * 0.35, -h.Y / 2 - 0.35, -0.15),
					red,
					model
				)
			end
			local bell = decoration(
				"Bell",
				Vector3.new(0.4, 0.42, 0.4),
				head.CFrame * CFrame.new(0, -h.Y / 2 - 0.2, -0.2),
				GILT,
				model
			)
			ungrimed(onFront(model, bell, "Slot", Vector3.new(0.25, 0.06, 0.05), 0, -0.05, INK))
			chest(model, body, Vector3.new(b.X * 0.8, b.Y * 0.8, 0.35), 0.05, WHITE)
			-- Nine tails fanned out behind, each a run of fluffy blocks ending in a flame tip.
			for i = 1, 9 do
				local t = (i - 1) / 8
				-- Roots spread across the rump; the fan opens wide and low, curling up at the ends.
				local root = body.CFrame * CFrame.new((t - 0.5) * (b.X - 0.4), b.Y * 0.3, b.Z / 2 - 0.1)
				local yaw = math.rad(-75 + 150 * t)
				local lift = math.rad(25 + 30 * math.sin(t * math.pi))
				local start = root * CFrame.Angles(0, math.pi + yaw, 0) * CFrame.Angles(lift, 0, 0)
				local tail = chain({
					Name = "Tail",
					Start = start * CFrame.new(0, 0, -0.3),
					Count = 7,
					Length = 0.48,
					Size = 0.3,
					EndSize = 0.55,
					Turn = Vector2.new(math.rad(4), 0),
					Color = fur,
					Block = true,
				}, model)
				local last = tail[#tail]
				local tip = glow(
					decoration("TailTip", Vector3.new(0.5, 0.5, 0.5), last.CFrame * CFrame.new(0, 0, -0.45), red, model)
				)
				tip.Transparency = 0.05
				local flame = glow(
					decoration(
						"TailFlame",
						Vector3.new(0.3, 0.3, 0.35),
						last.CFrame * CFrame.new(0, 0, -0.78),
						ember,
						model
					)
				)
				flame.Transparency = 0.15
				if i % 3 == 2 then
					flair(flame, "FoxFire", {
						Texture = FIRE_TEX,
						Rate = 6,
						Lifetime = NumberRange.new(0.4, 0.7),
						Speed = NumberRange.new(0.8, 1.6),
						SpreadAngle = Vector2.new(20, 20),
						Size = NumberSequence.new(0.6, 0.1),
						Transparency = NumberSequence.new(0.2, 1),
						Color = flameColors(Color3.fromRGB(255, 230, 160), ember, red),
						Acceleration = Vector3.new(0, 3, 0),
						Rotation = NumberRange.new(0, 360),
					})
				end
			end
			bellyPlate(model, body, WHITE)
			socks(model, red, 0.15)
			paws(model, fur, red)
			addEyes(head, model)
		end,
	},
	Phoenix = {
		BodySize = Vector3.new(2.4, 2.4, 3.2),
		LegHeight = 2.0,
		LegCount = 2,
		LegThickness = 0.35,
		LegColor = Color3.fromRGB(255, 190, 60),
		HeadSize = Vector3.new(1.4, 1.4, 1.5),
		Neck = Vector3.new(1.0, 1.6, 1.0),
		NeckTilt = math.rad(18),
		BodyColor = Color3.fromRGB(215, 45, 30),
		HeadColor = Color3.fromRGB(255, 120, 30),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 0.95,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local crimson = spec.BodyColor
			local red = Color3.fromRGB(255, 70, 30)
			local orange = Color3.fromRGB(255, 150, 30)
			local yellow = Color3.fromRGB(255, 225, 70)
			local neck = model:FindFirstChild("Neck") :: BasePart?
			local function flames(parent: BasePart, rate: number, size: number)
				flair(parent, "Flames", {
					Rate = rate,
					Lifetime = NumberRange.new(0.5, 0.9),
					Speed = NumberRange.new(0.5, 1.5),
					SpreadAngle = Vector2.new(20, 20),
					Acceleration = Vector3.new(0, 4, 0),
					Size = swell(size),
					Transparency = NumberSequence.new(0.15, 1),
					Color = flameColors(yellow, orange, red),
					Rotation = NumberRange.new(0, 360),
				})
			end

			-- Golden hooked beak, glowing eyes and a crest of flame feathers.
			decoration(
				"Beak",
				Vector3.new(0.45, 0.35, 0.5),
				head.CFrame * CFrame.new(0, -0.15, -h.Z / 2 - 0.25),
				GILT,
				model
			)
			wedge(
				"BeakHook",
				Vector3.new(0.4, 0.4, 0.28),
				head.CFrame * CFrame.new(0, -0.32, -h.Z / 2 - 0.64) * CFrame.Angles(math.pi, 0, 0),
				GILT,
				model
			)
			heroEyes(head, model, { Size = 0.45, Spread = 0.28, Lift = 0.2, Iris = yellow, Glow = true })
			for k, color in { yellow, orange, red } do
				local crest = glowAll(
					triangle(
						"Crest",
						0.5 - k * 0.05,
						1.3 - k * 0.2,
						0.14,
						head.CFrame
							* CFrame.new(0, h.Y / 2 - 0.05, -0.45 + k * 0.35)
							* CFrame.Angles(math.rad(10 + k * 15), 0, 0)
							* CFrame.Angles(0, math.pi / 2, 0),
						color,
						model
					)
				)
				if k == 1 then
					flames(crest[1], 5, 0.5)
				end
			end

			-- Golden bib down the neck front and a feathered breast (front faces carry no mud).
			if neck then
				decoration(
					"Bib",
					Vector3.new(neck.Size.X - 0.2, neck.Size.Y - 0.3, 0.08),
					neck.CFrame * CFrame.new(0, 0, -neck.Size.Z / 2 - 0.03),
					GILT,
					model
				)
			end
			decoration(
				"Breast",
				Vector3.new(b.X - 0.6, b.Y - 0.6, 0.08),
				body.CFrame * CFrame.new(0, 0, -b.Z / 2 - 0.03),
				orange,
				model
			)
			for i = 0, 1 do
				wedge(
					"BreastFeather",
					Vector3.new(b.X - 0.8 - i * 0.3, 0.5, 0.3),
					body.CFrame * CFrame.new(0, -0.2 - 0.5 * i, -b.Z / 2 - 0.17) * CFrame.Angles(math.pi, 0, 0),
					GILT:Lerp(orange, i * 0.5),
					model
				)
			end

			-- Feathered thighs and taloned golden feet.
			for _, leg in legsOf(model) do
				local p = leg.Position
				ball("Thigh", 0.9, CFrame.new(p.X * 0.85, leg.Size.Y - 0.25, p.Z), crimson, model)
				decoration(
					"Foot",
					Vector3.new(0.5, 0.18, 0.5),
					CFrame.new(p.X, 0.09, p.Z - 0.1),
					spec.LegColor or GILT,
					model
				)
				claws(CFrame.new(p.X, 0, p.Z - 0.35), 3, 0.2, Vector3.new(0.12, 0.2, 0.35), INK, model)
				claws(
					CFrame.new(p.X, 0, p.Z + 0.15) * CFrame.Angles(0, math.pi, 0),
					1,
					0,
					Vector3.new(0.12, 0.2, 0.3),
					INK,
					model
				)
			end

			-- Wings raised in a V from the top edges, layered red to orange, edged with flame.
			for _, side in { -1, 1 } do
				local root = body.CFrame
					* CFrame.new(side * (b.X / 2 - 0.1), b.Y / 2 - 0.1, -0.5)
					* CFrame.Angles(0, 0, -side * math.rad(35))
				decoration(
					"WingArm",
					Vector3.new(0.3, 2.6, 0.5),
					root * CFrame.new(0, 1.3, -0.3),
					Color3.fromRGB(170, 30, 25),
					model
				)
				local coverts =
					decoration("Wing", Vector3.new(0.18, 2.3, 1.4), root * CFrame.new(0, 1.4, 0.55), crimson, model)
				decoration("Wing", Vector3.new(0.14, 1.9, 1.3), root * CFrame.new(0, 1.05, 1.7), orange, model)
				for k, color in { yellow, yellow:Lerp(orange, 0.5), orange, red } do
					glowAll(
						triangle(
							"WingFlame",
							0.6,
							1.2 - k * 0.1,
							0.12,
							root
								* CFrame.new(0, 2.8 - k * 0.35, -0.9 + k * 0.65)
								* CFrame.Angles(math.rad(2 + k * 18), 0, 0)
								* CFrame.Angles(0, math.pi / 2, 0),
							color,
							model
						)
					)
				end
				flames(coverts, 8, 0.6)
			end

			-- Five flame tail feathers fanning back and drooping toward the ground.
			local origin = (body.CFrame * CFrame.new(0, b.Y / 2 - 0.5, b.Z / 2 - 0.1)).Position
			for i = 1, 5 do
				local yaw = math.rad(-32 + 16 * (i - 1))
				local droop = math.rad(25)
				local f = facing(
					origin,
					Vector3.new(math.sin(yaw) * math.cos(droop), -math.sin(droop), math.cos(yaw) * math.cos(droop))
				)
				decoration("TailFeather", Vector3.new(0.42, 0.12, 1.4), f * CFrame.new(0, 0, -0.7), crimson, model)
				decoration(
					"TailFeather",
					Vector3.new(0.5, 0.12, 1.0),
					f * CFrame.new(0, 0, -1.85) * CFrame.Angles(math.rad(-6), 0, 0),
					orange,
					model
				)
				local tip = glowAll(
					triangle(
						"TailFlame",
						0.5,
						0.9,
						0.12,
						f * CFrame.new(0, -0.05, -2.35) * CFrame.Angles(-math.pi / 2, 0, 0),
						yellow,
						model
					)
				)
				if i == 3 then
					flames(tip[1], 6, 0.45)
				end
			end
		end,
	},
	Dragon = {
		BodySize = Vector3.new(3.6, 3.2, 7.0),
		LegHeight = 1.9,
		LegThickness = 1.25,
		HeadSize = Vector3.new(1.9, 1.7, 2.4),
		Neck = Vector3.new(1.4, 3.4, 1.4),
		NeckTilt = math.rad(30),
		BodyColor = Color3.fromRGB(95, 20, 30),
		HeadColor = Color3.fromRGB(95, 20, 30),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.4,
		SkipRump = true,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local skin = spec.BodyColor
			local dark = Color3.fromRGB(30, 8, 14)
			local belly = Color3.fromRGB(190, 130, 45)
			local membrane = Color3.fromRGB(125, 22, 30)
			local horn = Color3.fromRGB(225, 210, 175)
			local fire = Color3.fromRGB(255, 130, 30)
			local neck = model:FindFirstChild("Neck") :: BasePart?
			local spikeTurn = CFrame.Angles(0, math.pi / 2, 0) -- triangles thin across the body

			-- Ridged gold belly plates down the chest and neck, scale ridges on the flanks.
			for i = 0, 3 do
				chest(model, body, Vector3.new(b.X - 0.9 - i * 0.2, 0.55, 0.12 + i * 0.03), 1.0 - i * 0.7, belly)
			end
			bellyPlate(model, body, belly, 0.7)
			for _, side in { -1, 1 } do
				for i = 0, 4 do
					sidePlate(
						model,
						body,
						"Scales",
						side,
						Vector2.new(0.9, 0.12),
						0.9,
						-2.4 + i * 1.2,
						tint(skin, -0.25)
					)
				end
			end
			if neck then
				local n = neck.Size
				for i = 0, 4 do
					onFront(model, neck, "NeckPlate", Vector3.new(n.X - 0.25, 0.45, 0.1), 0, -1.3 + i * 0.65, belly)
				end
				for i = 0, 3 do
					triangle(
						"Spine",
						0.7,
						0.85,
						0.16,
						neck.CFrame
							* CFrame.new(0, -1 + i * 0.75, n.Z / 2 - 0.05)
							* CFrame.Angles(math.rad(65), 0, 0)
							* spikeTurn,
						dark,
						model
					)
				end
			end

			-- A row of big, swept-back spines from the shoulders to the tail.
			for i = 0, 6 do
				local s = 1.3 - math.abs(i - 2) * 0.12
				triangle(
					"Spine",
					s * 0.9,
					s,
					0.2,
					body.CFrame
						* CFrame.new(0, b.Y / 2 - 0.05, -2.8 + i * 0.95)
						* CFrame.Angles(math.rad(28), 0, 0)
						* spikeTurn,
					dark,
					model
				)
			end

			-- Huge bat wings: an arm bone and three finger bones, each gap closed by membrane.
			for _, side in { -1, 1 } do
				-- Raised high and spread wide, leaning back a little: a looming silhouette.
				local wingRoot = body.CFrame
					* CFrame.new(side * (b.X / 2 - 0.3), b.Y / 2 - 0.1, -1.6)
					* CFrame.Angles(math.rad(14), 0, -side * math.rad(36))
				local armLength = 4.8
				decoration(
					"WingArm",
					Vector3.new(0.45, armLength, 0.45),
					wingRoot * CFrame.new(0, armLength / 2, 0),
					dark,
					model
				)
				local wrist = wingRoot * CFrame.new(0, armLength, 0)
				wedge("WingClaw", Vector3.new(0.3, 0.7, 0.3), wrist * CFrame.new(0, 0.4, -0.1), horn, model)
				local points = { wingRoot.Position, wrist.Position }
				for _, finger in { { 95, 7.2 }, { 118, 6.4 }, { 142, 5.2 }, { 166, 3.8 } } do
					local frame = wrist * CFrame.Angles(math.rad(finger[1]), 0, 0)
					decoration(
						"WingFinger",
						Vector3.new(0.24, finger[2], 0.24),
						frame * CFrame.new(0, finger[2] / 2, 0),
						dark,
						model
					)
					table.insert(points, (frame * CFrame.new(0, finger[2], 0)).Position)
				end
				-- Back to the flank, so the last panel meets the body.
				table.insert(points, (body.CFrame * CFrame.new(side * (b.X / 2 - 0.3), b.Y / 2 - 0.2, 1.6)).Position)
				for i = 2, #points - 1 do
					local shade = if i % 2 == 0 then membrane else tint(membrane, -0.18)
					sheet("Membrane", points[1], points[i], points[i + 1], 0.08, shade, model)
				end
			end

			-- Muscled haunches, heavy feet and long ivory talons.
			for _, leg in legsOf(model) do
				local l = leg.Size
				decoration(
					"Haunch",
					Vector3.new(l.X * 1.5, 1.3, l.Z * 1.7),
					leg.CFrame * CFrame.new(0, l.Y / 2 - 0.3, 0.1),
					skin,
					model
				)
				legPart(
					decoration(
						"Foot",
						Vector3.new(l.X * 1.3, 0.45, l.Z * 1.6),
						leg.CFrame * CFrame.new(0, -l.Y / 2 + 0.22, -0.25),
						dark,
						model
					)
				)
				for i = -1, 1 do
					legPart(
						wedge(
							"Claw",
							Vector3.new(0.2, 0.35, 0.5),
							leg.CFrame * CFrame.new(i * 0.38, -l.Y / 2 + 0.17, -l.Z * 1.05),
							horn,
							model
						)
					)
				end
			end

			-- Head: long snout, open jaws glowing with fire, heavy brows, two pairs of horns.
			local mouth = maw(head, model, {
				Top = 0.0,
				Width = 1.5,
				Length = 2.0,
				Height = 0.9,
				Bridge = 0.35,
				Open = 0.38,
				JawHeight = 0.45,
				Fangs = 4,
				Skin = skin,
				Inside = fire,
				Glow = true,
			})
			heroEyes(head, model, { Size = 0.5, Spread = 0.3, Lift = 0.3 })
			for _, side in { -1, 1 } do
				decoration(
					"Brow",
					Vector3.new(0.85, 0.3, 0.55),
					head.CFrame
						* CFrame.new(side * 0.5, h.Y / 2 - 0.05, -h.Z / 2 + 0.05)
						* CFrame.Angles(0.2, 0, side * 0.45),
					dark,
					model
				)
				for pair, hornSpec in { { 0.55, 6, 0.55, 0.42 }, { 0.85, 4, 0.36, 0.3 } } do
					chain({
						Name = "Horn",
						Start = facing(
							(head.CFrame * CFrame.new(side * hornSpec[1], h.Y / 2 - 0.15 * pair, 0.3 + pair * 0.3)).Position,
							Vector3.new(side * 0.3, 0.45, 1)
						),
						Count = hornSpec[2],
						Length = hornSpec[4],
						Size = hornSpec[3],
						EndSize = 0.14,
						Turn = Vector2.new(math.rad(-6), 0),
						Color = horn,
						EndColor = dark,
						Block = true,
					}, model)
				end
				for i = 0, 2 do
					triangle(
						"CheekSpike",
						0.35,
						0.6 - i * 0.12,
						0.1,
						head.CFrame
							* CFrame.new(side * (h.X / 2 - 0.05), -0.25 + i * 0.25, h.Z / 2 - 0.3 - i * 0.35)
							* CFrame.Angles(0, 0, -side * math.rad(80)),
						dark,
						model
					)
				end
			end

			-- Fire and embers from the jaws, smoke from the nostrils.
			local breath = anchorAt(head, mouth, "FireBreath")
			flair(breath, "FireBreath", {
				Texture = FIRE_TEX,
				Rate = 14,
				EmissionDirection = Enum.NormalId.Front,
				Speed = NumberRange.new(4, 7),
				SpreadAngle = Vector2.new(12, 12),
				Lifetime = NumberRange.new(0.35, 0.6),
				Size = swell(1.2),
				Transparency = NumberSequence.new(0.1, 1),
				Color = flameColors(Color3.fromRGB(255, 240, 150), fire, Color3.fromRGB(200, 30, 20)),
				Acceleration = Vector3.new(0, 3, 0),
				Rotation = NumberRange.new(0, 360),
				RotSpeed = NumberRange.new(-90, 90),
			})
			flair(breath, "Embers", {
				Texture = SPARKLE_TEX,
				Rate = 8,
				EmissionDirection = Enum.NormalId.Front,
				Speed = NumberRange.new(2, 4),
				SpreadAngle = Vector2.new(35, 35),
				Lifetime = NumberRange.new(0.8, 1.4),
				Size = NumberSequence.new(0.25, 0),
				Color = ColorSequence.new(Color3.fromRGB(255, 170, 60)),
				Acceleration = Vector3.new(0, 4, 0),
			})
			local nose = anchorAt(head, head.CFrame * CFrame.new(0, 0.2, -h.Z / 2 - 1.8), "Nostrils")
			flair(nose, "Smoke", {
				Texture = SMOKE_TEX,
				Rate = 4,
				LightEmission = 0,
				Speed = NumberRange.new(0.5, 1),
				SpreadAngle = Vector2.new(15, 15),
				Lifetime = NumberRange.new(1, 1.6),
				Size = NumberSequence.new(0.4, 1.2),
				Transparency = NumberSequence.new(0.45, 1),
				Color = ColorSequence.new(Color3.fromRGB(60, 55, 55)),
			})

			-- A long, heavy tail sweeping round, spined all the way, ending in a spade.
			local tail = chain({
				Name = "Tail",
				Start = facing((body.CFrame * CFrame.new(0, 0.4, b.Z / 2 - 0.3)).Position, Vector3.new(0, -0.25, 1)),
				Count = 12,
				Length = 0.62,
				Size = 1.7,
				EndSize = 0.35,
				Turn = Vector2.new(math.rad(-1), math.rad(9)),
				Color = skin,
				Block = true,
			}, model)
			for i = 1, #tail - 1 do
				local seg = tail[i]
				local s = seg.Size.X * 0.55
				triangle(
					"Spine",
					s,
					s * 1.1,
					0.14,
					seg.CFrame
						* CFrame.new(0, seg.Size.Y / 2 - 0.05, 0)
						* CFrame.Angles(math.rad(-25), 0, 0)
						* spikeTurn,
					dark,
					model
				)
			end
			local last = tail[#tail]
			triangle(
				"Spade",
				1.3,
				1.2,
				0.14,
				last.CFrame * CFrame.new(0, 0, -last.Size.Z / 2 + 0.05) * CFrame.Angles(-math.pi / 2, 0, 0),
				dark,
				model
			)

			head:SetAttribute("HaloLift", 1.8) -- clear of the horns
		end,
	},
	Kaiju = {
		BodySize = Vector3.new(4.2, 6.0, 4.2),
		LegHeight = 3.4,
		LegCount = 2,
		LegThickness = 1.1,
		HeadSize = Vector3.new(2.6, 2.2, 2.4),
		HeadPosition = Vector3.new(0, 10.4, -1.6),
		BodyColor = Color3.fromRGB(60, 66, 72),
		HeadColor = Color3.fromRGB(60, 66, 72),
		BodyMaterial = Enum.Material.Slate,
		PatchCell = 1.3,
		SkipRump = true,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local skin = spec.BodyColor
			local hide = Color3.fromRGB(40, 44, 50)
			local scute = Color3.fromRGB(125, 120, 105)
			local atomic = Color3.fromRGB(110, 230, 255)
			local plates: { Part } = {}
			-- Glowing dorsal plates: diamonds standing in the body's YZ plane.
			local function plate(cframe: CFrame, size: number): Part
				local part = glow(
					decoration(
						"Plate",
						Vector3.new(0.25, size, size),
						cframe * CFrame.Angles(math.rad(45), 0, 0),
						atomic,
						model
					),
					0.05
				)
				table.insert(plates, part)
				return part
			end

			-- Upright torso: neck bulk, pale chest scutes, huge thighs, shins and clawed feet.
			ball("NeckBulk", 2.6, body.CFrame * CFrame.new(0, b.Y / 2, -1.2), skin, model)
			for i = 0, 3 do
				decoration(
					"Scute",
					Vector3.new(b.X - 1.2, 0.55, 0.1),
					body.CFrame * CFrame.new(0, 1.6 - i * 0.95, -b.Z / 2 - 0.03),
					scute,
					model
				)
			end
			for _, leg in legsOf(model) do
				local p = leg.Position
				ball("Thigh", 2.2, CFrame.new(p.X * 0.9, 2.7, p.Z), skin, model)
				rod("Shin", 2.2, 1.7, CFrame.new(p.X, 1.5, p.Z), skin, model)
				decoration("Foot", Vector3.new(1.9, 0.6, 2.2), CFrame.new(p.X, 0.3, p.Z - 0.3), hide, model)
				claws(CFrame.new(p.X, 0, p.Z - 1.4), 3, 0.6, Vector3.new(0.3, 0.4, 0.55), IVORY, model)
			end

			-- Arms reaching forward from the chest.
			for _, side in { -1, 1 } do
				local shoulder = body.CFrame * CFrame.new(side * (b.X / 2 - 0.7), b.Y / 2 - 1.6, -b.Z / 2 - 0.1)
				ball("Shoulder", 1.3, shoulder, skin, model)
				local upper = decoration(
					"Arm",
					Vector3.new(0.8, 0.8, 1.5),
					shoulder * CFrame.Angles(math.rad(-35), 0, 0) * CFrame.new(0, 0, -0.7),
					skin,
					model
				)
				local fore = decoration(
					"Forearm",
					Vector3.new(0.7, 0.7, 1.3),
					upper.CFrame * CFrame.new(0, 0, -0.75) * CFrame.Angles(math.rad(55), 0, 0) * CFrame.new(0, 0, -0.6),
					skin,
					model
				)
				local hand = ball("Hand", 0.85, fore.CFrame * CFrame.new(0, 0, -0.7), skin, model)
				claws(hand.CFrame * CFrame.new(0, -0.2, -0.3), 3, 0.25, Vector3.new(0.16, 0.25, 0.4), IVORY, model)
			end

			-- Three columns of plates up the back (the rump face), two more on top behind the head.
			for _, info in { { 2.4, 1.5 }, { 1.3, 1.6 }, { 0.2, 1.5 }, { -0.9, 1.3 }, { -2.0, 1.1 } } do
				plate(body.CFrame * CFrame.new(0, info[1], b.Z / 2), info[2])
			end
			for _, side in { -1, 1 } do
				for _, info in { { 1.85, 1.0 }, { 0.75, 1.1 }, { -0.35, 1.0 }, { -1.45, 0.9 } } do
					plate(body.CFrame * CFrame.new(side * 0.75, info[1], b.Z / 2 - 0.05), info[2])
				end
			end
			plate(body.CFrame * CFrame.new(0, b.Y / 2, 0), 1.0)
			plate(body.CFrame * CFrame.new(0, b.Y / 2, 0.9), 1.2)

			-- Head: jaws glowing with atomic light, burning eyes, heavy brows and neon spikes.
			local mouth = maw(head, model, {
				Top = -0.05,
				Width = 1.9,
				Length = 1.4,
				Height = 0.9,
				Bridge = 0.3,
				Open = 0.3,
				JawHeight = 0.45,
				Fangs = 3,
				Skin = skin,
				Inside = atomic,
				Glow = true,
			})
			heroEyes(
				head,
				model,
				{ Size = 0.5, Spread = 0.3, Lift = 0.32, Iris = Color3.fromRGB(255, 200, 60), Slit = true, Glow = true }
			)
			for _, side in { -1, 1 } do
				decoration(
					"Brow",
					Vector3.new(1.0, 0.3, 0.5),
					head.CFrame
						* CFrame.new(side * 0.75, h.Y / 2 - 0.05, -h.Z / 2 - 0.05)
						* CFrame.Angles(0, 0, side * 0.3),
					hide,
					model
				)
			end
			for i = 0, 2 do
				glowAll(
					triangle(
						"Spike",
						0.5,
						0.7 - i * 0.1,
						0.18,
						head.CFrame * CFrame.new(0, h.Y / 2 - 0.05, -0.4 + i * 0.5) * CFrame.Angles(0, math.pi / 2, 0),
						atomic,
						model
					)
				)
			end

			-- Tail sweeping back and round to one side, plated along its top.
			local tail = chain({
				Name = "Tail",
				Start = facing(
					(body.CFrame * CFrame.new(0, -b.Y / 2 + 0.3, b.Z / 2 - 0.4)).Position,
					Vector3.new(0, -0.85, 1)
				),
				Count = 9,
				Length = 0.65,
				Size = 2.2,
				EndSize = 0.5,
				Turn = Vector2.new(math.rad(5), math.rad(14)),
				Color = skin,
			}, model)
			for i = 2, 8 do
				local seg = tail[i]
				plate(seg.CFrame * CFrame.new(0, seg.Size.X / 2 - 0.1, 0), seg.Size.X * 0.55)
			end

			-- Atomic breath wisps from the jaws; sparks crackling off the top plate.
			local breath = anchorAt(head, mouth, "AtomicBreath")
			flair(breath, "AtomicBreath", {
				Rate = 10,
				EmissionDirection = Enum.NormalId.Front,
				Speed = NumberRange.new(3, 5),
				SpreadAngle = Vector2.new(12, 12),
				Lifetime = NumberRange.new(0.5, 0.9),
				Size = swell(0.9),
				Transparency = NumberSequence.new(0.1, 1),
				Color = flameColors(WHITE, atomic, Color3.fromRGB(40, 90, 255)),
				Acceleration = Vector3.new(0, 1, 0),
			})
			local crown = plates[1]
			flair(crown, "PlateSparks", {
				Rate = 6,
				Speed = NumberRange.new(1, 2),
				SpreadAngle = Vector2.new(30, 30),
				Lifetime = NumberRange.new(0.6, 1),
				Size = NumberSequence.new(0.25, 0),
				Color = ColorSequence.new(atomic),
				Acceleration = Vector3.new(0, 2, 0),
			})
		end,
	},
	Axolotl = {
		BodySize = Vector3.new(2.4, 1.4, 3.4),
		LegHeight = 0.6,
		LegThickness = 0.45,
		LegColor = Color3.fromRGB(255, 150, 185),
		HeadSize = Vector3.new(2.3, 1.5, 1.8), -- no wider than the body so front side patches stay visible
		HeadLift = -0.35,
		BodyColor = Color3.fromRGB(255, 170, 200),
		HeadColor = Color3.fromRGB(255, 170, 200),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 0.8,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local skin = spec.BodyColor
			local gill = Color3.fromRGB(230, 60, 120)
			local frill = Color3.fromRGB(255, 90, 160)

			-- Three frilly gill stalks per side, sticking out from the back corners of the head
			-- (sideways, so the head top and sides keep their mud).
			for _, side in { -1, 1 } do
				for k, info in { { 0.5, 35, 1.05 }, { 0.12, 5, 0.95 }, { -0.25, -25, 0.85 } } do
					local root = (head.CFrame * CFrame.new(side * (h.X / 2 - 0.05), info[1], h.Z / 2 - 0.3)).Position
					local elev = math.rad(info[2])
					local look = facing(root, Vector3.new(side * math.cos(elev), math.sin(elev), 0.2))
					local len = info[3]
					shaped(
						decoration(
							"Gill",
							Vector3.new(len, 0.16, 0.16),
							look * CFrame.new(0, 0, -len / 2) * CFrame.Angles(0, math.pi / 2, 0),
							gill,
							model
						),
						Enum.PartType.Cylinder
					)
					for f, t in { 0.35, 0.65, 0.95 } do
						glow(
							ball(
								"GillFrill",
								0.26 + (k + f) % 2 * 0.04,
								look * CFrame.new(0, 0.1, -len * t),
								frill,
								model
							),
							0.1
						)
					end
				end
			end

			-- Wide smile, blushing cheeks and little bead eyes.
			decoration(
				"Smile",
				Vector3.new(0.8, 0.07, 0.05),
				head.CFrame * CFrame.new(0, -0.3, -h.Z / 2 - 0.03),
				INK,
				model
			)
			for _, side in { -1, 1 } do
				decoration(
					"Smile",
					Vector3.new(0.25, 0.07, 0.05),
					head.CFrame * CFrame.new(side * 0.5, -0.25, -h.Z / 2 - 0.03) * CFrame.Angles(0, 0, side * 0.45),
					INK,
					model
				)
				local blush = disc(
					"Blush",
					0.35,
					0.05,
					head.CFrame * CFrame.new(side * 0.85, -0.12, -h.Z / 2 - 0.02),
					Color3.fromRGB(255, 120, 160),
					model
				)
				blush:SetAttribute("NoGrime", true)
				for i, z in { -0.9, 0.1, 1.0 } do
					disc(
						"Freckle",
						0.22,
						0.05,
						body.CFrame
							* CFrame.new(side * (b.X / 2 + 0.01), 0.35 - (i % 2) * 0.5, z)
							* CFrame.Angles(0, math.rad(90), 0),
						Color3.fromRGB(235, 120, 160),
						model
					)
				end
			end
			heroEyes(head, model, { Size = 0.36, Spread = 0.36, Lift = 0.2, Sclera = INK })

			-- Paddle tail with a see-through fin; webbed little feet.
			local tail = chain({
				Name = "Tail",
				Start = facing((body.CFrame * CFrame.new(0, 0.05, b.Z / 2 - 0.1)).Position, Vector3.new(0.12, 0, 1)),
				Count = 4,
				Length = 0.55,
				Size = 0.85,
				EndSize = 0.35,
				Turn = Vector2.new(0, math.rad(8)),
				Color = skin,
				Block = true,
				Aspect = Vector2.new(0.55, 1),
			}, model)
			local fin = decoration(
				"TailFin",
				Vector3.new(0.06, 1.3, 2.3),
				tail[2].CFrame * CFrame.new(0, 0, -0.5),
				Color3.fromRGB(255, 195, 220),
				model
			)
			fin.Transparency = 0.35
			for _, leg in legsOf(model) do
				local p = leg.Position
				decoration(
					"Foot",
					Vector3.new(0.7, 0.14, 0.6),
					CFrame.new(p.X, 0.07, p.Z - 0.1),
					spec.LegColor or skin,
					model
				)
				for i = -1, 1 do
					ball("Toe", 0.18, CFrame.new(p.X + i * 0.22, 0.1, p.Z - 0.42), PINK_DARK, model)
				end
			end

			flair(head, "Bubbles", {
				Rate = 3,
				LightEmission = 0.3,
				Speed = NumberRange.new(0.5, 1),
				SpreadAngle = Vector2.new(40, 40),
				Lifetime = NumberRange.new(1.2, 2),
				Size = NumberSequence.new(0.15, 0.3),
				Transparency = NumberSequence.new(0.3, 1),
				Color = ColorSequence.new(Color3.fromRGB(255, 220, 240)),
				Acceleration = Vector3.new(0, 1.5, 0),
			})
		end,
	},
}

-- Covers one face of a box part in a thin skin of mud, tiled edge to edge. Each tile is one
-- patch; DirtRenderer breaks it into FlakesA x FlakesB flakes once it is sprayed. Tiles on the
-- face's border reach past it by the skin's thickness, so skins on neighbouring faces close the corner.
-- `normal`, `axisA`, `axisB` are unit vectors in the part's local space; `lenA`, `lenB` the face size.
local function addFacePatches(
	box: BasePart,
	normal: Vector3,
	axisA: Vector3,
	lenA: number,
	axisB: Vector3,
	lenB: number,
	cellSize: number,
	out: { PatchInfo },
	parent: Instance
)
	local depth = math.abs(normal:Dot(box.Size)) / 2
	local cols = math.max(1, math.floor(lenA / cellSize))
	local rows = math.max(1, math.floor(lenB / cellSize))
	local cellA, cellB = lenA / cols, lenB / rows
	local edge = SKIN_LIFT + PATCH_THICKNESS / 2
	local worldNormal = box.CFrame:VectorToWorldSpace(normal)
	local worldUp = box.CFrame:VectorToWorldSpace(axisA)

	for c = 1, cols do
		for r = 1, rows do
			local a0 = -lenA / 2 + (c - 1) * cellA - (if c == 1 then edge else 0)
			local a1 = -lenA / 2 + c * cellA + (if c == cols then edge else 0)
			local b0 = -lenB / 2 + (r - 1) * cellB - (if r == 1 then edge else 0)
			local b1 = -lenB / 2 + r * cellB + (if r == rows then edge else 0)
			local sizeA, sizeB = a1 - a0, b1 - b0
			local localPos = normal * (depth + SKIN_LIFT) + axisA * (a0 + a1) / 2 + axisB * (b0 + b1) / 2
			-- Local X = surface normal, Y = axisA; Z comes out as ±axisB, which a box doesn't mind.
			local frame = CFrame.fromMatrix(box.CFrame:PointToWorldSpace(localPos), worldNormal, worldUp)

			local id = "P" .. (#out + 1)
			local patch = Instance.new("Part")
			patch.Name = "Patch"
			patch.Anchored = true
			patch.CanCollide = false
			patch.CanTouch = false
			patch.CanQuery = true
			patch.CastShadow = false
			patch.Size = Vector3.new(PATCH_THICKNESS, sizeA, sizeB)
			patch.CFrame = frame
			patch.Color = MUD_COLOR
			patch.Material = Enum.Material.Mud
			patch:SetAttribute("PatchId", id)
			patch:SetAttribute("Skin", true)
			patch:SetAttribute("FlakesA", math.clamp(math.round(sizeA / FLAKE_SIZE), 2, MAX_FLAKES))
			patch:SetAttribute("FlakesB", math.clamp(math.round(sizeB / FLAKE_SIZE), 2, MAX_FLAKES))
			patch.Parent = parent
			table.insert(out, { Id = id, Part = patch :: BasePart })
		end
	end
end

-- Remember each part's clean colour so DirtRenderer can tint the whole animal muddy.
local function recordCleanColors(model: Model)
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= model.PrimaryPart and not part:GetAttribute("NoGrime") then
			part:SetAttribute("CleanColor", part.Color)
		end
	end
end

-- World-axis bounds of a part (a ball or cylinder is treated as its box).
local function partBounds(part: BasePart): (Vector3, Vector3)
	local cf, s = part.CFrame, part.Size / 2
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	local half = Vector3.new(
		math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z,
		math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z,
		math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z
	)
	return cf.Position - half, cf.Position + half
end

-- Bounds of the animal's own parts (not Root, not dirt patches).
local function modelBounds(model: Model): (Vector3, Vector3)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= model.PrimaryPart then
			local a, b = partBounds(part)
			lo, hi = lo:Min(a), hi:Max(b)
		end
	end
	return lo, hi
end

-- Slides every part along Z so snout-to-tail is centred on the pivot, which keeps long
-- animals inside their pen and cache slot.
local function centreFootprint(model: Model)
	local lo, hi = modelBounds(model)
	local shift = Vector3.new(0, 0, -(lo.Z + hi.Z) / 2)
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= model.PrimaryPart then
			part.CFrame += shift
		end
	end
end

-- Dirt patches over a placeholder's body, neck sides and head. Runs on a fresh build or on a
-- clone of a cached clean one: the patches only read the body, neck and head as built.
local function addPlaceholderPatches(model: Model, spec: Spec, patches: { PatchInfo })
	local body = model:FindFirstChild("Body") :: BasePart
	local head = model:FindFirstChild("Head") :: BasePart
	local neck = model:FindFirstChild("Neck") :: BasePart?
	local patchFolder = model:FindFirstChild("DirtPatches") :: Instance
	local b, leg, h = spec.BodySize, spec.LegHeight, spec.HeadSize
	local cell = spec.PatchCell or DEFAULT_PATCH_CELL
	local X, Y, Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
	-- Body: both sides, top, rump
	addFacePatches(body, X, Z, b.Z, Y, b.Y, cell, patches, patchFolder)
	addFacePatches(body, -X, Z, b.Z, Y, b.Y, cell, patches, patchFolder)
	if leg + b.Y <= MAX_TOP_PATCH_HEIGHT then
		addFacePatches(body, Y, Z, b.Z, X, b.X, cell, patches, patchFolder)
	end
	if not spec.SkipRump then
		addFacePatches(body, Z, Y, b.Y, X, b.X, cell, patches, patchFolder)
	end
	-- Neck sides (vertical faces are reachable at any height)
	if neck then
		local n = neck.Size
		addFacePatches(neck, X, Z, n.Z, Y, n.Y, cell, patches, patchFolder)
		addFacePatches(neck, -X, Z, n.Z, Y, n.Y, cell, patches, patchFolder)
	end
	-- Head: both sides, and the top when it's low enough
	addFacePatches(head, X, Z, h.Z, Y, h.Y, cell, patches, patchFolder)
	addFacePatches(head, -X, Z, h.Z, Y, h.Y, cell, patches, patchFolder)
	if head.Position.Y + h.Y / 2 <= MAX_TOP_PATCH_HEIGHT then
		addFacePatches(head, Y, Z, h.Z, X, h.X, cell, patches, patchFolder)
	end
end

local function buildPlaceholder(spec: Spec, clean: boolean): (Model, { PatchInfo })
	local model = Instance.new("Model")
	model.Name = "Animal"

	local root = makePart("Root", Vector3.new(1, 1, 1), CFrame.new(), Color3.new(), model)
	root.Transparency = 1
	root.CanCollide = false
	root.CanQuery = false
	model.PrimaryPart = root

	local b, leg, h = spec.BodySize, spec.LegHeight, spec.HeadSize
	local body = makePart("Body", b, CFrame.new(0, leg + b.Y / 2, 0), spec.BodyColor, model)
	body.Material = spec.BodyMaterial

	local headCFrame: CFrame
	if spec.Neck then
		-- Neck rises from the front of the body; the head sits on top, poking forward.
		-- NeckTilt pivots it forward about its base; the head stays level on the tip.
		local n = spec.Neck
		local base = CFrame.new(0, leg + b.Y - 0.6, -(b.Z / 2 - n.Z / 2)) * CFrame.Angles(-(spec.NeckTilt or 0), 0, 0)
		local neckPart = makePart("Neck", n, base * CFrame.new(0, n.Y / 2, 0), spec.BodyColor, model)
		neckPart.Material = spec.BodyMaterial
		local tip = (base * CFrame.new(0, n.Y, 0)).Position
		headCFrame = CFrame.new(tip) * CFrame.new(0, h.Y / 2 - 0.4, -h.Z / 2 + n.Z / 2 + 0.1)
	else
		headCFrame = if spec.HeadOnTop
			then CFrame.new(0, leg + b.Y + h.Y / 2 - 0.2, -0.1)
			else CFrame.new(0, leg + b.Y * 0.8 + (spec.HeadLift or 0), -(b.Z / 2 + h.Z / 2 - 0.3))
	end
	if spec.HeadPosition then
		headCFrame = CFrame.new(spec.HeadPosition)
	end
	local head = makePart("Head", h, headCFrame, spec.HeadColor, model)
	head.Material = spec.BodyMaterial

	local thickness = spec.LegThickness or 0.9
	local legColor = spec.LegColor or spec.HeadColor
	local legSpots: { { number } } = if spec.LegCount == 2
		then { { -1, 0 }, { 1, 0 } }
		else { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } }
	for _, spot in legSpots do
		local inset = math.max(thickness * 0.7, 0.3)
		local legBlock = makePart(
			"Leg",
			Vector3.new(thickness, leg, thickness),
			CFrame.new(spot[1] * (b.X / 2 - inset), leg / 2, spot[2] * (b.Z / 2 - inset - 0.2)),
			legColor,
			model
		)
		legBlock.CanQuery = true -- legs block spray like the real body would
	end

	spec.Decorate(model, body, head, spec)
	if spec.CenterZ then
		centreFootprint(model)
	end
	recordCleanColors(model)

	local patchFolder = Instance.new("Model")
	patchFolder.Name = "DirtPatches"
	patchFolder.Parent = model

	local patches: { PatchInfo } = {}
	if not clean then
		addPlaceholderPatches(model, spec, patches)
	end

	return model, patches
end

-- A modeler-supplied template from ServerStorage.AnimalTemplates, or nil if absent/invalid.
local function buildFromTemplate(templateName: string, clean: boolean): (Model?, { PatchInfo })
	local folder = ServerStorage:FindFirstChild("AnimalTemplates")
	local template = folder and folder:FindFirstChild(templateName)
	if not template or not template:IsA("Model") then
		return nil, {}
	end
	local templateRoot = template:FindFirstChild("Root")
	if not templateRoot or not templateRoot:IsA("BasePart") or not template:FindFirstChild("Body") then
		warn(`[AnimalBuilder] Template {templateName} breaks the contract (needs Root and Body); using placeholder`)
		return nil, {}
	end

	local model = template:Clone()
	model.Name = "Animal"
	model.PrimaryPart = model:FindFirstChild("Root") :: BasePart
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	recordCleanColors(model)

	local patchFolder = model:FindFirstChild("DirtPatches")
	if not patchFolder then
		local created = Instance.new("Model")
		created.Name = "DirtPatches"
		created.Parent = model
		patchFolder = created
	end
	local patches: { PatchInfo } = {}
	for _, part in (patchFolder :: Instance):GetChildren() do
		if part:IsA("BasePart") then
			if clean then
				part:Destroy()
			else
				local id = "P" .. (#patches + 1)
				part.CanQuery = true
				part.CanCollide = false
				part:SetAttribute("PatchId", id)
				part:SetAttribute("BaseDiameter", part.Size.Y)
				table.insert(patches, { Id = id, Part = part })
			end
		end
	end
	if not clean and #patches == 0 then
		warn(`[AnimalBuilder] Template {templateName} has no DirtPatches; using placeholder`)
		model:Destroy()
		return nil, {}
	end
	return model, patches
end

-- Mutation glints: sparkles twinkling over the body. No light: a lit-up blob reads as a
-- lamp, not as something special.
local function aura(model: Model, color: Color3, rate: number)
	local body = model:FindFirstChild("Body")
	if not body then
		return
	end
	if rate > 0 then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Aura"
		emitter.Rate = rate
		emitter.Lifetime = NumberRange.new(1, 1.6)
		emitter.Speed = NumberRange.new(0.5, 1.5)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.5),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Texture = SPARKLE_TEX
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-90, 90)
		emitter.Color = ColorSequence.new(color)
		emitter.LightEmission = 1
		emitter.Shape = Enum.ParticleEmitterShape.Box
		emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		emitter.Parent = body
	end
end

local function recolor(model: Model, transform: (clean: Color3, index: number) -> Color3, reflectance: number)
	local i = 0
	for _, part in model:GetChildren() do
		local clean = part:GetAttribute("CleanColor")
		if part:IsA("BasePart") and typeof(clean) == "Color3" then
			i += 1
			part:SetAttribute("CleanColor", transform(clean, i))
			part.Reflectance = reflectance
		end
	end
end

local GOLD = Color3.fromRGB(255, 200, 60)
local DIAMOND = Color3.fromRGB(170, 240, 255)

-- Mutation look. Works by rewriting CleanColor, so grime still fades to the mutation colours.
local function applyMutation(model: Model, mutationKey: string)
	model:SetAttribute("Mutation", mutationKey)
	if mutationKey == "Gold" then
		recolor(model, function(clean)
			return clean:Lerp(GOLD, 0.75)
		end, 0.15)
		aura(model, GOLD, 8)
	elseif mutationKey == "Diamond" then
		recolor(model, function(clean)
			return clean:Lerp(DIAMOND, 0.7)
		end, 0.35)
		aura(model, DIAMOND, 10)
	elseif mutationKey == "Rainbow" then
		recolor(model, function(_clean, i)
			return Color3.fromHSV((i * 0.13) % 1, 0.55, 1)
		end, 0.1)
		aura(model, Color3.fromRGB(255, 120, 220), 16)
	end
end

-- Rarity auras, in the Steal a Brainrot spirit: a glowing ring on the ground under the
-- animal, a column of particles rising off it, and a second layer around the body. No point
-- lights. The ring and its emitter base are decorations (no grime, no queries, no collisions)
-- and scale with the model.
type AuraStyle = {
	Ring: ColorSequence | Color3,
	RingTransparency: number,
	Rise: { [string]: any }, -- ParticleEmitter props for the column off the ring
	Body: { [string]: any }?, -- ParticleEmitter props around the body
	Extra: { [string]: any }?, -- a third layer (Secret: stars in the smoke)
}

local function flatBase(model: Model, name: string, diameter: number, height: number): Part
	local root = model.PrimaryPart or model:FindFirstChild("Root")
	local pivot = if root and root:IsA("BasePart") then root.CFrame else model:GetPivot()
	local base = decoration(
		name,
		Vector3.new(diameter, height, diameter),
		CFrame.new(pivot.Position.X, pivot.Position.Y + height / 2 + 0.04, pivot.Position.Z),
		Color3.new(1, 1, 1),
		model
	)
	base.CastShadow = false
	base:SetAttribute("NoGrime", true)
	return base
end

local function emitter(parent: Instance, name: string, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Rotation = NumberRange.new(0, 360)
	for key, value in props do
		(e :: any)[key] = value
	end
	e.Parent = parent
	return e
end

local function fade(peak: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, peak),
		NumberSequenceKeypoint.new(0.75, peak),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function grow(from: number, to: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, from),
		NumberSequenceKeypoint.new(1, to),
	})
end

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 220, 60)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 255, 120)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(80, 180, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 100, 255)),
})

local AURAS: { [string]: AuraStyle } = {
	Epic = {
		Ring = Color3.fromRGB(190, 110, 255),
		RingTransparency = 0.55,
		Rise = {
			Texture = SPARKLE_TEX,
			Rate = 7,
			Lifetime = NumberRange.new(1.2, 1.8),
			Speed = NumberRange.new(1.5, 2.5),
			Size = grow(0.5, 0),
			Transparency = fade(0.15),
			Color = ColorSequence.new(Color3.fromRGB(210, 150, 255)),
		},
		Body = {
			Texture = SPARKLE_TEX,
			Rate = 4,
			Lifetime = NumberRange.new(0.6, 1),
			Speed = NumberRange.new(0, 0.3),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.6),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Color = ColorSequence.new(Color3.fromRGB(230, 190, 255)),
		},
	},
	Legendary = {
		Ring = Color3.fromRGB(255, 205, 60),
		RingTransparency = 0.45,
		Rise = {
			Texture = SPARKLE_TEX,
			Rate = 14,
			Lifetime = NumberRange.new(1, 1.6),
			Speed = NumberRange.new(3, 5),
			Size = grow(0.6, 0.1),
			Squash = NumberSequence.new(-1.2),
			Transparency = fade(0.1),
			Color = ColorSequence.new(Color3.fromRGB(255, 235, 140), Color3.fromRGB(255, 180, 40)),
		},
		Body = {
			Texture = SPARKLE_TEX,
			Rate = 7,
			Lifetime = NumberRange.new(0.6, 1.1),
			Speed = NumberRange.new(0, 0.4),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.7),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Color = ColorSequence.new(Color3.fromRGB(255, 240, 170)),
		},
	},
	Mythic = {
		Ring = Color3.fromRGB(255, 70, 40),
		RingTransparency = 0.4,
		Rise = {
			Texture = FIRE_TEX,
			Rate = 22,
			Lifetime = NumberRange.new(0.6, 1),
			Speed = NumberRange.new(3, 5.5),
			Size = grow(1.2, 0.2),
			Transparency = fade(0.35),
			RotSpeed = NumberRange.new(-60, 60),
			Color = ColorSequence.new(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 40, 30)),
		},
		Body = {
			Texture = SPARKLE_TEX,
			Rate = 10,
			Lifetime = NumberRange.new(0.8, 1.4),
			Speed = NumberRange.new(1, 2),
			Acceleration = Vector3.new(0, 4, 0),
			Size = grow(0.35, 0),
			Color = ColorSequence.new(Color3.fromRGB(255, 150, 60)),
		},
	},
	ZooGod = {
		Ring = RAINBOW,
		RingTransparency = 0.35,
		Rise = {
			Texture = SPARKLE_TEX,
			Rate = 26,
			Lifetime = NumberRange.new(1.2, 1.8),
			Speed = NumberRange.new(4, 6.5),
			Size = grow(0.8, 0.15),
			Squash = NumberSequence.new(-1.4),
			Transparency = fade(0.05),
			Color = RAINBOW,
		},
		Body = {
			Texture = SPARKLE_TEX,
			Rate = 12,
			Lifetime = NumberRange.new(0.8, 1.2),
			Speed = NumberRange.new(0, 0.5),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.9),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Color = RAINBOW,
		},
	},
	Secret = {
		Ring = Color3.fromRGB(40, 10, 60),
		RingTransparency = 0.2,
		Rise = {
			Texture = SMOKE_TEX,
			Rate = 14,
			Lifetime = NumberRange.new(1.5, 2.4),
			Speed = NumberRange.new(1, 2.5),
			Size = grow(1.6, 3.4),
			RotSpeed = NumberRange.new(-40, 40),
			Transparency = fade(0.35),
			Color = ColorSequence.new(Color3.fromRGB(70, 20, 110), Color3.fromRGB(10, 0, 20)),
			LightEmission = 0,
		},
		Body = {
			Texture = SPARKLE_TEX,
			Rate = 9,
			Lifetime = NumberRange.new(0.6, 1),
			Speed = NumberRange.new(0, 0.4),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.7),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Color = ColorSequence.new(Color3.new(1, 1, 1)),
		},
		Extra = {
			Texture = SPARKLE_TEX,
			Rate = 6,
			Lifetime = NumberRange.new(0.3, 0.5),
			Speed = NumberRange.new(6, 9),
			Size = grow(0.6, 0),
			Squash = NumberSequence.new(-2),
			Color = ColorSequence.new(Color3.fromRGB(190, 120, 255)),
		},
	},
}

local function applyTierAura(model: Model, rarityKey: string)
	local style = AURAS[rarityKey]
	if not style then
		return
	end
	local lo, hi = modelBounds(model)
	local footprint = math.max(hi.X - lo.X, hi.Z - lo.Z)
	local diameter = footprint * 0.95 + 1.5

	local ring = flatBase(model, "AuraRing", diameter, 0.08)
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.08, diameter, diameter)
	ring.CFrame = ring.CFrame * CFrame.Angles(0, 0, math.rad(90))
	ring.Material = Enum.Material.Neon
	ring.Transparency = style.RingTransparency
	if typeof(style.Ring) == "Color3" then
		ring.Color = style.Ring
	else
		-- A Neon disc can't take a gradient, so clients cycle its hue (ZooController).
		ring.Color = Color3.fromRGB(255, 200, 255)
		CollectionService:AddTag(ring, RAINBOW_RING_TAG)
	end

	-- A flat box at foot level: the column rises from its whole footprint.
	local base = flatBase(model, "AuraBase", diameter * 0.8, 0.1)
	base.Transparency = 1
	local rise = table.clone(style.Rise)
	rise.Shape = Enum.ParticleEmitterShape.Box
	rise.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	rise.EmissionDirection = Enum.NormalId.Top
	rise.SpreadAngle = Vector2.new(6, 6)
	emitter(base, "AuraRise", rise)

	local body = model:FindFirstChild("Body")
	if body and style.Body then
		local around = table.clone(style.Body)
		around.Shape = Enum.ParticleEmitterShape.Box
		around.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		around.SpreadAngle = Vector2.new(180, 180)
		emitter(body, "AuraBody", around)
	end
	if style.Extra then
		local extra = table.clone(style.Extra)
		extra.Shape = Enum.ParticleEmitterShape.Box
		extra.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		extra.EmissionDirection = Enum.NormalId.Top
		extra.SpreadAngle = Vector2.new(4, 4)
		emitter(base, "AuraBolts", extra)
	end

	if rarityKey == "ZooGod" then
		local head = model:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			-- Heads with horns or domes set HaloLift so the halo floats clear of them.
			local lift = head:GetAttribute("HaloLift")
			local halo = decoration(
				"Halo",
				Vector3.new(0.15, head.Size.X * 0.9, head.Size.X * 0.9),
				head.CFrame
					* CFrame.new(0, head.Size.Y / 2 + (if typeof(lift) == "number" then lift else 0.9), 0)
					* CFrame.Angles(0, 0, math.rad(90)),
				Color3.fromRGB(255, 230, 120),
				model
			)
			halo.Shape = Enum.PartType.Cylinder
			halo.Material = Enum.Material.Neon
			halo.Transparency = 0.2
			halo:SetAttribute("NoGrime", true)
		end
	end
end

-- Pen limits the placeholder roster is checked against (see AnimalBuilder.audit).
local AUDIT_MAX_WIDTH = 9
local AUDIT_MAX_LENGTH = 11.5
local AUDIT_MAX_HEIGHT = 16
local AUDIT_MAX_PARTS = 150
local BODY_PARTS = { Root = true, Body = true, Head = true, Neck = true, Leg = true }

-- Command-bar check for the placeholder models: footprint, height, part count, patch count
-- and the decoration rule (only body parts may be queryable or collidable). Returns the
-- number of problems; each one is also warned.
--   require(game.ServerScriptService.Server.Services.AnimalBuilder).audit()
function AnimalBuilder.audit(): number
	local names = {}
	for name in SPECS do
		table.insert(names, name)
	end
	table.sort(names)
	local problems = 0
	local function problem(message: string)
		problems += 1
		warn(`[AnimalBuilder.audit] {message}`)
	end
	for _, name in names do
		local model, patches = buildPlaceholder(SPECS[name], false)
		local lo, hi = modelBounds(model)
		local parts = 0
		for _, part in model:GetChildren() do
			if part:IsA("BasePart") then
				parts += 1
				if not BODY_PARTS[part.Name] and (part.CanQuery or part.CanCollide) then
					problem(`{name}: decoration {part.Name} is queryable or collidable`)
				end
			end
		end
		local width = 2 * math.max(-lo.X, hi.X)
		local length = 2 * math.max(-lo.Z, hi.Z)
		print(
			string.format(
				"[AnimalBuilder.audit] %-9s %3d parts %3d patches  width %.1f  length %.1f  height %.1f",
				name,
				parts,
				#patches,
				width,
				length,
				hi.Y
			)
		)
		if width > AUDIT_MAX_WIDTH or length > AUDIT_MAX_LENGTH or hi.Y > AUDIT_MAX_HEIGHT then
			problem(`{name}: {width}x{length}x{hi.Y} studs is too big for a pen`)
		end
		if parts > AUDIT_MAX_PARTS then
			problem(`{name}: {parts} parts (limit {AUDIT_MAX_PARTS})`)
		end
		if #patches < 6 then
			problem(`{name}: only {#patches} dirt patches`)
		end
		model:Destroy()
	end
	return problems
end

function AnimalBuilder.has(templateName: string): boolean
	return SPECS[templateName] ~= nil
end

-- Clean builds are deterministic, and building one sets every property of up to ~150
-- parts from Lua. Each look (template, mutation, rarity) is built once, kept unparented,
-- and cloned after that. Pens, the cache, pets and the showcase all take clean builds.
local cleanPrototypes: { [string]: Model } = {}

local function cleanBuild(templateName: string, mutation: string, rarity: string): Model
	local key = `{templateName}|{mutation}|{rarity}`
	local prototype = cleanPrototypes[key]
	if not prototype then
		local model = buildFromTemplate(templateName, true)
		if not model then
			local spec = SPECS[templateName]
			assert(spec, "Unknown animal template: " .. templateName)
			model = buildPlaceholder(spec, true)
		end
		prototype = model :: Model
		applyMutation(prototype, mutation)
		applyTierAura(prototype, rarity)
		cleanPrototypes[key] = prototype
	end
	return prototype:Clone()
end

-- Returns the model (pivoted at the origin) and its dirt patches (empty when Clean).
-- Part colours are left at their clean values; DirtRenderer.setGrime applies grime/mutation colour.
function AnimalBuilder.build(templateName: string, options: BuildOptions?): (Model, { PatchInfo })
	local opts: BuildOptions = options or {}
	local clean = opts.Clean == true
	local mutation = opts.Mutation or MutationConfig.Default
	local rarity = opts.Rarity or "Common"
	if clean then
		return cleanBuild(templateName, mutation, rarity), {}
	end
	local spec = SPECS[templateName]
	local templates = ServerStorage:FindFirstChild("AnimalTemplates")
	if spec and not (templates and templates:FindFirstChild(templateName)) then
		-- A dirty placeholder is the clean one plus its mud skin.
		local model = cleanBuild(templateName, mutation, rarity)
		local patches: { PatchInfo } = {}
		addPlaceholderPatches(model, spec, patches)
		return model, patches
	end
	local model, patches = buildFromTemplate(templateName, clean)
	if not model then
		assert(spec, "Unknown animal template: " .. templateName)
		model, patches = buildPlaceholder(spec, clean)
	end
	local built = model :: Model
	applyMutation(built, mutation)
	applyTierAura(built, rarity)
	return built, patches
end

return AnimalBuilder
