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
		BodySize = Vector3.new(3.0, 3.0, 5.0),
		LegHeight = 4.0,
		LegThickness = 0.7,
		HeadSize = Vector3.new(1.2, 1.4, 2.2),
		Neck = Vector3.new(1.2, 6.0, 1.2),
		BodyColor = Color3.fromRGB(240, 190, 90),
		HeadColor = Color3.fromRGB(240, 190, 90),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.3,
		Decorate = function(model, body, head, spec)
			local b = body.Size
			local spot = Color3.fromRGB(150, 90, 40)
			for _, offset in
				{ Vector2.new(-1.2, 0.6), Vector2.new(0.4, -0.5), Vector2.new(1.6, 0.4), Vector2.new(-0.2, 0.9) }
			do
				for _, side in { -1, 1 } do
					decoration(
						"Spot",
						Vector3.new(0.05, 0.9, 1.0),
						body.CFrame * CFrame.new(side * (b.X / 2 + 0.01), offset.Y, offset.X),
						spot,
						model
					)
				end
			end
			for _, side in { -1, 1 } do
				decoration(
					"Ossicone",
					Vector3.new(0.2, 0.6, 0.2),
					head.CFrame * CFrame.new(side * 0.3, head.Size.Y / 2 + 0.3, 0.5),
					spot,
					model
				)
			end
			pairOfEars(head, Vector3.new(0.5, 0.25, 0.2), spec.HeadColor, -0.1, 0, model)
			addEyes(head, model)
		end,
	},
	Elephant = {
		BodySize = Vector3.new(6.0, 5.0, 8.5),
		LegHeight = 3.0,
		LegThickness = 1.6,
		HeadSize = Vector3.new(4.0, 4.0, 3.4),
		HeadLift = -0.2,
		BodyColor = Color3.fromRGB(150, 150, 160),
		HeadColor = Color3.fromRGB(150, 150, 160),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.8,
		Decorate = function(model, _body, head, spec)
			local h = head.Size
			-- Ears stick out sideways behind the head so head-side mud stays visible.
			for _, side in { -1, 1 } do
				decoration(
					"Ear",
					Vector3.new(2.8, 3.4, 0.3),
					head.CFrame * CFrame.new(side * (h.X / 2 + 1.2), 0.2, h.Z / 2 - 0.3),
					Color3.fromRGB(140, 140, 150),
					model
				)
				decoration(
					"Tusk",
					Vector3.new(0.3, 0.3, 1.4),
					head.CFrame * CFrame.new(side * 0.9, -h.Y * 0.35, -h.Z / 2 - 0.6),
					Color3.fromRGB(250, 245, 230),
					model
				)
			end
			decoration(
				"Trunk",
				Vector3.new(0.9, 3.2, 0.9),
				head.CFrame * CFrame.new(0, -h.Y * 0.4, -h.Z / 2 - 0.45),
				spec.HeadColor,
				model
			)
			addEyes(head, model)
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
		BodySize = Vector3.new(4.0, 4.0, 7.0),
		LegHeight = 3.0,
		LegCount = 2,
		LegThickness = 1.3,
		HeadSize = Vector3.new(2.6, 2.6, 3.6),
		HeadLift = 1.4,
		BodyColor = Color3.fromRGB(90, 140, 70),
		HeadColor = Color3.fromRGB(90, 140, 70),
		BodyMaterial = Enum.Material.SmoothPlastic,
		PatchCell = 1.6,
		Decorate = function(model, body, head, spec)
			local b = body.Size
			decoration(
				"Tail",
				Vector3.new(1.6, 1.6, 5.0),
				body.CFrame * CFrame.new(0, 0.2, b.Z / 2 + 2.3) * CFrame.Angles(0.15, 0, 0),
				spec.BodyColor,
				model
			)
			for _, side in { -1, 1 } do
				decoration(
					"Arm",
					Vector3.new(0.4, 0.4, 1.2),
					body.CFrame * CFrame.new(side * (b.X / 2 - 0.4), -0.3, -b.Z / 2 - 0.4),
					spec.BodyColor,
					model
				)
			end
			decoration(
				"Teeth",
				Vector3.new(head.Size.X * 0.9, 0.2, 0.1),
				head.CFrame * CFrame.new(0, -head.Size.Y * 0.2, -head.Size.Z / 2 - 0.03),
				Color3.fromRGB(250, 250, 240),
				model
			)
			addEyes(head, model)
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
		local n = spec.Neck
		local neckZ = -(b.Z / 2 - n.Z / 2)
		local neckY = leg + b.Y + n.Y / 2 - 0.6
		local neckPart = makePart("Neck", n, CFrame.new(0, neckY, neckZ), spec.BodyColor, model)
		neckPart.Material = spec.BodyMaterial
		neck = neckPart
		headCFrame = CFrame.new(0, neckY + n.Y / 2 + h.Y / 2 - 0.4, neckZ - h.Z / 2 + n.Z / 2 + 0.1)
	else
		headCFrame = if spec.HeadOnTop
			then CFrame.new(0, leg + b.Y + h.Y / 2 - 0.2, -0.1)
			else CFrame.new(0, leg + b.Y * 0.8 + (spec.HeadLift or 0), -(b.Z / 2 + h.Z / 2 - 0.3))
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
		addFacePatches(body, Z, Y, b.Y, X, b.X, cell, rng, patches, patchFolder)
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

-- The top two tiers always shimmer, whatever their mutation.
local function applyTierAura(model: Model, rarityKey: string)
	if rarityKey == "ZooGod" then
		aura(model, Color3.fromRGB(255, 255, 200), 12)
	elseif rarityKey == "Secret" then
		aura(model, Color3.fromRGB(120, 60, 200), 12)
	end
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
