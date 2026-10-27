-- Cosmetic farm scenery that grows with the farm. Each farm level (the barn tier bought,
-- 0 for the starting stalls) adds its own set on the plot's sides and back pasture, and
-- every level keeps the sets below it, so a richer farm looks richer from the road:
--   0 Homestead  veggie patch and scarecrow, hay bales, a cart, a mailbox by the road
--   1 Barnyard   a red barn, a chicken coop with chickens
--   2 Windmill   a windmill (the client turns its blades) and a grain silo
--   3 Harvest    a tractor, a wheat field, a water tower
--   4 Garden     a greenhouse, a duck pond with a dock, a flower garden under an arch
--   5 Golden     a golden fountain at the walkway's end, a hot-air balloon (the client bobs
--                it), flags at the corners, a giant golden trophy
-- Nothing here has prompts or gameplay. Every piece stays clear of the drive, the plaza,
-- the Robux row and every pen's footprint at any level (WorldBuilder's layout).
--
-- Coordinates are (depth, lateral) from PlotLayout: depth away from the road, lateral to the
-- plot's right while facing the road. Props are built in a local frame whose -Z faces the
-- walkway, so their fronts face the players walking it.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlotLayout = require(ReplicatedStorage.Shared.PlotLayout)

local FarmDecor = {}

FarmDecor.MaxLevel = #GameConfig.Zoo.Expansions
-- CollectionService tags the client animates (Features/FarmMotion).
FarmDecor.SpinTag = "FarmSpin"
FarmDecor.BobTag = "FarmBob"

local FOLDER = "FarmDecor"
local PROP_SCALE = 1.3 -- every building and prop, so they read from the road
local FLAT = { VeggiePatch = true, WheatField = true, Pond = true, FlowerGarden = true }

local WOOD = Color3.fromRGB(150, 105, 65)
local DARK_WOOD = Color3.fromRGB(105, 70, 45)
local WHITE = Color3.fromRGB(245, 245, 240)
local BARN_RED = Color3.fromRGB(176, 42, 36)
local ROOF = Color3.fromRGB(70, 60, 60)
local HAY = Color3.fromRGB(228, 194, 96)
local SOIL = Color3.fromRGB(110, 76, 48)
local SOIL_DARK = Color3.fromRGB(86, 58, 38)
local LEAF = Color3.fromRGB(80, 170, 70)
local GOLD = Color3.fromRGB(255, 200, 60)
local STEEL = Color3.fromRGB(200, 202, 208)
local WATER = Color3.fromRGB(70, 160, 225)
local STONE = Color3.fromRGB(150, 150, 156)

type Props = { [string]: any }

local function part(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, props: Props?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanQuery = false
	p.CanTouch = false
	for key, value in props or {} do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function wedge(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.Size = size
	w.CFrame = cframe
	w.Color = color
	w.Material = Enum.Material.SmoothPlastic
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.CanQuery = false
	w.CanTouch = false
	w.Parent = parent
	return w
end

local function ball(
	parent: Instance,
	name: string,
	diameter: number,
	cframe: CFrame,
	color: Color3,
	props: Props?
): Part
	local fields: Props = { Shape = Enum.PartType.Ball, CanCollide = false }
	for key, value in props or {} do
		fields[key] = value
	end
	return part(parent, name, Vector3.one * diameter, cframe, color, fields)
end

-- A cylinder standing upright, its base `y` above the frame's origin.
local function column(
	parent: Instance,
	name: string,
	height: number,
	diameter: number,
	at: CFrame,
	color: Color3,
	props: Props?
): Part
	local fields: Props = { Shape = Enum.PartType.Cylinder }
	for key, value in props or {} do
		fields[key] = value
	end
	return part(
		parent,
		name,
		Vector3.new(height, diameter, diameter),
		at * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		fields
	)
end

-- A wheel on an axle along the frame's Z.
local function wheel(parent: Instance, diameter: number, width: number, at: CFrame, color: Color3): Part
	return part(
		parent,
		"Wheel",
		Vector3.new(width, diameter, diameter),
		at * CFrame.Angles(0, math.rad(90), 0),
		color,
		{ Shape = Enum.PartType.Cylinder }
	)
end

local function model(parent: Instance, name: string, pivot: CFrame): Model
	local m = Instance.new("Model")
	m.Name = name
	m.WorldPivot = pivot
	m.Parent = parent
	return m
end

-- Ground point on the plot, its local -Z turned toward the walkway (or along `face`).
local function site(plot: PlotLayout.PlotFrame, depth: number, lateral: number, face: Vector3?): CFrame
	local pos = PlotLayout.point(plot, depth, lateral, 0)
	local dir = face or (if lateral >= 0 then -plot.Right else plot.Right)
	return CFrame.lookAt(pos, pos + dir)
end

-- Props --------------------------------------------------------------------------------

local function hayBale(parent: Instance, at: CFrame)
	local size = Vector3.new(3.6, 2.2, 2.4)
	local centre = at * CFrame.new(0, size.Y / 2, 0)
	part(parent, "HayBale", size, centre, HAY, { Material = Enum.Material.Sand })
	for _, x in { -0.9, 0.9 } do
		part(
			parent,
			"Twine",
			Vector3.new(0.15, size.Y + 0.06, size.Z + 0.06),
			centre * CFrame.new(x, 0, 0),
			Color3.fromRGB(170, 130, 60),
			{ CanCollide = false }
		)
	end
end

local function hayStack(parent: Instance, at: CFrame)
	local m = model(parent, "HayStack", at)
	hayBale(m, at * CFrame.new(-1.9, 0, 0))
	hayBale(m, at * CFrame.new(1.9, 0, 0))
	hayBale(m, at * CFrame.new(0, 2.2, 0))
	hayBale(m, at * CFrame.new(-1, 0, 3.4) * CFrame.Angles(0, math.rad(80), 0))
end

local function cart(parent: Instance, at: CFrame)
	local m = model(parent, "Cart", at)
	part(m, "Bed", Vector3.new(5, 0.4, 3), at * CFrame.new(0, 2, 0), WOOD, { Material = Enum.Material.WoodPlanks })
	for _, z in { -1.4, 1.4 } do
		part(m, "Side", Vector3.new(5, 1, 0.25), at * CFrame.new(0, 2.7, z), DARK_WOOD)
		wheel(m, 2.8, 0.35, at * CFrame.new(0.6, 1.4, z + (if z > 0 then 0.35 else -0.35)), DARK_WOOD)
	end
	part(m, "Back", Vector3.new(0.25, 1, 3), at * CFrame.new(2.4, 2.7, 0), DARK_WOOD)
	for _, z in { -0.9, 0.9 } do
		part(
			m,
			"Handle",
			Vector3.new(3.4, 0.25, 0.25),
			at * CFrame.new(-3.9, 1.7, z) * CFrame.Angles(0, 0, math.rad(-12)),
			DARK_WOOD,
			{ CanCollide = false }
		)
	end
	ball(m, "Pumpkin", 1.5, at * CFrame.new(-0.8, 2.9, 0), Color3.fromRGB(240, 130, 30))
	ball(m, "Pumpkin", 1.2, at * CFrame.new(0.9, 2.8, 0.5), Color3.fromRGB(250, 150, 40))
end

local function mailbox(parent: Instance, at: CFrame)
	local m = model(parent, "Mailbox", at)
	part(m, "Post", Vector3.new(0.4, 3.4, 0.4), at * CFrame.new(0, 1.7, 0), WOOD)
	part(m, "Box", Vector3.new(1.2, 1, 2), at * CFrame.new(0, 3.9, 0), Color3.fromRGB(60, 120, 200))
	part(m, "Lid", Vector3.new(1.25, 0.25, 2.05), at * CFrame.new(0, 4.5, 0), Color3.fromRGB(50, 100, 170))
	part(m, "FlagPole", Vector3.new(0.12, 1.2, 0.12), at * CFrame.new(0.7, 4.3, 0.5), Color3.fromRGB(220, 40, 40))
	part(m, "Flag", Vector3.new(0.12, 0.45, 0.6), at * CFrame.new(0.7, 4.8, 0.25), Color3.fromRGB(220, 40, 40))
end

local function scarecrow(parent: Instance, at: CFrame)
	local m = model(parent, "Scarecrow", at)
	part(m, "Post", Vector3.new(0.4, 6.5, 0.4), at * CFrame.new(0, 3.25, 0), WOOD)
	part(m, "Arms", Vector3.new(5.2, 0.35, 0.35), at * CFrame.new(0, 5, 0), WOOD)
	part(m, "Shirt", Vector3.new(2, 2.4, 1), at * CFrame.new(0, 4.6, 0), Color3.fromRGB(200, 60, 50), {
		Material = Enum.Material.Fabric,
	})
	part(m, "Trousers", Vector3.new(1.8, 1.4, 0.9), at * CFrame.new(0, 2.8, 0), Color3.fromRGB(70, 90, 160), {
		Material = Enum.Material.Fabric,
	})
	for _, x in { -2.2, 2.2 } do
		part(m, "Straw", Vector3.new(0.6, 0.6, 0.6), at * CFrame.new(x * 1.12, 5, 0), HAY, { CanCollide = false })
	end
	ball(m, "Head", 1.6, at * CFrame.new(0, 6.6, 0), Color3.fromRGB(215, 185, 130), { Material = Enum.Material.Fabric })
	column(m, "HatBrim", 0.15, 3, at * CFrame.new(0, 7.2, 0), Color3.fromRGB(200, 160, 80))
	column(m, "HatTop", 1, 1.6, at * CFrame.new(0, 7.3, 0), Color3.fromRGB(200, 160, 80))
end

-- Crop rows along the frame's X, each row its own crop.
local function veggiePatch(parent: Instance, at: CFrame, length: number)
	local m = model(parent, "VeggiePatch", at)
	local crops = {
		{ Color = Color3.fromRGB(110, 190, 80), Size = 1.3 }, -- cabbages
		{ Color = Color3.fromRGB(240, 130, 30), Size = 1.6 }, -- pumpkins
		{ Color = Color3.fromRGB(70, 150, 60), Size = 0.9 }, -- carrot tops
		{ Color = Color3.fromRGB(220, 50, 50), Size = 0.9 }, -- tomatoes
	}
	local width = #crops * 2.6
	part(m, "Soil", Vector3.new(length, 0.3, width), at * CFrame.new(0, 0.15, 0), SOIL, {
		Material = Enum.Material.Ground,
		CanCollide = false,
	})
	for row, crop in crops do
		local z = -width / 2 + (row - 0.5) * 2.6
		part(m, "Row", Vector3.new(length - 1, 0.5, 1.4), at * CFrame.new(0, 0.4, z), SOIL_DARK, {
			Material = Enum.Material.Ground,
			CanCollide = false,
		})
		local count = math.floor((length - 2) / 2.6)
		for i = 0, count - 1 do
			local x = -length / 2 + 1.6 + i * 2.6
			ball(m, "Crop", crop.Size, at * CFrame.new(x, 0.65 + crop.Size / 2, z), crop.Color)
		end
	end
end

-- A classic barn: red walls with white trim, a pitched roof, a big X-braced door and a
-- hayloft window. Its ridge runs along the frame's Z, so the gable faces the walkway.
local function barn(parent: Instance, at: CFrame, w: number, d: number, h: number)
	local m = model(parent, "Barn", at)
	local rise = w * 0.42
	part(m, "Walls", Vector3.new(w, h, d), at * CFrame.new(0, h / 2, 0), BARN_RED, {
		Material = Enum.Material.WoodPlanks,
	})
	-- Gable: two red wedges (solid, so both ends are closed triangles).
	local wedgeSize = Vector3.new(d, rise, w / 2)
	wedge(m, "Gable", wedgeSize, at * CFrame.new(-w / 4, h + rise / 2, 0) * CFrame.Angles(0, math.rad(90), 0), BARN_RED)
	wedge(m, "Gable", wedgeSize, at * CFrame.new(w / 4, h + rise / 2, 0) * CFrame.Angles(0, math.rad(-90), 0), BARN_RED)
	-- Roof boards on the slopes, overhanging every edge.
	local run = w / 2
	local slope = math.sqrt(run * run + rise * rise)
	local angle = math.atan2(rise, run)
	for _, side in { -1, 1 } do
		local normal = Vector3.new(side * rise, run, 0).Unit
		local mid = Vector3.new(side * w / 4, h + rise / 2, 0) + normal * 0.3
		part(
			m,
			"Roof",
			Vector3.new(slope + 1.2, 0.5, d + 1.6),
			at * CFrame.new(mid) * CFrame.Angles(0, 0, -side * angle),
			ROOF,
			{ Material = Enum.Material.Slate }
		)
	end
	local front = -d / 2
	-- Corner trim, standing a little proud of the walls so no faces share a plane.
	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			part(
				m,
				"Trim",
				Vector3.new(0.6, h, 0.6),
				at * CFrame.new(x * (w / 2 + 0.05), h / 2, z * (d / 2 + 0.05)),
				WHITE
			)
		end
	end
	part(m, "EaveTrim", Vector3.new(w + 0.4, 0.5, 0.3), at * CFrame.new(0, h - 0.25, front - 0.1), WHITE)
	-- Big door with a white frame and an X brace.
	local doorW, doorH = w * 0.42, h * 0.72
	local doorAt = at * CFrame.new(0, doorH / 2, front - 0.12)
	part(m, "Door", Vector3.new(doorW, doorH, 0.2), doorAt, Color3.fromRGB(140, 30, 28))
	part(m, "DoorFrameTop", Vector3.new(doorW + 0.8, 0.45, 0.3), doorAt * CFrame.new(0, doorH / 2, -0.05), WHITE)
	for _, x in { -1, 1 } do
		part(m, "DoorFrame", Vector3.new(0.45, doorH, 0.3), doorAt * CFrame.new(x * doorW / 2, 0, -0.05), WHITE)
	end
	local diagonal = math.sqrt(doorW * doorW + doorH * doorH) - 0.6
	local braceAngle = math.atan2(doorH, doorW)
	for _, sign in { -1, 1 } do
		part(
			m,
			"Brace",
			Vector3.new(diagonal, 0.35, 0.25),
			doorAt * CFrame.new(0, 0, -0.1) * CFrame.Angles(0, 0, sign * braceAngle),
			WHITE,
			{ CanCollide = false }
		)
	end
	-- Hayloft window up in the gable, hay showing through.
	local loftAt = at * CFrame.new(0, h + rise * 0.3, front - 0.12)
	part(m, "Loft", Vector3.new(w * 0.22, w * 0.22, 0.2), loftAt, HAY, { Material = Enum.Material.Sand })
	part(m, "LoftFrame", Vector3.new(w * 0.22 + 0.6, 0.35, 0.3), loftAt * CFrame.new(0, w * 0.11, -0.05), WHITE)
	part(m, "LoftFrame", Vector3.new(w * 0.22 + 0.6, 0.35, 0.3), loftAt * CFrame.new(0, -w * 0.11, -0.05), WHITE)
	return m
end

local function chicken(parent: Instance, at: CFrame)
	ball(parent, "ChickenBody", 1.2, at * CFrame.new(0, 0.6, 0), WHITE)
	ball(parent, "ChickenHead", 0.75, at * CFrame.new(0, 1.35, -0.45), WHITE)
	part(parent, "Comb", Vector3.new(0.15, 0.35, 0.4), at * CFrame.new(0, 1.8, -0.45), Color3.fromRGB(220, 40, 40), {
		CanCollide = false,
	})
	part(parent, "Beak", Vector3.new(0.2, 0.15, 0.3), at * CFrame.new(0, 1.3, -0.9), Color3.fromRGB(250, 170, 40), {
		CanCollide = false,
	})
end

local function chickenCoop(parent: Instance, at: CFrame)
	local m = model(parent, "ChickenCoop", at)
	local house = at * CFrame.new(0, 0, 2)
	for _, x in { -2.2, 2.2 } do
		for _, z in { -1.6, 1.6 } do
			part(m, "Stilt", Vector3.new(0.4, 1.6, 0.4), house * CFrame.new(x, 0.8, z), DARK_WOOD)
		end
	end
	part(m, "House", Vector3.new(5, 3, 4), house * CFrame.new(0, 3.1, 0), Color3.fromRGB(235, 205, 150), {
		Material = Enum.Material.WoodPlanks,
	})
	for _, side in { -1, 1 } do
		part(
			m,
			"Roof",
			Vector3.new(5.8, 0.3, 2.9),
			house * CFrame.new(0, 5.1, side * 1.2) * CFrame.Angles(side * math.rad(-28), 0, 0),
			BARN_RED
		)
	end
	part(m, "Hatch", Vector3.new(1.2, 1.4, 0.2), house * CFrame.new(0, 2.4, -2.05), DARK_WOOD)
	wedge(m, "Ramp", Vector3.new(1.2, 1.6, 2.6), house * CFrame.new(0, 0.8, -3.4), WOOD)
	-- A low white run in front, with the hens out in it.
	local runW, runD = 9, 6
	local runAt = at * CFrame.new(0, 0, -2.5)
	for _, x in { -1, 1 } do
		part(m, "Run", Vector3.new(0.25, 1.2, runD), runAt * CFrame.new(x * runW / 2, 0.6, 0), WHITE)
	end
	part(m, "Run", Vector3.new(runW, 1.2, 0.25), runAt * CFrame.new(0, 0.6, -runD / 2), WHITE)
	chicken(m, runAt * CFrame.new(-2.5, 0, -1) * CFrame.Angles(0, math.rad(30), 0))
	chicken(m, runAt * CFrame.new(0.5, 0, -1.6) * CFrame.Angles(0, math.rad(-20), 0))
	chicken(m, runAt * CFrame.new(2.6, 0, 0.4) * CFrame.Angles(0, math.rad(200), 0))
end

local function windmill(parent: Instance, at: CFrame)
	local m = model(parent, "Windmill", at)
	local stone = Color3.fromRGB(235, 228, 210)
	column(m, "Tower", 8, 7, at, stone, { Material = Enum.Material.Brick })
	column(m, "Tower", 7, 6, at * CFrame.new(0, 8, 0), stone, { Material = Enum.Material.Brick })
	column(m, "Tower", 6, 5, at * CFrame.new(0, 15, 0), stone, { Material = Enum.Material.Brick })
	column(m, "Cap", 0.6, 6, at * CFrame.new(0, 21, 0), BARN_RED)
	ball(m, "Dome", 5, at * CFrame.new(0, 21.4, 0), BARN_RED, { CanCollide = true })
	part(m, "Door", Vector3.new(1.8, 3, 0.3), at * CFrame.new(0, 1.5, -3.4), DARK_WOOD)
	-- Blades on a hub out front. The client turns this model about its pivot's Z.
	local hubAt = at * CFrame.new(0, 19, -3.4)
	local blades = model(m, "Blades", hubAt)
	local hub = part(blades, "Hub", Vector3.new(1.2, 1.2, 1), hubAt, DARK_WOOD, { CanCollide = false })
	blades.PrimaryPart = hub
	for k = 0, 3 do
		local arm = hubAt * CFrame.Angles(0, 0, math.rad(45 + k * 90))
		part(blades, "Spar", Vector3.new(0.3, 10, 0.3), arm * CFrame.new(0, 5, -0.4), DARK_WOOD, { CanCollide = false })
		part(blades, "Sail", Vector3.new(2.2, 7, 0.12), arm * CFrame.new(1.25, 6, -0.4), WHITE, {
			Material = Enum.Material.Fabric,
			CanCollide = false,
		})
	end
	blades:SetAttribute("SpinSpeed", 0.8) -- radians per second
	CollectionService:AddTag(blades, FarmDecor.SpinTag)
end

local function silo(parent: Instance, at: CFrame)
	local m = model(parent, "Silo", at)
	column(m, "Body", 18, 7, at, STEEL, { Material = Enum.Material.Metal })
	for i = 1, 4 do
		column(m, "Band", 0.4, 7.2, at * CFrame.new(0, i * 3.8, 0), Color3.fromRGB(150, 152, 160), {
			Material = Enum.Material.Metal,
			CanCollide = false,
		})
	end
	ball(m, "Dome", 7, at * CFrame.new(0, 18, 0), STEEL, { Material = Enum.Material.Metal, CanCollide = true })
	part(m, "Ladder", Vector3.new(1, 17, 0.2), at * CFrame.new(0, 8.5, -3.6), Color3.fromRGB(120, 120, 128), {
		CanCollide = false,
	})
end

local function tractor(parent: Instance, at: CFrame)
	local m = model(parent, "Tractor", at)
	local green = Color3.fromRGB(40, 150, 60)
	local yellow = Color3.fromRGB(250, 200, 40)
	local tyre = Color3.fromRGB(35, 35, 38)
	part(m, "Chassis", Vector3.new(6.5, 1.2, 2.6), at * CFrame.new(0, 2.2, 0), green)
	part(m, "Hood", Vector3.new(3.6, 1.8, 2.4), at * CFrame.new(-1.6, 3.6, 0), green)
	part(m, "Grille", Vector3.new(0.2, 1.4, 2), at * CFrame.new(-3.45, 3.5, 0), Color3.fromRGB(60, 60, 60))
	part(m, "Exhaust", Vector3.new(0.3, 2.2, 0.3), at * CFrame.new(-1.8, 5.5, 0.7), Color3.fromRGB(70, 70, 70), {
		CanCollide = false,
	})
	part(m, "Cab", Vector3.new(2.8, 2.8, 2.8), at * CFrame.new(1.7, 4.6, 0), Color3.fromRGB(190, 230, 255), {
		Material = Enum.Material.Glass,
		Transparency = 0.45,
	})
	part(m, "CabRoof", Vector3.new(3.4, 0.35, 3.4), at * CFrame.new(1.7, 6.2, 0), green)
	for _, z in { -1, 1 } do
		wheel(m, 4.4, 1.2, at * CFrame.new(1.8, 2.2, z * 2), tyre)
		wheel(m, 2.2, 1.25, at * CFrame.new(1.8, 2.2, z * 2), yellow)
		wheel(m, 2.4, 0.8, at * CFrame.new(-2.4, 1.2, z * 1.6), tyre)
	end
end

local function wheatField(parent: Instance, at: CFrame, length: number, width: number)
	local m = model(parent, "WheatField", at)
	part(m, "Soil", Vector3.new(length, 0.3, width), at * CFrame.new(0, 0.15, 0), SOIL, {
		Material = Enum.Material.Ground,
		CanCollide = false,
	})
	local rows = math.floor(width / 1.8)
	for i = 0, rows - 1 do
		local z = -width / 2 + 0.9 + i * 1.8
		local tone = if i % 2 == 0 then Color3.fromRGB(236, 200, 92) else Color3.fromRGB(222, 184, 78)
		part(m, "Wheat", Vector3.new(length - 1, 1.8, 1), at * CFrame.new(0, 1.2, z), tone, {
			Material = Enum.Material.Grass,
			CanCollide = false,
		})
	end
end

local function waterTower(parent: Instance, at: CFrame)
	local m = model(parent, "WaterTower", at)
	local legColor = Color3.fromRGB(120, 85, 55)
	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			part(m, "Leg", Vector3.new(0.7, 15, 0.7), at * CFrame.new(x * 3.4, 7.5, z * 3.4), legColor)
		end
		part(m, "Brace", Vector3.new(0.35, 0.35, 7.4), at * CFrame.new(x * 3.4, 7, 0), legColor, { CanCollide = false })
		part(m, "Brace", Vector3.new(7.4, 0.35, 0.35), at * CFrame.new(0, 7, x * 3.4), legColor, { CanCollide = false })
	end
	column(m, "Deck", 0.5, 10, at * CFrame.new(0, 15, 0), legColor)
	column(m, "Tank", 7, 9, at * CFrame.new(0, 15.5, 0), Color3.fromRGB(170, 120, 75), {
		Material = Enum.Material.WoodPlanks,
	})
	for i, dia in { 10, 7.5, 5, 2.5 } do
		column(m, "Roof", 0.9, dia, at * CFrame.new(0, 22.5 + (i - 1) * 0.9, 0), BARN_RED)
	end
	ball(m, "Finial", 1, at * CFrame.new(0, 26.4, 0), GOLD, { Material = Enum.Material.Metal })
	part(m, "Ladder", Vector3.new(1, 15, 0.2), at * CFrame.new(0, 7.5, -3.9), Color3.fromRGB(90, 90, 95), {
		CanCollide = false,
	})
end

local function greenhouse(parent: Instance, at: CFrame)
	local m = model(parent, "Greenhouse", at)
	local length, width, wall = 14, 10, 5.5
	local glass = { Material = Enum.Material.Glass, Transparency = 0.55, CanCollide = true }
	local pane = Color3.fromRGB(200, 240, 255)
	part(m, "Base", Vector3.new(length, 0.4, width), at * CFrame.new(0, 0.2, 0), Color3.fromRGB(200, 200, 195), {
		Material = Enum.Material.Concrete,
	})
	part(m, "Glass", Vector3.new(length, wall, 0.2), at * CFrame.new(0, 0.4 + wall / 2, -width / 2), pane, glass)
	part(m, "Glass", Vector3.new(length, wall, 0.2), at * CFrame.new(0, 0.4 + wall / 2, width / 2), pane, glass)
	for _, x in { -1, 1 } do
		part(m, "Glass", Vector3.new(0.2, wall, width), at * CFrame.new(x * length / 2, 0.4 + wall / 2, 0), pane, glass)
	end
	local rise = 3
	local run = width / 2
	local angle = math.atan2(rise, run)
	local slope = math.sqrt(run * run + rise * rise)
	for _, side in { -1, 1 } do
		part(
			m,
			"RoofGlass",
			Vector3.new(length, 0.2, slope),
			at * CFrame.new(0, 0.4 + wall + rise / 2, side * width / 4) * CFrame.Angles(side * angle, 0, 0),
			pane,
			glass
		)
	end
	-- White frame: corner and middle posts and the ridge.
	for _, x in { -length / 2, 0, length / 2 } do
		for _, z in { -width / 2, width / 2 } do
			part(m, "Frame", Vector3.new(0.35, wall, 0.35), at * CFrame.new(x, 0.4 + wall / 2, z), WHITE)
		end
	end
	part(m, "Ridge", Vector3.new(length + 0.4, 0.35, 0.35), at * CFrame.new(0, 0.4 + wall + rise, 0), WHITE)
	-- Two benches of potted plants and a red flower in every other pot.
	for _, z in { -2.4, 2.4 } do
		part(m, "Bench", Vector3.new(length - 3, 0.3, 2), at * CFrame.new(0, 2.4, z), WOOD)
		for i = 0, 4 do
			local x = -length / 2 + 2.5 + i * 2.25
			column(m, "Pot", 0.9, 1, at * CFrame.new(x, 2.55, z), Color3.fromRGB(190, 100, 60))
			ball(m, "Plant", 1.3, at * CFrame.new(x, 4, z), LEAF)
			if i % 2 == 0 then
				ball(m, "Bloom", 0.6, at * CFrame.new(x, 4.6, z), Color3.fromRGB(240, 70, 110))
			end
		end
	end
end

local function duck(parent: Instance, at: CFrame)
	ball(parent, "DuckBody", 1.4, at * CFrame.new(0, 0.5, 0), Color3.fromRGB(255, 225, 70))
	ball(parent, "DuckHead", 0.9, at * CFrame.new(0, 1.3, -0.5), Color3.fromRGB(255, 225, 70))
	part(parent, "Beak", Vector3.new(0.4, 0.2, 0.5), at * CFrame.new(0, 1.25, -1.05), Color3.fromRGB(250, 140, 30), {
		CanCollide = false,
	})
end

local function pond(parent: Instance, at: CFrame, diameter: number)
	local m = model(parent, "Pond", at)
	part(
		m,
		"Water",
		Vector3.new(0.3, diameter, diameter),
		at * CFrame.new(0, 0.15, 0) * CFrame.Angles(0, 0, math.rad(90)),
		WATER,
		{ Shape = Enum.PartType.Cylinder, Material = Enum.Material.Glass, Transparency = 0.15, CanCollide = false }
	)
	local rocks = 16
	for i = 0, rocks - 1 do
		local a = i / rocks * math.pi * 2
		local r = diameter / 2 + 0.3
		ball(m, "Rock", 1.4 + (i % 3) * 0.5, at * CFrame.new(math.cos(a) * r, 0.3, math.sin(a) * r), STONE, {
			Material = Enum.Material.Slate,
		})
	end
	for _, spot in { Vector2.new(-3, 2), Vector2.new(2.5, 4), Vector2.new(4, -2.5) } do
		part(
			m,
			"LilyPad",
			Vector3.new(0.1, 2.2, 2.2),
			at * CFrame.new(spot.X, 0.36, spot.Y) * CFrame.Angles(0, 0, math.rad(90)),
			Color3.fromRGB(70, 160, 70),
			{ Shape = Enum.PartType.Cylinder, CanCollide = false }
		)
	end
	ball(m, "Lily", 0.6, at * CFrame.new(-3, 0.6, 2), Color3.fromRGB(255, 150, 200))
	duck(m, at * CFrame.new(1, 0.1, -2) * CFrame.Angles(0, math.rad(40), 0))
	duck(m, at * CFrame.new(-1.5, 0.1, -4) * CFrame.Angles(0, math.rad(70), 0))
	-- A little dock out from the walkway side of the bank.
	local dockAt = at * CFrame.new(0, 0, -diameter / 2 + 1)
	part(
		m,
		"Dock",
		Vector3.new(3, 0.35, 7),
		dockAt * CFrame.new(0, 0.8, 0),
		WOOD,
		{ Material = Enum.Material.WoodPlanks }
	)
	for _, x in { -1.3, 1.3 } do
		part(m, "DockPost", Vector3.new(0.4, 1.6, 0.4), dockAt * CFrame.new(x, 0.6, 3.2), DARK_WOOD)
	end
end

local function flowerGarden(parent: Instance, at: CFrame)
	local m = model(parent, "FlowerGarden", at)
	local colors = {
		Color3.fromRGB(255, 90, 120),
		Color3.fromRGB(255, 210, 70),
		Color3.fromRGB(190, 120, 255),
		Color3.fromRGB(255, 150, 60),
		Color3.fromRGB(250, 250, 255),
	}
	-- Beds either side of a path that runs under the arch.
	for _, side in { -1, 1 } do
		for row = 0, 2 do
			local z = 2 + row * 3
			local bedAt = at * CFrame.new(side * 5, 0, z)
			part(m, "Bed", Vector3.new(6, 0.5, 2), bedAt * CFrame.new(0, 0.25, 0), SOIL_DARK, {
				Material = Enum.Material.Ground,
				CanCollide = false,
			})
			for i = 0, 3 do
				local color = colors[(row * 4 + i + (if side > 0 then 2 else 0)) % #colors + 1]
				ball(m, "Flower", 0.9, bedAt * CFrame.new(-2.2 + i * 1.45, 0.9, 0), color)
			end
		end
	end
	part(m, "Path", Vector3.new(3, 0.3, 11), at * CFrame.new(0, 0.15, 4.5), Color3.fromRGB(225, 210, 180), {
		Material = Enum.Material.Pebble,
		CanCollide = false,
	})
	-- A white arch over the path's walkway end, with roses climbing it.
	local archAt = at * CFrame.new(0, 0, -1)
	for _, x in { -2, 2 } do
		part(m, "ArchPost", Vector3.new(0.5, 6, 0.5), archAt * CFrame.new(x, 3, 0), WHITE)
	end
	part(m, "ArchTop", Vector3.new(5, 0.5, 0.6), archAt * CFrame.new(0, 6.6, 0), WHITE)
	for _, x in { -1, 1 } do
		part(
			m,
			"ArchCurve",
			Vector3.new(1.8, 0.5, 0.6),
			archAt * CFrame.new(x * 2.2, 6.2, 0) * CFrame.Angles(0, 0, x * math.rad(-40)),
			WHITE
		)
	end
	for i, y in { 1.5, 3, 4.5, 6 } do
		ball(m, "Rose", 0.6, archAt * CFrame.new(if i % 2 == 0 then -2.3 else 2.3, y, -0.3), colors[1])
	end
	-- A bench to sit and look at it.
	local benchAt = at * CFrame.new(0, 0, 11.5)
	part(m, "Seat", Vector3.new(4, 0.3, 1.2), benchAt * CFrame.new(0, 1.4, 0), WOOD)
	part(m, "Backrest", Vector3.new(4, 1.2, 0.25), benchAt * CFrame.new(0, 2.3, 0.5), WOOD)
	for _, x in { -1.7, 1.7 } do
		part(m, "BenchLeg", Vector3.new(0.3, 1.3, 1), benchAt * CFrame.new(x, 0.65, 0), DARK_WOOD)
	end
end

local function fountain(parent: Instance, at: CFrame)
	local m = model(parent, "GoldenFountain", at)
	column(m, "Basin", 1.4, 18, at, Color3.fromRGB(240, 235, 225), { Material = Enum.Material.Marble })
	column(m, "Pool", 0.2, 16, at * CFrame.new(0, 1.3, 0), WATER, {
		Material = Enum.Material.Glass,
		Transparency = 0.15,
		CanCollide = false,
	})
	column(m, "Stem", 4, 1.6, at * CFrame.new(0, 1.4, 0), GOLD, { Material = Enum.Material.Metal })
	column(m, "Bowl", 0.8, 8, at * CFrame.new(0, 5.4, 0), GOLD, { Material = Enum.Material.Metal })
	column(m, "BowlWater", 0.15, 7, at * CFrame.new(0, 6.15, 0), WATER, {
		Material = Enum.Material.Glass,
		Transparency = 0.15,
		CanCollide = false,
	})
	column(m, "Spire", 2.5, 0.8, at * CFrame.new(0, 6.2, 0), GOLD, { Material = Enum.Material.Metal })
	local top = ball(m, "Crown", 1.6, at * CFrame.new(0, 9.2, 0), GOLD, { Material = Enum.Material.Neon })
	local spray = Instance.new("ParticleEmitter")
	spray.Name = "Spray"
	spray.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	spray.Color = ColorSequence.new(Color3.fromRGB(180, 230, 255), Color3.fromRGB(255, 240, 160))
	spray.Size = NumberSequence.new(0.6, 0.1)
	spray.Lifetime = NumberRange.new(1, 1.4)
	spray.Rate = 25
	spray.Speed = NumberRange.new(8, 10)
	spray.SpreadAngle = Vector2.new(25, 25)
	spray.Acceleration = Vector3.new(0, -18, 0)
	spray.LightEmission = 0.6
	spray.Parent = top
	local glow = Instance.new("PointLight")
	glow.Color = GOLD
	glow.Range = 16
	glow.Brightness = 1.5
	glow.Parent = top
end

local function balloon(parent: Instance, at: CFrame)
	local lift = at * CFrame.new(0, 42, 0)
	local m = model(parent, "HotAirBalloon", lift)
	local envelope = ball(m, "Envelope", 15, lift * CFrame.new(0, 9, 0), Color3.fromRGB(240, 70, 80), {
		Material = Enum.Material.Fabric,
	})
	m.PrimaryPart = envelope
	-- Bands around the envelope, a little proud so they show as stripes.
	column(m, "Band", 1.6, 15.2, lift * CFrame.new(0, 8.2, 0), Color3.fromRGB(255, 220, 70), {
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	column(m, "Band", 1.2, 13.2, lift * CFrame.new(0, 12.3, 0), Color3.fromRGB(80, 160, 255), {
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	column(m, "Band", 1.2, 13.2, lift * CFrame.new(0, 3.9, 0), Color3.fromRGB(80, 160, 255), {
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	column(m, "Skirt", 2, 5, lift * CFrame.new(0, 1.2, 0), Color3.fromRGB(240, 70, 80), {
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	part(m, "Basket", Vector3.new(3, 2.2, 3), lift * CFrame.new(0, -4, 0), Color3.fromRGB(170, 120, 60), {
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			local from = Vector3.new(x * 1.4, -2.9, z * 1.4)
			local to = Vector3.new(x * 2.2, 1.2, z * 2.2)
			local length = (to - from).Magnitude
			part(
				m,
				"Rope",
				Vector3.new(0.12, 0.12, length),
				lift * CFrame.lookAt((from + to) / 2, to),
				Color3.fromRGB(90, 70, 50),
				{ CanCollide = false }
			)
		end
	end
	local flame =
		part(m, "Flame", Vector3.new(0.8, 1.4, 0.8), lift * CFrame.new(0, -1.8, 0), Color3.fromRGB(255, 160, 40), {
			Material = Enum.Material.Neon,
			CanCollide = false,
		})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 170, 60)
	light.Range = 10
	light.Parent = flame
	CollectionService:AddTag(m, FarmDecor.BobTag)
end

local function flag(parent: Instance, at: CFrame, color: Color3)
	local m = model(parent, "Flag", at)
	part(m, "Pole", Vector3.new(0.5, 18, 0.5), at * CFrame.new(0, 9, 0), WHITE, { Material = Enum.Material.Metal })
	ball(m, "Finial", 1, at * CFrame.new(0, 18.4, 0), GOLD, { Material = Enum.Material.Metal })
	part(m, "Banner", Vector3.new(0.15, 3.6, 6), at * CFrame.new(0, 15.8, 3.2), color, {
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	part(m, "BannerStripe", Vector3.new(0.2, 0.6, 6), at * CFrame.new(0, 15.8, 3.2), GOLD, {
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
end

local function trophy(parent: Instance, at: CFrame)
	local m = model(parent, "GoldenTrophy", at)
	part(m, "Plinth", Vector3.new(7, 3, 7), at * CFrame.new(0, 1.5, 0), Color3.fromRGB(240, 235, 225), {
		Material = Enum.Material.Marble,
	})
	part(
		m,
		"PlinthTrim",
		Vector3.new(7.4, 0.4, 7.4),
		at * CFrame.new(0, 3.2, 0),
		GOLD,
		{ Material = Enum.Material.Metal }
	)
	local metal = { Material = Enum.Material.Metal }
	column(m, "Foot", 0.8, 4, at * CFrame.new(0, 3.4, 0), GOLD, metal)
	column(m, "Stem", 3, 1.2, at * CFrame.new(0, 4.2, 0), GOLD, metal)
	column(m, "Cup", 5, 5, at * CFrame.new(0, 7.2, 0), GOLD, metal)
	column(m, "Rim", 0.5, 5.6, at * CFrame.new(0, 12, 0), GOLD, metal)
	for _, x in { -1, 1 } do
		part(m, "Handle", Vector3.new(1.6, 0.5, 0.5), at * CFrame.new(x * 3.2, 11, 0), GOLD, metal)
		part(m, "Handle", Vector3.new(0.5, 3, 0.5), at * CFrame.new(x * 3.8, 9.7, 0), GOLD, metal)
		part(m, "Handle", Vector3.new(1.4, 0.5, 0.5), at * CFrame.new(x * 3.3, 8.3, 0), GOLD, metal)
	end
	local star = ball(m, "Star", 1.6, at * CFrame.new(0, 13.4, 0), Color3.fromRGB(255, 240, 150), {
		Material = Enum.Material.Neon,
	})
	local glow = Instance.new("PointLight")
	glow.Color = GOLD
	glow.Range = 14
	glow.Brightness = 1.2
	glow.Parent = star
end

-- Levels -------------------------------------------------------------------------------
-- Left is +lateral (the gear shop and showcase side), right is -lateral (the wash and Robux
-- side). Side strips run from the plaza to the giant pens, outside every pen (|lateral| > 26).

local LEVELS: { (Instance, PlotLayout.PlotFrame) -> () } = {
	-- 0 Homestead
	function(m, plot)
		veggiePatch(m, site(plot, 78, 38), 22)
		scarecrow(m, site(plot, 78, 48))
		hayStack(m, site(plot, 80, -36))
		cart(m, site(plot, 84, -50) * CFrame.Angles(0, math.rad(20), 0))
		mailbox(m, site(plot, 3, 54, plot.Look))
	end,
	-- 1 Barnyard
	function(m, plot)
		barn(m, site(plot, 109, -44), 22, 16, 11)
		chickenCoop(m, site(plot, 104, 40))
	end,
	-- 2 Windmill
	function(m, plot)
		windmill(m, site(plot, 124, 48))
		silo(m, site(plot, 129, -42))
	end,
	-- 3 Harvest
	function(m, plot)
		tractor(m, site(plot, 142, -36) * CFrame.Angles(0, math.rad(90), 0))
		wheatField(m, site(plot, 168, 43), 54, 26)
		waterTower(m, site(plot, 186, -46))
	end,
	-- 4 Garden
	function(m, plot)
		greenhouse(m, site(plot, 158, -46) * CFrame.Angles(0, math.rad(90), 0))
		pond(m, site(plot, 330, -28, plot.Look), 26)
		flowerGarden(m, site(plot, 322, 28, plot.Look))
	end,
	-- 5 Golden
	function(m, plot)
		fountain(m, site(plot, 312, 0, plot.Look))
		balloon(m, site(plot, 362, 14))
		local royal = Color3.fromRGB(132, 86, 214)
		flag(m, site(plot, 2, 58, plot.Look), royal)
		flag(m, site(plot, 2, -58, plot.Look), royal)
		flag(m, site(plot, 300, 58, plot.Look), royal)
		flag(m, site(plot, 300, -58, plot.Look), royal)
		trophy(m, site(plot, 219, 46))
		-- The level 1 barn also gets a golden weathervane (FarmDecor.apply).
	end,
}

-- New scenery rises out of the ground, so an upgrade is seen happening.
local function rise(level: Model)
	local finalPivot = level:GetPivot()
	local _, size = level:GetBoundingBox()
	local drop = math.min(size.Y + 1, 40)
	local value = Instance.new("NumberValue")
	value.Value = 0
	local start = finalPivot * CFrame.new(0, -drop, 0)
	level:PivotTo(start)
	local connection = value.Changed:Connect(function(alpha: number)
		if level.Parent then
			level:PivotTo(start:Lerp(finalPivot, alpha))
		end
	end)
	local tween = TweenService:Create(value, TweenInfo.new(1.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Value = 1,
	})
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if level.Parent then
			level:PivotTo(finalPivot)
		end
	end)
	tween:Play()
end

local function buildLevel(folder: Instance, plot: PlotLayout.PlotFrame, level: number): Model
	local m = Instance.new("Model")
	m.Name = "Level" .. level
	m:SetAttribute("FarmLevel", level)
	m.WorldPivot = CFrame.new(plot.Anchor)
	LEVELS[level + 1](m, plot)
	-- Buildings grow about their own ground pivot; the flat plots stay their size to keep
	-- clear of the pens.
	for _, prop in m:GetChildren() do
		if prop:IsA("Model") and not FLAT[prop.Name] then
			prop:ScaleTo(PROP_SCALE)
		end
	end
	m.Parent = folder
	return m
end

-- Shows exactly the scenery for `level` on a bay: builds the sets it's missing and removes
-- any above it (only the dev level keys ever go down). `animate` lifts the new sets out of
-- the ground, for a live upgrade.
function FarmDecor.apply(bay: Model, level: number, animate: boolean?)
	local index = bay:GetAttribute("BayIndex")
	if typeof(index) ~= "number" then
		return
	end
	level = math.clamp(math.floor(level), 0, FarmDecor.MaxLevel)
	local plot = PlotLayout.frame(index)
	local folder = bay:FindFirstChild(FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER
		folder.Parent = bay
	end
	for n = 0, FarmDecor.MaxLevel do
		local existing = folder:FindFirstChild("Level" .. n)
		if n <= level and not existing and LEVELS[n + 1] then
			local built = buildLevel(folder, plot, n)
			if animate and RunService:IsRunning() then
				rise(built)
			end
		elseif n > level and existing then
			existing:Destroy()
		end
	end
	-- The top level crowns the barn with a golden weathervane.
	local barnModel = folder:FindFirstChild("Level1")
	local barnShell = barnModel and barnModel:FindFirstChild("Barn")
	local vane = barnShell and barnShell:FindFirstChild("Vane")
	if barnShell and barnShell:IsA("Model") then
		if level >= FarmDecor.MaxLevel and not vane then
			local vaneModel = Instance.new("Model")
			vaneModel.Name = "Vane"
			local _, size = barnShell:GetBoundingBox()
			local top = barnShell:GetPivot() * CFrame.new(0, size.Y + 0.2, 0)
			part(vaneModel, "VanePole", Vector3.new(0.25, 3, 0.25), top * CFrame.new(0, 1.5, 0), GOLD, {
				CanCollide = false,
			})
			part(vaneModel, "VaneArrow", Vector3.new(0.2, 0.35, 3), top * CFrame.new(0, 2.6, 0), GOLD, {
				CanCollide = false,
			})
			ball(vaneModel, "VaneBall", 0.7, top * CFrame.new(0, 3.2, 0), GOLD, { Material = Enum.Material.Neon })
			vaneModel.Parent = barnShell
		elseif level < FarmDecor.MaxLevel and vane then
			vane:Destroy()
		end
	end
	bay:SetAttribute("FarmLevel", level)
end

return FarmDecor
