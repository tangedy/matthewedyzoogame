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
--   Zoo.BarnSmall / BarnMedium / BarnLarge / BarnGargantuan / BarnMega   a roof on red posts over each lane
--   Zoo.Pen23 / Pen24   the mega barn: two gargantuan pens behind the last barn
--   Zoo.Pen29 / Pen30   two pens on the path, just after the six stalls and in front of the barns

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

-- Depths measured from the road edge, away from the street.
-- The queue is a straight lane in from the road. The wash road runs parallel to the
-- main road at the wash depth, and the cache is further along that road.
local ROAD_D = -8
local QUEUE_DEPTH = { 40, 28, 16 } -- 1 is the wash, furthest in; 3 is the back of the queue
local CACHE_LAT = 18
local SOLD_LAT = CACHE_LAT + 10 -- forward of the cache, still facing along the wash road
local WALK_START = 58
local STALL_DEPTH = 8 -- half the old 16; every larger pen is a multiple of this
local STALL_LAT = 7
local STALL_PITCH = 14
local STALL_LATERAL = GameConfig.SidewalkWidth / 2 + 4 + STALL_LAT / 2
local WALK_END = WALK_START + 8 + STALL_DEPTH / 2 + 2 * STALL_PITCH + STALL_DEPTH / 2 + 8

-- Two pens the size of a large pasture, left and right of the path, immediately
-- behind the six stalls. The barns all start behind these.
local FLEX_DEPTH = 24
local FLEX_LAT_SIZE = 42
local FLEX_LATERAL = GameConfig.SidewalkWidth / 2 + 4 + FLEX_LAT_SIZE / 2
local FLEX_CENTER = (WALK_END - 8) + 4 + FLEX_DEPTH / 2

-- Lanes beside the path. Large is 1.5x the small pen, giant 3x, gargantuan 8x.
local LARGE_DEPTH = STALL_DEPTH * 1.5
local LARGE_LAT = STALL_LAT * 1.5
local GIANT_DEPTH = STALL_DEPTH * 3
local GIANT_LAT = STALL_LAT * 3
local GARG_DEPTH = STALL_DEPTH * 8
local GARG_LAT = STALL_LAT * 8

local ROOF_OVER = 1 -- roof and posts sit just outside the pen
local LANE_GAP = 4
local ROW_GAP = 3

local BARN_FRONT = FLEX_CENTER + FLEX_DEPTH / 2 + 8
local ROW_PITCH = LARGE_DEPTH + ROW_GAP
local ROW_DEPTH = {
	BARN_FRONT + ROOF_OVER + LARGE_DEPTH / 2,
	0,
}
ROW_DEPTH[2] = ROW_DEPTH[1] + ROW_PITCH
-- The path ends at the back of the front barn. Rear lanes sit behind that.
local BARN_AISLE_END = ROW_DEPTH[2] + LARGE_DEPTH / 2 + ROOF_OVER
local OUTER_LATERAL = STALL_LATERAL + STALL_LAT / 2 + LANE_GAP + LARGE_LAT / 2

-- Large tier: two small barns side by side, then the giant's barn behind them.
local LARGE_FRONT = BARN_AISLE_END + 8
local PAIR_GAP = 4
local PAIR_LAT = LARGE_LAT / 2 + PAIR_GAP / 2
local PAIR_CENTER = LARGE_FRONT + ROOF_OVER + LARGE_DEPTH / 2
local PAIR_BACK = PAIR_CENTER + LARGE_DEPTH / 2 + ROOF_OVER
local LARGE_CENTER = PAIR_BACK + 6 + ROOF_OVER + GIANT_DEPTH / 2
local LARGE_BACK = LARGE_CENTER + GIANT_DEPTH / 2 + ROOF_OVER

-- Extra-large tier: a giant pen, then an open gargantuan pen with a skinny
-- medium barn along the left, right, and back.
local YARD_GAP = 6
local G18_CENTER = LARGE_BACK + 8 + ROOF_OVER + GIANT_DEPTH / 2
local G18_BACK = G18_CENTER + GIANT_DEPTH / 2 + ROOF_OVER
local GARG_FRONT_EDGE = G18_BACK + YARD_GAP
local GARG_CENTER = GARG_FRONT_EDGE + GARG_DEPTH / 2
local GARG_BACK_EDGE = GARG_CENTER + GARG_DEPTH / 2
local SURROUND_GAP = 8
local SIDE_LAT = GARG_LAT / 2 + SURROUND_GAP + LARGE_LAT / 2
local BACK_CENTER = GARG_BACK_EDGE + SURROUND_GAP + LARGE_LAT / 2

-- Mega barn behind the gargantuan yard. Two gargantuan pens, side by side.
-- Hidden until the upgrade after the gargantuan barn.
local MEGA_GAP = 8
local MEGA_LAT = GARG_LAT / 2 + MEGA_GAP / 2
local MEGA_FRONT = BACK_CENTER + LARGE_LAT / 2 + ROOF_OVER + 10
local MEGA_CENTER = MEGA_FRONT + GARG_DEPTH / 2

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
	reach: number,
	depthSize: number
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
	elseif depth > BARN_AISLE_END then
		-- Rear lanes are not on the sidewalk. The pad sits on the near side of the pen.
		padPos = PlotLayout.point(plot, depth - depthSize / 2 - 2.4, lateral, 0.3)
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
	addPenPrompts(plot, pen, depth, lateral, look, reach, depthSize)
end

local buildBarns: (plot: PlotLayout.PlotFrame, zoo: Folder) -> ()

local function inwardLook(plot: PlotLayout.PlotFrame, lateral: number): Vector3
	return if lateral >= 0 then -plot.Right else plot.Right
end

local function buildZoo(plot: PlotLayout.PlotFrame, bay: Model)
	local zoo = Instance.new("Folder")
	zoo.Name = "Zoo"

	local function addPen(
		index: number,
		depth: number,
		lateral: number,
		depthSize: number,
		latSize: number,
		class: string,
		lookAt: Vector3?
	)
		local pen = Instance.new("Model")
		pen.Name = "Pen" .. index
		pen:SetAttribute("PenIndex", index)
		pen:SetAttribute("PenClass", class)
		local look = lookAt
		if not look then
			look = if class == "Giant" or class == "Gargantuan" or class == "Large"
				then if math.abs(lateral) < 1 then plot.Look else inwardLook(plot, lateral)
				else inwardLook(plot, lateral)
		end
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

	-- Small barn: two standard pens each side of the path. Medium adds an outer lane
	-- each side, 1.5x the small pen, for large animals.
	for row = 1, 2 do
		local depth = ROW_DEPTH[row]
		local left = 6 + row * 2 - 1 -- 7, 9
		local right = left + 1 -- 8, 10
		addPen(left, depth, -STALL_LATERAL, STALL_DEPTH, STALL_LAT, "Standard")
		addPen(right, depth, STALL_LATERAL, STALL_DEPTH, STALL_LAT, "Standard")
		local outerLeft = 10 + row * 2 - 1 -- 11, 13
		local outerRight = outerLeft + 1
		addPen(outerLeft, depth, -OUTER_LATERAL, LARGE_DEPTH, LARGE_LAT, "Medium")
		addPen(outerRight, depth, OUTER_LATERAL, LARGE_DEPTH, LARGE_LAT, "Medium")
	end

	-- Two small barns side by side, then the giant's barn behind them.
	addPen(16, PAIR_CENTER, -PAIR_LAT, LARGE_DEPTH, LARGE_LAT, "Large", plot.Look)
	addPen(17, PAIR_CENTER, PAIR_LAT, LARGE_DEPTH, LARGE_LAT, "Large", plot.Look)
	addPen(15, LARGE_CENTER, 0, GIANT_DEPTH, GIANT_LAT, "Giant")

	-- Open gargantuan pen. A giant pen sits in front of it. Three skinny medium
	-- barns stand on the left, right, and back, each with one medium pen.
	addPen(18, G18_CENTER, 0, GIANT_DEPTH, GIANT_LAT, "Giant")
	addPen(19, GARG_CENTER, 0, GARG_DEPTH, GARG_LAT, "Gargantuan")
	addPen(20, GARG_CENTER, -SIDE_LAT, LARGE_DEPTH, LARGE_LAT, "Medium")
	addPen(21, GARG_CENTER, SIDE_LAT, LARGE_DEPTH, LARGE_LAT, "Medium")
	addPen(22, BACK_CENTER, 0, LARGE_LAT, LARGE_DEPTH, "Medium", plot.Look)

	-- Mega barn: two gargantuan pens. They stay hidden until that upgrade.
	local megaFirst = GameConfig.Zoo.MaxPens - 1
	addPen(megaFirst, MEGA_CENTER, -MEGA_LAT, GARG_DEPTH, GARG_LAT, "Gargantuan", plot.Look)
	addPen(megaFirst + 1, MEGA_CENTER, MEGA_LAT, GARG_DEPTH, GARG_LAT, "Gargantuan", plot.Look)

	local flexColor = Color3.fromRGB(130, 220, 255)
	local function flexPen(index: number, lateral: number, side: string, lockText: string)
		-- Gate faces the path, same as the six stalls in front of them.
		addPen(index, FLEX_CENTER, lateral, FLEX_DEPTH, FLEX_LAT_SIZE, "PastureFlex")
		local built = zoo:FindFirstChild("Pen" .. index)
		local builtFloor = built and built:FindFirstChild("Floor")
		if builtFloor and builtFloor:IsA("BasePart") then
			local classLabel = billboardLabel(builtFloor, "2 MEDIUM\nOR 1 LARGE", Vector3.new(0, 8, 0), Vector2.new(240, 80), flexColor)
			classLabel.Name = "ClassLabel"
			classLabel.TextWrapped = true
		end
		local pen = zoo:FindFirstChild("Pen" .. index)
		if not pen then
			return
		end
		pen:SetAttribute("FlexSide", side)
		local function sideSlot(name: string, latOffset: number)
			local pos = PlotLayout.point(plot, FLEX_CENTER, lateral + latOffset, FLOOR_Y)
			local look = inwardLook(plot, lateral)
			makeMarker(name, CFrame.lookAt(pos, pos + look), pen)
		end
		sideSlot("SlotMedium1", -FLEX_LAT_SIZE * 0.22)
		sideSlot("SlotMedium2", FLEX_LAT_SIZE * 0.22)
		local lock = Instance.new("Model")
		lock.Name = "FlexLock"
		local towardPath = if lateral >= 0 then 1 else -1
		local bar = makePart({
			Name = "Bar",
			Size = Vector3.new(FLEX_DEPTH - 6, 8, 0.8),
			Position = PlotLayout.point(plot, FLEX_CENTER, lateral - towardPath * (FLEX_LAT_SIZE / 2 - 1.2), 4),
			Color = Color3.fromRGB(176, 48, 40),
			Material = Enum.Material.Wood,
			Parent = lock,
		})
		local lockLabel = billboardLabel(bar, lockText, Vector3.new(0, 6.5, 0), Vector2.new(240, 80), Color3.fromRGB(255, 230, 120))
		lockLabel.Name = "LockLabel"
		lockLabel.TextWrapped = true
		local lockGui = lockLabel.Parent :: BillboardGui
		lockGui.MaxDistance = 80
		lock.Parent = pen
		local post = pen:FindFirstChild("GatePost")
		if post then
			local sell2 = makePrompt("PenPrompt2", "Sell", 1, post, Enum.KeyCode.F)
			sell2.UIOffset = Vector2.new(0, -90)
			sell2.GamepadKeyCode = Enum.KeyCode.ButtonY
			sell2.Enabled = false
			sell2:SetAttribute("RestEnabled", true)
			if side == "Right" then
				local unlock = makePrompt("UnlockPrompt", "Unlock (99 ROBUX)", 0.4, post)
				unlock.ObjectText = "Right pasture"
				unlock.Enabled = false
				unlock:SetAttribute("RestEnabled", true)
			end
		end
		local classLabel = pen:FindFirstChild("ClassLabel", true)
		if classLabel and classLabel:IsA("TextLabel") then
			classLabel.TextWrapped = true
			local gui = classLabel.Parent
			if gui and gui:IsA("BillboardGui") then
				gui.Size = UDim2.fromOffset(240, 80)
			end
		end
		WorldBuilder.setShown(pen, false)
	end
	local flexLeft = GameConfig.Zoo.MaxPens + 1
	-- Positive lateral is the left side when walking in from the road.
	flexPen(flexLeft, FLEX_LATERAL, "Left", "SPEND ANY ROBUX")
	flexPen(flexLeft + 1, -FLEX_LATERAL, "Right", "99 ROBUX\nOR AXOLOTL")

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

-- Open shelter: red posts and a gable roof, no walls, so the pens stay visible.
-- The ridge runs along the plot depth. Pitch is around the plot's back axis, so the
-- peak is up on both sides of the road.
local POST_RED = Color3.fromRGB(186, 42, 36)
local ROOF_RED = Color3.fromRGB(150, 34, 30)

local function barnShelter(
	plot: PlotLayout.PlotFrame,
	parent: Instance,
	depth0: number,
	depth1: number,
	lat0: number,
	lat1: number,
	eave: number,
	post: number,
	ridgeAlongLat: boolean?
)
	local midD = (depth0 + depth1) / 2
	local midL = (lat0 + lat1) / 2
	local alongSpan = if ridgeAlongLat then lat1 - lat0 else depth1 - depth0
	local acrossSpan = if ridgeAlongLat then depth1 - depth0 else lat1 - lat0
	local run = acrossSpan / 2
	local pitch = math.rad(18)
	local overlap = 1
	local panelLen = (run + overlap) / math.cos(pitch)
	local halfHoriz = (run + overlap) / 2
	-- Ridge along the plot. Local Z points toward the negative across-axis so the
	-- same pitch puts the eave down on both sides of the road.
	local xAxis = if ridgeAlongLat then -plot.Right else plot.Back
	local zAxis = if ridgeAlongLat then -plot.Back else -plot.Right

	local function posts(across: number)
		local count = math.max(2, math.floor(alongSpan / 12) + 1)
		for i = 0, count - 1 do
			local along = (if ridgeAlongLat then lat0 else depth0) + alongSpan * (i / (count - 1))
			local depth = if ridgeAlongLat then across else along
			local lat = if ridgeAlongLat then along else across
			makePart({
				Name = "Post",
				Size = Vector3.new(post, eave, post),
				Position = PlotLayout.point(plot, depth, lat, eave / 2),
				Color = POST_RED,
				Material = Enum.Material.Wood,
				CanQuery = false,
				Parent = parent,
			})
		end
	end
	if ridgeAlongLat then
		posts(depth0)
		posts(depth1)
	else
		posts(lat0)
		posts(lat1)
	end

	for _, side in { -1, 1 } do
		local shift = side * (run - halfHoriz)
		local centerY = eave + (panelLen / 2) * math.sin(pitch)
		local center = PlotLayout.point(
			plot,
			if ridgeAlongLat then midD + shift else midD,
			if ridgeAlongLat then midL else midL + shift,
			centerY
		)
		local cf = CFrame.fromMatrix(center, xAxis, Vector3.yAxis, zAxis) * CFrame.Angles(-side * pitch, 0, 0)
		makePart({
			Name = "Roof",
			Size = Vector3.new(alongSpan + 1, 0.4, panelLen),
			CFrame = cf,
			Color = ROOF_RED,
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = parent,
		})
	end
end

function buildBarns(plot: PlotLayout.PlotFrame, zoo: Folder)
	local function shell(name: string): Model
		local model = Instance.new("Model")
		model.Name = name
		model.Parent = zoo
		WorldBuilder.setShown(model, false)
		return model
	end

	-- Small: the two standard lanes and the path between them. Only as deep as those pens.
	local smallLat = STALL_LATERAL + STALL_LAT / 2 + ROOF_OVER
	barnShelter(
		plot,
		shell("BarnSmall"),
		ROW_DEPTH[1] - STALL_DEPTH / 2 - ROOF_OVER,
		ROW_DEPTH[2] + STALL_DEPTH / 2 + ROOF_OVER,
		-smallLat,
		smallLat,
		7,
		0.6
	)

	-- Medium replaces it and reaches the outer 1.5x lanes. Taller, so a giraffe fits under the eave.
	local mediumLat = OUTER_LATERAL + LARGE_LAT / 2 + ROOF_OVER
	barnShelter(plot, shell("BarnMedium"), BARN_FRONT, BARN_AISLE_END, -mediumLat, mediumLat, 14, 0.7)

	-- Two small barns in front of the giant's barn. Each roof fits one pen.
	local large = shell("BarnLarge")
	local function cover(
		parent: Instance,
		depth: number,
		lat: number,
		depthSize: number,
		latSize: number,
		eave: number,
		post: number,
		ridgeAlongLat: boolean?
	)
		barnShelter(
			plot,
			parent,
			depth - depthSize / 2 - ROOF_OVER,
			depth + depthSize / 2 + ROOF_OVER,
			lat - latSize / 2 - ROOF_OVER,
			lat + latSize / 2 + ROOF_OVER,
			eave,
			post,
			ridgeAlongLat
		)
	end
	for _, side in { -1, 1 } do
		cover(large, PAIR_CENTER, side * PAIR_LAT, LARGE_DEPTH, LARGE_LAT, 7, 0.6)
	end
	cover(large, LARGE_CENTER, 0, GIANT_DEPTH, GIANT_LAT, 12, 0.8)

	-- Gargantuan pen stays open. A giant barn sits in front of it, and three skinny
	-- medium barns run along the left, the right, and the back.
	local garg = shell("BarnGargantuan")
	cover(garg, G18_CENTER, 0, GIANT_DEPTH, GIANT_LAT, 12, 0.8)
	local skinny = LARGE_LAT / 2 + ROOF_OVER
	for _, side in { -1, 1 } do
		local lat = side * SIDE_LAT
		barnShelter(
			plot,
			garg,
			GARG_FRONT_EDGE - ROOF_OVER,
			GARG_BACK_EDGE + ROOF_OVER,
			lat - skinny,
			lat + skinny,
			14,
			0.7
		)
	end
	barnShelter(
		plot,
		garg,
		BACK_CENTER - LARGE_LAT / 2 - ROOF_OVER,
		BACK_CENTER + LARGE_LAT / 2 + ROOF_OVER,
		-(GARG_LAT / 2 + ROOF_OVER),
		GARG_LAT / 2 + ROOF_OVER,
		14,
		0.7,
		true
	)

	-- Two gargantuan pens behind the last barn. Hidden until the mega upgrade.
	local mega = shell("BarnMega")
	local megaOuter = MEGA_LAT + GARG_LAT / 2 + ROOF_OVER
	barnShelter(
		plot,
		mega,
		MEGA_CENTER - GARG_DEPTH / 2 - ROOF_OVER,
		MEGA_CENTER + GARG_DEPTH / 2 + ROOF_OVER,
		-megaOuter,
		megaOuter,
		24,
		1.2
	)
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
	-- Wash road, parallel to the main road. It runs a little past the queue lane on
	-- both edges so the join is a sharp corner, and sits a few bits higher so the
	-- two dirt surfaces don't flicker.
	local laneHalf = 6
	local nearLat = -(laneHalf + 2)
	local farLat = SOLD_LAT + 8
	local roadSpan = farLat - nearLat
	local roadCenterLat = (nearLat + farLat) / 2
	makePart({
		Name = "WashRoad",
		Size = Vector3.new(16, 0.25, roadSpan),
		Position = PlotLayout.point(plot, QUEUE_DEPTH[1], roadCenterLat, 0.22),
		Color = Color3.fromRGB(186, 142, 86),
		Material = Enum.Material.Ground,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	-- Road from just ahead of the cache back to the street. Sold animals jog down it.
	local exitSpan = QUEUE_DEPTH[1] - ROAD_D
	makePart({
		Name = "ExitRoad",
		Size = Vector3.new(exitSpan, 0.25, 10),
		Position = PlotLayout.point(plot, ROAD_D + exitSpan / 2, SOLD_LAT, 0.28),
		Color = Color3.fromRGB(176, 132, 78),
		Material = Enum.Material.Ground,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	makePart({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.15, 8, 8),
		CFrame = CFrame.new(PlotLayout.point(plot, QUEUE_DEPTH[1], 0, FLOOR_Y + 0.05))
			* CFrame.Angles(0, 0, math.rad(90)),
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
	makeMarker("SoldSpot", alongRoad(QUEUE_DEPTH[1], SOLD_LAT), bay)
	local back = PlotLayout.point(plot, ROAD_D, SOLD_LAT, FLOOR_Y)
	makeMarker("RoadReturn", CFrame.lookAt(back, back + plot.Look), bay)
	makeMarker("Exit", CFrame.lookAt(back, back + plot.Look), bay)
end

local function buildSidewalk(plot: PlotLayout.PlotFrame, bay: Model)
	local span = BARN_AISLE_END - WALK_START
	makePart({
		Name = "Sidewalk",
		Size = Vector3.new(span, 0.35, GameConfig.SidewalkWidth),
		Position = PlotLayout.point(plot, (WALK_START + BARN_AISLE_END) / 2, 0, 0.18),
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
	-- Not neutral: only the owner, via Player.RespawnLocation, appears here.
	spawn.Neutral = false
	spawn.AllowTeamChangeOnTouch = false
	spawn.Enabled = true
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
	-- The place file's pad sits at the middle of the road. Bases bring their own spawn.
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			descendant:Destroy()
		end
	end
	local existing = Workspace:FindFirstChild("WashBays")
	if existing then
		existing:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "WashBays"
	folder.Parent = Workspace
end

return WorldBuilder
