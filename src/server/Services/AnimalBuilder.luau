-- Builds placeholder block animals with dirt patches, so the repo needs no model assets.
--
-- Template contract (matches the design doc so real models can replace these later):
--   Model "Animal" (PrimaryPart = Root, pivot on the ground under the body, facing -Z)
--   ├── Root          invisible pivot part
--   ├── Body, Head    collidable, queryable body parts (spray must hit these or a patch)
--   ├── ...           legs and non-queryable decorations
--   └── DirtPatches   Model of Parts, each with a PatchId attribute
--
-- Patches are only placed on surfaces a standing player can spray: sides, rump, head sides,
-- and top faces low enough to hit from above (see MAX_TOP_PATCH_HEIGHT).

local AnimalBuilder = {}

export type PatchInfo = { Id: string, Part: BasePart }

type Spec = {
	BodySize: Vector3, -- X = width, Y = height, Z = length
	LegHeight: number,
	HeadSize: Vector3,
	BodyColor: Color3,
	HeadColor: Color3,
	BodyMaterial: Enum.Material,
	Decorate: (model: Model, body: BasePart, head: BasePart, spec: Spec) -> (),
}

local MUD_COLOR = Color3.fromRGB(92, 64, 40)
local PATCH_CELL = 1.5 -- target studs per patch grid cell
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

local function addEyes(head: BasePart, parent: Instance)
	local s = head.Size
	for _, side in { -1, 1 } do
		local offset = Vector3.new(side * s.X * 0.28, s.Y * 0.15, -s.Z / 2 - 0.02)
		decoration("Eye", Vector3.new(0.35, 0.35, 0.1), head.CFrame * CFrame.new(offset), Color3.new(0, 0, 0), parent)
	end
end

local SPECS: { [string]: Spec } = {
	Pig = {
		BodySize = Vector3.new(3.4, 3, 5.5),
		LegHeight = 1.2,
		HeadSize = Vector3.new(2.6, 2.4, 2.4),
		BodyColor = Color3.fromRGB(255, 175, 185),
		HeadColor = Color3.fromRGB(255, 175, 185),
		BodyMaterial = Enum.Material.SmoothPlastic,
		Decorate = function(model, body, head, _spec)
			local h = head.Size
			decoration(
				"Snout",
				Vector3.new(1.3, 0.9, 0.4),
				head.CFrame * CFrame.new(0, -0.3, -h.Z / 2 - 0.2),
				Color3.fromRGB(235, 130, 150),
				model
			)
			for _, side in { -1, 1 } do
				decoration(
					"Ear",
					Vector3.new(0.7, 0.7, 0.2),
					head.CFrame * CFrame.new(side * h.X * 0.32, h.Y / 2 + 0.25, -0.2) * CFrame.Angles(0.4, 0, 0),
					Color3.fromRGB(235, 130, 150),
					model
				)
			end
			decoration(
				"Tail",
				Vector3.new(0.3, 0.3, 0.7),
				body.CFrame * CFrame.new(0, body.Size.Y * 0.3, body.Size.Z / 2 + 0.3),
				Color3.fromRGB(235, 130, 150),
				model
			)
			addEyes(head, model)
		end,
	},
	Sheep = {
		BodySize = Vector3.new(3.8, 3.4, 6),
		LegHeight = 1.6,
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
			local eyes = head.CFrame
			for _, side in { -1, 1 } do
				decoration(
					"Eye",
					Vector3.new(0.35, 0.35, 0.1),
					eyes * CFrame.new(side * h.X * 0.28, h.Y * 0.15, -h.Z / 2 - 0.02),
					Color3.new(1, 1, 1),
					model
				)
			end
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
	rng: Random,
	out: { PatchInfo },
	parent: Instance
)
	local depth = math.abs(normal:Dot(box.Size)) / 2
	local cols = math.max(1, math.floor(lenA / PATCH_CELL))
	local rows = math.max(1, math.floor(lenB / PATCH_CELL))
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
			table.insert(out, { Id = id, Part = patch :: BasePart })
		end
	end
end

function AnimalBuilder.has(templateName: string): boolean
	return SPECS[templateName] ~= nil
end

-- Returns the model (pivoted at the origin) and its dirt patches.
function AnimalBuilder.build(templateName: string, seed: number?): (Model, { PatchInfo })
	local spec = SPECS[templateName]
	assert(spec, "Unknown animal template: " .. templateName)
	local rng = if seed then Random.new(seed) else Random.new()

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
	local head = makePart("Head", h, CFrame.new(0, leg + b.Y * 0.8, -(b.Z / 2 + h.Z / 2 - 0.3)), spec.HeadColor, model)

	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local legPart = makePart(
				"Leg",
				Vector3.new(0.9, leg, 0.9),
				CFrame.new(sx * (b.X / 2 - 0.6), leg / 2, sz * (b.Z / 2 - 0.8)),
				spec.HeadColor,
				model
			)
			legPart.CanQuery = true -- legs block spray like the real body would
		end
	end

	spec.Decorate(model, body, head, spec)

	local patchFolder = Instance.new("Model")
	patchFolder.Name = "DirtPatches"
	patchFolder.Parent = model

	local patches: { PatchInfo } = {}
	local X, Y, Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
	-- Body: both sides, top, rump
	addFacePatches(body, X, Z, b.Z, Y, b.Y, rng, patches, patchFolder)
	addFacePatches(body, -X, Z, b.Z, Y, b.Y, rng, patches, patchFolder)
	if leg + b.Y <= MAX_TOP_PATCH_HEIGHT then
		addFacePatches(body, Y, Z, b.Z, X, b.X, rng, patches, patchFolder)
	end
	addFacePatches(body, Z, Y, b.Y, X, b.X, rng, patches, patchFolder)
	-- Head: both sides and top
	addFacePatches(head, X, Z, h.Z, Y, h.Y, rng, patches, patchFolder)
	addFacePatches(head, -X, Z, h.Z, Y, h.Y, rng, patches, patchFolder)
	if leg + b.Y * 0.8 + h.Y / 2 <= MAX_TOP_PATCH_HEIGHT then
		addFacePatches(head, Y, Z, h.Z, X, h.X, rng, patches, patchFolder)
	end

	return model, patches
end

return AnimalBuilder
