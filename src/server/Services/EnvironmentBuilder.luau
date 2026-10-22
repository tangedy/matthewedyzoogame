-- The cozy farm-zoo world around the bays: bright lighting, grass, a dirt road the animals
-- walk in on, picket fences, trees, flower beds, hay bales, a barn, a pond, a welcome plaza
-- and clouds. All procedural and deterministic (fixed seed), and kept clear of every bay slot
-- so bays can appear and disappear on top of it.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local EnvironmentBuilder = {}

local GRASS = Color3.fromRGB(110, 200, 80)
local ROAD = Color3.fromRGB(205, 165, 110)
local FENCE = Color3.fromRGB(250, 248, 240)
local WOOD = Color3.fromRGB(130, 90, 55)
local LEAF_COLORS = {
	Color3.fromRGB(80, 180, 70),
	Color3.fromRGB(100, 200, 80),
	Color3.fromRGB(60, 160, 75),
	Color3.fromRGB(130, 210, 90),
}
local FLOWER_COLORS = {
	Color3.fromRGB(255, 90, 110),
	Color3.fromRGB(255, 210, 60),
	Color3.fromRGB(255, 140, 220),
	Color3.fromRGB(170, 120, 255),
	Color3.fromRGB(255, 255, 255),
}

local WORLD_HALF_LENGTH = 300 -- along Z, past the furthest bay slot
local FENCE_X = 62 -- picket fences either side of the bay strip
local ROAD_X = -30 -- the entrance side: animals walk in along this road

local rng = Random.new(20261022)
local folder: Folder

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	p.CanQuery = false -- scenery never blocks the hose
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = props.Parent or folder
	return p
end

-- Bay footprints (pad + pens), so scenery never lands inside a slot.
local function insideBaySlot(x: number, z: number, margin: number): boolean
	if math.abs(x) > 52 + margin then
		return false
	end
	for i = 1, GameConfig.BayCount do
		local row = math.ceil(i / 2)
		local side = if i % 2 == 1 then 1 else -1
		local cz = side * (row - 0.5) * GameConfig.BaySpacing
		if z > cz + GameConfig.Zoo.PenRowZ - 8 - margin and z < cz + GameConfig.BayPadSize.Z / 2 + margin then
			return true
		end
	end
	return false
end

local function setupLighting()
	Lighting.ClockTime = 13
	Lighting.Brightness = 2.6
	Lighting.Ambient = Color3.fromRGB(140, 140, 155)
	Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 180)
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 0.6
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.4

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmosphere.Density = 0.22
	atmosphere.Offset = 0.1
	atmosphere.Color = Color3.fromRGB(205, 228, 255)
	atmosphere.Decay = Color3.fromRGB(140, 195, 255)
	atmosphere.Glare = 0
	atmosphere.Haze = 0.6
	atmosphere.Parent = Lighting

	local bloom = Lighting:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect")
	bloom.Intensity = 0.5
	bloom.Size = 24
	bloom.Threshold = 1.6
	bloom.Parent = Lighting

	local grade = Lighting:FindFirstChild("CozyGrade") or Instance.new("ColorCorrectionEffect")
	grade.Name = "CozyGrade"
	(grade :: ColorCorrectionEffect).Saturation = 0.18
	(grade :: ColorCorrectionEffect).Contrast = 0.06
	(grade :: ColorCorrectionEffect).Brightness = 0.02
	(grade :: ColorCorrectionEffect).TintColor = Color3.fromRGB(255, 250, 240)
	grade.Parent = Lighting

	local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	if dof then
		dof.Enabled = false -- keeps far-away rare animals and signs crisp
	end
end

local function setupGround()
	local baseplate = Workspace:FindFirstChild("Baseplate")
	local ground: BasePart
	if baseplate and baseplate:IsA("BasePart") then
		ground = baseplate
		for _, child in baseplate:GetChildren() do
			if child:IsA("Texture") or child:IsA("Decal") then
				child:Destroy() -- the Studio grid
			end
		end
	else
		ground = Workspace:FindFirstChild("Ground") :: BasePart
	end
	if ground then
		ground.Color = GRASS
		ground.Material = Enum.Material.Grass
	end
	-- Darker grass verges along the fences for a bit of variety
	for _, side in { -1, 1 } do
		part({
			Name = "Verge",
			Size = Vector3.new(20, 0.1, WORLD_HALF_LENGTH * 2),
			Position = Vector3.new(side * (FENCE_X + 10), 0.05, 0),
			Color = Color3.fromRGB(95, 185, 70),
			Material = Enum.Material.Grass,
			CanCollide = false,
		})
	end
end

local function buildRoad()
	part({
		Name = "Road",
		Size = Vector3.new(9, 0.2, WORLD_HALF_LENGTH * 2),
		Position = Vector3.new(ROAD_X, 0.1, 0),
		Color = ROAD,
		Material = Enum.Material.Ground,
		CanCollide = false,
	})
	for _, side in { -1, 1 } do
		part({
			Name = "RoadEdge",
			Size = Vector3.new(0.6, 0.25, WORLD_HALF_LENGTH * 2),
			Position = Vector3.new(ROAD_X + side * 4.8, 0.12, 0),
			Color = Color3.fromRGB(170, 130, 85),
			Material = Enum.Material.Ground,
			CanCollide = false,
		})
	end
end

local function buildFences()
	local step = 10
	for _, side in { -1, 1 } do
		local x = side * FENCE_X
		for z = -WORLD_HALF_LENGTH, WORLD_HALF_LENGTH - step, step do
			part({
				Name = "FencePost",
				Size = Vector3.new(0.8, 3.2, 0.8),
				Position = Vector3.new(x, 1.6, z),
				Color = FENCE,
			})
			for _, y in { 1.1, 2.3 } do
				part({
					Name = "FenceRail",
					Size = Vector3.new(0.3, 0.4, step),
					Position = Vector3.new(x, y, z + step / 2),
					Color = FENCE,
				})
			end
		end
	end
end

local function tree(position: Vector3, scale: number)
	local height = 7 * scale
	part({
		Name = "Trunk",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, 1.6 * scale, 1.6 * scale),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = WOOD,
		Material = Enum.Material.Wood,
	})
	local top = position + Vector3.new(0, height, 0)
	for i = 1, 3 do
		local size = rng:NextNumber(5, 7.5) * scale
		local offset = Vector3.new(rng:NextNumber(-1.6, 1.6), rng:NextNumber(-0.5, 2), rng:NextNumber(-1.6, 1.6))
			* scale
		part({
			Name = "Leaves",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(size, size, size),
			Position = top + offset + Vector3.new(0, i * 0.4, 0),
			Color = LEAF_COLORS[rng:NextInteger(1, #LEAF_COLORS)],
			Material = Enum.Material.Grass,
			CanCollide = false,
		})
	end
end

local function buildTrees()
	for _, side in { -1, 1 } do
		local z = -WORLD_HALF_LENGTH
		while z < WORLD_HALF_LENGTH do
			local x = side * rng:NextNumber(72, 150)
			-- Leave room for the barn (west) and the pond (east)
			local nearBarn = side == -1 and math.abs(z) < 40 and math.abs(x) < 135
			local nearPond = side == 1 and z > -75 and z < -5 and math.abs(x) < 125
			if not nearBarn and not nearPond then
				tree(Vector3.new(x, 0, z), rng:NextNumber(0.85, 1.35))
			end
			z += rng:NextNumber(9, 16)
		end
	end
	-- A few behind the far ends
	for i = -4, 4 do
		for _, endZ in { -WORLD_HALF_LENGTH - 15, WORLD_HALF_LENGTH + 15 } do
			tree(Vector3.new(i * 16 + rng:NextNumber(-4, 4), 0, endZ + rng:NextNumber(-5, 5)), rng:NextNumber(0.9, 1.3))
		end
	end
end

local function flowerBed(center: Vector3, width: number, depth: number)
	part({
		Name = "FlowerBedSoil",
		Size = Vector3.new(width, 0.4, depth),
		Position = center + Vector3.new(0, 0.2, 0),
		Color = Color3.fromRGB(120, 80, 50),
		Material = Enum.Material.Ground,
		CanCollide = false,
	})
	local count = math.floor(width * depth / 3)
	for _ = 1, count do
		local pos = center
			+ Vector3.new(
				rng:NextNumber(-width / 2 + 0.5, width / 2 - 0.5),
				0,
				rng:NextNumber(-depth / 2 + 0.5, depth / 2 - 0.5)
			)
		part({
			Name = "Stem",
			Size = Vector3.new(0.15, 0.9, 0.15),
			Position = pos + Vector3.new(0, 0.85, 0),
			Color = Color3.fromRGB(70, 150, 60),
			CanCollide = false,
		})
		part({
			Name = "Flower",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.7, 0.7, 0.7),
			Position = pos + Vector3.new(0, 1.4, 0),
			Color = FLOWER_COLORS[rng:NextInteger(1, #FLOWER_COLORS)],
			CanCollide = false,
		})
	end
end

local function hayBale(position: Vector3, angle: number)
	part({
		Name = "HayBale",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(3, 3.2, 3.2),
		CFrame = CFrame.new(position + Vector3.new(0, 1.6, 0)) * CFrame.Angles(0, angle, 0),
		Color = Color3.fromRGB(235, 200, 90),
		Material = Enum.Material.Fabric,
	})
end

-- Flower beds and hay in the gaps between bay slots, and along the road.
local function buildGapDecor()
	for i = 0, GameConfig.BayCount do
		for _, side in { -1, 1 } do
			local z = side * i * GameConfig.BaySpacing - side * 7 -- middle of each gap
			if math.abs(z) < WORLD_HALF_LENGTH and not insideBaySlot(14, z, 1) and i > 0 then
				flowerBed(Vector3.new(14, 0, z), 10, 4)
				flowerBed(Vector3.new(-6, 0, z), 8, 4)
			end
		end
	end
	local z = -WORLD_HALF_LENGTH + 10
	while z < WORLD_HALF_LENGTH - 10 do
		if not insideBaySlot(ROAD_X - 9, z, 2) then
			hayBale(Vector3.new(ROAD_X - 8.5, 0, z), rng:NextNumber(0, math.pi))
		end
		z += rng:NextNumber(18, 32)
	end
end

local function buildBarn()
	local base = Vector3.new(-100, 0, 0)
	local red = Color3.fromRGB(200, 60, 50)
	part({ Name = "Barn", Size = Vector3.new(26, 16, 34), Position = base + Vector3.new(0, 8, 0), Color = red })
	for _, side in { -1, 1 } do
		part({
			Name = "BarnRoof",
			Size = Vector3.new(16, 1.2, 36),
			CFrame = CFrame.new(base + Vector3.new(side * 6.5, 19.2, 0)) * CFrame.Angles(0, 0, side * math.rad(-35)),
			Color = Color3.fromRGB(120, 60, 50),
		})
	end
	part({
		Name = "BarnGable",
		Size = Vector3.new(0.6, 9, 20),
		CFrame = CFrame.new(base + Vector3.new(13.2, 17, 0)),
		Color = red,
	})
	part({
		Name = "BarnDoor",
		Size = Vector3.new(0.4, 10, 12),
		Position = base + Vector3.new(13.2, 5, 0),
		Color = FENCE,
	})
	for _, sign in { -1, 1 } do
		part({
			Name = "BarnDoorX",
			Size = Vector3.new(0.5, 15.5, 0.8),
			CFrame = CFrame.new(base + Vector3.new(13.4, 5, 0)) * CFrame.Angles(sign * math.rad(50), 0, 0),
			Color = red,
		})
	end
	part({
		Name = "Silo",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(26, 9, 9),
		CFrame = CFrame.new(base + Vector3.new(0, 13, -24)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(220, 220, 225),
		Material = Enum.Material.Metal,
	})
	part({
		Name = "SiloTop",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(9, 9, 9),
		Position = base + Vector3.new(0, 26, -24),
		Color = Color3.fromRGB(120, 60, 50),
	})
end

local function buildPond()
	local center = Vector3.new(92, 0, -40)
	part({
		Name = "PondShore",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 34, 34),
		CFrame = CFrame.new(center + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(220, 200, 150),
		Material = Enum.Material.Sand,
		CanCollide = false,
	})
	part({
		Name = "PondWater",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 30, 30),
		CFrame = CFrame.new(center + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(80, 170, 240),
		Material = Enum.Material.Glass,
		Transparency = 0.15,
		Reflectance = 0.2,
		CanCollide = false,
	})
	for i = 1, 8 do
		local a = i / 8 * math.pi * 2
		part({
			Name = "Reed",
			Size = Vector3.new(0.3, rng:NextNumber(2, 3.5), 0.3),
			Position = center + Vector3.new(math.cos(a) * 15.5, 1.2, math.sin(a) * 15.5),
			Color = Color3.fromRGB(90, 150, 60),
			CanCollide = false,
		})
	end
end

-- Welcome plaza at the origin (between the first two slots), with a fountain and a sign.
local function buildPlaza()
	local center = Vector3.new(0, 0, -7)
	part({
		Name = "Plaza",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 22, 22),
		CFrame = CFrame.new(center + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(230, 220, 200),
		Material = Enum.Material.Cobblestone,
		CanCollide = false,
	})
	local basin = part({
		Name = "FountainBasin",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.6, 8, 8),
		CFrame = CFrame.new(center + Vector3.new(9, 0.8, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(200, 200, 210),
		Material = Enum.Material.Marble,
	})
	part({
		Name = "FountainWater",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 7, 7),
		CFrame = basin.CFrame * CFrame.new(0.75, 0, 0),
		Color = Color3.fromRGB(100, 190, 255),
		Material = Enum.Material.Glass,
		Transparency = 0.2,
		CanCollide = false,
	})
	local spout = part({
		Name = "FountainSpout",
		Size = Vector3.new(1, 3, 1),
		Position = basin.Position + Vector3.new(0, 2, 0),
		Color = Color3.fromRGB(200, 200, 210),
		Material = Enum.Material.Marble,
	})
	local spray = Instance.new("ParticleEmitter")
	spray.Rate = 40
	spray.Speed = NumberRange.new(8, 11)
	spray.SpreadAngle = Vector2.new(12, 12)
	spray.EmissionDirection = Enum.NormalId.Top
	spray.Acceleration = Vector3.new(0, -30, 0)
	spray.Lifetime = NumberRange.new(0.6, 0.8)
	spray.Size = NumberSequence.new(0.35, 0.15)
	spray.Color = ColorSequence.new(Color3.fromRGB(190, 230, 255))
	spray.Transparency = NumberSequence.new(0.2, 0.8)
	spray.Parent = spout

	local sign = part({
		Name = "WelcomeSign",
		Size = Vector3.new(0.6, 6, 14),
		Position = center + Vector3.new(-9, 5, 0),
		Color = WOOD,
		Material = Enum.Material.Wood,
	})
	for _, dz in { -5.5, 5.5 } do
		part({
			Name = "SignLeg",
			Size = Vector3.new(0.6, 5, 0.6),
			Position = center + Vector3.new(-9, 2.5, dz),
			Color = WOOD,
		})
	end
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Right
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = sign
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.Parent = gui
	UIStyle.text(text, Color3.fromRGB(255, 230, 120), Color3.fromRGB(60, 35, 15), 5)
	text.Text = "WASH THE ZOO"
end

local function buildClouds()
	for _ = 1, 16 do
		local center = Vector3.new(rng:NextNumber(-260, 260), rng:NextNumber(110, 160), rng:NextNumber(-340, 340))
		for _ = 1, rng:NextInteger(3, 5) do
			local size = rng:NextNumber(14, 26)
			part({
				Name = "Cloud",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(size, size * 0.6, size),
				Position = center + Vector3.new(rng:NextNumber(-14, 14), rng:NextNumber(-3, 3), rng:NextNumber(-8, 8)),
				Color = Color3.new(1, 1, 1),
				Material = Enum.Material.SmoothPlastic,
				CanCollide = false,
				CastShadow = false,
			})
		end
	end
end

function EnvironmentBuilder.build()
	local existing = Workspace:FindFirstChild("Environment")
	if existing then
		existing:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "Environment"
	setupLighting()
	setupGround()
	buildRoad()
	buildFences()
	buildTrees()
	buildGapDecor()
	buildBarn()
	buildPond()
	buildPlaza()
	buildClouds()
	folder.Parent = Workspace
end

return EnvironmentBuilder
