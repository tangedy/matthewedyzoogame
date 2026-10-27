-- Builds one farm when a player is given a plot, and destroys it when they leave.
-- Slots 1-4 are east of the road, 5-8 west. Each plot faces the road and grows backward:
--   road front: showcase podium | U driveway (cache arm, wash arm) | tier gear + truck
--   hub plaza (gear shop, Robux shop, spawn) -> one walkway, pens on both sides in unlock order
--   -> three gargantuan yards across the back.
--
-- Each bay exposes:
--   Approach, TurnIn, WashPosition, Queue2, Queue3, RoadReturn, Exit, StreetEnd
--   Spawn                          the owner's SpawnLocation
--   Showcase.SignPost.Sign.BayLabel   owner name over the podium (Income.IncomeLabel, ShowcaseSlot)
--   UpgradeStation.Counter         hose shop prompt
--   Cache.Slot{i}                  where washed animals wait (PickupPrompt, SellPrompt)
--   Zoo.Pen{i}                     Floor, Slot, GatePost.PenPrompt, CollectPad (+ Cash label)
--   Zoo.ExpandStand.ExpandCounter  barn upgrade; ZooService moves it to Zoo.UnlockSpot{tier}
--   GearSpot / TruckSpot           where StationProps parks the tier's gear and the fire truck
--   RobuxShop.Counter              Robux shop prompt (opens the shop panel, Monetization)
--   RobuxKiosk{Key}.Counter        single-item Robux stands around the plot (RobuxKioskPrompt)
--   AutoCleanPad.AutoCleanSign.Status  auto-wash pad beside the spawn (AutoCleanService)
--   Zoo.Pen19 / 23 / 24  the three gargantuan yards across the back
--   Zoo.Pen25-28   the Robux pastures, right after the starting stalls

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local PenTiers = require(ReplicatedStorage.Shared.PenTiers)
local PlotLayout = require(ReplicatedStorage.Shared.PlotLayout)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local WorldBuilder = {}

local folder: Folder

local FLOOR_Y = 0.5
-- The dirt drive animals walk in on, out to the wash and back past the cache.
local PATH_DIRT = Color3.fromRGB(176, 132, 86)
local PATH_EDGE = Color3.fromRGB(140, 102, 66)
local SIDEWALK_PAVING = Color3.fromRGB(190, 175, 150)

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
-- Side pens' inner edge: a strip of grass between the walkway and the fences, crossed by a
-- short paved path to each gate.
local PEN_SETBACK = 4
local PEN_INNER = WALK_HALF + PEN_SETBACK
local PEN_GAP = 2 -- between pens on one side
local GROUP_GAP = 6 -- between unlock groups; the next group's unlock stand stands in it
local FIRST_PEN = PLAZA_DEPTH + PLAZA_HALF_DEPTH + 2

-- Pen sizes by class: depth along the walkway, lateral away from it.
local STALL = Vector2.new(10, 10)
local MEDIUM = Vector2.new(12, 10.5)
local GIANT = Vector2.new(24, 21)
local YARD = Vector2.new(48, 38) -- gargantuan yards, one each side at the walkway end

-- Which pens unlock together, and which side of the walkway each goes on (+1 left walking in,
-- -1 right). Tier is the step's index in GameConfig.Zoo.Expansions (0 is the six starting
-- stalls). Pen numbers are the save format;
-- only where the pens stand.
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
	{ Tier = 1, Left = { { Index = 7, Class = "Medium" } }, Right = { { Index = 8, Class = "Medium" } } },
	{
		Tier = 2,
		Left = { { Index = 9, Class = "Medium" }, { Index = 11, Class = "Medium" } },
		Right = { { Index = 10, Class = "Medium" }, { Index = 12, Class = "Medium" } },
	},
	{
		Tier = 3,
		Left = { { Index = 13, Class = "Medium" }, { Index = 15, Class = "Medium" }, { Index = 17, Class = "Medium" } },
		Right = { { Index = 14, Class = "Medium" }, { Index = 16, Class = "Medium" }, { Index = 18, Class = "Medium" } },
	},
	{ Tier = 4, Left = { { Index = 19, Class = "Giant" } }, Right = { { Index = 20, Class = "Giant" } } },
	{ Tier = 5, Left = { { Index = 21, Class = "Gargantuan" } }, Right = { { Index = 22, Class = "Gargantuan" } } },
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

-- A wedge (full faces on its bottom and back, sloping down to the front), as decor.
local function wedgeBlock(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
	local part = makePart({
		Name = name,
		Size = size,
		CFrame = cframe,
		Color = color,
		Material = Enum.Material.WoodPlanks,
		CanQuery = false,
		Parent = parent,
	})
	part.Shape = Enum.PartType.Wedge
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
local GEAR_DEPTH = 27 -- clear of the Robux kiosk row behind it
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
	Hold: number, -- seconds; the Robux booth needs a short hold so walking past never opens it
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
	Hold = 0,
	Keeper = "Shop",
}

-- The full Robux shop panel opens here; a few items also have their own kiosks (KIOSKS).
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
	Hold = 0.3,
	Keeper = "Robux Shop",
}

-- Shopkeeper look: warm skin, a cream shirt (the arms are sleeves; hands get skin below) and
-- brown trousers. Built from colours alone, so no catalog asset can fail to load.
local MERCHANT_SKIN = Color3.fromRGB(234, 184, 146)
local MERCHANT_SHIRT = Color3.fromRGB(240, 228, 200)
local MERCHANT_TROUSERS = Color3.fromRGB(95, 66, 44)
local MERCHANT_HAIR = Color3.fromRGB(70, 45, 30)

local function merchantLook(): HumanoidDescription
	local look = Instance.new("HumanoidDescription")
	look.HeadColor = MERCHANT_SKIN
	look.TorsoColor = MERCHANT_SHIRT
	look.LeftArmColor = MERCHANT_SHIRT
	look.RightArmColor = MERCHANT_SHIRT
	look.LeftLegColor = MERCHANT_TROUSERS
	look.RightLegColor = MERCHANT_TROUSERS
	return look
end

-- Dresses an anchored R15 shopkeeper: an apron in the booth's colour with a neck strap and a
-- pocket, a flat cap, a moustache, skin-coloured hands and dark shoes. Every piece is
-- anchored in place on the posed rig (the keeper never moves).
local function dressMerchant(keeper: Model, apron: Color3)
	local function piece(name: string, size: Vector3, cframe: CFrame, color: Color3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cframe
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Parent = keeper
		return p
	end
	local function part(name: string): BasePart?
		local found = keeper:FindFirstChild(name)
		return if found and found:IsA("BasePart") then found else nil
	end
	-- A BodyColors instance overrides part colours and can leave the rig black, so drop it and
	-- paint every limb directly.
	for _, child in keeper:GetChildren() do
		if child:IsA("BodyColors") or child:IsA("CharacterMesh") then
			child:Destroy()
		end
	end
	local limbColors: { [string]: Color3 } = {
		Head = MERCHANT_SKIN,
		UpperTorso = MERCHANT_SHIRT,
		LowerTorso = MERCHANT_SHIRT,
		LeftUpperArm = MERCHANT_SHIRT,
		LeftLowerArm = MERCHANT_SHIRT,
		RightUpperArm = MERCHANT_SHIRT,
		RightLowerArm = MERCHANT_SHIRT,
		LeftUpperLeg = MERCHANT_TROUSERS,
		LeftLowerLeg = MERCHANT_TROUSERS,
		RightUpperLeg = MERCHANT_TROUSERS,
		RightLowerLeg = MERCHANT_TROUSERS,
	}
	for name, color in limbColors do
		local limb = part(name)
		if limb then
			limb.Color = color
			limb.Material = Enum.Material.SmoothPlastic
		end
	end
	for _, name in { "LeftHand", "RightHand" } do
		local hand = part(name)
		if hand then
			hand.Color = MERCHANT_SKIN
		end
	end
	for _, name in { "LeftFoot", "RightFoot" } do
		local foot = part(name)
		if foot then
			foot.Color = Color3.fromRGB(40, 30, 25)
		end
	end

	-- R15 faces -Z, so the apron hangs on each torso piece's front face.
	local pocket = apron:Lerp(Color3.new(0, 0, 0), 0.25)
	local upper = part("UpperTorso")
	if upper then
		local s = upper.Size
		piece(
			"ApronBib",
			Vector3.new(s.X * 0.62, s.Y * 0.7, 0.06),
			upper.CFrame * CFrame.new(0, -s.Y * 0.12, -s.Z / 2 - 0.03),
			apron
		)
		piece(
			"ApronStrap",
			Vector3.new(s.X * 0.62, 0.12, s.Z + 0.1),
			upper.CFrame * CFrame.new(0, s.Y * 0.38, 0),
			apron
		)
	end
	local lower = part("LowerTorso")
	if lower then
		local s = lower.Size
		-- Down past the hips to mid-thigh.
		local skirt = s.Y + 1.1
		piece(
			"ApronSkirt",
			Vector3.new(s.X * 0.9, skirt, 0.06),
			lower.CFrame * CFrame.new(0, s.Y / 2 - skirt / 2, -s.Z / 2 - 0.08),
			apron
		)
		piece(
			"ApronPocket",
			Vector3.new(s.X * 0.5, 0.35, 0.04),
			lower.CFrame * CFrame.new(0, -s.Y * 0.6, -s.Z / 2 - 0.12),
			pocket
		)
		piece("ApronTie", Vector3.new(s.X + 0.1, 0.14, s.Z + 0.1), lower.CFrame * CFrame.new(0, s.Y * 0.35, 0), apron)
	end

	local head = part("Head")
	if head then
		local s = head.Size
		local top = head.CFrame * CFrame.new(0, s.Y / 2, 0)
		-- Flat cap: a crown with a short peak out front, and a band in the apron colour.
		piece("CapCrown", Vector3.new(s.X * 1.02, 0.32, s.Z * 1.02), top * CFrame.new(0, 0.06, 0.02), MERCHANT_TROUSERS)
		piece("CapBand", Vector3.new(s.X * 1.05, 0.1, s.Z * 1.05), top * CFrame.new(0, -0.05, 0.02), apron)
		piece(
			"CapPeak",
			Vector3.new(s.X * 0.8, 0.08, 0.4),
			top * CFrame.new(0, -0.04, -s.Z / 2 - 0.15) * CFrame.Angles(math.rad(-8), 0, 0),
			MERCHANT_TROUSERS
		)
		piece(
			"Hair",
			Vector3.new(s.X * 1.01, s.Y * 0.35, 0.1),
			head.CFrame * CFrame.new(0, s.Y * 0.1, s.Z / 2 + 0.03),
			MERCHANT_HAIR
		)
		-- A friendly moustache just above the smile.
		piece(
			"Moustache",
			Vector3.new(s.X * 0.42, 0.12, 0.06),
			head.CFrame * CFrame.new(0, -s.Y * 0.06, -s.Z / 2 - 0.03),
			MERCHANT_HAIR
		)
	end
end

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
	local prompt = makePrompt(spec.PromptName, spec.PromptAction, spec.Hold, counter)
	prompt.ObjectText = spec.PromptObject
	prompt.MaxActivationDistance = 12
	station.Parent = parent

	task.spawn(function()
		local ok, result = pcall(function()
			return Players:CreateHumanoidModelFromDescription(merchantLook(), Enum.HumanoidRigType.R15)
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
		dressMerchant(keeper, spec.Stripe)
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
	-- No platform: washed animals wait right on the drive.
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
		-- Short, so the action card it carries floats low, near the animals' feet.
		Size = Vector3.new(0.6, 1, 0.6),
		Position = gate + Vector3.new(0, 0.5, 0) + plot.Right * 1.6,
		-- Only carries the prompts; never seen.
		Transparency = 1,
		CanCollide = false,
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
	local branch = pen:FindFirstChild("GatePath") :: BasePart?
	local padPos
	if branch then
		-- On the paved branch between the walkway and the gate, right at the pen.
		padPos = Vector3.new(branch.Position.X, 0.3, branch.Position.Z)
	elseif facingRoad then
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
	-- Low fences so the animals show: stalls at 70% of the old height, every bigger pen at 50%.
	local heightScale = if pen:GetAttribute("PenClass") == "Standard" then 0.7 else 0.5
	local h = math.clamp(latSize * 0.28, 3.5, 8) * heightScale
	pen:SetAttribute("FenceHeight", h)
	local y = h / 2
	-- Fence wood by how much cash the pen's pad holds: oak, redwood, golden, royal.
	local wood = PenTiers.forClass(pen:GetAttribute("PenClass") :: string?).Wood
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
			Color = wood,
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = pen,
		})
		for _, edge in { -1, 1 } do
			makePart({
				Name = "Fence",
				Size = Vector3.new(depthSize, h, 0.4),
				Position = PlotLayout.point(plot, depth, lateral + edge * halfL, y),
				Color = wood,
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
				Color = wood,
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
			Color = wood,
			Material = Enum.Material.Wood,
			CanQuery = false,
			Parent = pen,
		})
		for _, edge in { -1, 1 } do
			makePart({
				Name = "Fence",
				Size = Vector3.new(0.4, h, latSize),
				Position = PlotLayout.point(plot, depth + edge * halfD, lateral, y),
				Color = wood,
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
				Color = wood,
				Material = Enum.Material.Wood,
				CanQuery = false,
				Parent = pen,
			})
		end
		-- Paving from the walkway's edge to the gate, across the setback grass.
		local gap = math.abs(frontLat) - WALK_HALF
		if gap > 0.5 then
			makePart({
				Name = "GatePath",
				Size = Vector3.new(gate + 1, 0.35, gap),
				Position = PlotLayout.point(plot, depth, sign * (WALK_HALF + gap / 2), 0.2),
				Color = SIDEWALK_PAVING,
				Material = Enum.Material.Cobblestone,
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
	local barnRed = Color3.fromRGB(176, 40, 36)
	local trim = Color3.fromRGB(250, 245, 235)
	local gold = Color3.fromRGB(255, 200, 70)
	local function block(name: string, size: Vector3, offset: CFrame, color: Color3, props: { [string]: any }?): Part
		local fields: { [string]: any } = {
			Name = name,
			Size = size,
			CFrame = at * offset,
			Color = color,
			CanQuery = false,
			Parent = stand,
		}
		for key, value in props or {} do
			fields[key] = value
		end
		return makePart(fields)
	end
	-- A barn front over the walkway: two board posts with white X-braces, a gable roof, and
	-- the next barn's name and price on a big hanging sign. Locked ghost pens stand behind it.
	local half = GameConfig.SidewalkWidth / 2 + 1.2
	for _, side in { -1, 1 } do
		local x = side * half
		block(
			"Post",
			Vector3.new(2.4, 11, 2.4),
			CFrame.new(x, 5.5, 0),
			barnRed,
			{ Material = Enum.Material.WoodPlanks }
		)
		for _, tilt in { -1, 1 } do
			block(
				"Brace",
				Vector3.new(0.35, 9.5, 0.3),
				CFrame.new(x, 5.2, -1.25) * CFrame.Angles(0, 0, tilt * 0.22),
				trim,
				{ Material = Enum.Material.Wood }
			)
		end
		block("PostCap", Vector3.new(2.8, 0.5, 2.8), CFrame.new(x, 11.2, 0), trim)
	end
	block(
		"Beam",
		Vector3.new(half * 2 + 2.4, 1.6, 2.4),
		CFrame.new(0, 11.6, 0),
		barnRed,
		{ Material = Enum.Material.WoodPlanks }
	)
	for _, side in { -1, 1 } do
		wedgeBlock(
			stand,
			"Roof",
			Vector3.new(3.6, 3.6, half + 2.4),
			-- Each half slopes down away from the ridge.
			at * CFrame.new(side * (half + 1.2) / 2, 14.2, 0) * CFrame.Angles(0, -side * math.pi / 2, 0),
			Color3.fromRGB(120, 30, 28)
		)
	end
	-- The sign: a white board with gold edges, hanging under the beam on two chains.
	local board = block("Sign", Vector3.new(half * 2 - 2, 3.4, 0.4), CFrame.new(0, 8.6, -0.2), trim)
	block("SignEdge", Vector3.new(half * 2 - 1.4, 3.9, 0.3), CFrame.new(0, 8.6, 0), gold)
	for _, side in { -1, 1 } do
		block(
			"Chain",
			Vector3.new(0.2, 1.2, 0.2),
			CFrame.new(side * (half - 2.5), 10.6, -0.2),
			Color3.fromRGB(90, 90, 95)
		)
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "BarnSign"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = board
	stampDecor(gui, true)
	local signText = Instance.new("TextLabel")
	signText.Name = "NextLabel"
	signText.Size = UDim2.fromScale(1, 1)
	signText.BackgroundTransparency = 1
	signText.Text = ""
	signText.Parent = gui
	UIStyle.text(signText, barnRed, Color3.new(1, 1, 1), 3)
	-- Warm bulbs along the beam and a sparkle off the sign, so it reads from the plaza.
	for i = -3, 3 do
		local bulb = block(
			"Bulb",
			Vector3.new(0.5, 0.5, 0.5),
			CFrame.new(i * (half / 3.2), 10.6, -1.3),
			Color3.fromRGB(255, 225, 140)
		)
		bulb.Material = Enum.Material.Neon
		bulb:SetAttribute("RestTransparency", 0)
	end
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "Sparkle"
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Rate = 6
	sparkle.Lifetime = NumberRange.new(0.6, 1)
	sparkle.Speed = NumberRange.new(0.5, 1.5)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Size = NumberSequence.new(0.5, 0)
	sparkle.Color = ColorSequence.new(gold)
	sparkle.LightEmission = 1
	sparkle.Shape = Enum.ParticleEmitterShape.Box
	sparkle.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	sparkle.Parent = board
	stampDecor(sparkle, true)
	-- The counter you buy at, in front of the gate.
	local counter = makePart({
		Name = "ExpandCounter",
		Size = Vector3.new(6, 3, 2),
		CFrame = at * CFrame.new(0, 1.5, -2.6),
		Color = Color3.fromRGB(120, 170, 80),
		Material = Enum.Material.WoodPlanks,
		Parent = stand,
	})
	local label = billboardLabel(counter, "", Vector3.new(0, 3.2, 0), Vector2.new(200, 40), gold)
	label.Name = "NextLabel"
	label.TextWrapped = true
	makePrompt("ExpandPrompt", "Expand Farm", 0.5, counter).ObjectText = "Farm Upgrade"
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
	-- One dirt path: in along the wash arm, out along the cache arm.
	arm("WashArm", WASH_LAT, PATH_DIRT, PATH_EDGE)
	arm("CacheArm", CACHE_LAT, PATH_DIRT, PATH_EDGE)
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
	-- The far end of Main Street on the wash-arm side, in this farm's lane: new animals appear
	-- here and run the whole street to the driveway. StreetEnd is the other end, where sold and
	-- let-go animals run off to. GameConfig.StreetRun.StreetEnd is how far along the road.
	local lane = PlotLayout.point(plot, ROAD_D, 0, FLOOR_Y)
	local reach = GameConfig.StreetRun.StreetEnd
	local inZ = if plot.Right.Z < 0 then reach else -reach -- the end behind the wash arm
	local startPos = Vector3.new(lane.X, FLOOR_Y, inZ)
	makeMarker("Approach", CFrame.lookAt(startPos, startPos + plot.Right), bay)
	local endPos = Vector3.new(lane.X, FLOOR_Y, -inZ)
	makeMarker("StreetEnd", CFrame.lookAt(endPos, endPos + plot.Right), bay)
	-- On the street in line with the wash arm, in the same lane as Approach: arrivals run
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
	local paving = SIDEWALK_PAVING
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

-- Robux kiosks: single-item stands lined up with the ROBUX SHOP booth, two on each side of
-- it, all facing the plaza like one storefront. Everything else stays in the shop panel.
-- Holding the prompt sends its ProductKey (Monetization client); the server then shows
-- Roblox's own purchase dialog, so a stray tap never spends anything.
type KioskSpec = { Key: string, Depth: number, Label: string }
local KIOSK_LAT = ROBUX_BOOTH.Lateral
local KIOSK_NEAR = 8 -- booth centre to the kiosk on either side of it
local KIOSK_STEP = 6.5 -- kiosk to kiosk
local KIOSKS: { KioskSpec } = {
	-- Road end of the row first.
	{ Key = "SpeedBoost", Depth = SHOP_DEPTH - KIOSK_NEAR - KIOSK_STEP, Label = "2X SPEED" },
	{ Key = "CashMedium", Depth = SHOP_DEPTH - KIOSK_NEAR, Label = "BAG OF CASH" },
	{ Key = "AutoCollect2h", Depth = SHOP_DEPTH + KIOSK_NEAR, Label = "AUTO-COLLECT" },
	{ Key = "VIPKeeper", Depth = SHOP_DEPTH + KIOSK_NEAR + KIOSK_STEP, Label = "VIP KEEPER" },
}

local function buildKiosk(plot: PlotLayout.PlotFrame, parent: Instance, spec: KioskSpec)
	local item: { Robux: number, DisplayName: string, Color: Color3 }? = MonetizationConfig.ProductsByKey[spec.Key]
		or MonetizationConfig.PassesByKey[spec.Key]
	if not item then
		warn(`[WorldBuilder] No Robux item {spec.Key} for a kiosk`)
		return
	end
	local station = Instance.new("Model")
	station.Name = "RobuxKiosk" .. spec.Key
	local base = PlotLayout.point(plot, spec.Depth, KIOSK_LAT, 0)
	-- Square to the row: every kiosk faces the walkway's line, the same way as the booth.
	local frame = CFrame.lookAt(base, PlotLayout.point(plot, spec.Depth, 0, 0))
	makePart({
		Name = "Pedestal",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 5, 5),
		CFrame = frame * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(245, 245, 240),
		Parent = station,
	})
	local counter = makePart({
		Name = "Counter",
		Size = Vector3.new(3.4, 3, 1.6),
		CFrame = frame * CFrame.new(0, 2.1, 0),
		Color = UIStyle.Colors.Robux,
		Parent = station,
	})
	-- A sign board on two posts over the counter. World-space text, so neighbouring kiosks'
	-- names never pile up over each other the way billboards did.
	for _, side in { -1, 1 } do
		makePart({
			Name = "SignPost",
			Size = Vector3.new(0.25, 2.3, 0.25),
			-- Behind the board, so no face shares its plane.
			CFrame = frame * CFrame.new(side * 1.9, 4.75, 0.5),
			Color = Color3.fromRGB(245, 245, 240),
			CanQuery = false,
			Parent = station,
		})
	end
	local board = makePart({
		Name = "Sign",
		Size = Vector3.new(4.6, 2.3, 0.3),
		CFrame = frame * CFrame.new(0, 6.6, 0.3),
		Color = ROBUX_BOOTH.Sign, -- the booth's sign blue, so the row reads as one storefront
		CanQuery = false,
		Parent = station,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.Parent = board
	local name = Instance.new("TextLabel")
	name.Name = "ItemName"
	name.Position = UDim2.fromScale(0.04, 0.06)
	name.Size = UDim2.fromScale(0.92, 0.5)
	name.BackgroundTransparency = 1
	name.Text = spec.Label
	name.Parent = gui
	UIStyle.text(name, item.Color, Color3.fromRGB(10, 30, 70), 2)
	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.Position = UDim2.fromScale(0.15, 0.56)
	price.Size = UDim2.fromScale(0.7, 0.38)
	price.BackgroundTransparency = 1
	price.Text = `R$ {item.Robux}`
	price.Parent = gui
	UIStyle.text(price, Color3.new(1, 1, 1), Color3.fromRGB(10, 30, 70), 2)
	-- A glowing token in the item's colour floats over the sign.
	makePart({
		Name = "Token",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 1.8, 1.8),
		CFrame = frame * CFrame.new(0, 8.8, 0.3) * CFrame.Angles(0, math.rad(90), 0),
		Color = item.Color,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		Parent = station,
	})
	local prompt = makePrompt("RobuxKioskPrompt", `Buy R$ {item.Robux}`, 0.3, counter)
	prompt.ObjectText = item.DisplayName
	-- Kiosks stand close together; a short reach keeps the prompt on the one you're facing.
	prompt.MaxActivationDistance = 6
	prompt:SetAttribute("ProductKey", spec.Key)
	station.Parent = parent
end

local function buildKiosks(plot: PlotLayout.PlotFrame, bay: Model)
	for _, spec in KIOSKS do
		buildKiosk(plot, bay, spec)
	end
end

-- The auto-wash pad: on the plaza beside the spawn, on the wash arm's side. AutoCleanService
-- washes the front animal while the owner stands on it and writes AutoCleanSign.Status.
local AUTO_PAD_LAT = -12
local AUTO_PAD_COLOR = Color3.fromRGB(70, 200, 255)
local function buildAutoCleanPad(plot: PlotLayout.PlotFrame, bay: Model)
	local size = GameConfig.AutoClean.PadSize
	local pos = PlotLayout.point(plot, PLAZA_DEPTH, AUTO_PAD_LAT, 0.42)
	local frame = CFrame.lookAt(pos, PlotLayout.point(plot, QUEUE_DEPTH[1], WASH_LAT, 0.42))
	makePart({
		Name = "AutoCleanRim",
		Size = Vector3.new(size + 1, 0.12, size + 1),
		CFrame = frame * CFrame.new(0, -0.04, 0),
		Color = Color3.new(1, 1, 1),
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = bay,
	})
	local pad = makePart({
		Name = "AutoCleanPad",
		Size = Vector3.new(size, 0.16, size),
		CFrame = frame,
		Color = AUTO_PAD_COLOR,
		Material = Enum.Material.Neon,
		Transparency = 0.35,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = bay,
	})
	local bubbles = Instance.new("ParticleEmitter")
	bubbles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	bubbles.Color = ColorSequence.new(Color3.fromRGB(200, 240, 255))
	bubbles.Size = NumberSequence.new(0.5, 0)
	bubbles.Lifetime = NumberRange.new(1, 1.6)
	bubbles.Rate = 6
	bubbles.Speed = NumberRange.new(1.5, 3)
	bubbles.EmissionDirection = Enum.NormalId.Top
	bubbles.LightEmission = 0.6
	bubbles.Parent = pad
	stampDecor(bubbles, true)

	local gui = Instance.new("BillboardGui")
	gui.Name = "AutoCleanSign"
	gui.Size = UDim2.fromOffset(260, 64)
	gui.StudsOffset = Vector3.new(0, 6, 0)
	gui.MaxDistance = 60
	gui.Parent = pad
	stampDecor(gui, true)
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.58)
	title.Text = "AUTO WASH"
	title.Parent = gui
	UIStyle.text(title, AUTO_PAD_COLOR)
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Position = UDim2.fromScale(0, 0.6)
	status.Size = UDim2.fromScale(1, 0.4)
	status.Text = "Stand here to wash hands-free"
	status.Parent = gui
	UIStyle.text(status)
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
	buildKiosks(plot, bay)
	buildAutoCleanPad(plot, bay)

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
