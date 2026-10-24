-- Builds one farm when a player is given a plot, and destroys it when they leave.
-- Slots 1-4 are east of the road, 5-8 west. Each plot faces the road and grows backward:
--   U driveway (wash arm, cache arm) -> sidewalk -> cages -> barns.
--
-- Each bay exposes:
--   Approach, TurnIn, WashPosition, Queue2, Queue3, RoadReturn, Exit
--   Spawn                          the owner's SpawnLocation
--   SignPost.Sign.BayLabel         owner name
--   UpgradeStation.Counter         hose shop prompt
--   Cache.Slot{i}                  where washed animals wait (PickupPrompt, SellPrompt)
--   Zoo.Pen{i}                     Floor, Slot, GatePost.PenPrompt, CollectPad (+ Cash label)
--   Zoo.ExpandCounter              barn upgrade, at the far end of the path
--   GearSpot / TruckSpot           where StationProps parks the tier's gear and the fire truck
--   KioskSpot                      the auto-collect kiosk (Monetization)
--   Zoo.BarnSmall / BarnMedium / BarnLarge / BarnGargantuan / BarnMega   a roof on red posts over each lane
--   Zoo.Pen23 / Pen24   the mega barn: two gargantuan pens behind the last barn
--   Zoo.Pen25-28   two large cages on the road, two medium cages behind them, gates toward the yard

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
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
-- A U driveway: the left arm is the wash queue, the right arm is the cache, and a
-- cross piece joins them. Both arms sit the same distance off the plot centre.
local ROAD_D = -8
local DRIVE_ARM = 14
local YARD_D = 38
local QUEUE_DEPTH = { YARD_D, 24, 10 } -- 1 is the wash, furthest in; 3 is the back of the queue
local WASH_LAT = -DRIVE_ARM
local CACHE_LAT = DRIVE_ARM
local SOLD_LAT = CACHE_LAT
-- The path starts just behind the drive's cross piece (depth 32-44), so the stalls are a
-- few steps from the cache. The six stalls sit three a side with their gates on the path.
local WALK_START = 50
local STALL_DEPTH = 10
local STALL_LAT = 10
local STALL_PITCH = 12
local STALL_FIRST = WALK_START + 2 + STALL_DEPTH / 2
local STALL_LATERAL = GameConfig.SidewalkWidth / 2 + 1 + STALL_LAT / 2
local WALK_END = STALL_FIRST + 2 * STALL_PITCH + STALL_DEPTH / 2 + 4

-- Lanes beside the path. Large is 1.5x the small pen, giant 3x, gargantuan 8x.
-- Larger lanes are multiples of the original 8-by-7 stall.
local BASE_DEPTH = 8
local BASE_LAT = 7
local LARGE_DEPTH = BASE_DEPTH * 1.5
local LARGE_LAT = BASE_LAT * 1.5
local GIANT_DEPTH = BASE_DEPTH * 3
local GIANT_LAT = BASE_LAT * 3
local GARG_DEPTH = BASE_DEPTH * 8
local GARG_LAT = BASE_LAT * 8

local ROOF_OVER = 1 -- roof and posts sit just outside the pen
local LANE_GAP = 4
local ROW_GAP = 3

-- The barn ladder starts just past the stalls; the barn counter stands in the gap.
local BARN_FRONT = WALK_END + 4
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

-- Road cages and the hose stand use the newer labels. Keep those smaller than the barn signs.
local function compactBillboards(root: Instance, scale: number)
	for _, gui in root:GetDescendants() do
		if gui:IsA("BillboardGui") then
			gui.Size = UDim2.fromOffset(math.floor(gui.Size.X.Offset * scale), math.floor(gui.Size.Y.Offset * scale))
			gui.MaxDistance = math.min(gui.MaxDistance, 42)
		end
	end
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

-- Hides or shows the pens and the cache together. New players stay hidden until the
-- opening washes are done; buildBay starts hidden so the yard never flashes in.
function WorldBuilder.setYardShown(bay: Model, shown: boolean)
	local zoo = bay:FindFirstChild("Zoo")
	local cache = bay:FindFirstChild("Cache")
	if zoo then
		WorldBuilder.setShown(zoo, shown)
	end
	if cache then
		WorldBuilder.setShown(cache, shown)
	end
	bay:SetAttribute("YardRevealed", shown)
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

-- The gear shop: a little booth just outside the wash arm, between the road cages, with its
-- counter facing the animal being washed and the shopkeeper behind it. Gear for the player's
-- tier stands at GearSpot (StationProps), behind the wash, and the fire truck parks at
-- TruckSpot past the left cages.
local SHOP_DEPTH = 38
local SHOP_LAT = WASH_LAT - 16
local GEAR_DEPTH = 47
local GEAR_LAT = WASH_LAT - 8.5

local function buildUpgradeStation(plot: PlotLayout.PlotFrame, parent: Instance)
	local station = Instance.new("Model")
	station.Name = "UpgradeStation"
	local base = PlotLayout.point(plot, SHOP_DEPTH, SHOP_LAT, 0)
	-- Local -Z faces the wash; local X runs along the plot depth.
	local frame = CFrame.lookAt(base, base + plot.Right)
	local function block(name: string, size: Vector3, offset: CFrame, color: Color3, props: { [string]: any }?): Part
		local fields: { [string]: any } = {
			Name = name,
			Size = size,
			CFrame = frame * offset,
			Color = color,
			Parent = station,
		}
		for key, value in props or {} do
			fields[key] = value
		end
		return makePart(fields)
	end
	local blue = Color3.fromRGB(60, 150, 230)
	local white = Color3.fromRGB(245, 245, 240)
	local wood = Color3.fromRGB(200, 150, 95)
	block("Deck", Vector3.new(9, 0.4, 7), CFrame.new(0, 0.2, 0.5), wood, { Material = Enum.Material.WoodPlanks })
	local counter = block("Counter", Vector3.new(8, 3.2, 1.6), CFrame.new(0, 2, -2.2), blue)
	block("CounterTop", Vector3.new(8.6, 0.3, 2.2), CFrame.new(0, 3.75, -2.2), white, { CanQuery = false })
	block("BackWall", Vector3.new(9, 9, 0.6), CFrame.new(0, 4.7, 3.7), wood, { Material = Enum.Material.WoodPlanks })
	for _, side in { -1, 1 } do
		block("Post", Vector3.new(0.6, 8.6, 0.6), CFrame.new(side * 4.2, 4.5, -2.9), white, { CanQuery = false })
	end
	-- Striped awning, sloping down toward the wash.
	for i = 0, 5 do
		block(
			"Awning",
			Vector3.new(1.5, 0.25, 7.6),
			CFrame.new(-3.75 + i * 1.5, 9.1, 0) * CFrame.Angles(math.rad(-12), 0, 0),
			if i % 2 == 0 then Color3.fromRGB(230, 60, 60) else white,
			{ CanQuery = false }
		)
	end
	local sign = block("Sign", Vector3.new(8, 2.2, 0.4), CFrame.new(0, 11.2, -0.6), Color3.fromRGB(255, 210, 70), {
		CanQuery = false,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = sign
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = "GEAR SHOP"
	text.Parent = gui
	UIStyle.text(text, Color3.fromRGB(60, 40, 20), Color3.new(1, 1, 1), 2)
	-- Upgrades hang on the back wall: a sponge, a brush, a nozzle.
	block(
		"Hook1",
		Vector3.new(1.2, 0.8, 0.4),
		CFrame.new(-2.6, 6, 3.3),
		Color3.fromRGB(255, 220, 70),
		{ CanQuery = false }
	)
	block("Hook2", Vector3.new(0.3, 2, 0.4), CFrame.new(0, 6, 3.3), Color3.fromRGB(170, 115, 60), { CanQuery = false })
	block(
		"Hook3",
		Vector3.new(0.5, 0.5, 1.6),
		CFrame.new(2.6, 6, 3.1),
		Color3.fromRGB(220, 40, 40),
		{ CanQuery = false }
	)
	local prompt = makePrompt("UpgradePrompt", "Upgrade Gear", 0, counter)
	prompt.ObjectText = "Gear Shop"
	prompt.MaxActivationDistance = 12
	station.Parent = parent

	task.spawn(function()
		local ok, result = pcall(function()
			return Players:CreateHumanoidModelFromDescription(
				Instance.new("HumanoidDescription"),
				Enum.HumanoidRigType.R15
			)
		end)
		if not ok or typeof(result) ~= "Instance" or not result:IsA("Model") or not station.Parent then
			return
		end
		local keeper = result
		keeper.Name = "ShopKeeper"
		local humanoid = keeper:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayName = "Shop"
			humanoid.WalkSpeed = 0
			humanoid.JumpHeight = 0
		end
		keeper.Parent = station
		-- Behind the counter, looking out at the wash.
		keeper:PivotTo(frame * CFrame.new(0, 3.4, 1))
		for _, part in keeper:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
	end)

	local gearPos = PlotLayout.point(plot, GEAR_DEPTH, GEAR_LAT, FLOOR_Y - 0.5)
	makeMarker("GearSpot", CFrame.lookAt(gearPos, gearPos + plot.Right), parent)
	-- Nose toward the road, parked behind the booth.
	local truckPos = PlotLayout.point(plot, 46, WASH_LAT - 40, 0)
	makeMarker("TruckSpot", CFrame.lookAt(truckPos, truckPos + plot.Look), parent)
	-- The auto-collect kiosk (Monetization): behind the cache arm, beside the first stalls.
	local kioskPos = PlotLayout.point(plot, 47, CACHE_LAT + 9, 0)
	makeMarker("KioskSpot", CFrame.lookAt(kioskPos, kioskPos - plot.Right), parent)
end

local function buildCache(plot: PlotLayout.PlotFrame, bay: Model)
	local cache = Instance.new("Folder")
	cache.Name = "Cache"
	local spacing = GameConfig.Cache.SlotSpacing
	-- Slot 1 is closer to the road. A sale walks that animal out, then the one behind steps up.
	local depths = { YARD_D - spacing, YARD_D }
	local mid = (depths[1] + depths[2]) / 2
	local floorPos = PlotLayout.point(plot, mid, CACHE_LAT, FLOOR_Y)
	makePart({
		Name = "CacheFloor",
		Size = Vector3.new(spacing + 10, 0.4, 12),
		Position = floorPos,
		Color = Color3.fromRGB(230, 190, 120),
		Material = Enum.Material.WoodPlanks,
		CanQuery = false,
		Parent = cache,
	})
	for index, depth in depths do
		local pos = PlotLayout.point(plot, depth, CACHE_LAT, FLOOR_Y)
		local slot = makeMarker("Slot" .. index, CFrame.lookAt(pos, pos + plot.Look), cache)
		slot:SetAttribute("SlotIndex", index)
		makePrompt("PickupPrompt", "Pick up", 0, slot).Enabled = false
		local sell = makePrompt("SellPrompt", "Sell", 1.5, slot, Enum.KeyCode.F)
		sell.UIOffset = Vector2.new(0, -110)
		sell.GamepadKeyCode = Enum.KeyCode.ButtonY
		sell.Enabled = false
	end
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
	local pet = makePrompt("PetPrompt", "Set pet", 0.4, post, Enum.KeyCode.R)
	pet.UIOffset = Vector2.new(0, 72)
	pet.GamepadKeyCode = Enum.KeyCode.ButtonX
	pet.Enabled = false
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
	local alongDepth = math.abs(look:Dot(plot.Look)) > 0.5
	if alongDepth then
		local towardRoad = look:Dot(plot.Look) > 0
		local frontDepth = if towardRoad then depth - halfD else depth + halfD
		local backDepth = if towardRoad then depth + halfD else depth - halfD
		makePart({
			Name = "Fence",
			Size = Vector3.new(0.4, h, latSize),
			Position = PlotLayout.point(plot, backDepth, lateral, y),
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
	local reach = if alongDepth then depthSize / 2 + 2 else latSize / 2 + 2
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
			look = if class == "Giant"
					or class == "Gargantuan"
					or class == "Large"
				then if math.abs(lateral) < 1 then plot.Look else inwardLook(plot, lateral)
				else inwardLook(plot, lateral)
		end
		buildFencedPen(plot, pen, depth, lateral, depthSize, latSize, look)
		pen.Parent = zoo
		if index > GameConfig.Zoo.StartPens then
			WorldBuilder.setShown(pen, false)
		end
	end

	-- Six stalls, three on each side of the path, right behind the drive. Gates open onto the
	-- path, so walking down it passes every animal and every collect pad.
	for row = 0, 2 do
		local depth = STALL_FIRST + row * STALL_PITCH
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

	-- Large cages sit on the road with a wide gap for the driveway. Each medium cage
	-- is directly behind its large cage. Gates and pads face into the yard.
	local MEDIUM_SIZE = 16
	local LARGE_SIZE = 24
	local LARGE_FRONT = 8
	local largeLat = 24 + LARGE_SIZE / 2
	local largeDepth = LARGE_FRONT + LARGE_SIZE / 2
	local mediumDepth = LARGE_FRONT + LARGE_SIZE + 4 + MEDIUM_SIZE / 2
	for offset, spec in GameConfig.Zoo.RoadCages do
		local index = GameConfig.Zoo.MaxPens + offset
		local large = spec.Class == "PastureLarge"
		local size = if large then LARGE_SIZE else MEDIUM_SIZE
		local sign = if spec.Side == "Left" then -1 else 1
		local lateral = sign * largeLat
		local depth = if large then largeDepth else mediumDepth
		addPen(index, depth, lateral, size, size, spec.Class, plot.Back)
		local pen = zoo:FindFirstChild("Pen" .. index)
		if not pen then
			continue
		end
		pen:SetAttribute("RoadUnlock", spec.Unlock)
		local builtFloor = pen:FindFirstChild("Floor")
		local labelColor = if large then Color3.fromRGB(255, 196, 80) else Color3.fromRGB(130, 220, 255)
		if builtFloor and builtFloor:IsA("BasePart") then
			local classLabel =
				billboardLabel(builtFloor, spec.Label, Vector3.new(0, 5, 0), Vector2.new(110, 24), labelColor)
			classLabel.Name = "ClassLabel"
		end
		local lock = Instance.new("Model")
		lock.Name = "FlexLock"
		local bar = makePart({
			Name = "Bar",
			Size = Vector3.new(0.6, 4.5, size - 6),
			Position = PlotLayout.point(plot, depth + size / 2 - 1.2, lateral, 2.4),
			Color = Color3.fromRGB(176, 48, 40),
			Material = Enum.Material.Wood,
			Parent = lock,
		})
		local lockLabel =
			billboardLabel(bar, spec.Lock, Vector3.new(0, 3.2, 0), Vector2.new(120, 32), Color3.fromRGB(255, 230, 120))
		lockLabel.Name = "LockLabel"
		lockLabel.TextWrapped = true
		local lockGui = lockLabel.Parent :: BillboardGui
		lockGui.MaxDistance = 40
		lock.Parent = pen
		compactBillboards(pen, 0.72)
		if spec.Unlock == "Cash" then
			local post = pen:FindFirstChild("GatePost")
			if post then
				local price = spec.Price or 500000
				local unlock = makePrompt("UnlockPrompt", `Unlock ({UIStyle.formatMoney(price)})`, 0.6, post)
				unlock.ObjectText = "Large cage"
				unlock.Enabled = false
				unlock:SetAttribute("RestEnabled", true)
			end
		end
		WorldBuilder.setShown(pen, false)
	end

	-- Barn upgrade, at the far end of the path where the barns will go.
	local stand = PlotLayout.point(plot, WALK_END + 0.5, -(GameConfig.SidewalkWidth / 2 + 4), 0)
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
	makePrompt("ExpandPrompt", "Expand Farm", 0.5, counter).ObjectText = "Barn Upgrade"

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
	local drive = Color3.fromRGB(176, 176, 184)
	local curb = Color3.fromRGB(92, 96, 104)
	local armW = 12
	local armStart = 0
	local armSpan = YARD_D - armStart
	local function arm(name: string, lateral: number)
		makePart({
			Name = name,
			Size = Vector3.new(armSpan, 0.35, armW + 1.6),
			Position = PlotLayout.point(plot, armStart + armSpan / 2, lateral, 0.12),
			Color = curb,
			Material = Enum.Material.Basalt,
			CanQuery = false,
			CanCollide = false,
			Parent = bay,
		})
		makePart({
			Name = name .. "Pave",
			Size = Vector3.new(armSpan - 1, 0.28, armW),
			Position = PlotLayout.point(plot, armStart + armSpan / 2, lateral, 0.28),
			Color = drive,
			Material = Enum.Material.Cobblestone,
			CanQuery = false,
			CanCollide = false,
			Parent = bay,
		})
	end
	arm("WashArm", WASH_LAT)
	arm("CacheArm", CACHE_LAT)
	local spanLat = (CACHE_LAT - WASH_LAT) + armW
	makePart({
		Name = "DriveCross",
		Size = Vector3.new(armW + 1.6, 0.35, spanLat + 1.6),
		Position = PlotLayout.point(plot, YARD_D, 0, 0.12),
		Color = curb,
		Material = Enum.Material.Basalt,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	makePart({
		Name = "DriveCrossPave",
		Size = Vector3.new(armW, 0.28, spanLat),
		Position = PlotLayout.point(plot, YARD_D, 0, 0.28),
		Color = drive,
		Material = Enum.Material.Cobblestone,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	-- Mouth of the U, so the two arms read as one drive off the main road.
	makePart({
		Name = "DriveApron",
		Size = Vector3.new(6, 0.3, spanLat),
		Position = PlotLayout.point(plot, -1, 0, 0.2),
		Color = drive,
		Material = Enum.Material.Cobblestone,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	makePart({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.15, 8, 8),
		CFrame = CFrame.new(PlotLayout.point(plot, YARD_D, WASH_LAT, FLOOR_Y + 0.05))
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
	makeMarker("Approach", alongRoad(ROAD_D, WASH_LAT - 22), bay)
	local turn = PlotLayout.point(plot, 1, WASH_LAT, FLOOR_Y)
	makeMarker("TurnIn", CFrame.lookAt(turn, turn + plot.Back), bay)
	makeMarker("WashPosition", PlotLayout.inbound(plot, QUEUE_DEPTH[1], WASH_LAT, FLOOR_Y), bay)
	makeMarker("Queue2", PlotLayout.inbound(plot, QUEUE_DEPTH[2], WASH_LAT, FLOOR_Y), bay)
	makeMarker("Queue3", PlotLayout.inbound(plot, QUEUE_DEPTH[3], WASH_LAT, FLOOR_Y), bay)
	makeMarker("Entrance", alongRoad(ROAD_D, 0), bay)
	-- Where the cross piece meets the cache arm. Animals leaving the wash turn here.
	local cacheTurn = PlotLayout.point(plot, YARD_D, CACHE_LAT, FLOOR_Y)
	makeMarker("CacheTurn", CFrame.lookAt(cacheTurn, cacheTurn + plot.Look), bay)
	local soldPos = PlotLayout.point(plot, YARD_D - GameConfig.Cache.SlotSpacing - 8, SOLD_LAT, FLOOR_Y)
	makeMarker("SoldSpot", CFrame.lookAt(soldPos, soldPos + plot.Look), bay)
	local back = PlotLayout.point(plot, ROAD_D, SOLD_LAT, FLOOR_Y)
	makeMarker("RoadReturn", CFrame.lookAt(back, back + plot.Look), bay)
	makeMarker("Exit", CFrame.lookAt(back, back + plot.Look), bay)
end

-- The path runs past the six stalls. Its barn stretch is part of the BarnAisle shell, so it
-- only appears once there is a barn to walk to.
local function buildSidewalk(plot: PlotLayout.PlotFrame, bay: Model)
	local function stretch(name: string, from: number, to: number, parent: Instance)
		makePart({
			Name = name,
			Size = Vector3.new(to - from, 0.35, GameConfig.SidewalkWidth),
			Position = PlotLayout.point(plot, (from + to) / 2, 0, 0.18),
			Color = Color3.fromRGB(190, 175, 150),
			Material = Enum.Material.Cobblestone,
			CanQuery = false,
			Parent = parent,
		})
	end
	stretch("Sidewalk", WALK_START, WALK_END, bay)
	local zoo = bay:FindFirstChild("Zoo")
	if zoo then
		local aisle = Instance.new("Model")
		aisle.Name = "BarnAisle"
		stretch("Sidewalk", WALK_END, BARN_AISLE_END, aisle)
		aisle.Parent = zoo
		WorldBuilder.setShown(aisle, false)
	end
end

function WorldBuilder.buildBay(index: number): Model
	local plot = PlotLayout.frame(index)
	local bay = Instance.new("Model")
	bay.Name = "Bay" .. index

	buildWash(plot, bay)
	buildCache(plot, bay)
	buildUpgradeStation(plot, bay)
	buildZoo(plot, bay)
	buildSidewalk(plot, bay)

	-- At the head of the path, facing the wash; the tier gear stands where this used to be.
	local spawnPos = PlotLayout.point(plot, 53, -4, FLOOR_Y)
	local washPos = PlotLayout.point(plot, QUEUE_DEPTH[1], WASH_LAT, FLOOR_Y)
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
		-- In the gap between the two road cages, in front of both, so the post isn't inside one.
		Position = PlotLayout.point(plot, 2, 0, 4),
		Color = Color3.fromRGB(120, 85, 60),
		Material = Enum.Material.Wood,
		Parent = bay,
	})
	local sign = billboardLabel(post, "", Vector3.new(0, 5.5, 0), Vector2.new(260, 50))
	sign.Name = "BayLabel"
	local signGui = sign.Parent :: BillboardGui
	signGui.Name = "Sign"
	signGui.MaxDistance = 80

	WorldBuilder.setYardShown(bay, false)
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
