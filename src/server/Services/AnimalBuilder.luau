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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)

local AnimalBuilder = {}

export type PatchInfo = { Id: string, Part: BasePart }

export type BuildOptions = {
	Mutation: string?, -- MutationConfig key; changes colours (Gold, Diamond, Rainbow)
	Rarity: string?, -- RarityConfig key; Zoo God and Secret animals get an aura
	Clean: boolean?, -- no dirt patches (pens, cache, carried)
	Seed: number?,
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

-- Decorations never block spray or collide.
local function decoration(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = makePart(name, size, cframe, color, parent)
	part.CanCollide = false
	part.CanQuery = false
	return part
end

-- White eye with a pupil looking slightly forward. Eyes are never tinted by grime or rarity.
local function addEyes(head: BasePart, parent: Instance)
	local s = head.Size
	local eyeSize = math.clamp(s.Y * 0.22, 0.25, 0.55)
	for _, side in { -1, 1 } do
		local offset = Vector3.new(side * s.X * 0.28, s.Y * 0.15, -s.Z / 2 - 0.03)
		local eye = decoration(
			"Eye",
			Vector3.new(eyeSize * 0.9, eyeSize, 0.08),
			head.CFrame * CFrame.new(offset),
			Color3.new(1, 1, 1),
			parent
		)
		eye:SetAttribute("NoGrime", true)
		local pupil = decoration(
			"Pupil",
			Vector3.new(eyeSize * 0.5, eyeSize * 0.55, 0.06),
			eye.CFrame * CFrame.new(side * -eyeSize * 0.1, -eyeSize * 0.08, -0.05),
			Color3.fromRGB(20, 20, 25),
			parent
		)
		pupil:SetAttribute("NoGrime", true)
	end
end

local function pairOfEars(head: BasePart, size: Vector3, color: Color3, lift: number, tilt: number, parent: Instance)
	local h = head.Size
	for _, side in { -1, 1 } do
		decoration(
			"Ear",
			size,
			head.CFrame * CFrame.new(side * h.X * 0.32, h.Y / 2 + lift, 0.1) * CFrame.Angles(0, 0, side * -tilt),
			color,
			parent
		)
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

local function shaped(part: Part, shape: Enum.PartType): Part
	part.Shape = shape
	return part
end

local function ball(name: string, diameter: number, cframe: CFrame, color: Color3, parent: Instance): Part
	return shaped(
		decoration(name, Vector3.new(diameter, diameter, diameter), cframe, color, parent),
		Enum.PartType.Ball
	)
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

local function glowLight(parent: Instance, color: Color3, brightness: number, range: number)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Parent = parent
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

-- Big cartoon eyes on the head's front face: sclera, iris, pupil and a glinting highlight.
local function heroEyes(head: BasePart, parent: Instance, style: EyeStyle)
	local s = head.Size
	local size = style.Size
	local spread = style.Spread or 0.28
	local lift = style.Lift or 0.15
	for _, side in { -1, 1 } do
		local face = head.CFrame * CFrame.new(side * s.X * spread, s.Y * lift, -s.Z / 2)
		local parts = { disc("Eye", size, 0.1, face * CFrame.new(0, 0, -0.03), style.Sclera or WHITE, parent) }
		local look = face * CFrame.new(-side * size * 0.06, -size * 0.04, 0) -- gaze slightly in and down
		if style.Iris then
			local iris = disc("Iris", size * 0.64, 0.1, look * CFrame.new(0, 0, -0.07), style.Iris, parent)
			if style.Glow then
				glow(iris)
			end
			table.insert(parts, iris)
		end
		table.insert(
			parts,
			if style.Slit
				then decoration(
					"Pupil",
					Vector3.new(size * 0.13, size * 0.5, 0.1),
					look * CFrame.new(0, 0, -0.11),
					INK,
					parent
				)
				else disc("Pupil", size * 0.34, 0.1, look * CFrame.new(0, 0, -0.11), INK, parent)
		)
		table.insert(
			parts,
			glow(disc("Shine", size * 0.2, 0.1, look * CFrame.new(size * 0.15, size * 0.15, -0.15), WHITE, parent))
		)
		for _, part in parts do
			part:SetAttribute("NoGrime", true)
		end
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

local SPECS: { [string]: Spec } = {
	Chicken = {
		BodySize = Vector3.new(1.6, 1.5, 2.0),
		LegHeight = 0.8,
		LegCount = 2,
		LegThickness = 0.25,
		LegColor = ORANGE,
		HeadSize = Vector3.new(1.0, 1.1, 1.0),
		HeadLift = 0.9,
		BodyColor = Color3.fromRGB(250, 250, 245),
		HeadColor = Color3.fromRGB(250, 250, 245),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 0.75,
		Decorate = function(model, body, head, _spec)
			local h = head.Size
			decoration(
				"Beak",
				Vector3.new(0.3, 0.25, 0.45),
				head.CFrame * CFrame.new(0, -0.1, -h.Z / 2 - 0.2),
				ORANGE,
				model
			)
			decoration(
				"Comb",
				Vector3.new(0.2, 0.45, 0.6),
				head.CFrame * CFrame.new(0, h.Y / 2 + 0.2, 0),
				Color3.fromRGB(220, 40, 40),
				model
			)
			decoration(
				"Tail",
				Vector3.new(1.0, 0.9, 0.3),
				body.CFrame * CFrame.new(0, body.Size.Y * 0.5, body.Size.Z / 2 + 0.1) * CFrame.Angles(-0.4, 0, 0),
				Color3.fromRGB(250, 250, 245),
				model
			)
			addEyes(head, model)
		end,
	},
	Duck = {
		BodySize = Vector3.new(1.7, 1.3, 2.4),
		LegHeight = 0.6,
		LegCount = 2,
		LegThickness = 0.25,
		LegColor = ORANGE,
		HeadSize = Vector3.new(0.9, 1.0, 1.0),
		HeadLift = 1.0,
		BodyColor = Color3.fromRGB(245, 245, 235),
		HeadColor = Color3.fromRGB(40, 130, 70),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 0.75,
		Decorate = function(model, body, head, _spec)
			local h = head.Size
			decoration(
				"Bill",
				Vector3.new(0.6, 0.2, 0.6),
				head.CFrame * CFrame.new(0, -0.2, -h.Z / 2 - 0.25),
				ORANGE,
				model
			)
			decoration(
				"Tail",
				Vector3.new(0.8, 0.3, 0.4),
				body.CFrame * CFrame.new(0, body.Size.Y * 0.35, body.Size.Z / 2 + 0.15) * CFrame.Angles(-0.5, 0, 0),
				Color3.fromRGB(245, 245, 235),
				model
			)
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
			pairOfEars(head, Vector3.new(0.3, 1.4, 0.15), spec.HeadColor, 0.65, 0.15, model)
			local tail = decoration(
				"Tail",
				Vector3.new(0.6, 0.6, 0.6),
				body.CFrame * CFrame.new(0, 0.2, body.Size.Z / 2 + 0.2),
				Color3.fromRGB(250, 250, 250),
				model
			)
			tail.Shape = Enum.PartType.Ball
			decoration(
				"Nose",
				Vector3.new(0.25, 0.2, 0.08),
				head.CFrame * CFrame.new(0, -0.15, -head.Size.Z / 2 - 0.03),
				PINK_DARK,
				model
			)
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
		Decorate = function(model, body, head, _spec)
			local h = head.Size
			local snout = decoration(
				"Snout",
				Vector3.new(0.4, 1.1, 1.1),
				head.CFrame * CFrame.new(0, -0.3, -h.Z / 2 - 0.2) * CFrame.Angles(0, math.rad(90), 0),
				PINK_DARK,
				model
			)
			snout.Shape = Enum.PartType.Cylinder
			for _, side in { -1, 1 } do
				decoration(
					"Nostril",
					Vector3.new(0.15, 0.3, 0.06),
					head.CFrame * CFrame.new(side * 0.22, -0.3, -h.Z / 2 - 0.41),
					Color3.fromRGB(150, 60, 80),
					model
				)
			end
			for _, side in { -1, 1 } do
				decoration(
					"Ear",
					Vector3.new(0.7, 0.7, 0.2),
					head.CFrame * CFrame.new(side * h.X * 0.32, h.Y / 2 + 0.25, -0.2) * CFrame.Angles(0.4, 0, 0),
					PINK_DARK,
					model
				)
			end
			decoration(
				"Tail",
				Vector3.new(0.3, 0.3, 0.7),
				body.CFrame * CFrame.new(0, body.Size.Y * 0.3, body.Size.Z / 2 + 0.3),
				PINK_DARK,
				model
			)
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
		Decorate = function(model, _body, head, _spec)
			local h = head.Size
			for _, side in { -1, 1 } do
				decoration(
					"Ear",
					Vector3.new(0.9, 0.3, 0.4),
					head.CFrame * CFrame.new(side * (h.X / 2 + 0.35), h.Y * 0.2, 0),
					Color3.fromRGB(70, 60, 60),
					model
				)
			end
			decoration(
				"Tuft",
				Vector3.new(h.X * 0.9, 0.5, h.Z * 0.6),
				head.CFrame * CFrame.new(0, h.Y / 2 + 0.2, 0.2),
				Color3.fromRGB(245, 245, 235),
				model
			)
			addEyes(head, model)
		end,
	},
	Goat = {
		BodySize = Vector3.new(2.6, 2.4, 4.2),
		LegHeight = 1.6,
		LegThickness = 0.6,
		HeadSize = Vector3.new(1.5, 1.7, 1.8),
		HeadLift = 0.4,
		BodyColor = Color3.fromRGB(235, 230, 220),
		HeadColor = Color3.fromRGB(235, 230, 220),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.2,
		Decorate = function(model, _body, head, spec)
			local h = head.Size
			for _, side in { -1, 1 } do
				decoration(
					"Horn",
					Vector3.new(0.25, 0.9, 0.25),
					head.CFrame * CFrame.new(side * h.X * 0.25, h.Y / 2 + 0.35, 0.25) * CFrame.Angles(0.5, 0, 0),
					Color3.fromRGB(120, 110, 100),
					model
				)
			end
			pairOfEars(head, Vector3.new(0.7, 0.25, 0.3), spec.HeadColor, -0.4, 0, model)
			decoration(
				"Beard",
				Vector3.new(0.35, 0.6, 0.2),
				head.CFrame * CFrame.new(0, -h.Y / 2 - 0.2, -h.Z / 2 + 0.2),
				Color3.fromRGB(200, 195, 185),
				model
			)
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
			local h = head.Size
			pairOfEars(head, Vector3.new(0.4, 1.5, 0.3), spec.HeadColor, 0.7, 0.2, model)
			decoration(
				"Muzzle",
				Vector3.new(h.X * 0.9, h.Y * 0.45, 0.5),
				head.CFrame * CFrame.new(0, -h.Y * 0.25, -h.Z / 2 - 0.2),
				Color3.fromRGB(215, 210, 205),
				model
			)
			decoration(
				"Tail",
				Vector3.new(0.25, 1.6, 0.25),
				body.CFrame * CFrame.new(0, -0.1, body.Size.Z / 2 + 0.15) * CFrame.Angles(0.3, 0, 0),
				Color3.fromRGB(60, 55, 55),
				model
			)
			addEyes(head, model)
		end,
	},
	Cow = {
		BodySize = Vector3.new(4.4, 4, 8),
		LegHeight = 2.4,
		HeadSize = Vector3.new(2.8, 2.8, 3),
		BodyColor = Color3.fromRGB(250, 250, 250),
		HeadColor = Color3.fromRGB(250, 250, 250),
		BodyMaterial = Enum.Material.SmoothPlastic,
		Decorate = function(model, body, head, _spec)
			local h = head.Size
			local b = body.Size
			-- A few black spots, flush with the body so patches still sit on top.
			local spots = {
				{ side = 1, z = -1.5, y = 0.6, size = 1.8 },
				{ side = 1, z = 2, y = -0.4, size = 1.4 },
				{ side = -1, z = 0.5, y = 0.3, size = 2 },
			}
			for _, spot in spots do
				decoration(
					"Spot",
					Vector3.new(0.05, spot.size, spot.size * 1.2),
					body.CFrame * CFrame.new(spot.side * (b.X / 2 + 0.01), spot.y, spot.z),
					Color3.fromRGB(30, 30, 30),
					model
				)
			end
			decoration(
				"Muzzle",
				Vector3.new(h.X * 0.8, h.Y * 0.4, 0.5),
				head.CFrame * CFrame.new(0, -h.Y * 0.28, -h.Z / 2 - 0.2),
				Color3.fromRGB(240, 180, 180),
				model
			)
			for _, side in { -1, 1 } do
				decoration(
					"Horn",
					Vector3.new(0.3, 0.9, 0.3),
					head.CFrame * CFrame.new(side * h.X * 0.35, h.Y / 2 + 0.4, 0),
					Color3.fromRGB(235, 225, 200),
					model
				)
			end
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
			pairOfEars(head, Vector3.new(0.3, 0.9, 0.25), spec.HeadColor, 0.4, 0.1, model)
			decoration(
				"Tail",
				Vector3.new(0.5, 0.8, 0.4),
				body.CFrame * CFrame.new(0, body.Size.Y * 0.3, body.Size.Z / 2 + 0.2),
				spec.BodyColor,
				model
			)
			addEyes(head, model)
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
			local mane = Color3.fromRGB(45, 30, 20)
			local neck = model:FindFirstChild("Neck")
			if neck and neck:IsA("BasePart") then
				decoration(
					"Mane",
					Vector3.new(0.3, neck.Size.Y + 0.6, 0.5),
					neck.CFrame * CFrame.new(0, 0.2, neck.Size.Z / 2 + 0.15),
					mane,
					model
				)
			end
			pairOfEars(head, Vector3.new(0.3, 0.7, 0.25), spec.HeadColor, 0.3, 0.1, model)
			decoration(
				"Tail",
				Vector3.new(0.4, 2.2, 0.4),
				body.CFrame * CFrame.new(0, -0.2, body.Size.Z / 2 + 0.3) * CFrame.Angles(0.35, 0, 0),
				mane,
				model
			)
			addEyes(head, model)
		end,
	},
	Dog = {
		BodySize = Vector3.new(2.2, 2.0, 3.6),
		LegHeight = 1.2,
		LegThickness = 0.6,
		HeadSize = Vector3.new(1.6, 1.6, 1.8),
		HeadLift = 0.4,
		BodyColor = Color3.fromRGB(190, 140, 90),
		HeadColor = Color3.fromRGB(190, 140, 90),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.0,
		Decorate = function(model, body, head, _spec)
			local h = head.Size
			local dark = Color3.fromRGB(110, 75, 45)
			for _, side in { -1, 1 } do
				decoration(
					"Ear",
					Vector3.new(0.35, 1.0, 0.6),
					head.CFrame * CFrame.new(side * (h.X / 2 + 0.15), h.Y * 0.1, 0.1),
					dark,
					model
				)
			end
			decoration(
				"Snout",
				Vector3.new(0.9, 0.7, 0.6),
				head.CFrame * CFrame.new(0, -0.35, -h.Z / 2 - 0.25),
				Color3.fromRGB(230, 200, 160),
				model
			)
			decoration(
				"Nose",
				Vector3.new(0.35, 0.25, 0.1),
				head.CFrame * CFrame.new(0, -0.15, -h.Z / 2 - 0.58),
				Color3.new(0, 0, 0),
				model
			)
			decoration(
				"Tail",
				Vector3.new(0.25, 1.1, 0.25),
				body.CFrame * CFrame.new(0, body.Size.Y * 0.45, body.Size.Z / 2 + 0.2) * CFrame.Angles(-0.6, 0, 0),
				dark,
				model
			)
			addEyes(head, model)
		end,
	},
	Cat = {
		BodySize = Vector3.new(1.8, 1.6, 3.0),
		LegHeight = 1.0,
		LegThickness = 0.45,
		HeadSize = Vector3.new(1.5, 1.4, 1.4),
		HeadLift = 0.35,
		BodyColor = Color3.fromRGB(245, 160, 70),
		HeadColor = Color3.fromRGB(245, 160, 70),
		BodyMaterial = Enum.Material.Fabric,
		PatchCell = 0.85,
		Decorate = function(model, body, head, spec)
			pairOfEars(head, Vector3.new(0.45, 0.55, 0.2), spec.HeadColor, 0.25, 0.25, model)
			decoration(
				"Tail",
				Vector3.new(0.25, 1.8, 0.25),
				body.CFrame * CFrame.new(0, body.Size.Y * 0.6, body.Size.Z / 2 + 0.3) * CFrame.Angles(-0.35, 0, 0),
				spec.BodyColor,
				model
			)
			decoration(
				"Nose",
				Vector3.new(0.25, 0.18, 0.08),
				head.CFrame * CFrame.new(0, -0.2, -head.Size.Z / 2 - 0.03),
				PINK_DARK,
				model
			)
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
			local b = body.Size
			-- White belly on the front, flush so it never blocks spray.
			decoration(
				"Belly",
				Vector3.new(b.X * 0.7, b.Y * 0.8, 0.05),
				body.CFrame * CFrame.new(0, -0.1, -b.Z / 2 - 0.02),
				Color3.fromRGB(245, 245, 245),
				model
			)
			decoration(
				"Beak",
				Vector3.new(0.4, 0.25, 0.5),
				head.CFrame * CFrame.new(0, -0.15, -head.Size.Z / 2 - 0.22),
				ORANGE,
				model
			)
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
			local h = head.Size
			pairOfEars(head, Vector3.new(0.45, 0.65, 0.2), spec.HeadColor, 0.3, 0.2, model)
			decoration(
				"Snout",
				Vector3.new(0.7, 0.5, 0.7),
				head.CFrame * CFrame.new(0, -0.3, -h.Z / 2 - 0.3),
				Color3.fromRGB(250, 245, 235),
				model
			)
			local tail = decoration(
				"Tail",
				Vector3.new(0.8, 0.8, 2.0),
				body.CFrame * CFrame.new(0, 0.2, body.Size.Z / 2 + 0.9) * CFrame.Angles(0.3, 0, 0),
				spec.BodyColor,
				model
			)
			decoration(
				"TailTip",
				Vector3.new(0.82, 0.82, 0.5),
				tail.CFrame * CFrame.new(0, 0, 0.85),
				Color3.fromRGB(250, 245, 235),
				model
			)
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
		Decorate = function(model, body, head, spec)
			local b = body.Size
			-- Stripes painted flush on both sides.
			for i = -3, 3 do
				for _, side in { -1, 1 } do
					decoration(
						"Stripe",
						Vector3.new(0.05, b.Y * 0.9, 0.35),
						body.CFrame * CFrame.new(side * (b.X / 2 + 0.01), 0, i * 0.8),
						Color3.fromRGB(25, 25, 25),
						model
					)
				end
			end
			local neck = model:FindFirstChild("Neck")
			if neck and neck:IsA("BasePart") then
				decoration(
					"Mane",
					Vector3.new(0.3, neck.Size.Y + 0.4, 0.4),
					neck.CFrame * CFrame.new(0, 0.2, neck.Size.Z / 2 + 0.12),
					Color3.fromRGB(25, 25, 25),
					model
				)
			end
			pairOfEars(head, Vector3.new(0.3, 0.7, 0.25), spec.HeadColor, 0.3, 0.1, model)
			addEyes(head, model)
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
		Decorate = function(model, _body, head, _spec)
			local h = head.Size
			local black = Color3.fromRGB(25, 25, 30)
			for _, side in { -1, 1 } do
				local ear = decoration(
					"Ear",
					Vector3.new(0.8, 0.8, 0.8),
					head.CFrame * CFrame.new(side * h.X * 0.38, h.Y / 2 + 0.15, 0.2),
					black,
					model
				)
				ear.Shape = Enum.PartType.Ball
				local patch = decoration(
					"EyePatch",
					Vector3.new(0.7, 0.8, 0.06),
					head.CFrame * CFrame.new(side * h.X * 0.28, h.Y * 0.12, -h.Z / 2 - 0.02),
					black,
					model
				)
				patch:SetAttribute("NoGrime", true)
			end
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
		Decorate = function(model, body, head, _spec)
			local h = head.Size
			local mane = Color3.fromRGB(150, 85, 35)
			decoration(
				"Mane",
				Vector3.new(h.X + 1.4, h.Y + 1.4, 1.0),
				head.CFrame * CFrame.new(0, 0, h.Z / 2 + 0.3),
				mane,
				model
			)
			decoration(
				"Muzzle",
				Vector3.new(1.2, 0.8, 0.5),
				head.CFrame * CFrame.new(0, -0.45, -h.Z / 2 - 0.2),
				Color3.fromRGB(245, 220, 170),
				model
			)
			local tail = decoration(
				"Tail",
				Vector3.new(0.25, 2.0, 0.25),
				body.CFrame * CFrame.new(0, 0, body.Size.Z / 2 + 0.3) * CFrame.Angles(0.5, 0, 0),
				Color3.fromRGB(225, 175, 95),
				model
			)
			decoration("TailTuft", Vector3.new(0.6, 0.6, 0.6), tail.CFrame * CFrame.new(0, -1.0, 0), mane, model)
			addEyes(head, model)
		end,
	},
	Hippo = {
		BodySize = Vector3.new(5.0, 3.6, 7.5),
		LegHeight = 1.4,
		LegThickness = 1.4,
		HeadSize = Vector3.new(3.6, 2.8, 3.4),
		HeadLift = -0.6,
		BodyColor = Color3.fromRGB(150, 130, 165),
		HeadColor = Color3.fromRGB(150, 130, 165),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.6,
		Decorate = function(model, _body, head, spec)
			local h = head.Size
			pairOfEars(head, Vector3.new(0.5, 0.5, 0.3), spec.HeadColor, 0.15, 0, model)
			decoration(
				"Mouth",
				Vector3.new(h.X * 0.95, h.Y * 0.45, 0.6),
				head.CFrame * CFrame.new(0, -h.Y * 0.25, -h.Z / 2 - 0.25),
				Color3.fromRGB(190, 160, 200),
				model
			)
			for _, side in { -1, 1 } do
				decoration(
					"Nostril",
					Vector3.new(0.3, 0.3, 0.08),
					head.CFrame * CFrame.new(side * 0.6, 0.0, -h.Z / 2 - 0.58),
					Color3.fromRGB(70, 50, 80),
					model
				)
			end
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
					* CFrame.new(side * (h.X / 2 + 1.0), 0.3, h.Z / 2 - 0.2)
					* CFrame.Angles(0, side * math.rad(-12), 0)
				disc("Ear", 3.2, 0.3, ear, skin, model)
				disc("EarInner", 2.4, 0.1, ear * CFrame.new(0, -0.1, -0.2), PINK_DARK:Lerp(skin, 0.5), model)
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
			local neck = model:FindFirstChild("Neck")
			if neck and neck:IsA("BasePart") then
				for i, hue in { 0.85, 0.6, 0.15 } do
					decoration(
						"Mane",
						Vector3.new(0.25, neck.Size.Y + 0.4, 0.3),
						neck.CFrame * CFrame.new((i - 2) * 0.22, 0.2, neck.Size.Z / 2 + 0.12),
						Color3.fromHSV(hue, 0.45, 1),
						model
					)
				end
			end
			decoration(
				"Horn",
				Vector3.new(0.3, 1.4, 0.3),
				head.CFrame * CFrame.new(0, head.Size.Y / 2 + 0.6, -head.Size.Z / 2 + 0.5) * CFrame.Angles(-0.4, 0, 0),
				Color3.fromRGB(255, 220, 120),
				model
			)
			pairOfEars(head, Vector3.new(0.3, 0.7, 0.25), spec.HeadColor, 0.3, 0.1, model)
			decoration(
				"Tail",
				Vector3.new(0.4, 2.2, 0.4),
				body.CFrame * CFrame.new(0, -0.2, body.Size.Z / 2 + 0.3) * CFrame.Angles(0.35, 0, 0),
				Color3.fromRGB(200, 170, 255),
				model
			)
			addEyes(head, model)
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
			ball("Ruff", 2.2, body.CFrame * CFrame.new(0, 0.9, -b.Z / 2 + 0.1), feather, model)
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
			local fur = spec.BodyColor
			local red = Color3.fromRGB(215, 40, 60)
			local fire = Color3.fromRGB(90, 200, 255)
			local function foxFire(parent: BasePart, rate: number)
				flair(parent, "FoxFire", {
					Rate = rate,
					Lifetime = NumberRange.new(0.6, 1.0),
					Speed = NumberRange.new(0.3, 0.8),
					SpreadAngle = Vector2.new(25, 25),
					Acceleration = Vector3.new(0, 2.5, 0),
					Size = swell(0.4),
					Transparency = NumberSequence.new(0.1, 1),
					Color = flameColors(Color3.fromRGB(220, 245, 255), fire, Color3.fromRGB(60, 110, 255)),
				})
			end

			-- Tall pointed ears with red insides, shrine-fox face markings and a forehead gem.
			for _, side in { -1, 1 } do
				local base = head.CFrame
					* CFrame.new(side * 0.5, h.Y / 2 - 0.05, 0.2)
					* CFrame.Angles(0, 0, side * -0.2)
				triangle("Ear", 0.75, 1.0, 0.2, base, fur, model)
				triangle("EarInner", 0.42, 0.62, 0.08, base * CFrame.new(0, 0.05, -0.12), red, model)
				local mark = decoration(
					"Marking",
					Vector3.new(0.5, 0.1, 0.05),
					head.CFrame * CFrame.new(side * 0.45, 0.62, -h.Z / 2 - 0.03) * CFrame.Angles(0, 0, side * 0.5),
					red,
					model
				)
				mark:SetAttribute("NoGrime", true)
			end
			glow(
				decoration(
					"Gem",
					Vector3.new(0.24, 0.24, 0.08),
					head.CFrame * CFrame.new(0, 0.5, -h.Z / 2 - 0.04) * CFrame.Angles(0, 0, math.rad(45)),
					fire,
					model
				)
			)
			decoration(
				"Snout",
				Vector3.new(0.8, 0.6, 0.8),
				head.CFrame * CFrame.new(0, -0.4, -h.Z / 2 - 0.35),
				fur,
				model
			)
			ball("Nose", 0.28, head.CFrame * CFrame.new(0, -0.18, -h.Z / 2 - 0.76), INK, model)
			decoration(
				"Mouth",
				Vector3.new(0.35, 0.05, 0.05),
				head.CFrame * CFrame.new(0, -0.55, -h.Z / 2 - 0.76),
				INK,
				model
			)
			heroEyes(head, model, { Size = 0.5, Spread = 0.27, Lift = 0.15, Iris = fire, Slit = true, Glow = true })

			-- Fluffy chest ruff (kept below the back so top mud stays visible), a red rope
			-- collar with a gold bell and paper streamers.
			ball("Ruff", 1.7, body.CFrame * CFrame.new(0, b.Y / 2 - 0.9, -b.Z / 2 - 0.1), fur, model)
			local collar = shaped(
				decoration(
					"Collar",
					Vector3.new(1.3, 0.3, 0.3),
					body.CFrame * CFrame.new(0, -0.1, -b.Z / 2 - 1.05),
					red,
					model
				),
				Enum.PartType.Cylinder
			)
			local bell = ball("Bell", 0.38, collar.CFrame * CFrame.new(0, -0.3, -0.1), GILT, model)
			bell.Reflectance = 0.3
			for _, side in { -1, 1 } do
				decoration(
					"Streamer",
					Vector3.new(0.18, 0.45, 0.04),
					collar.CFrame * CFrame.new(side * 0.35, -0.3, -0.15) * CFrame.Angles(0, 0, side * 0.2),
					WHITE,
					model
				)
			end
			for _, leg in legsOf(model) do
				local p = leg.Position
				rod("Paw", 0.45, 0.75, CFrame.new(p.X, 0.22, p.Z), Color3.fromRGB(60, 45, 60), model)
			end

			-- Nine tails fanned behind the rump like a peacock, each tipped with white fur and a
			-- blue fox-fire wisp. They start behind the rump plane so the sides stay clear.
			local origin = (body.CFrame * CFrame.new(0, b.Y / 2 - 0.6, b.Z / 2 + 0.05)).Position
			for i = 1, 9 do
				local t = (i - 1) / 8
				local yaw = math.rad(-65 + 130 * t)
				local rise = math.rad(25 + 25 * (1 - math.abs(2 * t - 1)))
				local dir = Vector3.new(math.sin(yaw) * math.cos(rise), math.sin(rise), math.cos(yaw) * math.cos(rise))
				local tail = chain({
					Name = "Tail",
					Start = facing(origin, dir),
					Count = 5,
					Length = 0.55,
					Size = 0.6,
					EndSize = 1.0,
					Turn = Vector2.new(math.rad(7), 0),
					Color = fur,
					EndColor = fur:Lerp(Color3.fromRGB(255, 225, 190), 0.35),
				}, model)
				local tip = ball("TailTip", 0.85, tail[#tail].CFrame * CFrame.new(0, 0, -0.55), WHITE, model)
				local wisp = glow(ball("FoxFire", 0.45, tip.CFrame * CFrame.new(0, 0, -0.55), fire, model), 0.15)
				if i % 4 == 1 then
					foxFire(wisp, 4)
				end
			end
			-- Two fox-fire orbs hovering above head height, clear of the head-side mud.
			for _, side in { -1, 1 } do
				local orb =
					glow(ball("FoxFire", 0.5, head.CFrame * CFrame.new(side * 1.7, 1.3, 0.1), fire, model), 0.15)
				foxFire(orb, 3)
				glowLight(orb, fire, 1, 6)
			end
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
		SkipRump = true,
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
		BodySize = Vector3.new(4.0, 3.4, 5.4),
		LegHeight = 2.6,
		LegThickness = 1.0,
		HeadSize = Vector3.new(2.0, 1.9, 2.0),
		Neck = Vector3.new(1.5, 3.0, 1.5),
		NeckTilt = math.rad(24),
		BodyColor = Color3.fromRGB(175, 35, 45),
		HeadColor = Color3.fromRGB(175, 35, 45),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.4,
		SkipRump = true,
		CenterZ = true,
		Decorate = function(model, body, head, spec)
			local b, h = body.Size, head.Size
			local skin = spec.BodyColor
			local dark = Color3.fromRGB(105, 20, 30)
			local belly = Color3.fromRGB(255, 190, 70)
			local membrane = Color3.fromRGB(235, 105, 65)
			local horn = Color3.fromRGB(240, 220, 170)
			local neck = model:FindFirstChild("Neck") :: BasePart?
			local spikeTurn = CFrame.Angles(0, math.pi / 2, 0) -- triangles thin across the body

			-- Gold belly plates on the chest, under the body and down the neck front.
			for i = 0, 2 do
				decoration(
					"BellyPlate",
					Vector3.new(b.X - 1.2, 0.55, 0.1),
					body.CFrame * CFrame.new(0, 0.9 - i * 0.75, -b.Z / 2 - 0.03),
					belly,
					model
				)
			end
			decoration(
				"Belly",
				Vector3.new(b.X - 1.0, 0.05, b.Z - 1.0),
				body.CFrame * CFrame.new(0, -b.Y / 2 - 0.01, 0),
				belly,
				model
			)
			if neck then
				local n = neck.Size
				for _, y in { -1.0, -0.35, 0.3, 0.95 } do
					decoration(
						"BellyPlate",
						Vector3.new(n.X - 0.3, 0.4, 0.1),
						neck.CFrame * CFrame.new(0, y, -n.Z / 2 - 0.03),
						belly,
						model
					)
				end
				for _, y in { -0.6, 0.3, 1.1 } do
					triangle(
						"Spine",
						0.55,
						0.6,
						0.15,
						neck.CFrame * CFrame.new(0, y, n.Z / 2 - 0.05) * CFrame.Angles(math.rad(60), 0, 0) * spikeTurn,
						dark,
						model
					)
				end
			end

			-- Spines down the back (the top is too high to carry mud).
			for i = 0, 4 do
				local s = 0.95 - i * 0.1
				triangle(
					"Spine",
					s,
					s,
					0.18,
					body.CFrame
						* CFrame.new(0, b.Y / 2 - 0.05, -0.7 + i * 0.75)
						* CFrame.Angles(math.rad(20), 0, 0)
						* spikeTurn,
					dark,
					model
				)
			end

			-- Wings raised in a V from the shoulders: bone, claw, finger spars and membrane.
			for _, side in { -1, 1 } do
				local root = body.CFrame
					* CFrame.new(side * (b.X / 2 - 0.25), b.Y / 2 - 0.05, -0.6)
					* CFrame.Angles(0, 0, -side * math.rad(28))
				local arm = root * CFrame.Angles(math.rad(-12), 0, 0)
				rod("WingBone", 3.8, 0.35, arm * CFrame.new(0, 1.9, 0), dark, model)
				local tip = arm * CFrame.new(0, 3.8, 0)
				ball("WingClaw", 0.45, tip, horn, model)
				for _, spar in { { 141, 4.7 }, { 155, 3.7 }, { 170, 3.3 } } do
					local frame = tip * CFrame.Angles(math.rad(spar[1]), 0, 0)
					rod("WingSpar", spar[2], 0.18, frame * CFrame.new(0, spar[2] / 2, 0), dark, model)
				end
				local sheet = wedge(
					"Membrane",
					Vector3.new(0.08, 3.6, 3.0),
					arm * CFrame.new(0, 1.9, 1.5) * CFrame.Angles(0, math.pi, 0),
					membrane,
					model
				)
				sheet.Transparency = 0.1
				wedge(
					"Membrane",
					Vector3.new(0.06, 2.4, 2.0),
					arm * CFrame.new(side * 0.04, 1.3, 1.0) * CFrame.Angles(0, math.pi, 0),
					membrane:Lerp(dark, 0.45),
					model
				)
			end

			-- Clawed feet and muscular haunches tucked under the body.
			for _, leg in legsOf(model) do
				local p = leg.Position
				ball("Haunch", 1.5, CFrame.new(p.X * 0.92, 2.2, p.Z), skin, model)
				decoration("Foot", Vector3.new(1.2, 0.4, 1.4), CFrame.new(p.X, 0.2, p.Z - 0.2), dark, model)
				claws(CFrame.new(p.X, 0, p.Z - 0.9), 3, 0.38, Vector3.new(0.2, 0.3, 0.45), horn, model)
			end

			-- Head: open jaws glowing with fire, swept-back horns, frills and fierce brows.
			local mouth = maw(head, model, {
				Top = 0.05,
				Width = 1.5,
				Length = 1.6,
				Height = 1.0,
				Bridge = 0.25,
				Open = 0.3,
				JawHeight = 0.45,
				Fangs = 3,
				Skin = skin,
				Inside = Color3.fromRGB(255, 140, 40),
				Glow = true,
			})
			heroEyes(head, model, {
				Size = 0.48,
				Spread = 0.28,
				Lift = 0.34,
				Iris = Color3.fromRGB(255, 200, 40),
				Slit = true,
				Glow = true,
			})
			for _, side in { -1, 1 } do
				decoration(
					"Brow",
					Vector3.new(0.7, 0.18, 0.3),
					head.CFrame
						* CFrame.new(side * 0.56, h.Y / 2 + 0.05, -h.Z / 2 - 0.08)
						* CFrame.Angles(0, 0, side * 0.35),
					dark,
					model
				)
				chain({
					Name = "Horn",
					Start = facing(
						(head.CFrame * CFrame.new(side * 0.55, h.Y / 2 - 0.1, 0.2)).Position,
						Vector3.new(side * 0.35, 0.8, 1)
					),
					Count = 5,
					Length = 0.38,
					Size = 0.5,
					EndSize = 0.18,
					Turn = Vector2.new(math.rad(-14), 0),
					Color = horn,
					EndColor = GILT,
				}, model)
				triangle(
					"Frill",
					0.5,
					0.8,
					0.12,
					head.CFrame
						* CFrame.new(side * (h.X / 2 - 0.05), h.Y * 0.15, h.Z / 2 - 0.1)
						* CFrame.Angles(0, 0, -side * math.rad(70)),
					dark,
					model
				)
			end

			-- Fire breath: flame wisps and embers from the mouth, smoke curling from the nose.
			local breath = anchorAt(head, mouth, "FireBreath")
			flair(breath, "FireBreath", {
				Rate = 12,
				EmissionDirection = Enum.NormalId.Front,
				Speed = NumberRange.new(4, 7),
				SpreadAngle = Vector2.new(14, 14),
				Lifetime = NumberRange.new(0.35, 0.6),
				Size = swell(1.0),
				Transparency = NumberSequence.new(0.1, 1),
				Color = flameColors(
					Color3.fromRGB(255, 240, 150),
					Color3.fromRGB(255, 140, 30),
					Color3.fromRGB(220, 40, 20)
				),
				Acceleration = Vector3.new(0, 3, 0),
				Rotation = NumberRange.new(0, 360),
				RotSpeed = NumberRange.new(-90, 90),
			})
			flair(breath, "Embers", {
				Rate = 6,
				EmissionDirection = Enum.NormalId.Front,
				Speed = NumberRange.new(2, 4),
				SpreadAngle = Vector2.new(35, 35),
				Lifetime = NumberRange.new(0.8, 1.4),
				Size = NumberSequence.new(0.18, 0),
				Color = ColorSequence.new(Color3.fromRGB(255, 170, 60)),
				Acceleration = Vector3.new(0, 4, 0),
			})
			glowLight(breath, Color3.fromRGB(255, 140, 50), 1.2, 7)
			local nose = anchorAt(head, head.CFrame * CFrame.new(0, 0.1, -h.Z / 2 - 1.4), "Nostrils")
			flair(nose, "Smoke", {
				Rate = 3,
				LightEmission = 0,
				Speed = NumberRange.new(0.5, 1),
				SpreadAngle = Vector2.new(15, 15),
				Lifetime = NumberRange.new(1, 1.5),
				Size = NumberSequence.new(0.3, 0.9),
				Transparency = NumberSequence.new(0.5, 1),
				Color = ColorSequence.new(Color3.fromRGB(90, 85, 85)),
			})

			-- Long tail curling round beside the hind legs, finished with a spade.
			local tail = chain({
				Name = "Tail",
				Start = facing((body.CFrame * CFrame.new(0, 0.2, b.Z / 2 - 0.3)).Position, Vector3.new(0, -0.35, 1)),
				Count = 9,
				Length = 0.55,
				Size = 1.7,
				EndSize = 0.45,
				Turn = Vector2.new(math.rad(-3), math.rad(13)),
				Color = skin,
			}, model)
			for i = 2, 6 do
				local seg = tail[i]
				local s = seg.Size.X * 0.45
				triangle(
					"Spine",
					s,
					s,
					0.12,
					seg.CFrame * CFrame.new(0, seg.Size.X / 2 - 0.05, 0) * spikeTurn,
					dark,
					model
				)
			end
			local last = tail[#tail]
			triangle(
				"Spade",
				1.0,
				0.9,
				0.12,
				last.CFrame * CFrame.new(0, 0, -last.Size.X / 2 + 0.05) * CFrame.Angles(-math.pi / 2, 0, 0),
				dark,
				model
			)

			head:SetAttribute("HaloLift", 1.5) -- clear of the horns
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
			glowLight(crown, atomic, 1.4, 10)
		end,
	},
	Axolotl = {
		BodySize = Vector3.new(2.4, 1.4, 3.4),
		LegHeight = 0.6,
		LegThickness = 0.45,
		LegColor = Color3.fromRGB(255, 150, 185),
		HeadSize = Vector3.new(2.6, 1.5, 1.8),
		HeadLift = -0.35,
		BodyColor = Color3.fromRGB(255, 170, 200),
		HeadColor = Color3.fromRGB(255, 170, 200),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 0.8,
		SkipRump = true,
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

-- Lays a grid of disc patches over one face of a box part.
-- `normal`, `axisA`, `axisB` are unit vectors in the part's local space; `lenA`, `lenB` the face size.
local function addFacePatches(
	box: BasePart,
	normal: Vector3,
	axisA: Vector3,
	lenA: number,
	axisB: Vector3,
	lenB: number,
	cellSize: number,
	rng: Random,
	out: { PatchInfo },
	parent: Instance
)
	local depth = math.abs(normal:Dot(box.Size)) / 2
	local cols = math.max(1, math.floor(lenA / cellSize))
	local rows = math.max(1, math.floor(lenB / cellSize))
	local cellA, cellB = lenA / cols, lenB / rows
	local cell = math.min(cellA, cellB)

	for c = 1, cols do
		for r = 1, rows do
			local a = -lenA / 2 + (c - 0.5) * cellA + rng:NextNumber(-0.15, 0.15) * cellA
			local b = -lenB / 2 + (r - 0.5) * cellB + rng:NextNumber(-0.15, 0.15) * cellB
			local localPos = normal * (depth + 0.02) + axisA * a + axisB * b
			local worldPos = box.CFrame:PointToWorldSpace(localPos)
			local worldNormal = box.CFrame:VectorToWorldSpace(normal)
			local worldUp = box.CFrame:VectorToWorldSpace(axisA)
			local diameter = cell * rng:NextNumber(0.8, 1.0)

			local id = "P" .. (#out + 1)
			local patch = Instance.new("Part")
			patch.Name = "Patch"
			patch.Shape = Enum.PartType.Cylinder -- cylinder axis is local X, so X = surface normal
			patch.Anchored = true
			patch.CanCollide = false
			patch.CanTouch = false
			patch.CanQuery = true
			patch.Size = Vector3.new(PATCH_THICKNESS, diameter, diameter)
			patch.CFrame = CFrame.fromMatrix(worldPos, worldNormal, worldUp)
				* CFrame.Angles(rng:NextNumber(0, math.pi * 2), 0, 0)
			local shade = rng:NextNumber(-12, 12)
			patch.Color =
				Color3.fromRGB(MUD_COLOR.R * 255 + shade, MUD_COLOR.G * 255 + shade, MUD_COLOR.B * 255 + shade)
			patch.Material = Enum.Material.Mud
			patch:SetAttribute("PatchId", id)
			patch:SetAttribute("BaseDiameter", diameter)
			patch.Parent = parent

			-- Two small splatters around the main blob so mud reads as splashes, not dots.
			-- Cosmetic only: they can't be hit and fade with their patch.
			for _ = 1, 2 do
				local angle = rng:NextNumber(0, math.pi * 2)
				local reach = diameter * rng:NextNumber(0.45, 0.6)
				local size = diameter * rng:NextNumber(0.3, 0.45)
				local splat = Instance.new("Part")
				splat.Name = "Splat"
				splat.Shape = Enum.PartType.Cylinder
				splat.Anchored = true
				splat.CanCollide = false
				splat.CanTouch = false
				splat.CanQuery = false
				splat.Size = Vector3.new(PATCH_THICKNESS * 0.8, size, size)
				splat.CFrame = patch.CFrame * CFrame.new(-0.01, math.cos(angle) * reach, math.sin(angle) * reach)
				splat.Color = patch.Color
				splat.Material = Enum.Material.Mud
				splat.Parent = patch
			end
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

local function buildPlaceholder(spec: Spec, rng: Random, clean: boolean): (Model, { PatchInfo })
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

	local neck: Part? = nil
	local headCFrame: CFrame
	if spec.Neck then
		-- Neck rises from the front of the body; the head sits on top, poking forward.
		-- NeckTilt pivots it forward about its base; the head stays level on the tip.
		local n = spec.Neck
		local base = CFrame.new(0, leg + b.Y - 0.6, -(b.Z / 2 - n.Z / 2)) * CFrame.Angles(-(spec.NeckTilt or 0), 0, 0)
		local neckPart = makePart("Neck", n, base * CFrame.new(0, n.Y / 2, 0), spec.BodyColor, model)
		neckPart.Material = spec.BodyMaterial
		neck = neckPart
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
		local legPart = makePart(
			"Leg",
			Vector3.new(thickness, leg, thickness),
			CFrame.new(spot[1] * (b.X / 2 - inset), leg / 2, spot[2] * (b.Z / 2 - inset - 0.2)),
			legColor,
			model
		)
		legPart.CanQuery = true -- legs block spray like the real body would
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
		local cell = spec.PatchCell or DEFAULT_PATCH_CELL
		local X, Y, Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
		-- Body: both sides, top, rump
		addFacePatches(body, X, Z, b.Z, Y, b.Y, cell, rng, patches, patchFolder)
		addFacePatches(body, -X, Z, b.Z, Y, b.Y, cell, rng, patches, patchFolder)
		if leg + b.Y <= MAX_TOP_PATCH_HEIGHT then
			addFacePatches(body, Y, Z, b.Z, X, b.X, cell, rng, patches, patchFolder)
		end
		if not spec.SkipRump then
			addFacePatches(body, Z, Y, b.Y, X, b.X, cell, rng, patches, patchFolder)
		end
		-- Neck sides (vertical faces are reachable at any height)
		if neck then
			local n = neck.Size
			addFacePatches(neck, X, Z, n.Z, Y, n.Y, cell, rng, patches, patchFolder)
			addFacePatches(neck, -X, Z, n.Z, Y, n.Y, cell, rng, patches, patchFolder)
		end
		-- Head: both sides, and the top when it's low enough
		addFacePatches(head, X, Z, h.Z, Y, h.Y, cell, rng, patches, patchFolder)
		addFacePatches(head, -X, Z, h.Z, Y, h.Y, cell, rng, patches, patchFolder)
		if head.Position.Y + h.Y / 2 <= MAX_TOP_PATCH_HEIGHT then
			addFacePatches(head, Y, Z, h.Z, X, h.X, cell, rng, patches, patchFolder)
		end
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

local function aura(model: Model, color: Color3, rate: number)
	local body = model:FindFirstChild("Body")
	if not body then
		return
	end
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 10
	light.Brightness = 1.2
	light.Parent = body
	if rate > 0 then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Aura"
		emitter.Rate = rate
		emitter.Lifetime = NumberRange.new(1, 1.6)
		emitter.Speed = NumberRange.new(0.5, 1.5)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new(0.3, 0)
		emitter.Color = ColorSequence.new(color)
		emitter.LightEmission = 1
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

-- Particles that fill the body volume (Box shape), used for the tier auras below.
local function bodyEmitter(model: Model, props: { [string]: any })
	local body = model:FindFirstChild("Body")
	if not body then
		return
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "TierAura"
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.LightEmission = 1
	for key, value in props do
		(emitter :: any)[key] = value
	end
	emitter.Parent = body
end

local function tierLight(model: Model, color: Color3, brightness: number, range: number)
	local body = model:FindFirstChild("Body")
	if body then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Brightness = brightness
		light.Range = range
		light.Parent = body
	end
end

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 220, 60)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 255, 120)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(80, 180, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 100, 255)),
})

-- Rarer tiers carry their own particles, whatever their mutation:
-- Epic purple twinkles, Legendary gold glitter, Mythic rising embers, Zoo God rainbow
-- sparkles with a halo, Secret dark smoke with white stars.
local function applyTierAura(model: Model, rarityKey: string)
	if rarityKey == "Epic" then
		bodyEmitter(model, {
			Rate = 5,
			Lifetime = NumberRange.new(0.8, 1.2),
			Speed = NumberRange.new(0.2, 0.6),
			Size = NumberSequence.new(0.3, 0),
			Color = ColorSequence.new(Color3.fromRGB(200, 130, 255)),
		})
	elseif rarityKey == "Legendary" then
		bodyEmitter(model, {
			Rate = 10,
			Lifetime = NumberRange.new(1, 1.6),
			Speed = NumberRange.new(0.3, 0.8),
			Acceleration = Vector3.new(0, 1.5, 0),
			Size = NumberSequence.new(0.35, 0),
			Color = ColorSequence.new(Color3.fromRGB(255, 215, 80)),
		})
		tierLight(model, Color3.fromRGB(255, 210, 90), 1, 10)
	elseif rarityKey == "Mythic" then
		bodyEmitter(model, {
			Rate = 16,
			Lifetime = NumberRange.new(1, 1.8),
			Speed = NumberRange.new(0.5, 1.5),
			Acceleration = Vector3.new(0, 4, 0),
			Size = NumberSequence.new(0.4, 0),
			Color = ColorSequence.new(Color3.fromRGB(255, 120, 40), Color3.fromRGB(255, 40, 40)),
		})
		tierLight(model, Color3.fromRGB(255, 90, 60), 1.5, 12)
	elseif rarityKey == "ZooGod" then
		bodyEmitter(model, {
			Rate = 22,
			Lifetime = NumberRange.new(1, 1.6),
			Speed = NumberRange.new(0.5, 1.5),
			Acceleration = Vector3.new(0, 2, 0),
			Size = NumberSequence.new(0.45, 0),
			Color = RAINBOW,
		})
		tierLight(model, Color3.fromRGB(255, 255, 220), 2, 14)
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
	elseif rarityKey == "Secret" then
		bodyEmitter(model, {
			Rate = 10,
			Lifetime = NumberRange.new(1.5, 2.5),
			Speed = NumberRange.new(0.3, 0.8),
			Acceleration = Vector3.new(0, 1, 0),
			Size = NumberSequence.new(1.2, 2.4),
			Transparency = NumberSequence.new(0.5, 1),
			Color = ColorSequence.new(Color3.fromRGB(60, 20, 90)),
			LightEmission = 0,
		})
		bodyEmitter(model, {
			Rate = 8,
			Lifetime = NumberRange.new(0.5, 0.9),
			Speed = NumberRange.new(0.2, 0.5),
			Size = NumberSequence.new(0.35, 0),
			Color = ColorSequence.new(Color3.new(1, 1, 1)),
		})
		tierLight(model, Color3.fromRGB(150, 80, 255), 1.5, 12)
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
		local model, patches = buildPlaceholder(SPECS[name], Random.new(1), false)
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

-- Returns the model (pivoted at the origin) and its dirt patches (empty when Clean).
-- Part colours are left at their clean values; DirtRenderer.setGrime applies grime/mutation colour.
function AnimalBuilder.build(templateName: string, options: BuildOptions?): (Model, { PatchInfo })
	local opts: BuildOptions = options or {}
	local clean = opts.Clean == true
	local model, patches = buildFromTemplate(templateName, clean)
	if not model then
		local spec = SPECS[templateName]
		assert(spec, "Unknown animal template: " .. templateName)
		local rng = if opts.Seed then Random.new(opts.Seed) else Random.new()
		model, patches = buildPlaceholder(spec, rng, clean)
	end
	local built = model :: Model
	applyMutation(built, opts.Mutation or MutationConfig.Default)
	applyTierAura(built, opts.Rarity or "Common")
	return built, patches
end

return AnimalBuilder
