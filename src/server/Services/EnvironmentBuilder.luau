-- Trees, grass, and the center dirt road. Plots are reserved rectangles (see PlotLayout),
-- so scenery never lands where a farm or its barn will grow. Lighting and clouds stay.

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

local WORLD_HALF_LENGTH = 700 -- along Z, past the furthest plot and the truck's drive-in
local BOARD_Z = -520 -- LiveOpsConfig.Board.Position, kept clear of trees

local rng = Random.new(20261022)
local folder: Folder

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	p.CanQuery = false
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

-- Forest everywhere that isn't road, a plot (including the barn it may grow into), or the board.
local function buildTrees()
	local halfX = GameConfig.GroundSize.X / 2 - 12
	local halfZ = GameConfig.GroundSize.Z / 2 - 12
	local roadClear = GameConfig.RoadWidth / 2 + 8
	local planted = 0
	local x = -halfX
	while x < halfX do
		local z = -halfZ
		while z < halfZ do
			local px = x + rng:NextNumber(-5, 5)
			local pz = z + rng:NextNumber(-5, 5)
			local onRoad = math.abs(px - GameConfig.RoadX) < roadClear
			local nearBoard = math.abs(px) < 20 and math.abs(pz - BOARD_Z) < 24
			if not onRoad and not nearBoard and not PlotLayout.contains(px, pz, 4) then
				tree(Vector3.new(px, 0, pz), rng:NextNumber(0.85, 1.35))
				planted += 1
				if planted % 80 == 0 then
					task.wait()
				end
			end
			z += rng:NextNumber(22, 34)
		end
		x += rng:NextNumber(22, 34)
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
	buildTrees()
	buildClouds()
end

return EnvironmentBuilder
