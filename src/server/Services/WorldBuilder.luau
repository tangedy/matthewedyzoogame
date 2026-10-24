-- Builds one farm when a player is given a plot, and destroys it when they leave.
-- Slots 1-4 are east of the road, 5-8 west. Each plot faces the road and grows backward:
--   road front: showcase podium | U driveway (cache arm, wash arm) | tier gear + truck
--   hub plaza (gear shop, Robux shop, spawn) -> one walkway, pens on both sides in unlock order
--   -> three gargantuan yards across the back.
--
-- Each bay exposes:
--   Approach, TurnIn, WashPosition, Queue2, Queue3, RoadReturn, Exit
--   Spawn                          the owner's SpawnLocation
--   Showcase.SignPost.Sign.BayLabel   owner name over the podium (Income.IncomeLabel, ShowcaseSlot)
--   UpgradeStation.Counter         hose shop prompt
--   Cache.Slot{i}                  where washed animals wait (PickupPrompt, SellPrompt)
--   Zoo.Pen{i}                     Floor, Slot, GatePost.PenPrompt, CollectPad (+ Cash label)
--   Zoo.ExpandStand.ExpandCounter  barn upgrade; ZooService moves it to Zoo.UnlockSpot{tier}
--   GearSpot / TruckSpot           where StationProps parks the tier's gear and the fire truck
--   RobuxShop.Counter              Robux shop prompt (+ auto-collect, Monetization)
--   Zoo.Pen19 / 23 / 24  the three gargantuan yards across the back
--   Zoo.Pen25-28   the Robux pastures, right after the starting stalls

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
-- The drive animals walk in on, and the darker dirt of the cache arm where washed ones wait.
local PATH_DIRT = Color3.fromRGB(176, 132, 86)
local PATH_EDGE = Color3.fromRGB(140, 102, 66)
local CACHE_DIRT = Color3.fromRGB(118, 84, 54)
local CACHE_EDGE = Color3.fromRGB(92, 64, 40)

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
-- Main Street. The drive's cross piece ends at depth 44; the hub plaza sits right behind it
-- (spawn, gear shop, Robux shop), and one walkway runs from the plaza to the back of
-- the plot. Every pen opens onto it, in the order they unlock, so one walk up and back passes
-- every animal and every collect pad. The three gargantuan yards close the far end, where a
-- look down the walkway from the road ends on them.
local WALK_START = YARD_D + 6
local PLAZA_DEPTH = 52 -- centre of the hub plaza
local PLAZA_HALF_DEPTH = 8
local PLAZA_HALF_LAT = 22
local WALK_HALF = GameConfig.SidewalkWidth / 2
local PEN_INNER = WALK_HALF + 1 -- side pens' inner edge, just off the walkway
local PEN_GAP = 2 -- between pens on one side
local GROUP_GAP = 6 -- between unlock groups; the next group's unlock stand stands in it
local FIRST_PEN = PLAZA_DEPTH + PLAZA_HALF_DEPTH + 2

-- Pen sizes by class: depth along the walkway, lateral away from it.
local STALL = Vector2.new(10, 10)
local MEDIUM = Vector2.new(12, 10.5)
local GIANT = Vector2.new(24, 21)
local YARD = Vector2.new(48, 38) -- gargantuan yards, three abreast across the back
local YARD_GAP = 4
local PASTURE_SIZE = { PastureMedium = 16, PastureLarge = 24 }

-- Which pens unlock together (GameConfig.Zoo.Expansions, in order), and which side of the
-- walkway each goes on (+1 left walking in, -1 right). Tier 0 is the six starting stalls; the
-- Robux pastures (GameConfig.Zoo.RoadCages) come straight after them. Pen numbers and classes
-- are the save format, so they never change; only where the pens stand.
type PenSpec = { Index: number, Class: string }
local PEN_GROUPS: { { Tier: number, Left: { PenSpec }, Right: { PenSpec } } } = {
	{
		Tier = 0,
		Left = {
			{ Index = 1, Class = "Standard" },
			{ Index = 3, Class = "Standard" },
			{ Index = 5, Class = "Standard" },
		},
		Right = {
			{ Index = 2, Class = "Standard" },
			{ Index = 4, Class = "Standard" },
			{ Index = 6, Class = "Standard" },
		},
	},
	{
		Tier = 1,
		Left = { { Index = 7, Class = "Standard" }, { Index = 9, Class = "Standard" } },
		Right = { { Index = 8, Class = "Standard" }, { Index = 10, Class = "Standard" } },
	},
	{
		Tier = 2,
		Left = { { Index = 11, Class = "Medium" }, { Index = 13, Class = "Medium" } },
		Right = { { Index = 12, Class = "Medium" }, { Index = 14, Class = "Medium" } },
	},
	{
		Tier = 3,
		Left = { { Index = 15, Class = "Giant" } },
		Right = { { Index = 16, Class = "Large" }, { Index = 17, Class = "Large" } },
	},
	{
		Tier = 4,
		Left = { { Index = 18, Class = "Giant" }, { Index = 22, Class = "Medium" } },
		Right = { { Index = 20, Class = "Medium" }, { Index = 21, Class = "Medium" } },
	},
}
-- The back row, left to right walking in: a mega yard, the gargantuan yard, a mega yard.
local BACK_ROW = {
	{ Index = 23, Tier = 5, Lateral = YARD.Y + YARD_GAP },
	{ Index = 19, Tier = 4, Lateral = 0 },
	{ Index = 24, Tier = 5, Lateral = -(YARD.Y + YARD_GAP) },
}

local function penSize(class: string): Vector2
	if class == "Giant" then
		return GIANT
	elseif class == "Gargantuan" then
		return YARD
	elseif class == "Medium" or class == "Large" then
		return MEDIUM
	end
	return STALL
end

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

-- The stamped parts and decor under a root, in GetDescendants order. Pens are refreshed
-- every income tick, so rescanning each pen's whole tree (animal included) every second
-- was the cost. The list is dropped whenever anything under the root is added or removed.
type Layout = { Parts: { BasePart }, Decor: { Instance } }
local layouts: { [Instance]: Layout } = {}
local layoutWatched: { [Instance]: boolean } = {}

local function layoutOf(root: Instance): Layout
	local cached = layouts[root]
	if cached then
		return cached
	end
	local parts: { BasePart } = {}
	local decor: { Instance } = {}
	for _, d in root:GetDescendants() do
		if d:GetAttribute("LayoutPart") == true and d:IsA("BasePart") then
			table.insert(parts, d)
		elseif d:GetAttribute("LayoutDecor") == true then
			if d:IsA("ProximityPrompt") or d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("Light") then
				table.insert(decor, d)
			end
		end
	end
	cached = { Parts = parts, Decor = decor }
	layouts[root] = cached
	if not layoutWatched[root] then
		layoutWatched[root] = true
		local function invalidate()
			layouts[root] = nil
		end
		root.DescendantAdded:Connect(invalidate)
		root.DescendantRemoving:Connect(invalidate)
		root.Destroying:Connect(function()
			layouts[root] = nil
			layoutWatched[root] = nil
		end)
	end
	return cached
end

-- Shows or hides a pen or barn shell. Only parts stamped at build time move, so an
-- animal standing in the pen is left alone.
function WorldBuilder.setShown(root: Instance, shown: boolean)
	local layout = layoutOf(root)
	for _, d in layout.Parts do
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
	end
	for _, d in layout.Decor do
		(d :: any).Enabled = shown and d:GetAttribute("RestEnabled") == true
	end
end

-- A locked pen in the next unlock group: a faint outline you can walk through, with no
-- prompts or pad, so players see what the next upgrade gives them and where.
function WorldBuilder.setGhost(root: Instance)
	local layout = layoutOf(root)
	for _, d in layout.Parts do
		local rest = d:GetAttribute("RestTransparency") :: number
		d.Transparency = if rest >= 1 or d.Name == "CollectPad" then 1 else math.max(rest, 0.72)
		d.CanCollide = false
		d.CanTouch = false
		d.CanQuery = false
	end
	for _, d in layout.Decor do
		(d :: any).Enabled = false
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

-- The two plaza shops: the gear shop is a booth on the left of the hub plaza, and the Robux
-- shop is the same booth in bright blue on the right, both with their counters turned to the
-- plaza. The gear for the player's tier (StationProps) stands at GearSpot, right of the wash
-- arm on the road, with the fire truck at TruckSpot beside it; the showcase podium mirrors it.
local SHOP_DEPTH = PLAZA_DEPTH
local SHOP_LAT = PLAZA_HALF_LAT + 6
local GEAR_DEPTH = 30
local GEAR_LAT = WASH_LAT - 15

type BoothSpec = {
	Name: string,
	Lateral: number,
	Counter: Color3,
	Stripe: Color3, -- every other awning stripe; the rest are white
	Sign: Color3,
	SignText: string,
	SignTextColor: Color3,
	SignStroke: Color3,
	PromptName: string,
	PromptAction: string,
	PromptObject: string,
	Keeper: string,
}

local GEAR_BOOTH: BoothSpec = {
	Name = "UpgradeStation",
	Lateral = SHOP_LAT,
	Counter = Color3.fromRGB(60, 150, 230),
	Stripe = Color3.fromRGB(230, 60, 60),
	Sign = Color3.fromRGB(255, 210, 70),
	SignText = "GEAR SHOP",
	SignTextColor = Color3.fromRGB(60, 40, 20),
	SignStroke = Color3.new(1, 1, 1),
	PromptName = "UpgradePrompt",
	PromptAction = "Upgrade Gear",
	PromptObject = "Gear Shop",
	Keeper = "Shop",
}

-- Every Robux purchase in the world lives here (Monetization adds the auto-collect prompt).
local ROBUX_BOOTH: BoothSpec = {
	Name = "RobuxShop",
	Lateral = -SHOP_LAT,
	Counter = Color3.fromRGB(0, 120, 255),
	Stripe = Color3.fromRGB(0, 160, 255),
	Sign = Color3.fromRGB(40, 190, 255),
	SignText = "ROBUX SHOP",
	SignTextColor = Color3.new(1, 1, 1),
	SignStroke = Color3.fromRGB(0, 40, 110),
	PromptName = "RobuxShopPrompt",
	PromptAction = "Open Robux Shop",
	PromptObject = "Robux Shop",
	Keeper = "Robux Shop",
}

local function buildBooth(plot: PlotLayout.PlotFrame, parent: Instance, spec: BoothSpec)
	local station = Instance.new("Model")
	station.Name = spec.Name
	local base = PlotLayout.point(plot, SHOP_DEPTH, spec.Lateral, 0)
	-- Local -Z faces the plaza, so the counter is what you see stepping out of the wash.
	local plazaCentre = PlotLayout.point(plot, PLAZA_DEPTH, 0, 0)
	local frame = CFrame.lookAt(base, plazaCentre)
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
	local white = Color3.fromRGB(245, 245, 240)
	local wood = Color3.fromRGB(200, 150, 95)
	block("Deck", Vector3.new(9, 0.4, 7), CFrame.new(0, 0.2, 0.5), wood, { Material = Enum.Material.WoodPlanks })
	local counter = block("Counter", Vector3.new(8, 3.2, 1.6), CFrame.new(0, 2, -2.2), spec.Counter)
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
			if i % 2 == 0 then spec.Stripe else white,
			{ CanQuery = false }
		)
	end
	local sign = block("Sign", Vector3.new(8, 2.2, 0.4), CFrame.new(0, 11.2, -0.6), spec.Sign, {
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
	text.Text = spec.SignText
	text.Parent = gui
	UIStyle.text(text, spec.SignTextColor, spec.SignStroke, 2)
	-- Wares hang on the back wall: a sponge, a brush, a nozzle.
	block(
		"Hook1",
		Vector3.new(1.2, 0.8, 0.4),
		CFrame.new(-2.6, 6, 3.3),
		Color3.fromRGB(255, 220, 70),
		{ CanQuery = false }
	)
	block("Hook2", Vector3.new(0.3, 2, 0.4), CFrame.new(0, 6, 3.3), Color3.fromRGB(170, 115, 60), { CanQuery = false })
	block("Hook3", Vector3.new(0.5, 0.5, 1.6), CFrame.new(2.6, 6, 3.1), spec.Stripe, { CanQuery = false })
	local prompt = makePrompt(spec.PromptName, spec.PromptAction, 0, counter)
	prompt.ObjectText = spec.PromptObject
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
			humanoid.DisplayName = spec.Keeper
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
end

local function buildUpgradeStation(plot: PlotLayout.PlotFrame, parent: Instance)
	buildBooth(plot, parent, GEAR_BOOTH)
	buildBooth(plot, parent, ROBUX_BOOTH)

	local gearPos = PlotLayout.point(plot, GEAR_DEPTH, GEAR_LAT, FLOOR_Y - 0.5)
	makeMarker("GearSpot", CFrame.lookAt(gearPos, gearPos + plot.Right), parent)
	-- Nose toward the road, beside the gear spot.
	local truckPos = PlotLayout.point(plot, 24, WASH_LAT - 32, 0)
	makeMarker("TruckSpot", CFrame.lookAt(truckPos, truckPos + plot.Look), parent)
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
		local sell = makePrompt("SellPrompt", "Sell", 0, slot, Enum.KeyCode.F)
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
	-- E picks up / places, F sells, R sets the pet.
	makePrompt("PenPrompt", "Pick up", 0, post).Enabled = false
	local sell = makePrompt("PenSellPrompt", "Sell", 0, post, Enum.KeyCode.F)
	sell.UIOffset = Vector2.new(0, 36)
	sell.GamepadKeyCode = Enum.KeyCode.ButtonY
	sell.Enabled = false
	local pet = makePrompt("PetPrompt", "Set pet", 0, post, Enum.KeyCode.R)
	pet.UIOffset = Vector2.new(0, 72)
	pet.GamepadKeyCode = Enum.KeyCode.ButtonX
	pet.Enabled = false
	-- Collect pad sits on the path in front of the cage, not inside it.
	local facingRoad = math.abs(look:Dot(plot.Look)) > 0.5
	local padPos
	if facingRoad then
		padPos = gate + look * 2.2
	else
		-- Side pens: on the walkway's edge, level with the pen, so walking it collects.
		local sign = if lateral >= 0 then 1 else -1
		padPos = PlotLayout.point(plot, depth, sign * (WALK_HALF - 2.2), 0.3)
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
	local status = billboardLabel(floor, "", Vector3.new(0, 4, 0), Vector2.new(96, 36))
	local stroke = status:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = 1.25
	end
	(status.Parent :: Instance).Name = "Status"
	local reach = if alongDepth then depthSize / 2 + 2 else latSize / 2 + 2
	addPenPrompts(plot, pen, depth, lateral, look, reach)
end

local function inwardLook(plot: PlotLayout.PlotFrame, lateral: number): Vector3
	return if lateral >= 0 then -plot.Right else plot.Right
end

-- An unlock stand: a counter across the walkway in front of the next locked group, with the
-- price over it. ZooService moves it to that group's UnlockSpot after every purchase.
local function buildExpandStand(zoo: Folder, at: CFrame)
	local stand = Instance.new("Model")
	stand.Name = "ExpandStand"
	local counter = makePart({
		Name = "ExpandCounter",
		Size = Vector3.new(2, 3, 6),
		CFrame = at * CFrame.new(0, 1.5, 0),
		Color = Color3.fromRGB(120, 170, 80),
		Parent = stand,
	})
	for _, side in { -1, 1 } do
		makePart({
			Name = "Post",
			Size = Vector3.new(0.5, 6, 0.5),
			CFrame = at * CFrame.new(side * 3.2, 3, 0),
			Color = Color3.fromRGB(186, 42, 36),
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = stand,
		})
	end
	makePart({
		Name = "Awning",
		Size = Vector3.new(7.4, 0.4, 2.6),
		CFrame = at * CFrame.new(0, 6.2, 0),
		Color = Color3.fromRGB(200, 60, 50),
		CanQuery = false,
		Parent = stand,
	})
	local label = billboardLabel(counter, "", Vector3.new(0, 6, 0), Vector2.new(200, 56), Color3.fromRGB(255, 230, 120))
	label.Name = "NextLabel"
	label.TextWrapped = true
	makePrompt("ExpandPrompt", "Expand Farm", 0.5, counter).ObjectText = "Barn Upgrade"
	stand.PrimaryPart = counter
	stand.WorldPivot = at
	stand.Parent = zoo
end

local function buildZoo(plot: PlotLayout.PlotFrame, bay: Model)
	local zoo = Instance.new("Folder")
	zoo.Name = "Zoo"

	local function addPen(
		index: number,
		depth: number,
		lateral: number,
		size: Vector2,
		class: string,
		look: Vector3
	): Model
		local pen = Instance.new("Model")
		pen.Name = "Pen" .. index
		pen:SetAttribute("PenIndex", index)
		pen:SetAttribute("PenClass", class)
		buildFencedPen(plot, pen, depth, lateral, size.X, size.Y, look)
		pen.Parent = zoo
		if index > GameConfig.Zoo.StartPens then
			WorldBuilder.setShown(pen, false)
		end
		return pen
	end

	-- One side of the walkway: pens back to back from `start`. Returns where the row ends.
	local function row(start: number, side: number, specs: { PenSpec }): number
		local cursor = start
		for _, spec in specs do
			local size = penSize(spec.Class)
			local lateral = side * (PEN_INNER + size.Y / 2)
			addPen(spec.Index, cursor + size.X / 2, lateral, size, spec.Class, inwardLook(plot, lateral))
			cursor += size.X + PEN_GAP
		end
		return cursor
	end

	local function unlockSpot(tier: number, depth: number)
		local pos = PlotLayout.point(plot, depth, 0, 0)
		makeMarker("UnlockSpot" .. tier, CFrame.lookAt(pos, pos + plot.Look), zoo)
	end

	local cursor = FIRST_PEN
	for _, group in PEN_GROUPS do
		if group.Tier > 0 then
			unlockSpot(group.Tier, cursor - GROUP_GAP / 2)
		end
		local left = row(cursor, 1, group.Left)
		local right = row(cursor, -1, group.Right)
		cursor = math.max(left, right) + GROUP_GAP

		-- The Robux pastures follow the starting stalls: the first upgrade a new player walks
		-- past. Each shows its lock until bought.
		if group.Tier == 0 then
			local sides: { [number]: number } = { [1] = cursor, [-1] = cursor }
			for offset, spec in GameConfig.Zoo.RoadCages do
				local index = GameConfig.Zoo.MaxPens + offset
				local size = PASTURE_SIZE[spec.Class] or 16
				local side = if spec.Side == "Left" then 1 else -1
				local lateral = side * (PEN_INNER + size / 2)
				local depth = sides[side] + size / 2
				sides[side] += size + PEN_GAP
				local pen =
					addPen(index, depth, lateral, Vector2.new(size, size), spec.Class, inwardLook(plot, lateral))
				pen:SetAttribute("RoadUnlock", spec.Unlock)
				local builtFloor = pen:FindFirstChild("Floor")
				local large = spec.Class == "PastureLarge"
				local labelColor = if large then Color3.fromRGB(255, 196, 80) else Color3.fromRGB(130, 220, 255)
				if builtFloor and builtFloor:IsA("BasePart") then
					local classLabel =
						billboardLabel(builtFloor, spec.Label, Vector3.new(0, 5, 0), Vector2.new(110, 24), labelColor)
					classLabel.Name = "ClassLabel"
				end
				-- A red bar across the gate, facing the walkway, with what unlocks it.
				local lock = Instance.new("Model")
				lock.Name = "FlexLock"
				local bar = makePart({
					Name = "Bar",
					Size = Vector3.new(size - 6, 4.5, 0.6),
					Position = PlotLayout.point(plot, depth, lateral - side * (size / 2 - 1.2), 2.4),
					Color = Color3.fromRGB(176, 48, 40),
					Material = Enum.Material.Wood,
					Parent = lock,
				})
				local lockLabel = billboardLabel(
					bar,
					spec.Lock,
					Vector3.new(0, 3.2, 0),
					Vector2.new(120, 32),
					Color3.fromRGB(255, 230, 120)
				)
				lockLabel.Name = "LockLabel"
				lockLabel.TextWrapped = true
				local lockGui = lockLabel.Parent :: BillboardGui
				lockGui.MaxDistance = 40
				lock.Parent = pen
				compactBillboards(pen, 0.72)
				-- Every road cage can be bought with cash at its gate.
				local post = pen:FindFirstChild("GatePost")
				if post and typeof(spec.Price) == "number" then
					local unlock = makePrompt("UnlockPrompt", `Unlock ({UIStyle.formatMoney(spec.Price)})`, 0.6, post)
					unlock.ObjectText = if large then "Large cage" else "Medium cage"
					unlock.Enabled = false
					unlock:SetAttribute("RestEnabled", true)
				end
				WorldBuilder.setShown(pen, false)
			end
			cursor = math.max(sides[1], sides[-1]) - PEN_GAP + GROUP_GAP
		end
	end

	-- The back row: three gargantuan yards abreast, gates toward the walkway's end.
	unlockSpot(5, cursor - GROUP_GAP / 2)
	for _, yard in BACK_ROW do
		addPen(yard.Index, cursor + YARD.X / 2, yard.Lateral, YARD, "Gargantuan", plot.Look)
	end
	zoo:SetAttribute("WalkEnd", cursor + 2)

	local first = zoo:FindFirstChild("UnlockSpot1")
	buildExpandStand(zoo, if first and first:IsA("BasePart") then first.CFrame else CFrame.new())
	zoo.Parent = bay
end

local function buildWash(plot: PlotLayout.PlotFrame, bay: Model)
	local armW = 12
	local armStart = 0
	-- The arms stop where the cross piece starts instead of running under it: overlapping
	-- slabs with the same top height flicker (z-fight) at the two corners.
	local edgeSpan = YARD_D - (armW + 1.6) / 2 - armStart
	local paveSpan = YARD_D - armW / 2 - (armStart + 0.5)
	local function arm(name: string, lateral: number, dirt: Color3, edge: Color3)
		makePart({
			Name = name,
			Size = Vector3.new(edgeSpan, 0.35, armW + 1.6),
			Position = PlotLayout.point(plot, armStart + edgeSpan / 2, lateral, 0.12),
			Color = edge,
			Material = Enum.Material.Ground,
			CanQuery = false,
			CanCollide = false,
			Parent = bay,
		})
		makePart({
			Name = name .. "Pave",
			Size = Vector3.new(paveSpan, 0.28, armW),
			Position = PlotLayout.point(plot, armStart + 0.5 + paveSpan / 2, lateral, 0.28),
			Color = dirt,
			Material = Enum.Material.Ground,
			CanQuery = false,
			CanCollide = false,
			Parent = bay,
		})
	end
	-- Animals walk in on a dirt path. The cache arm, where washed ones wait, is darker dirt.
	arm("WashArm", WASH_LAT, PATH_DIRT, PATH_EDGE)
	arm("CacheArm", CACHE_LAT, CACHE_DIRT, CACHE_EDGE)
	local spanLat = (CACHE_LAT - WASH_LAT) + armW
	makePart({
		Name = "DriveCross",
		Size = Vector3.new(armW + 1.6, 0.35, spanLat + 1.6),
		Position = PlotLayout.point(plot, YARD_D, 0, 0.12),
		Color = PATH_EDGE,
		Material = Enum.Material.Ground,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	makePart({
		Name = "DriveCrossPave",
		Size = Vector3.new(armW, 0.28, spanLat),
		Position = PlotLayout.point(plot, YARD_D, 0, 0.28),
		Color = PATH_DIRT,
		Material = Enum.Material.Ground,
		CanQuery = false,
		CanCollide = false,
		Parent = bay,
	})
	-- Mouth of the U, so the two arms read as one drive off the main road.
	makePart({
		Name = "DriveApron",
		Size = Vector3.new(6, 0.3, spanLat),
		Position = PlotLayout.point(plot, -1, 0, 0.2),
		Color = PATH_DIRT,
		Material = Enum.Material.Ground,
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
	-- On the street in line with the wash arm, at the same depth as Approach: arrivals walk
	-- along the road, turn here, and go straight up the arm instead of cutting the corner.
	local turn = PlotLayout.point(plot, ROAD_D, WASH_LAT, FLOOR_Y)
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

-- The hub plaza behind the drive, and the walkway from it to the back row.
local function buildSidewalk(plot: PlotLayout.PlotFrame, bay: Model)
	local paving = Color3.fromRGB(190, 175, 150)
	makePart({
		Name = "Plaza",
		Size = Vector3.new(PLAZA_HALF_DEPTH * 2, 0.35, PLAZA_HALF_LAT * 2),
		Position = PlotLayout.point(plot, PLAZA_DEPTH, 0, 0.18),
		Color = paving,
		Material = Enum.Material.Cobblestone,
		CanQuery = false,
		Parent = bay,
	})
	local zoo = bay:FindFirstChild("Zoo")
	local walkEnd = zoo and zoo:GetAttribute("WalkEnd")
	local to = if typeof(walkEnd) == "number" then walkEnd else 300
	makePart({
		Name = "Sidewalk",
		Size = Vector3.new(to - WALK_START, 0.35, GameConfig.SidewalkWidth),
		-- Clear of the plaza's top where the two overlap, so the join does not flicker.
		Position = PlotLayout.point(plot, (WALK_START + to) / 2, 0, 0.22),
		Color = paving,
		Material = Enum.Material.Cobblestone,
		CanQuery = false,
		Parent = bay,
	})
end

-- The showcase podium at the road, left of the drive: the farm's name, its income, and its
-- best animal on top (ZooService fills those in), so anyone walking the road sees them.
local SHOWCASE_DEPTH = 18
local SHOWCASE_LAT = CACHE_LAT + 24
local function buildShowcase(plot: PlotLayout.PlotFrame, bay: Model)
	local model = Instance.new("Model")
	model.Name = "Showcase"
	local base = PlotLayout.point(plot, SHOWCASE_DEPTH, SHOWCASE_LAT, 0)
	local frame = CFrame.lookAt(base, base + plot.Look) -- faces the road
	makePart({
		Name = "Plinth",
		Size = Vector3.new(16, 1.6, 16),
		CFrame = frame * CFrame.new(0, 0.8, 0),
		Color = Color3.fromRGB(235, 225, 200),
		Material = Enum.Material.Marble,
		Parent = model,
	})
	makePart({
		Name = "Top",
		Size = Vector3.new(13, 0.5, 13),
		CFrame = frame * CFrame.new(0, 1.85, 0),
		Color = Color3.fromRGB(200, 40, 50),
		Material = Enum.Material.Fabric,
		CanQuery = false,
		Parent = model,
	})
	-- Corner posts stand a little proud of the plinth's sides and clear of the cloth top, so
	-- no two faces share a plane (they flickered when flush).
	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			makePart({
				Name = "Corner",
				Size = Vector3.new(1.5, 2.4, 1.5),
				CFrame = frame * CFrame.new(x * 7.3, 1.2, z * 7.3),
				Color = Color3.fromRGB(255, 200, 70),
				Material = Enum.Material.Metal,
				CanQuery = false,
				Parent = model,
			})
		end
	end
	local top = frame * CFrame.new(0, 2.1, 0)
	makeMarker("ShowcaseSlot", top, model)
	-- BayService writes the farm name into SignPost.Sign.BayLabel.
	local post = makeMarker("SignPost", frame * CFrame.new(0, 2.1, 6.5), model)
	local sign = billboardLabel(post, "", Vector3.new(0, 0, 0), Vector2.new(300, 52))
	sign.Name = "BayLabel"
	local signGui = sign.Parent :: BillboardGui
	signGui.Name = "Sign"
	signGui.MaxDistance = 160
	signGui.StudsOffsetWorldSpace = Vector3.new(0, 15, 0)
	local income = billboardLabel(post, "", Vector3.new(0, 0, 0), Vector2.new(240, 40), UIStyle.CashColor)
	income.Name = "IncomeLabel"
	local incomeGui = income.Parent :: BillboardGui
	incomeGui.Name = "Income"
	incomeGui.MaxDistance = 160
	-- Same anchor as the name, one row lower in pixels, so the two never overlap at any range.
	incomeGui.StudsOffsetWorldSpace = Vector3.new(0, 15, 0)
	incomeGui.SizeOffset = Vector2.new(0, -1.15)
	model.Parent = bay
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
	buildShowcase(plot, bay)

	-- In the middle of the hub plaza, facing the wash.
	local spawnPos = PlotLayout.point(plot, PLAZA_DEPTH, 0, FLOOR_Y)
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
	-- Players land on the plaza; the pad itself is never seen.
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	for _, child in spawn:GetChildren() do
		if child:IsA("Decal") then
			child:Destroy()
		end
	end
	spawn.Parent = bay

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
