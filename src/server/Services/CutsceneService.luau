-- Spawn cutscene, set in the real world. The opening shot is the new player's own starter
-- bay: a muddy piglet at their wash, sponged by a copy of their avatar. A whip pan across the
-- road lands on a fully upgraded farm (every pen unlocked and stocked, tier 6 gear and the fire
-- truck, the showcase podium) where a top player on a crane rig fire-hoses a volcanic Kaiju at
-- the wash.
--
-- The maxed farm is a real bay from WorldBuilder, furnished once at startup and kept in
-- ServerStorage. Each new player gets a private copy in their PlayerGui (only they receive
-- it); CutsceneController drops it on the plot across the road for the length of the shot,
-- hiding whoever's farm is there on that client only. No plot is taken from real players.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local PlotLayout = require(ReplicatedStorage.Shared.PlotLayout)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Settings = require(ReplicatedStorage.Shared.CutsceneSettings)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local AnimalBuilder = require(script.Parent.AnimalBuilder)
local AnimalService = require(script.Parent.AnimalService)
local DirtRenderer = require(script.Parent.DirtRenderer)
local MutationPayout = require(script.Parent.MutationPayout)
local PlayerDataService = require(script.Parent.PlayerDataService)
local StationProps = require(script.Parent.StationProps)
local WorldBuilder = require(script.Parent.WorldBuilder)

local CutsceneService = {}

local skipAt: { [Player]: number } = {}
local endsAt: { [Player]: number } = {}
local sent: { [Player]: Instance } = {}
local setFailed = false
local template: Model? = nil
local janitor = Janitor.new()

-- The maxed farm is built on this plot's frame; the client moves it to the plot it needs.
local TEMPLATE_SLOT = 1
local SET_NAME = "CutsceneSet"
-- The client may start a little after begin() (it waits for its bay and this set), so the
-- server holds the lock this long past Duration before dropping it on its own.
local GRACE = 10
local READY_WAIT = 8 -- seconds begin() waits for the keeper's avatar before sending anyway
local SHOWCASE_MAX = 16 -- longest side of the podium animal, like ZooService's podium

local STEEL = Color3.fromRGB(168, 172, 178)
local CRANE_YELLOW = Color3.fromRGB(245, 186, 40)
local VOLCANIC = Color3.fromRGB(38, 30, 28)
local WATER = Color3.fromRGB(150, 215, 255)
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local MUTATIONS = { "Rainbow", "Diamond", "Gold" }

local function part(props: { [string]: any }): Part
	local block = Instance.new("Part")
	block.Anchored = true
	block.TopSurface = Enum.SurfaceType.Smooth
	block.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(block :: any)[key] = value
	end
	return block
end

-- A box or cylinder stretched from a to b.
local function span(
	parent: Instance,
	name: string,
	a: Vector3,
	b: Vector3,
	thickness: number,
	color: Color3,
	material: Enum.Material?,
	round: boolean?
): Part
	local length = (b - a).Magnitude
	local cframe = CFrame.lookAt((a + b) / 2, b)
	if round then
		return part({
			Name = name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(length, thickness, thickness),
			CFrame = cframe * CFrame.Angles(0, math.rad(90), 0),
			Color = color,
			Material = material or Enum.Material.Metal,
			Parent = parent,
		})
	end
	return part({
		Name = name,
		Size = Vector3.new(thickness, thickness, length),
		CFrame = cframe,
		Color = color,
		Material = material or Enum.Material.Metal,
		Parent = parent,
	})
end

-- An upright cylinder standing on the ground at (x, z).

local function emitter(parent: Instance, name: string, props: { [string]: any }): ParticleEmitter
	local fx = Instance.new("ParticleEmitter")
	fx.Name = name
	for key, value in props do
		(fx :: any)[key] = value
	end
	fx.Parent = parent
	return fx
end

local function anchorAll(model: Instance)
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			child.Anchored = true
		end
	end
end

local function createAvatar(description: HumanoidDescription): Model?
	local ok, model = pcall(function()
		local players = Players :: any
		if typeof(players.CreateHumanoidModelFromDescriptionAsync) == "function" then
			return players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
		end
		return players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if ok and typeof(model) == "Instance" and model:IsA("Model") then
		return model
	end
	return nil
end

-- Stands an avatar with its feet at `feet`, facing `toward` (level).
local function placeAvatar(avatar: Model, feet: Vector3, toward: Vector3)
	local root = avatar:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = avatar:FindFirstChildOfClass("Humanoid")
	if not root then
		return
	end
	root.Anchored = true
	local lift = root.Size.Y / 2 + (if humanoid then humanoid.HipHeight else 2)
	local level = Vector3.new(toward.X, feet.Y, toward.Z)
	-- The whole rig moves, not just the root: outside Workspace no joint pulls the limbs along.
	local goal = CFrame.lookAt(feet, level) + Vector3.new(0, lift, 0)
	avatar:PivotTo(goal * root.CFrame:ToObjectSpace(avatar:GetPivot()))
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
end

-- Both arms straight out in front, hands on the hose.
local function armsForward(avatar: Model)
	for _, name in { "RightShoulder", "LeftShoulder" } do
		local arm = avatar:FindFirstChild(if name == "RightShoulder" then "RightUpperArm" else "LeftUpperArm")
		local motor = arm and arm:FindFirstChild(name)
		if motor and motor:IsA("Motor6D") then
			local inward = if name == "RightShoulder" then 0.25 else -0.25
			motor.C0 = motor.C0 * CFrame.Angles(math.rad(80), inward, 0)
		end
	end
end

-- Truck, outriggers, two-stage boom and a basket at `basket`, facing `target`.
-- Returns the basket's cframe (floor top, -Z toward the target).
local function buildCrane(parent: Instance, base: Vector3, basket: Vector3, target: Vector3): CFrame
	local crane = Instance.new("Model")
	crane.Name = "CraneRig"
	crane.Parent = parent
	local level = CFrame.lookAt(base, Vector3.new(basket.X, base.Y, basket.Z))

	part({
		Name = "Chassis",
		Size = Vector3.new(8, 3, 18),
		CFrame = level * CFrame.new(0, 2.6, 2),
		Color = CRANE_YELLOW,
		Material = Enum.Material.Metal,
		Parent = crane,
	})
	part({
		Name = "Cab",
		Size = Vector3.new(7, 4, 4.5),
		CFrame = level * CFrame.new(0, 5.6, 9),
		Color = CRANE_YELLOW,
		Material = Enum.Material.Metal,
		Parent = crane,
	})
	part({
		Name = "Windshield",
		Size = Vector3.new(6, 2.2, 0.2),
		CFrame = level * CFrame.new(0, 6.2, 6.7),
		Color = Color3.fromRGB(40, 60, 80),
		Material = Enum.Material.Glass,
		Transparency = 0.2,
		Parent = crane,
	})
	for _, side in { -1, 1 } do
		for _, z in { -4, 1, 8 } do
			local wheel = level * CFrame.new(side * 4.2, 1.5, z)
			part({
				Name = "Wheel",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.4, 3, 3),
				CFrame = wheel,
				Color = Color3.fromRGB(30, 30, 32),
				Material = Enum.Material.Rubber,
				Parent = crane,
			})
		end
		for _, z in { -6, 9 } do
			local foot = (level * CFrame.new(side * 8, 0.3, z)).Position
			span(
				crane,
				"Outrigger",
				(level * CFrame.new(side * 4, 2, z)).Position,
				foot + Vector3.new(0, 1, 0),
				0.9,
				CRANE_YELLOW:Lerp(Color3.new(0, 0, 0), 0.25)
			)
			part({
				Name = "Pad",
				Size = Vector3.new(2.4, 0.5, 2.4),
				CFrame = CFrame.new(foot),
				Color = Color3.fromRGB(60, 60, 62),
				Material = Enum.Material.DiamondPlate,
				Parent = crane,
			})
		end
	end
	local pivot = (level * CFrame.new(0, 5.2, -2)).Position
	part({
		Name = "Turret",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.4, 7, 7),
		CFrame = CFrame.new(pivot - Vector3.new(0, 0.9, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(70, 74, 80),
		Material = Enum.Material.Metal,
		Parent = crane,
	})
	local beacon = part({
		Name = "Beacon",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1, 1, 1),
		CFrame = level * CFrame.new(0, 8.1, 9),
		Color = Color3.fromRGB(255, 140, 20),
		Material = Enum.Material.Neon,
		Parent = crane,
	})
	local light = Instance.new("PointLight")
	light.Color = beacon.Color
	light.Range = 14
	light.Brightness = 2
	light.Parent = beacon

	-- Boom: a fat outer stage, then a thinner telescoped stage to the basket.
	local dropTo = basket - Vector3.new(0, 1.2, 0)
	local split = pivot:Lerp(dropTo, 0.55)
	span(crane, "BoomOuter", pivot, split, 2.6, CRANE_YELLOW)
	span(
		crane,
		"BoomInner",
		split - (dropTo - pivot).Unit * 2,
		dropTo,
		1.7,
		CRANE_YELLOW:Lerp(Color3.new(1, 1, 1), 0.15)
	)
	span(
		crane,
		"Ram",
		(level * CFrame.new(0, 3.6, 5)).Position,
		pivot:Lerp(split, 0.55),
		1,
		STEEL,
		Enum.Material.Metal,
		true
	)
	for i = 1, 6 do
		-- Hazard stripes along the outer stage.
		local p = pivot:Lerp(split, i / 7)
		local stripe = span(
			crane,
			"Stripe",
			p,
			p + (split - pivot).Unit * 0.6,
			2.7,
			Color3.fromRGB(30, 30, 30),
			Enum.Material.SmoothPlastic
		)
		stripe.CanQuery = false
	end

	-- The basket, squared up to the target.
	local basketCF = CFrame.lookAt(basket, Vector3.new(target.X, basket.Y, target.Z))
	part({
		Name = "BasketFloor",
		Size = Vector3.new(7, 0.6, 7),
		CFrame = basketCF * CFrame.new(0, -0.3, 0),
		Color = Color3.fromRGB(80, 84, 90),
		Material = Enum.Material.DiamondPlate,
		Parent = crane,
	})
	local railH = 3.4
	local corners =
		{ Vector3.new(-3.4, 0, -3.4), Vector3.new(3.4, 0, -3.4), Vector3.new(3.4, 0, 3.4), Vector3.new(-3.4, 0, 3.4) }
	for i, c in corners do
		local a = (basketCF * CFrame.new(c)).Position
		local b = (basketCF * CFrame.new(corners[i % 4 + 1])).Position
		span(crane, "BasketPost", a, a + Vector3.new(0, railH, 0), 0.35, CRANE_YELLOW, Enum.Material.Metal, true)
		span(
			crane,
			"BasketRail",
			a + Vector3.new(0, railH, 0),
			b + Vector3.new(0, railH, 0),
			0.3,
			CRANE_YELLOW,
			Enum.Material.Metal,
			true
		)
		span(
			crane,
			"BasketRail",
			a + Vector3.new(0, railH / 2, 0),
			b + Vector3.new(0, railH / 2, 0),
			0.25,
			CRANE_YELLOW,
			Enum.Material.Metal,
			true
		)
	end
	-- Pressure tank strapped to the back rail.
	part({
		Name = "PressureTank",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(3.2, 1.8, 1.8),
		CFrame = basketCF * CFrame.new(-2.2, 1.6, 2.6) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(200, 40, 40),
		Material = Enum.Material.Metal,
		Parent = crane,
	})
	return basketCF
end

local function marker(parent: Instance, name: string, cframe: CFrame): Part
	return part({
		Name = name,
		Size = Vector3.new(1, 1, 1),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CFrame = cframe,
		Parent = parent,
	})
end

-- Pivots a model to cframe, then lifts or drops it so its lowest point sits at floorY.
local function standOn(model: Model, cframe: CFrame, floorY: number)
	model:PivotTo(cframe)
	local box, size = model:GetBoundingBox()
	local bottom = box.Position.Y - size.Y / 2
	model:PivotTo(cframe + Vector3.new(0, floorY - bottom, 0))
end

------------------------------------------------------------------------------------------
-- Furnishing the maxed farm: every pen open and stocked, top gear, a full podium.

local function incomeOf(species: string, mutation: string): number
	return AnimalConfig.Animals[species].Income * MutationPayout.multiplier(mutation)
end

-- The best earners that fit a pen class, richest first.
local bestCache: { [string]: { string } } = {}
local function bestFor(penClass: string): { string }
	local cached = bestCache[penClass]
	if cached then
		return cached
	end
	local list: { string } = {}
	for key, def in AnimalConfig.Animals do
		local built = (def :: any).TemplateName or key
		if AnimalConfig.fits(def.BodyClass or "Standard", penClass) and AnimalBuilder.has(built) then
			table.insert(list, key)
		end
	end
	table.sort(list, function(a, b)
		return AnimalConfig.Animals[a].Income > AnimalConfig.Animals[b].Income
	end)
	while #list > 4 do
		table.remove(list)
	end
	bestCache[penClass] = list
	return list
end

local function stockPens(bay: Model): (number, string?, string?)
	local zoo = bay:FindFirstChild("Zoo")
	if not zoo then
		return 0, nil, nil
	end
	local total, best, bestMutation, bestIncome = 0, nil, nil, -1
	for _, pen in zoo:GetChildren() do
		local index = tonumber(string.match(pen.Name, "^Pen(%d+)$"))
		if not index or not pen:IsA("Model") then
			continue
		end
		WorldBuilder.setShown(pen, true)
		local lock = pen:FindFirstChild("FlexLock")
		if lock then
			WorldBuilder.setShown(lock, false)
		end
		local classAttr = pen:GetAttribute("PenClass")
		local choices = bestFor(if typeof(classAttr) == "string" then classAttr else "Standard")
		local slot = pen:FindFirstChild("Slot")
		if #choices == 0 or not slot or not slot:IsA("BasePart") then
			continue
		end
		local species = choices[index % #choices + 1]
		local mutation = MUTATIONS[index % #MUTATIONS + 1]
		local model = AnimalService.buildZooAnimal(species, mutation)
		model.Name = "ZooAnimal"
		AnimalService.resize(model, AnimalService.bodyScale(species))
		model:PivotTo(slot.CFrame)
		model.Parent = pen
		local income = incomeOf(species, mutation)
		total += income
		if income > bestIncome then
			best, bestMutation, bestIncome = species, mutation, income
		end
		local floor = pen:FindFirstChild("Floor")
		if floor and floor:IsA("BasePart") then
			floor.Color = Color3.fromRGB(120, 170, 80)
			local label = floor:FindFirstChild("Label", true)
			if label and label:IsA("TextLabel") then
				label.Text = ""
			end
		end
		-- PenCashController draws the pad's counter from these, like any real pen.
		local pad = pen:FindFirstChild("CollectPad")
		if pad and pad:IsA("BasePart") then
			pad.Transparency = 0
			pad:SetAttribute("Cash", math.floor(income * 900))
			pad:SetAttribute("Rate", income)
		end
	end
	local stand = zoo:FindFirstChild("ExpandStand")
	if stand then
		WorldBuilder.setShown(stand, false) -- nothing left to buy
	end
	return total, best, bestMutation
end

local function dressShowcase(bay: Model, income: number, species: string?, mutation: string?)
	local showcase = bay:FindFirstChild("Showcase")
	if not showcase then
		return
	end
	-- A real farm shows its owner's name here. This one stays anonymous.
	local name = showcase:FindFirstChild("BayLabel", true)
	if name and name:IsA("TextLabel") then
		name.Text = "Top Farmer's Farm"
	end
	local incomeLabel = showcase:FindFirstChild("IncomeLabel", true)
	if incomeLabel and incomeLabel:IsA("TextLabel") then
		incomeLabel.Text = `{UIStyle.formatMoney(income)}/s`
	end
	local slot = showcase:FindFirstChild("ShowcaseSlot")
	if species and mutation and slot and slot:IsA("BasePart") then
		local model = AnimalService.buildZooAnimal(species, mutation)
		model.Name = "ShowcaseAnimal"
		AnimalService.resize(model, AnimalService.bodyScale(species), SHOWCASE_MAX)
		model:PivotTo(slot.CFrame)
		model.Parent = showcase
	end
end

------------------------------------------------------------------------------------------
-- The wash: a filthy Kaiju, the crane rig beside it, and the jet.

local function grimeUp(kaiju: Model)
	for _, child in kaiju:GetDescendants() do
		if child:IsA("BasePart") and child.Material ~= Enum.Material.Neon then
			child.Color = child.Color:Lerp(VOLCANIC, 0.6)
		end
	end
end

local function buildKaiju(bay: Model, wash: CFrame, plot: PlotLayout.PlotFrame): Model
	local species = Settings.Species
	local def = AnimalConfig.Animals[species]
	local templateName = (def :: any).TemplateName or species
	local kaiju = AnimalBuilder.build(templateName, { Mutation = "Normal", Rarity = def.Rarity, Seed = 11 })
	kaiju.Name = "WashAnimal"
	DirtRenderer.setGrime(kaiju, 0)
	AnimalService.resize(kaiju, AnimalService.bodyScale(species))
	anchorAll(kaiju)
	grimeUp(kaiju)
	-- Side on to the road, facing the crane, so the shot from across the road sees its profile.
	standOn(kaiju, CFrame.lookAt(wash.Position, wash.Position + plot.Right), wash.Position.Y)
	kaiju.Parent = bay

	local box, size = kaiju:GetBoundingBox()
	local vents = marker(bay, "Vents", box)
	for _, offset in
		{
			Vector3.new(-0.25, 0.25, 0.2),
			Vector3.new(0.25, 0.1, 0.25),
			Vector3.new(0, 0.4, 0.1),
		}
	do
		local a = Instance.new("Attachment")
		a.Position = size * offset
		a.Parent = vents
		emitter(a, "Smoke", {
			Texture = SMOKE,
			Rate = 5,
			Lifetime = NumberRange.new(3, 5),
			Speed = NumberRange.new(3, 5),
			SpreadAngle = Vector2.new(20, 20),
			EmissionDirection = Enum.NormalId.Top,
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 10) }),
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) }),
			Color = ColorSequence.new(Color3.fromRGB(70, 62, 58)),
			RotSpeed = NumberRange.new(-20, 20),
		})
		emitter(a, "Embers", {
			Texture = SPARKLE,
			Rate = 8,
			Lifetime = NumberRange.new(1.2, 2.4),
			Speed = NumberRange.new(4, 9),
			SpreadAngle = Vector2.new(60, 60),
			EmissionDirection = Enum.NormalId.Top,
			Size = NumberSequence.new(0.5, 0),
			Color = ColorSequence.new(Color3.fromRGB(255, 150, 40), Color3.fromRGB(255, 60, 20)),
			LightEmission = 1,
		})
	end
	return kaiju
end

-- Where the jet lands: the Kaiju's skin, found by casting from the basket at its chest.
-- Runs while the farm is still in Workspace (raycasts only see Workspace).
local function blastPoint(kaiju: Model, from: Vector3): Vector3
	local box, size = kaiju:GetBoundingBox()
	local chest = Vector3.new(box.Position.X, box.Position.Y - size.Y / 2 + size.Y * 0.6, box.Position.Z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { kaiju }
	local hit = Workspace:Raycast(from, (chest - from).Unit * 300, params)
	return if hit then hit.Position else chest
end

local function buildImpact(bay: Model, aim: Vector3, from: Vector3)
	local impact = marker(bay, "BlastPoint", CFrame.lookAt(aim, from))
	local target = Instance.new("Attachment")
	target.Name = "SprayTarget"
	target.Parent = impact
	emitter(target, "Steam", {
		Texture = SMOKE,
		Rate = 20,
		Lifetime = NumberRange.new(1.5, 2.5),
		Speed = NumberRange.new(5, 10),
		SpreadAngle = Vector2.new(70, 70),
		EmissionDirection = Enum.NormalId.Front,
		Acceleration = Vector3.new(0, 4, 0),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.5), NumberSequenceKeypoint.new(1, 9) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) }),
		Color = ColorSequence.new(Color3.fromRGB(235, 240, 245)),
		RotSpeed = NumberRange.new(-30, 30),
	})
	emitter(target, "Splash", {
		Texture = SPARKLE,
		Rate = 90,
		Lifetime = NumberRange.new(0.5, 1),
		Speed = NumberRange.new(12, 24),
		SpreadAngle = Vector2.new(75, 75),
		EmissionDirection = Enum.NormalId.Front,
		Acceleration = Vector3.new(0, -50, 0),
		Size = NumberSequence.new(0.7, 0.2),
		Color = ColorSequence.new(WATER),
		LightEmission = 0.5,
	})
	emitter(target, "Grime", {
		Rate = 30,
		Lifetime = NumberRange.new(1, 2),
		Speed = NumberRange.new(6, 14),
		SpreadAngle = Vector2.new(60, 60),
		EmissionDirection = Enum.NormalId.Front,
		Acceleration = Vector3.new(0, -45, 0),
		Size = NumberSequence.new(0.5, 0.3),
		Color = ColorSequence.new(VOLCANIC, Color3.fromRGB(90, 60, 40)),
		Transparency = NumberSequence.new(0),
	})
	-- The scrubbed patch: a disc of clean skin under the jet.
	part({
		Name = "CleanPatch",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 5, 5),
		CFrame = CFrame.lookAt(aim, from) * CFrame.Angles(0, math.rad(90), 0),
		Color = Color3.fromRGB(70, 80, 88),
		Material = Enum.Material.Slate,
		CanCollide = false,
		CanQuery = false,
		Parent = bay,
	})
end

-- The top player. Their look comes from Settings.AvatarUserId, but no name is shown anywhere.
-- Tools are equipped on the client (CutsceneController): a hand weld made here, outside
-- Workspace, does not hold once the copy reaches the client, and the hose drops to the ground.
local function loadKeeper(set: Model, bay: Model, feet: Vector3, aim: Vector3)
	local description: HumanoidDescription? = nil
	local ok, loaded = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(Settings.AvatarUserId)
	end)
	if ok and typeof(loaded) == "Instance" and loaded:IsA("HumanoidDescription") then
		description = loaded
	else
		description = Instance.new("HumanoidDescription")
	end
	local avatar = createAvatar(description :: HumanoidDescription)
	if avatar then
		avatar.Name = "TopKeeper"
		avatar.Parent = bay
		placeAvatar(avatar, feet, aim)
		armsForward(avatar)
	end
	set:SetAttribute("Ready", true)
end

------------------------------------------------------------------------------------------

local function buildSet(): Model
	local set = Instance.new("Model")
	set.Name = SET_NAME
	set:SetAttribute("TemplateSlot", TEMPLATE_SLOT)

	-- The maxed farm, from the same builder every player's farm comes from. It is built in
	-- Workspace (raycasts need that) and moved out at the end of this function.
	local plot = PlotLayout.frame(TEMPLATE_SLOT)
	local bay = WorldBuilder.buildBay(TEMPLATE_SLOT)
	bay.Name = "MaxFarm"
	for _, d in bay:GetDescendants() do
		if d:IsA("SpawnLocation") or d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end
	WorldBuilder.setYardShown(bay, true)
	local income, best, bestMutation = stockPens(bay)
	dressShowcase(bay, income, best, bestMutation)
	StationProps.buildGear(bay, 6)

	local washMarker = bay:FindFirstChild("WashPosition")
	assert(washMarker and washMarker:IsA("BasePart"), "MaxFarm has no WashPosition")
	local wash = washMarker.CFrame
	local kaiju = buildKaiju(bay, wash, plot)
	local _, size = kaiju:GetBoundingBox()
	local reach = math.max(size.X, size.Z) / 2
	local basket = wash.Position + plot.Right * (reach + 5) - plot.Back * 2 + Vector3.new(0, size.Y * 0.55, 0)
	local base = wash.Position + plot.Right * (reach + 14) - plot.Back * 14
	base = Vector3.new(base.X, 0, base.Z)
	local basketCF = buildCrane(bay, base, basket, kaiju:GetPivot().Position)
	marker(bay, "Basket", basketCF)
	local aim = blastPoint(kaiju, basket + Vector3.new(0, 3, 0))
	buildImpact(bay, aim, basket)
	local feet = (basketCF * CFrame.new(0, 0, 0.6)).Position
	bay.Parent = set

	-- The pig "you" wash, and a default-avatar stand-in for you if your character can't be copied.
	local piglet = AnimalBuilder.build("Pig", { Mutation = "Normal", Rarity = "Common", Seed = 7 })
	piglet.Name = "Piglet"
	piglet:ScaleTo(Settings.PigletScale)
	anchorAll(piglet)
	DirtRenderer.setGrime(piglet, 0.15)
	piglet.Parent = set

	local holder = Instance.new("Folder")
	holder.Name = "CutsceneTemplate"
	holder.Parent = ServerStorage
	set.Parent = holder

	local rookie = createAvatar(Instance.new("HumanoidDescription"))
	if rookie then
		rookie.Name = "Rookie"
		rookie.Parent = set
		placeAvatar(rookie, Vector3.zero, Vector3.new(0, 0, -1))
	end

	task.spawn(loadKeeper, set, bay, feet, aim)
	return set
end

function CutsceneService.init()
	-- The set is decoration. If any of it fails to build, new players skip the cutscene
	-- instead of the error stopping ServerBootstrap (which froze the whole game).
	local built, result = pcall(buildSet)
	if built then
		template = result
	else
		warn("[CutsceneService] Could not build the cutscene set; skipping the cutscene:", result)
		setFailed = true
		local bays = Workspace:FindFirstChild("WashBays")
		local stray = bays and bays:FindFirstChild("MaxFarm")
		if stray then
			stray:Destroy()
		end
	end

	janitor:Add(Remotes.event("CutsceneFinished").OnServerEvent:Connect(function(player: Player)
		local data = PlayerDataService.get(player)
		local skip = skipAt[player]
		-- E is ignored until SkipAfter. After that the hose has to work immediately.
		if not data or data.CutsceneSeen or skip == nil or os.clock() < skip then
			return
		end
		data.CutsceneSeen = true
		PlayerDataService.markDirty(player)
		PlayerDataService.saveNow(player)
		skipAt[player] = nil
		endsAt[player] = nil
		player:SetAttribute("InCutscene", false)
		local copy = sent[player]
		sent[player] = nil
		if copy then
			copy:Destroy()
		end
	end))
	janitor:Add(Players.PlayerRemoving:Connect(function(player)
		skipAt[player] = nil
		endsAt[player] = nil
		sent[player] = nil
	end))
end

-- True only while the opening shot is still running. A skip or the timer clears it,
-- so the hose is not left locked after the camera comes back.
function CutsceneService.blocksCleaning(player: Player): boolean
	if player:GetAttribute("InCutscene") ~= true then
		return false
	end
	local ends = endsAt[player]
	if ends == nil or os.clock() >= ends then
		player:SetAttribute("InCutscene", false)
		return false
	end
	return true
end

-- Hands this player their own copy of the set (PlayerGui contents replicate to that player
-- only). The client moves it into its Workspace.
local function sendSet(player: Player)
	local source = template
	if not source then
		return
	end
	local waited = 0
	while source:GetAttribute("Ready") ~= true and waited < READY_WAIT do
		waited += task.wait(0.2)
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not playerGui or not player.Parent or player:GetAttribute("InCutscene") ~= true then
		return
	end
	local copy = source:Clone()
	copy.Parent = playerGui
	sent[player] = copy
end

function CutsceneService.begin(player: Player)
	local data = PlayerDataService.get(player)
	if not data or data.CutsceneSeen or setFailed then
		player:SetAttribute("InCutscene", false)
		return
	end
	local now = os.clock()
	local skipAfter = Settings.SkipAfter
	local hold = Settings.Duration + GRACE
	player:SetAttribute("InCutscene", true)
	skipAt[player] = now + skipAfter
	endsAt[player] = now + hold
	task.spawn(sendSet, player)
	task.delay(hold, function()
		if player.Parent and player:GetAttribute("InCutscene") == true then
			player:SetAttribute("InCutscene", false)
		end
		local copy = sent[player]
		if copy then
			sent[player] = nil
			copy:Destroy()
		end
	end)
end

return CutsceneService
