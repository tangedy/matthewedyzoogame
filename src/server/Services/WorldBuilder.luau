-- Builds one farm when a player is given a plot, and destroys it when they leave.
-- Slots 1-4 are east of the road, 5-8 west. Each plot faces the road and grows backward:
--   square wash lane -> cache on the parallel dirt road -> wide path -> cages -> barns.
--
-- Each bay exposes:
--   Approach, TurnIn, WashPosition, Queue2, Queue3, RoadReturn, Exit
--   Spawn                          the owner's SpawnLocation
--   SignPost.Sign.BayLabel         owner name
--   UpgradeStation.Counter         hose shop prompt
--   Cache.Slot{i}                  where washed animals wait (PickupPrompt, SellPrompt)
--   Zoo.Pen{i}                     Floor, Slot, GatePost.PenPrompt, CollectPad (+ Cash label)
--   Zoo.ExpandCounter              barn upgrade, beside the path entrance
--   Zoo.BarnSmall / BarnMedium / BarnLarge / BarnGargantuan

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlotLayout = require(ReplicatedStorage.Shared.PlotLayout)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local WorldBuilder = {}

local folder: Folder

local FLOOR_Y = 0.5
local WOOD = Color3.fromRGB(150, 110, 70)
local WOOD_DARK = Color3.fromRGB(110, 75, 45)

-- Depths measured from the road edge, away from the street.
-- The queue is a straight lane in from the road. The wash road runs parallel to the
-- main road at the wash depth, and the cache is further along that road.
local ROAD_D = -8
local QUEUE_DEPTH = { 40, 28, 16 } -- 1 is the wash, furthest in; 3 is the back of the queue
local CACHE_LAT = 18
local WALK_START = 58
local STALL_DEPTH = 8 -- half the old 16
local STALL_LAT = 7 -- half the old 14
local STALL_PITCH = 14
local STALL_LATERAL = GameConfig.SidewalkWidth / 2 + 4 + STALL_LAT / 2
local WALK_END = WALK_START + 8 + STALL_DEPTH / 2 + 2 * STALL_PITCH + STALL_DEPTH / 2 + 8

local BARN_FRONT = WALK_END + 8
local MED_DEPTH = 26
local MED_LAT = 22
local MED_PITCH = MED_DEPTH + 8
local ROW_DEPTH = {
	BARN_FRONT + 8 + MED_DEPTH / 2,
	0,
}
ROW_DEPTH[2] = ROW_DEPTH[1] + MED_PITCH
local BARN_BACK = ROW_DEPTH[2] + MED_DEPTH / 2 + 8
local OUTER_LATERAL = STALL_LATERAL + STALL_LAT / 2 + 3 + MED_LAT / 2

local LARGE_FRONT = BARN_BACK + 12
local GIANT_DEPTH = 36
local GIANT_LAT = 32
local LARGE_DEPTH = 26
local LARGE_LAT = 22
local LARGE_CENTER = LARGE_FRONT + 8 + GIANT_DEPTH / 2
local LARGE_BACK = LARGE_CENTER + GIANT_DEPTH / 2 + 8
local LARGE_SIDE = GIANT_LAT / 2 + 4 + LARGE_LAT / 2

local GARG_FRONT = LARGE_BACK + 12
local GARG_DEPTH = 48
local GARG_LAT = 44
local GARG_CENTER = GARG_FRONT + 8 + GARG_DEPTH / 2
local GARG_BACK = GARG_CENTER + GARG_DEPTH / 2 + 8
-- The pair is centred: giant on the left of the plot, gargantuan on the right.
local GARG_SPAN = GIANT_LAT + 6 + GARG_LAT
local GARG_GIANT_LAT = -GARG_SPAN / 2 + GIANT_LAT / 2
local GARG_PEN_LAT = GARG_GIANT_LAT + GIANT_LAT / 2 + 6 + GARG_LAT / 2

local function makePart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		(part :: any)[key] = value
	end
	part:SetAttribute("LayoutPart", true)
	part:SetAttribute("RestTransparency", part.Transparency)
	part:SetAttribute("RestCollide", part.CanCollide)
	part:SetAttribute("RestTouch", part.CanTouch)
	part:SetAttribute("RestQuery", part.CanQuery)
	return part
end

local function makeMarker(name: string, cframe: CFrame, parent: Instance): Part
	return makePart({
		Name = name,
		Size = Vector3.new(1, 1, 1),
		CFrame = cframe,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = parent,
	})
end

local function stampDecor(inst: Instance, enabled: boolean)
	inst:SetAttribute("LayoutDecor", true)
	inst:SetAttribute("RestEnabled", enabled)
end

local function makePrompt(
	name: string,
	action: string,
	hold: number,
	parent: Instance,
	key: Enum.KeyCode?
): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = action
	prompt.HoldDuration = hold
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = key or Enum.KeyCode.E
	prompt.Parent = parent
	stampDecor(prompt, prompt.Enabled)
	return prompt
end

local function billboardLabel(
	adornee: BasePart,
	text: string,
	offset: Vector3,
	size: Vector2,
	color: Color3?
): TextLabel
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(size.X, size.Y)
	billboard.StudsOffset = offset
	billboard.MaxDistance = 50
	billboard.Parent = adornee
	stampDecor(billboard, true)
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = billboard
	UIStyle.text(label, color)
	label.Text = text
	return label
end

-- Shows or hides a pen or barn shell. Only parts stamped at build time move, so an
-- animal standing in the pen is left alone.
function WorldBuilder.setShown(root: Instance, shown: boolean)
	for _, d in root:GetDescendants() do
		if d:GetAttribute("LayoutPart") == true and d:IsA("BasePart") then
			if shown then
				d.Transparency = d:GetAttribute("RestTransparency") :: number
				d.CanCollide = d:GetAttribute("RestCollide") == true
				d.CanTouch = d:GetAttribute("RestTouch") == true
				d.CanQuery = d:GetAttribute("RestQuery") == true
			else
				d.Transparency = 1
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
			end
		elseif d:GetAttribute("LayoutDecor") == true then
			local enabled = shown and d:GetAttribute("RestEnabled") == true
			if d:IsA("ProximityPrompt") or d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("Light") then
				d.Enabled = enabled
			end
		end
	end
end

local function ensureGround()
	local ground = Workspace:FindFirstChild("Baseplate") or Workspace:FindFirstChild("Ground")
	if ground and ground:IsA("BasePart") then
		ground.Size = GameConfig.GroundSize
		ground.Position = Vector3.new(0, -GameConfig.GroundSize.Y / 2, 0)
		return
	end
	makePart({
		Name = "Ground",
		Size = GameConfig.GroundSize,
		Position = Vector3.new(0, -GameConfig.GroundSize.Y / 2, 0),
		Color = Color3.fromRGB(106, 168, 79),
		Material = Enum.Material.Grass,
		Parent = Workspace,
	})
end

local function buildUpgradeStation(plot: PlotLayout.PlotFrame, parent: Instance)
	local station = Instance.new("Model")
	station.Name = "UpgradeStation"
	local base = PlotLayout.point(plot, 24, -30, 0)
	local counter = makePart({
		Name = "Counter",
		Size = Vector3.new(3, 3, 6),
		Position = base + Vector3.new(0, 1.5, 0),
		Color = Color3.fromRGB(60, 150, 230),
		Material = Enum.Material.SmoothPlastic,
		Parent = station,
	})
	makePart({
		Name = "Awning",
		Size = Vector3.new(4, 0.4, 7),
		Position = base + Vector3.new(0, 6.5, 0),
		Color = Color3.fromRGB(255, 210, 70),
		CanQuery = false,
		Parent = station,
	})
	local prompt = makePrompt("UpgradePrompt", "Upgrade Hose", 0, counter)
	prompt.ObjectText = "Hose Shop"
	station.Parent = parent
end

local function buildCache(plot: PlotLayout.PlotFrame, bay: Model)
	local cache = Instance.new("Folder")
	cache.Name = "Cache"
	local pos = PlotLayout.point(plot, QUEUE_DEPTH[1], CACHE_LAT, FLOOR_Y)
	-- Faces along the wash road, the direction the animal walked. It does not turn around.
	local facing = CFrame.lookAt(pos, pos + plot.Right)
	makePart({
		Name = "CacheFloor",
		Size = Vector3.new(10, 0.4, 10),
		Position = pos,
		Color = Color3.fromRGB(230, 190, 120),
		Material = Enum.Material.WoodPlanks,
		CanQuery = false,
		Parent = cache,
	})
	local slot = makeMarker("Slot1", facing, cache)
	slot:SetAttribute("SlotIndex", 1)
	makePrompt("PickupPrompt", "Pick up", 0, slot).Enabled = false
	local sell = makePrompt("SellPrompt", "Sell", 1.5, slot, Enum.KeyCode.F)
	sell.UIOffset = Vector2.new(0, -110)
	sell.GamepadKeyCode = Enum.KeyCode.ButtonY
	sell.Enabled = false
	cache.Parent = bay
end

local function addPenPrompts(
	plot: PlotLayout.PlotFrame,
	pen: Model,
	depth: number,
	lateral: number,
	look: Vector3,
	reach: number
)
	local slotPos = PlotLayout.point(plot, depth, lateral, FLOOR_Y)
	makeMarker("Slot", CFrame.lookAt(slotPos, slotPos + look), pen)
	local gate = slotPos + look * reach
	makeMarker("Gate", CFrame.lookAt(gate, gate + look), pen)
	local post = makePart({
		Name = "GatePost",
		Size = Vector3.new(0.6, 3.5, 0.6),
		Position = gate + Vector3.new(0, 1.75, 0) + plot.Right * 1.6,
		Color = Color3.fromRGB(240, 240, 240),
		Parent = pen,
	})
	makePrompt("PenPrompt", "Sell", 1, post).Enabled = false
	-- Collect pad sits on the path in front of the cage, not inside it.
	local facingRoad = math.abs(look:Dot(plot.Look)) > 0.5
	local padPos
	if facingRoad then
		padPos = gate + look * 2.2
	else
		local sign = if lateral >= 0 then 1 else -1
		padPos = PlotLayout.point(plot, depth, sign * (GameConfig.SidewalkWidth / 2 - 3.5), 0.3)
	end
	local pad = makePart({
		Name = "CollectPad",
		Size = Vector3.new(3.2, 0.3, 3.2),
		Position = padPos + Vector3.new(0, 0.15, 0),
		Color = Color3.fromRGB(80, 220, 90),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = pen,
	})
	local cash = billboardLabel(pad, "", Vector3.new(0, 2.6, 0), Vector2.new(170, 44), UIStyle.CashColor);
	(cash.Parent :: Instance).Name = "Cash"
	local glow = Instance.new("PointLight")
	glow.Color = UIStyle.CashColor
	glow.Brightness = 1.2
	glow.Range = 7
	glow.Parent = pad
	stampDecor(glow, true)
	CollectionService:AddTag(pad, "CollectPad")
end

local function buildFencedPen(
	plot: PlotLayout.PlotFrame,
	pen: Model,
	depth: number,
	lateral: number,
	depthSize: number,
	latSize: number,
	look: Vector3
)
	local pos = PlotLayout.point(plot, depth, lateral, 0)
	local floor = makePart({
		Name = "Floor",
		Size = Vector3.new(depthSize, 1, latSize),
		Position = pos,
		Color = Color3.fromRGB(120, 170, 80),
		Material = Enum.Material.Grass,
		Parent = pen,
	})
	local h = math.clamp(latSize * 0.28, 3.5, 8)
	local y = h / 2
	local halfD, halfL = depthSize / 2, latSize / 2
	local gate = if math.min(depthSize, latSize) <= 10 then 3 else 4
	-- Back and sides are solid. The front, toward `look`, is split around a gate.
	-- Front is the side the look vector leaves through. look is either Â±Right (a side
	-- pen) or Look (a pen facing the road). Both are axis-aligned, so the front wall
	-- is the thin face on that axis.
	local facingRoad = math.abs(look:Dot(plot.Look)) > 0.5
	if facingRoad then
		local frontDepth = depth - halfD
		makePart({
			Name = "Fence",
			Size = Vector3.new(0.4, h, latSize),
			Position = PlotLayout.point(plot, depth + halfD, lateral, y),
			Color = WOOD,
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = pen,
		})
		for _, edge in { -1, 1 } do
			makePart({
				Name = "Fence",
				Size = Vector3.new(depthSize, h, 0.4),
				Position = PlotLayout.point(plot, depth, lateral + edge * halfL, y),
				Color = WOOD,
				Material = Enum.Material.Wood,
				CanQuery = false,
				Parent = pen,
			})
		end
		local sideW = (latSize - gate) / 2
		for _, edge in { -1, 1 } do
			makePart({
				Name = "Fence",
				Size = Vector3.new(0.4, h, sideW),
				Position = PlotLayout.point(plot, frontDepth, lateral + edge * (gate / 2 + sideW / 2), y),
				Color = WOOD,
				Material = Enum.Material.Wood,
				CanQuery = false,
				Parent = pen,
			})
		end
	else
		local sign = if lateral >= 0 then 1 else -1
		local frontLat = lateral - sign * halfL
		makePart({
			Name = "Fence",
			Size = Vector3.new(depthSize, h, 0.4),
			Position = PlotLayout.point(plot, depth, lateral + sign * halfL, y),
			Color = WOOD,
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = pen,
		})
		for _, edge in { -1, 1 } do
			makePart({
				Name = "Fence",
				Size = Vector3.new(0.4, h, latSize),
				Position = PlotLayout.point(plot, depth + edge * halfD, lateral, y),
				Color = WOOD,
				Material = Enum.Material.Wood,
				CanQuery = false,
				Parent = pen,
			})
		end
		local sideW = (depthSize - gate) / 2
		for _, edge in { -1, 1 } do
			makePart({
				Name = "Fence",
				Size = Vector3.new(sideW, h, 0.4),
				Position = PlotLayout.point(plot, depth + edge * (gate / 2 + sideW / 2), frontLat, y),
				Color = WOOD,
				Material = Enum.Material.Wood,
				CanQuery = false,
				Parent = pen,
			})
		end
	end
	local status = billboardLabel(floor, "", Vector3.new(0, 4, 0), Vector2.new(80, 18))
	local stroke = status:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = 1.25
	end
	(status.Parent :: Instance).Name = "Status"
	local reach = if facingRoad then depthSize / 2 + 2 else latSize / 2 + 2
	addPenPrompts(plot, pen, depth, lateral, look, reach)
end

local buildBarns: (plot: PlotLayout.PlotFrame, zoo: Folder) -> ()

local function inwardLook(plot: PlotLayout.PlotFrame, lateral: number): Vector3
	return if lateral >= 0 then -plot.Right else plot.Right
end

local function buildZoo(plot: PlotLayout.PlotFrame, bay: Model)
	local zoo = Instance.new("Folder")
	zoo.Name = "Zoo"

	local function addPen(index: number, depth: number, lateral: number, depthSize: number, latSize: number, class: string)
		local pen = Instance.new("Model")
		pen.Name = "Pen" .. index
		pen:SetAttribute("PenIndex", index)
		pen:SetAttribute("PenClass", class)
		local look = if class == "Giant" or class == "Gargantuan" or class == "Large"
			then if math.abs(lateral) < 1 then plot.Look else inwardLook(plot, lateral)
			else inwardLook(plot, lateral)
		buildFencedPen(plot, pen, depth, lateral, depthSize, latSize, look)
		pen.Parent = zoo
		if index > GameConfig.Zoo.StartPens then
			WorldBuilder.setShown(pen, false)
		end
	end

	-- Six cages, three on each side of the path. Front of the row is nearest the road.
	local stallDepth0 = WALK_START + 8 + STALL_DEPTH / 2
	for row = 0, 2 do
		local depth = stallDepth0 + row * STALL_PITCH
		local left = row * 2 + 1
		local right = left + 1
		addPen(left, depth, -STALL_LATERAL, STALL_DEPTH, STALL_LAT, "Standard")
		addPen(right, depth, STALL_LATERAL, STALL_DEPTH, STALL_LAT, "Standard")
	end

	-- Small barn: two standard pens each side. Medium adds a wider column each side.
	for row = 1, 2 do
		local depth = ROW_DEPTH[row]
		local left = 6 + row * 2 - 1 -- 7, 9
		local right = left + 1 -- 8, 10
		addPen(left, depth, -STALL_LATERAL, STALL_DEPTH, STALL_LAT, "Standard")
		addPen(right, depth, STALL_LATERAL, STALL_DEPTH, STALL_LAT, "Standard")
		local outerLeft = 10 + row * 2 - 1 -- 11, 13
		local outerRight = outerLeft + 1
		addPen(outerLeft, depth, -OUTER_LATERAL, MED_DEPTH, MED_LAT, "Medium")
		addPen(outerRight, depth, OUTER_LATERAL, MED_DEPTH, MED_LAT, "Medium")
	end

	-- Large barn, one rank behind: giant in the middle, a large pen on each side.
	addPen(15, LARGE_CENTER, 0, GIANT_DEPTH, GIANT_LAT, "Giant")
	addPen(16, LARGE_CENTER, -LARGE_SIDE, LARGE_DEPTH, LARGE_LAT, "Large")
	addPen(17, LARGE_CENTER, LARGE_SIDE, LARGE_DEPTH, LARGE_LAT, "Large")

	-- Gargantuan barn, further back: one more giant and one gargantuan pen.
	addPen(18, GARG_CENTER, GARG_GIANT_LAT, GIANT_DEPTH, GIANT_LAT, "Giant")
	addPen(19, GARG_CENTER, GARG_PEN_LAT, GARG_DEPTH, GARG_LAT, "Gargantuan")

	-- Barn upgrade, beside the mouth of the sidewalk.
	local stand = PlotLayout.point(plot, WALK_START, -(GameConfig.SidewalkWidth / 2 + 7), 0)
	local counter = makePart({
		Name = "ExpandCounter",
		Size = Vector3.new(3, 3, 5),
		Position = stand + Vector3.new(0, 1.5, 0),
		Color = Color3.fromRGB(120, 170, 80),
		Parent = zoo,
	})
	makePart({
		Name = "Awning",
		Size = Vector3.new(4, 0.4, 6),
		Position = stand + Vector3.new(0, 5.2, 0),
		Color = Color3.fromRGB(200, 60, 50),
		CanQuery = false,
		Parent = zoo,
	})
	billboardLabel(counter, "BARN", Vector3.new(0, 4.2, 0), Vector2.new(160, 36))
	makePrompt("ExpandPrompt", "Expand Zoo", 0.5, counter).ObjectText = "Barn Upgrade"

	buildBarns(plot, zoo)
	zoo.Parent = bay
end

local function barnBox(
	plot: PlotLayout.PlotFrame,
	parent: Instance,
	depth0: number,
	depth1: number,
	halfLat: number,
	height: number,
	wall: Color3,
	roof: Color3
)
	local mid = (depth0 + depth1) / 2
	local span = depth1 - depth0
	local y = height / 2
	for _, side in { -1, 1 } do
		makePart({
			Name = "Wall",
			Size = Vector3.new(span, height, 1.2),
			Position = PlotLayout.point(plot, mid, side * halfLat, y),
			Color = wall,
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = parent,
		})
	end
	makePart({
		Name = "Wall",
		Size = Vector3.new(1.2, height, halfLat * 2),
		Position = PlotLayout.point(plot, depth1, 0, y),
		Color = wall,
		Material = Enum.Material.Wood,
		CanQuery = false,
		Parent = parent,
	})
	local doorW = 8
	local doorH = math.min(10, height - 3)
	local sideW = (halfLat * 2 - doorW) / 2
	for _, side in { -1, 1 } do
		makePart({
			Name = "Wall",
			Size = Vector3.new(1.2, height, sideW),
			Position = PlotLayout.point(plot, depth0, side * (doorW / 2 + sideW / 2), y),
			Color = wall,
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = parent,
		})
	end
	local lintel = height - doorH
	makePart({
		Name = "Wall",
		Size = Vector3.new(1.2, lintel, doorW),
		Position = PlotLayout.point(plot, depth0, 0, doorH + lintel / 2),
		Color = wall,
		Material = Enum.Material.Wood,
		CanQuery = false,
		Parent = parent,
	})
	-- Aisle floor, so the barn reads as a building even before its pens are noticed.
	makePart({
		Name = "Aisle",
		Size = Vector3.new(span, 0.3, GameConfig.SidewalkWidth),
		Position = PlotLayout.point(plot, mid, 0, 0.15),
		Color = Color3.fromRGB(190, 175, 150),
		Material = Enum.Material.Cobblestone,
		CanQuery = false,
		Parent = parent,
	})
	local panel = (halfLat + 1.5) / math.cos(math.rad(28))
	for _, side in { -1, 1 } do
		local center = PlotLayout.point(plot, mid, side * halfLat * 0.5, height + 1.2)
		makePart({
			Name = "Roof",
			Size = Vector3.new(span + 2, 0.8, panel),
			CFrame = CFrame.new(center) * CFrame.Angles(side * math.rad(-28), 0, 0),
			Color = roof,
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = parent,
		})
	end
end

function buildBarns(plot: PlotLayout.PlotFrame, zoo: Folder)
	local red = Color3.fromRGB(200, 60, 50)
	local redDark = Color3.fromRGB(120, 45, 40)
	local shells = {
		{
			Name = "BarnSmall",
			Depth0 = BARN_FRONT,
			Depth1 = BARN_BACK,
			Half = STALL_LATERAL + STALL_LAT / 2 + 2,
			Height = 14,
			Wall = red,
			Roof = redDark,
		},
		{
			Name = "BarnMedium",
			Depth0 = BARN_FRONT,
			Depth1 = BARN_BACK,
			Half = OUTER_LATERAL + MED_LAT / 2 + 2,
			Height = 16,
			Wall = Color3.fromRGB(180, 70, 50),
			Roof = Color3.fromRGB(90, 50, 40),
		},
		{
			Name = "BarnLarge",
			Depth0 = LARGE_FRONT,
			Depth1 = LARGE_BACK,
			Half = LARGE_SIDE + LARGE_LAT / 2 + 2,
			Height = 20,
			Wall = Color3.fromRGB(150, 55, 45),
			Roof = WOOD_DARK,
		},
		{
			Name = "BarnGargantuan",
			Depth0 = GARG_FRONT,
			Depth1 = GARG_BACK,
			Half = GARG_SPAN / 2 + 2,
			Height = 28,
			Wall = Color3.fromRGB(120, 70, 50),
			Roof = Color3.fromRGB(70, 45, 35),
		},
	}
	for _, spec in shells do
		local model = Instance.new("Model")
		model.Name = spec.Name
		barnBox(plot, model, spec.Depth0, spec.Depth1, spec.Half, spec.Height, spec.Wall, spec.Roof)
		model.Parent = zoo
		WorldBuilder.setShown(model, false)
	end
end

local function buildWash(plot: PlotLayout.PlotFrame, bay: Model)
	local laneSpan = QUEUE_DEPTH[1] - ROAD_D
	-- Inward lane: off the main road, a bit in, where the queue stands.
	makePart({
		Name = "QueueLane",
		Size = Vector3.new(laneSpan, 0.25, 12),
		Position = PlotLayout.point(plot, ROAD_D + laneSpan / 2, 0, 0.14),
		Color = Color3.fromRGB(196, 154, 96),
		Material = Enum.Material.Ground,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	-- Wash road, parallel to the main road. The animal turns onto it and walks forward to the cache.
	local roadSpan = CACHE_LAT + 16
	makePart({
		Name = "WashRoad",
		Size = Vector3.new(12, 0.25, roadSpan),
		Position = PlotLayout.point(plot, QUEUE_DEPTH[1], roadSpan / 2 - 4, 0.16),
		Color = Color3.fromRGB(186, 142, 86),
		Material = Enum.Material.Ground,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	makePart({
		Name = "Drain",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.15, 8, 8),
		CFrame = CFrame.new(PlotLayout.point(plot, QUEUE_DEPTH[1], 0, FLOOR_Y + 0.05)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(90, 140, 190),
		CanCollide = false,
		CanQuery = false,
		Parent = bay,
	})
	local function alongRoad(depth: number, lateral: number): CFrame
		local pos = PlotLayout.point(plot, depth, lateral, FLOOR_Y)
		return CFrame.lookAt(pos, pos + plot.Right)
	end
	makeMarker("Approach", alongRoad(ROAD_D, -40), bay)
	makeMarker("TurnIn", alongRoad(ROAD_D, 0), bay)
	makeMarker("WashPosition", PlotLayout.inbound(plot, QUEUE_DEPTH[1], 0, FLOOR_Y), bay)
	makeMarker("Queue2", PlotLayout.inbound(plot, QUEUE_DEPTH[2], 0, FLOOR_Y), bay)
	makeMarker("Queue3", PlotLayout.inbound(plot, QUEUE_DEPTH[3], 0, FLOOR_Y), bay)
	makeMarker("Entrance", alongRoad(ROAD_D, -16), bay)
	local back = PlotLayout.point(plot, ROAD_D, CACHE_LAT, FLOOR_Y)
	makeMarker("RoadReturn", CFrame.lookAt(back, back + plot.Look), bay)
	makeMarker("Exit", CFrame.lookAt(back, back + plot.Look), bay)
end

local function buildSidewalk(plot: PlotLayout.PlotFrame, bay: Model)
	local span = WALK_END - WALK_START
	makePart({
		Name = "Sidewalk",
		Size = Vector3.new(span, 0.35, GameConfig.SidewalkWidth),
		Position = PlotLayout.point(plot, (WALK_START + WALK_END) / 2, 0, 0.18),
		Color = Color3.fromRGB(190, 175, 150),
		Material = Enum.Material.Cobblestone,
		CanQuery = false,
		Parent = bay,
	})
end

function WorldBuilder.buildBay(index: number): Model
	local plot = PlotLayout.frame(index)
	local bay = Instance.new("Model")
	bay.Name = "Bay" .. index

	buildWash(plot, bay)
	buildCache(plot, bay)
	buildSidewalk(plot, bay)
	buildUpgradeStation(plot, bay)
	buildZoo(plot, bay)

	local spawnPos = PlotLayout.point(plot, 50, -22, FLOOR_Y)
	local washPos = PlotLayout.point(plot, QUEUE_DEPTH[1], 0, FLOOR_Y)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(6, 0.2, 6)
	spawn.CFrame = CFrame.lookAt(spawnPos, washPos)
	spawn.Color = Color3.fromRGB(120, 190, 255)
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.CanCollide = false
	spawn.Parent = bay

	local post = makePart({
		Name = "SignPost",
		Size = Vector3.new(1, 8, 1),
		Position = PlotLayout.point(plot, 6, 22, 4),
		Color = Color3.fromRGB(120, 85, 60),
		Material = Enum.Material.Wood,
		Parent = bay,
	})
	local sign = billboardLabel(post, "", Vector3.new(0, 5.5, 0), Vector2.new(260, 50))
	sign.Name = "BayLabel"
	local signGui = sign.Parent :: BillboardGui
	signGui.Name = "Sign"
	signGui.MaxDistance = 80

	bay:SetAttribute("BayIndex", index)
	bay.Parent = folder
	return bay
end

function WorldBuilder.init()
	ensureGround()
	local existing = Workspace:FindFirstChild("WashBays")
	if existing then
		existing:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "WashBays"
	folder.Parent = Workspace
end

return WorldBuilder
