-- The world around the farms: lighting, the center dirt road (ruts, lamp posts, planters),
-- a mowed lawn and white picket fence for every plot, a mixed forest with bushes, flowers
-- and rocks, a pond at the north end, and rolling hills around the edge. Plots are reserved
-- rectangles (see PlotLayout), so scenery never lands where a farm or its barn will grow.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlotLayout = require(ReplicatedStorage.Shared.PlotLayout)

local EnvironmentBuilder = {}

local GRASS = Color3.fromRGB(110, 200, 80)
local ROAD = Color3.fromRGB(205, 165, 110)
local WOOD = Color3.fromRGB(130, 90, 55)
local LEAF_COLORS = {
	Color3.fromRGB(80, 180, 70),
	Color3.fromRGB(100, 200, 80),
	Color3.fromRGB(60, 160, 75),
	Color3.fromRGB(130, 210, 90),
}
local PINE_COLORS = { Color3.fromRGB(40, 120, 70), Color3.fromRGB(50, 140, 80), Color3.fromRGB(35, 105, 65) }
local LAWN_A = Color3.fromRGB(118, 208, 86)
local LAWN_B = Color3.fromRGB(104, 194, 76)
local PICKET = Color3.fromRGB(250, 248, 240)
local FLOWER_COLORS = {
	Color3.fromRGB(255, 90, 120),
	Color3.fromRGB(255, 210, 70),
	Color3.fromRGB(250, 250, 255),
	Color3.fromRGB(190, 120, 255),
	Color3.fromRGB(255, 150, 60),
}
local ROCK_COLORS = { Color3.fromRGB(150, 150, 155), Color3.fromRGB(125, 125, 130), Color3.fromRGB(170, 165, 160) }
local POND_CENTER = Vector3.new(130, 0, 330)
local POND_SIZE = Vector2.new(56, 56) -- X, Z (round)

local WORLD_HALF_LENGTH = 370 -- along Z, just past the plots and the truck's drive-in
local BOARD_Z = 0 -- LiveOpsConfig.Board.Position, kept clear of trees

local rng = Random.new(20261022)
local folder: Folder

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	p.CanQuery = false
	p.CanTouch = false -- scenery never needs touch events; skips that physics work
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = props.Parent or folder
	return p
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
		dof.Enabled = false
	end
end

local function setupGround()
	local ground = Workspace:FindFirstChild("Baseplate") or Workspace:FindFirstChild("Ground")
	if ground and ground:IsA("BasePart") then
		for _, child in ground:GetChildren() do
			if child:IsA("Texture") or child:IsA("Decal") then
				child:Destroy()
			end
		end
		ground.Size = GameConfig.GroundSize
		ground.Position = Vector3.new(0, -GameConfig.GroundSize.Y / 2, 0)
		ground.Color = GRASS
		ground.Material = Enum.Material.Grass
	end
end

local function buildRoad()
	local half = GameConfig.RoadWidth / 2
	part({
		Name = "Road",
		Size = Vector3.new(GameConfig.RoadWidth, 0.2, WORLD_HALF_LENGTH * 2),
		Position = Vector3.new(GameConfig.RoadX, 0.1, 0),
		Color = ROAD,
		Material = Enum.Material.Ground,
		CanCollide = false,
	})
	for _, side in { -1, 1 } do
		part({
			Name = "RoadEdge",
			Size = Vector3.new(0.8, 0.25, WORLD_HALF_LENGTH * 2),
			Position = Vector3.new(GameConfig.RoadX + side * (half - 0.4), 0.12, 0),
			Color = Color3.fromRGB(170, 130, 85),
			Material = Enum.Material.Ground,
			CanCollide = false,
		})
		-- Worn wheel ruts down each lane.
		for _, lane in { -1, 1 } do
			part({
				Name = "Rut",
				Size = Vector3.new(1.6, 0.22, WORLD_HALF_LENGTH * 2),
				Position = Vector3.new(GameConfig.RoadX + side * half * 0.5 + lane * 3, 0.11, 0),
				Color = Color3.fromRGB(180, 140, 92),
				Material = Enum.Material.Ground,
				CanCollide = false,
			})
		end
	end
	-- A strip of grass down the middle of the road, the way a country lane wears.
	part({
		Name = "Median",
		Size = Vector3.new(2.4, 0.22, WORLD_HALF_LENGTH * 2),
		Position = Vector3.new(GameConfig.RoadX, 0.11, 0),
		Color = Color3.fromRGB(150, 190, 90),
		Material = Enum.Material.Grass,
		CanCollide = false,
	})
end

-- Z centres of the gaps between plots on one side, plus the two road ends.
local function gapCentres(): { number }
	local zs = {}
	for i = 1, 3 do
		table.insert(zs, (PlotLayout.zOf(i) + PlotLayout.zOf(i + 1)) / 2)
	end
	table.insert(zs, PlotLayout.zOf(1) - GameConfig.BaySpacing / 2)
	table.insert(zs, PlotLayout.zOf(4) + GameConfig.BaySpacing / 2)
	return zs
end

local function lampPost(position: Vector3)
	part({
		Name = "LampPost",
		Size = Vector3.new(0.6, 9, 0.6),
		Position = position + Vector3.new(0, 4.5, 0),
		Color = Color3.fromRGB(45, 50, 60),
		Material = Enum.Material.Metal,
	})
	part({
		Name = "LampCap",
		Size = Vector3.new(1.8, 0.4, 1.8),
		Position = position + Vector3.new(0, 9.9, 0),
		Color = Color3.fromRGB(45, 50, 60),
		Material = Enum.Material.Metal,
	})
	part({
		Name = "Lamp",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.4, 1.4, 1.4),
		Position = position + Vector3.new(0, 9.2, 0),
		Color = Color3.fromRGB(255, 225, 150),
		Material = Enum.Material.Neon,
		CanCollide = false,
		CastShadow = false,
	})
end

local function planter(position: Vector3, length: number)
	part({
		Name = "Planter",
		Size = Vector3.new(3, 1, length),
		Position = position + Vector3.new(0, 0.5, 0),
		Color = Color3.fromRGB(140, 95, 60),
		Material = Enum.Material.WoodPlanks,
	})
	part({
		Name = "Soil",
		Size = Vector3.new(2.4, 0.2, length - 0.6),
		Position = position + Vector3.new(0, 1.0, 0),
		Color = Color3.fromRGB(90, 60, 40),
		Material = Enum.Material.Ground,
		CanCollide = false,
	})
	local count = math.floor(length / 1.3)
	for i = 1, count do
		local z = -length / 2 + 0.6 + (i - 0.5) * (length - 1.2) / count
		part({
			Name = "Flower",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.9, 0.9, 0.9),
			Position = position + Vector3.new(rng:NextNumber(-0.6, 0.6), 1.5, z),
			Color = FLOWER_COLORS[rng:NextInteger(1, #FLOWER_COLORS)],
			CanCollide = false,
			CastShadow = false,
		})
	end
end

-- Lamp posts and planters along both road edges, in the gaps between farms.
local function buildRoadside()
	local edge = GameConfig.RoadWidth / 2 + 2.5
	for _, z in gapCentres() do
		for _, side in { -1, 1 } do
			lampPost(Vector3.new(GameConfig.RoadX + side * edge, 0, z))
			planter(Vector3.new(GameConfig.RoadX + side * (edge + 3), 0, z), 10)
		end
	end
end

-- A run of white picket fence from a to b (on the ground).
local function picketRun(a: Vector3, b: Vector3)
	local span = b - a
	local length = span.Magnitude
	if length < 1 then
		return
	end
	local frame = CFrame.lookAt(a, b)
	for _, height in { 1.0, 2.0 } do
		part({
			Name = "FenceRail",
			Size = Vector3.new(0.25, 0.3, length),
			CFrame = frame * CFrame.new(0, height, -length / 2),
			Color = PICKET,
			CastShadow = false, -- thousands of fence parts: shadows cost a lot and barely show
		})
	end
	local count = math.max(1, math.floor(length / 4))
	for i = 0, count do
		part({
			Name = "Picket",
			Size = Vector3.new(0.35, 2.8, 0.5),
			CFrame = frame * CFrame.new(0, 1.4, -i * length / count),
			Color = PICKET,
			CastShadow = false,
		})
	end
end

-- Every plot: mowed lawn stripes and a picket fence on its sides and back (the road side is
-- open; that's the way in).
local function buildPlots()
	local halfW = GameConfig.PlotWidth / 2
	local depth = GameConfig.PlotDepth
	local stripes = 13
	for i = 1, GameConfig.BayCount do
		local plot = PlotLayout.frame(i)
		local stripeWidth = GameConfig.PlotWidth / stripes
		for k = 1, stripes do
			local lateral = -halfW + (k - 0.5) * stripeWidth
			part({
				Name = "Lawn",
				Size = Vector3.new(depth, 0.06, stripeWidth),
				CFrame = CFrame.lookAt(
					PlotLayout.point(plot, depth / 2, lateral, 0.0),
					PlotLayout.point(plot, depth / 2, lateral, 0.0) + plot.Right
				),
				Color = if k % 2 == 0 then LAWN_A else LAWN_B,
				Material = Enum.Material.Grass,
				CanCollide = false,
				CastShadow = false,
			})
		end
		local margin = 3
		local nearL = PlotLayout.point(plot, 1, -(halfW + margin), 0)
		local nearR = PlotLayout.point(plot, 1, halfW + margin, 0)
		local farL = PlotLayout.point(plot, depth + margin, -(halfW + margin), 0)
		local farR = PlotLayout.point(plot, depth + margin, halfW + margin, 0)
		picketRun(nearL, farL)
		picketRun(farL, farR)
		picketRun(farR, nearR)
		task.wait()
	end
end

local function roundTree(position: Vector3, scale: number)
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

-- Stacked, shrinking blocks turned a little each layer: a chunky pine.
local function pineTree(position: Vector3, scale: number)
	local trunk = 3 * scale
	part({
		Name = "Trunk",
		Size = Vector3.new(1.2 * scale, trunk, 1.2 * scale),
		Position = position + Vector3.new(0, trunk / 2, 0),
		Color = Color3.fromRGB(110, 75, 45),
		Material = Enum.Material.Wood,
	})
	local color = PINE_COLORS[rng:NextInteger(1, #PINE_COLORS)]
	local y = trunk
	for layer = 1, 4 do
		local width = (8 - layer * 1.6) * scale
		local height = 2.6 * scale
		part({
			Name = "Needles",
			Size = Vector3.new(width, height, width),
			CFrame = CFrame.new(position + Vector3.new(0, y + height / 2, 0)) * CFrame.Angles(0, layer * 0.4, 0),
			Color = color,
			Material = Enum.Material.Grass,
			CanCollide = false,
		})
		y += height * 0.75
	end
end

local function bush(position: Vector3, scale: number)
	local color = LEAF_COLORS[rng:NextInteger(1, #LEAF_COLORS)]
	for _ = 1, 3 do
		local size = rng:NextNumber(2.5, 4) * scale
		part({
			Name = "Bush",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(size, size * 0.8, size),
			Position = position
				+ Vector3.new(rng:NextNumber(-1.5, 1.5), size * 0.3, rng:NextNumber(-1.5, 1.5))
					* Vector3.new(scale, 1, scale),
			Color = color:Lerp(Color3.new(0, 0, 0), 0.1),
			Material = Enum.Material.Grass,
			CanCollide = false,
		})
	end
end

local function flowerPatch(position: Vector3)
	local color = FLOWER_COLORS[rng:NextInteger(1, #FLOWER_COLORS)]
	for _ = 1, rng:NextInteger(4, 7) do
		part({
			Name = "Flower",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.7, 0.7, 0.7),
			Position = position + Vector3.new(rng:NextNumber(-2, 2), 0.4, rng:NextNumber(-2, 2)),
			Color = color,
			CanCollide = false,
			CastShadow = false,
		})
	end
end

local function rock(position: Vector3)
	local size = rng:NextNumber(2, 5)
	part({
		Name = "Rock",
		Size = Vector3.new(size, size * 0.6, size * rng:NextNumber(0.7, 1.2)),
		CFrame = CFrame.new(position + Vector3.new(0, size * 0.2, 0))
			* CFrame.Angles(rng:NextNumber(-0.2, 0.2), rng:NextNumber(0, math.pi), rng:NextNumber(-0.2, 0.2)),
		Color = ROCK_COLORS[rng:NextInteger(1, #ROCK_COLORS)],
		Material = Enum.Material.Slate,
	})
end

local function inPond(x: number, z: number, margin: number): boolean
	local dx = (x - POND_CENTER.X) / (POND_SIZE.X / 2 + margin)
	local dz = (z - POND_CENTER.Z) / (POND_SIZE.Y / 2 + margin)
	return dx * dx + dz * dz <= 1
end

local function buildPond()
	-- Sand rim, then water, then a few lily pads and rocks on the edge. Round: a cylinder
	-- part can't be stretched into an oval.
	part({
		Name = "PondShore",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, POND_SIZE.X + 8, POND_SIZE.X + 8),
		CFrame = CFrame.new(POND_CENTER + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(230, 210, 160),
		Material = Enum.Material.Sand,
		CanCollide = false,
	})
	local water = part({
		Name = "Pond",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, POND_SIZE.X, POND_SIZE.X),
		CFrame = CFrame.new(POND_CENTER + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(70, 160, 220),
		Material = Enum.Material.Glass,
		Transparency = 0.15,
		Reflectance = 0.2,
		CanCollide = false,
	})
	water.CastShadow = false
	for _ = 1, 7 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(0.2, 0.75)
		part({
			Name = "LilyPad",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.1, 3, 3),
			CFrame = CFrame.new(
				POND_CENTER
					+ Vector3.new(math.cos(angle) * POND_SIZE.X / 2 * r, 0.3, math.sin(angle) * POND_SIZE.Y / 2 * r)
			) * CFrame.Angles(0, 0, math.rad(90)),
			Color = Color3.fromRGB(70, 170, 70),
			CanCollide = false,
			CastShadow = false,
		})
	end
	for _ = 1, 9 do
		local angle = rng:NextNumber(0, math.pi * 2)
		rock(
			POND_CENTER
				+ Vector3.new(math.cos(angle) * (POND_SIZE.X / 2 + 3), 0, math.sin(angle) * (POND_SIZE.Y / 2 + 3))
		)
	end
end

-- Forest everywhere that isn't road, a plot (including the barn it may grow into), the
-- board or the pond: round trees and pines, with bushes, flowers and rocks between them.
local function buildTrees()
	local halfX = GameConfig.GroundSize.X / 2 - 8
	local halfZ = GameConfig.GroundSize.Z / 2 - 8
	local roadClear = GameConfig.RoadWidth / 2 + 14
	local planted = 0
	local function clear(px: number, pz: number, margin: number): boolean
		local onRoad = math.abs(px - GameConfig.RoadX) < roadClear
		local nearBoard = math.abs(px) < 20 + margin and math.abs(pz - BOARD_Z) < 24 + margin
		return not onRoad and not nearBoard and not inPond(px, pz, 6) and not PlotLayout.contains(px, pz, 6 + margin)
	end
	local x = -halfX
	while x < halfX do
		local z = -halfZ
		while z < halfZ do
			local px = x + rng:NextNumber(-5, 5)
			local pz = z + rng:NextNumber(-5, 5)
			if clear(px, pz, 0) then
				local roll = rng:NextNumber()
				local at = Vector3.new(px, 0, pz)
				if roll < 0.45 then
					roundTree(at, rng:NextNumber(0.85, 1.4))
				elseif roll < 0.8 then
					pineTree(at, rng:NextNumber(0.9, 1.5))
				elseif roll < 0.92 then
					bush(at, rng:NextNumber(0.9, 1.4))
				else
					rock(at)
				end
				if rng:NextNumber() < 0.35 then
					flowerPatch(at + Vector3.new(rng:NextNumber(-8, 8), 0, rng:NextNumber(-8, 8)))
				end
				planted += 1
				if planted % 60 == 0 then
					task.wait()
				end
			end
			z += rng:NextNumber(15, 22)
		end
		x += rng:NextNumber(15, 22)
	end
end

-- Rolling hills just past the edge of the ground, so the world ends in green, not sky.
local function buildHills()
	local halfX = GameConfig.GroundSize.X / 2
	local halfZ = GameConfig.GroundSize.Z / 2
	local perimeter = 4 * (halfX + halfZ)
	local count = math.floor(perimeter / 55)
	for i = 0, count - 1 do
		local t = i / count * perimeter
		local pos: Vector3
		if t < 2 * halfX then
			pos = Vector3.new(-halfX + t, 0, -halfZ)
		elseif t < 2 * halfX + 2 * halfZ then
			pos = Vector3.new(halfX, 0, -halfZ + (t - 2 * halfX))
		elseif t < 4 * halfX + 2 * halfZ then
			pos = Vector3.new(halfX - (t - 2 * halfX - 2 * halfZ), 0, halfZ)
		else
			pos = Vector3.new(-halfX, 0, halfZ - (t - 4 * halfX - 2 * halfZ))
		end
		local outward = Vector3.new(pos.X, 0, pos.Z).Unit
		for layer = 0, 1 do
			local size = rng:NextNumber(70, 120) * (1 + layer * 0.6)
			local center = pos + outward * (size * 0.25 + layer * 70) - Vector3.new(0, size * (0.32 - layer * 0.05), 0)
			part({
				Name = "Hill",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(size, size, size),
				Position = center,
				Color = GRASS:Lerp(Color3.fromRGB(60, 140, 70), rng:NextNumber(0.1, 0.4) + layer * 0.2),
				Material = Enum.Material.Grass,
				CastShadow = false,
			})
		end
		if i % 10 == 0 then
			task.wait()
		end
	end
end

local function buildClouds()
	for _ = 1, 18 do
		local center = Vector3.new(rng:NextNumber(-480, 480), rng:NextNumber(110, 160), rng:NextNumber(-640, 640))
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
	folder.Parent = Workspace
	setupLighting()
	setupGround()
	buildRoad()
	buildRoadside()
	buildPlots()
	buildPond()
	-- The forest, hills and clouds yield as they build. Run them on their own thread so
	-- services and player loading start right away instead of waiting on scenery.
	task.spawn(function()
		buildTrees()
		buildHills()
		buildClouds()
	end)
end

return EnvironmentBuilder
