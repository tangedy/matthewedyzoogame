-- Delivery truck (TruckConfig): once the player owns the Garden Hose, every few minutes a truck
-- drives down the dirt road, parks at the player's zoo for ParkSeconds carrying one animal a
-- rarity above what their hose can wash (fixed odds at the top tiers), then drives on.
-- Holding the prompt on the truck buys the animal for Robux through the Monetization feature:
--   * when the truck parks, the offer is written to data.Extra.Truck.Offer (server-chosen),
--   * the prompt fires Hooks "TruckBuyRequested" (player); Monetization prompts the product,
--   * Monetization grants the offer into the cache as a paid animal and fires
--     Hooks "TruckPurchased" (player), which takes the animal off the truck and sends it away.
-- Only the zoo's owner can buy from their truck.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local GearLadder = require(ReplicatedStorage.Shared.GearLadder)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local TruckConfig = require(ReplicatedStorage.Shared.FeatureConfig.TruckConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Services = ServerScriptService.Server.Services
local AnimalService = require(Services.AnimalService)
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

type Truck = {
	Model: Model,
	Animal: Model?,
	Prompt: ProximityPrompt,
	Timer: TextLabel,
	LeaveAt: number,
}

local DeliveryTruck = {}

local threads: { [Player]: thread } = {}
local trucks: { [Player]: Truck } = {}
local rng = Random.new()

local function truckData(player: Player): { [string]: any }?
	local data = PlayerDataService.get(player)
	if not data then
		return nil
	end
	if typeof(data.Extra.Truck) ~= "table" then
		data.Extra.Truck = {}
	end
	return data.Extra.Truck
end

local function toolTier(player: Player): number
	local data = PlayerDataService.get(player)
	return if data then data.ToolTier else 1
end

local function hosePower(player: Player): number
	local data = PlayerDataService.get(player)
	return if data then GearLadder.power(data.ToolTier, data.ToolUpgrade) else GearLadder.power(1)
end

-- The truck's rarity: one above the rarest this hose can wash, or the high-tier roll once
-- that is Farm God or better.
local function pickRarity(player: Player): string
	local above = CleanPower.rarityAbove(hosePower(player))
	if RarityConfig.ByKey[above].Order < RarityConfig.ByKey[TruckConfig.HighTierFrom].Order then
		return above
	end
	local roll = rng:NextNumber()
	local chances: { [string]: number } = TruckConfig.HighTierChances
	-- Rarest first, so the odds read the same whatever order the table lists them in.
	for index = #RarityConfig.List, 1, -1 do
		local key = RarityConfig.List[index].Key
		local p = chances[key]
		if p then
			roll -= p
			if roll < 0 then
				return key
			end
		end
	end
	return TruckConfig.HighTierFallback
end

-- A species of that rarity (weighted by spawn weight) and a mutation roll.
local function pickAnimal(player: Player): (string, string)
	local rarityKey = pickRarity(player)
	local pool, total = {}, 0
	for key, def in AnimalConfig.Animals do
		if def.Rarity == rarityKey and not def.Limited and def.SpawnWeight > 0 then
			table.insert(pool, key)
			total += def.SpawnWeight
		end
	end
	table.sort(pool)
	local roll = rng:NextNumber(0, total)
	local species = pool[#pool] or AnimalConfig.FallbackAnimal
	for _, key in pool do
		roll -= AnimalConfig.Animals[key].SpawnWeight
		if roll <= 0 then
			species = key
			break
		end
	end
	local mutation = MutationConfig.Default
	local chance = rng:NextNumber()
	local chances: { [string]: number } = TruckConfig.MutationChances
	for key, p in chances do
		if MutationConfig.ByKey[key] then
			chance -= p
			if chance <= 0 then
				mutation = key
				break
			end
		end
	end
	return species, mutation
end

local function part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function cylinder(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	return part({ Name = name, Shape = Enum.PartType.Cylinder, Size = size, CFrame = cframe, Color = color }, parent)
end

-- A cylinder's round faces point along X; these turn them to face Z (headlights) or Y (stack).
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0)
local ALONG_Y = CFrame.Angles(0, 0, math.rad(90))

local WHEEL_RADIUS = 1.4
local DARK = Color3.fromRGB(35, 35, 40)
local CHROME = Color3.fromRGB(205, 210, 220)
local WOOD = Color3.fromRGB(170, 115, 60)
local STRAW = Color3.fromRGB(235, 205, 110)
local GLASS = Color3.fromRGB(150, 210, 245)

type Wheel = { Part: BasePart, Rest: CFrame, Axle: Vector3 }
type TruckParts = {
	Bed: BasePart,
	Sign: BasePart,
	Wheels: { Wheel }, -- spun about their axles while driving
	Beacon: BasePart,
	Exhaust: ParticleEmitter,
}

-- An animal delivery truck built around a Root at road level, facing -Z: a cab with a grille,
-- round headlights, windows, mirrors and a paw print on each door, an ANIMAL DELIVERY sign
-- and an amber beacon on the roof, and a straw-floored stake bed with open rails so the
-- animal riding on it shows from the side.
local function buildTruck(): (Model, TruckParts)
	local colors = TruckConfig.Colors
	local model = Instance.new("Model")
	model.Name = "DeliveryTruck"
	local root = part({ Name = "Root", Size = Vector3.new(1, 1, 1), Transparency = 1 }, model)
	model.PrimaryPart = root

	local function box(name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): Part
		return part({
			Name = name,
			Size = size,
			CFrame = cframe,
			Color = color,
			Material = material or Enum.Material.SmoothPlastic,
		}, model)
	end
	local function round(name: string, size: Vector3, cframe: CFrame, color: Color3): Part
		return cylinder(name, size, cframe, color, model)
	end

	-- Frame and bumpers.
	box("Chassis", Vector3.new(5, 0.6, 14.4), CFrame.new(0, 1.5, 0), DARK)
	box("FrontBumper", Vector3.new(6.8, 0.6, 0.5), CFrame.new(0, 1.9, -7.45), CHROME, Enum.Material.Metal)
	box("RearBumper", Vector3.new(6.6, 0.5, 0.4), CFrame.new(0, 1.9, 7.6), DARK)

	-- Nose: hood, grille, round headlights, fenders over the front wheels.
	box("Hood", Vector3.new(4.6, 1.6, 3.2), CFrame.new(0, 3, -5.6), colors.Cab)
	box("HoodStripe", Vector3.new(0.9, 0.06, 3.2), CFrame.new(0, 3.82, -5.6), colors.Trim)
	box("Grille", Vector3.new(3, 1.2, 0.15), CFrame.new(0, 2.95, -7.25), CHROME, Enum.Material.Metal)
	for i = 0, 3 do
		box("GrilleBar", Vector3.new(2.8, 0.12, 0.08), CFrame.new(0, 2.5 + i * 0.3, -7.34), DARK)
	end
	for _, side in { -1, 1 } do
		round("HeadlightRim", Vector3.new(0.12, 0.95, 0.95), CFrame.new(side * 1.95, 3.25, -7.24) * ALONG_Z, CHROME)
		local lamp = round(
			"Headlight",
			Vector3.new(0.14, 0.72, 0.72),
			CFrame.new(side * 1.95, 3.25, -7.27) * ALONG_Z,
			Color3.fromRGB(255, 250, 210)
		)
		lamp.Material = Enum.Material.Neon
		local beam = Instance.new("SpotLight")
		beam.Face = Enum.NormalId.Right -- the cylinder's axis, which ALONG_Z turned to face forward
		beam.Angle = 50
		beam.Range = 22
		beam.Brightness = 1.5
		beam.Color = Color3.fromRGB(255, 245, 210)
		beam.Parent = lamp
		box("Fender", Vector3.new(1.3, 0.45, 3.4), CFrame.new(side * 2.95, 3.05, -5.4), colors.Cab)
		box("FenderLip", Vector3.new(1.3, 0.2, 0.3), CFrame.new(side * 2.95, 2.85, -7.05), DARK)
	end

	-- Cab: lower body, glasshouse and roof, with windows, doors, mirrors and steps.
	box("CabBody", Vector3.new(6.6, 2, 4), CFrame.new(0, 3.2, -2), colors.Cab)
	box("Cab", Vector3.new(6.2, 2.2, 3.6), CFrame.new(0, 5.3, -2), colors.Cab)
	box("Roof", Vector3.new(6.5, 0.3, 3.9), CFrame.new(0, 6.55, -2), colors.Cab)
	box("CabStripe", Vector3.new(6.64, 0.25, 4.04), CFrame.new(0, 4.05, -2), colors.Trim)
	local function glass(name: string, size: Vector3, cframe: CFrame)
		local pane = box(name, size, cframe, GLASS, Enum.Material.Glass)
		pane.Transparency = 0.25
		pane.Reflectance = 0.15
	end
	glass("Windshield", Vector3.new(5.4, 1.7, 0.12), CFrame.new(0, 5.35, -3.82))
	glass("RearWindow", Vector3.new(4.4, 1.2, 0.12), CFrame.new(0, 5.45, -0.18))
	for _, side in { -1, 1 } do
		glass("SideWindow", Vector3.new(0.12, 1.5, 2.4), CFrame.new(side * 3.11, 5.4, -2.2))
		box("DoorSeam", Vector3.new(0.06, 1.8, 0.08), CFrame.new(side * 3.32, 3.15, -0.6), DARK)
		box("DoorSeam", Vector3.new(0.06, 1.8, 0.08), CFrame.new(side * 3.32, 3.15, -3.75), DARK)
		box("DoorHandle", Vector3.new(0.12, 0.16, 0.55), CFrame.new(side * 3.35, 3.65, -1.05), CHROME)
		box("MirrorArm", Vector3.new(0.6, 0.12, 0.12), CFrame.new(side * 3.55, 5, -3.4), DARK)
		box("Mirror", Vector3.new(0.16, 0.75, 0.5), CFrame.new(side * 3.92, 5, -3.4), DARK)
		box("Step", Vector3.new(0.6, 0.2, 2.6), CFrame.new(side * 3.4, 2, -2), DARK)
		-- Paw print on the door: a pad and four toes.
		round("PawPad", Vector3.new(0.06, 0.85, 0.85), CFrame.new(side * 3.33, 2.95, -2.2), colors.Trim)
		for i, z in { -0.45, -0.16, 0.16, 0.45 } do
			local lift = if i == 1 or i == 4 then 0.48 else 0.66
			round("PawToe", Vector3.new(0.06, 0.34, 0.34), CFrame.new(side * 3.33, 2.95 + lift, -2.2 + z), colors.Trim)
		end
	end

	-- Exhaust stack behind the cab, puffing while the truck drives.
	round("Exhaust", Vector3.new(3.4, 0.35, 0.35), CFrame.new(3.45, 5.4, -0.4) * ALONG_Y, CHROME)
	local cap = round("ExhaustCap", Vector3.new(0.2, 0.48, 0.48), CFrame.new(3.45, 7.1, -0.4) * ALONG_Y, DARK)
	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "ExhaustSmoke"
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = 10
	smoke.Lifetime = NumberRange.new(0.8, 1.4)
	smoke.Speed = NumberRange.new(2, 3)
	smoke.SpreadAngle = Vector2.new(15, 15)
	smoke.EmissionDirection = Enum.NormalId.Right -- up the stack: ALONG_Y turned +X to +Y
	smoke.Size = NumberSequence.new(0.4, 1.6)
	smoke.Transparency = NumberSequence.new(0.5, 1)
	smoke.Color = ColorSequence.new(Color3.fromRGB(150, 150, 155))
	smoke.Enabled = false
	smoke.Parent = cap

	-- Roof sign and beacon.
	for _, side in { -1, 1 } do
		box("SignPost", Vector3.new(0.2, 0.75, 0.2), CFrame.new(side * 2, 6.95, -2.6), DARK)
	end
	-- Painted-on lettering: the roof sign reads up and down the road, the bed sides from the zoo.
	local function lettering(on: BasePart, face: Enum.NormalId, canvas: Vector2, stroke: Color3)
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = canvas
		gui.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(0.94, 0.8)
		label.Position = UDim2.fromScale(0.03, 0.1)
		label.Text = "🐾 ANIMAL DELIVERY 🐾"
		label.Parent = gui
		UIStyle.text(label, colors.Cab, stroke, 3)
		gui.Parent = on
	end
	local sign = box("RoofSign", Vector3.new(5.6, 1.25, 0.25), CFrame.new(0, 7.6, -2.6), colors.Trim)
	lettering(sign, Enum.NormalId.Front, Vector2.new(448, 100), Color3.new(1, 1, 1))
	lettering(sign, Enum.NormalId.Back, Vector2.new(448, 100), Color3.new(1, 1, 1))
	local beacon = box("Beacon", Vector3.new(0.7, 0.45, 0.7), CFrame.new(0, 6.93, -0.8), colors.Beacon)
	beacon.Material = Enum.Material.Neon
	local glow = Instance.new("PointLight")
	glow.Color = colors.Beacon
	glow.Range = 14
	glow.Brightness = 0
	glow.Parent = beacon

	-- Stake bed: plank floor on a subframe, straw, low white sides with stakes and two rails.
	box("Subframe", Vector3.new(5, 1.1, 7.2), CFrame.new(0, 2.35, 3.8), DARK)
	local bed = box("Bed", Vector3.new(7, 0.5, 7.4), CFrame.new(0, 3.15, 3.85), WOOD, Enum.Material.WoodPlanks)
	box("Straw", Vector3.new(6.3, 0.08, 6.8), CFrame.new(0, 3.44, 3.9), STRAW, Enum.Material.Fabric)
	for _, side in { -1, 1 } do
		local panel = box("BedSide", Vector3.new(0.3, 0.8, 7.4), CFrame.new(side * 3.35, 3.8, 3.85), colors.Bed)
		lettering(
			panel,
			if side > 0 then Enum.NormalId.Right else Enum.NormalId.Left,
			Vector2.new(740, 80),
			colors.Trim
		)
		box("TopRail", Vector3.new(0.26, 0.3, 7.4), CFrame.new(side * 3.35, 6.1, 3.85), WOOD, Enum.Material.Wood)
		box("MidRail", Vector3.new(0.2, 0.18, 7.4), CFrame.new(side * 3.35, 5.15, 3.85), WOOD, Enum.Material.Wood)
		for _, z in { 0.35, 2.85, 4.85, 7.35 } do
			box("Stake", Vector3.new(0.3, 2, 0.3), CFrame.new(side * 3.35, 5.2, z), colors.Cab)
		end
		box("MudFlap", Vector3.new(0.9, 1.1, 0.08), CFrame.new(side * 2.95, 1.1, 7.05), DARK)
		local tail = box(
			"Taillight",
			Vector3.new(0.55, 0.4, 0.1),
			CFrame.new(side * 2.7, 3.8, 7.56),
			Color3.fromRGB(255, 40, 40)
		)
		tail.Material = Enum.Material.Neon
	end
	for i = 0, 2 do
		box("Headboard", Vector3.new(6.4, 0.3, 0.2), CFrame.new(0, 4 + i * 0.8, 0.35), WOOD, Enum.Material.Wood)
	end
	box("Tailgate", Vector3.new(6.4, 0.8, 0.3), CFrame.new(0, 3.8, 7.35), colors.Bed)
	box("TailRail", Vector3.new(6.4, 0.3, 0.26), CFrame.new(0, 6.1, 7.35), WOOD, Enum.Material.Wood)
	box("Plate", Vector3.new(1.3, 0.6, 0.06), CFrame.new(0, 2.35, 7.43), Color3.new(1, 1, 1))

	-- Wheels: tyre, hub, two crossed spokes and a cap, so the spin shows.
	local wheels: { Wheel } = {}
	local spoke = Color3.fromRGB(120, 120, 130)
	for _, side in { -1, 1 } do
		for _, z in { -5.4, 2.3, 5.3 } do
			local axle = Vector3.new(side * 2.95, WHEEL_RADIUS, z)
			local at = CFrame.new(axle)
			for _, piece in
				{
					round("Tire", Vector3.new(1.1, WHEEL_RADIUS * 2, WHEEL_RADIUS * 2), at, DARK),
					round("Hub", Vector3.new(1.16, 1.5, 1.5), at, CHROME),
					box("Spoke", Vector3.new(1.2, 1.3, 0.22), at, spoke),
					box("Spoke", Vector3.new(1.2, 0.22, 1.3), at, spoke),
					round("HubCap", Vector3.new(1.24, 0.45, 0.45), at, colors.Trim),
				}
			do
				table.insert(wheels, { Part = piece, Rest = piece.CFrame, Axle = axle })
			end
		end
	end

	return model, { Bed = bed, Sign = sign, Wheels = wheels, Beacon = beacon, Exhaust = smoke }
end

-- Turns the wheels about their axles by how far the truck has rolled.
local function spinWheels(model: Model, truckParts: TruckParts, rolled: number)
	local pivot = model:GetPivot()
	local spin = CFrame.Angles(-rolled / WHEEL_RADIUS, 0, 0) -- rolling toward -Z turns the tops forward
	for _, wheel in truckParts.Wheels do
		local axle = wheel.Axle
		wheel.Part.CFrame = pivot * CFrame.new(axle) * spin * CFrame.new(-axle) * wheel.Rest
	end
end

local function driveTo(model: Model, truckParts: TruckParts, from: CFrame, to: CFrame, seconds: number)
	local elapsed = 0
	local span = (to.Position - from.Position).Magnitude
	truckParts.Exhaust.Enabled = true
	while elapsed < seconds and model.Parent do
		elapsed += task.wait()
		local t = math.min(elapsed / seconds, 1)
		local eased = t * t * (3 - 2 * t)
		model:PivotTo(from:Lerp(to, eased) + Vector3.new(0, math.abs(math.sin(elapsed * 14)) * 0.06, 0))
		spinWheels(model, truckParts, span * eased)
	end
	if model.Parent then
		model:PivotTo(to)
		spinWheels(model, truckParts, span)
	end
	truckParts.Exhaust.Enabled = false
end

-- A little nod forward on the springs as the truck brakes, rocking about the front axle.
local function settle(model: Model, at: CFrame)
	local elapsed = 0
	while elapsed < 0.6 and model.Parent do
		elapsed += task.wait()
		local u = math.min(elapsed / 0.6, 1)
		local nod = math.sin(u * math.pi * 2) * 0.03 * (1 - u)
		model:PivotTo(at * CFrame.new(0, 0, -5.4) * CFrame.Angles(-nod, 0, 0) * CFrame.new(0, 0, 5.4))
	end
	if model.Parent then
		model:PivotTo(at)
	end
end

-- The amber beacon flashes while the truck waits.
local function flashBeacon(beacon: BasePart, on: boolean)
	beacon.Transparency = if on then 0 else 0.55
	local glow = beacon:FindFirstChildOfClass("PointLight")
	if glow then
		glow.Brightness = if on then 3 else 0
	end
end

-- One visit: drive in, park with the offer, drive on. Yields for the whole visit.
local function visit(player: Player, bay: Model)
	local entrance = bay:FindFirstChild("Entrance")
	if not entrance or not entrance:IsA("BasePart") then
		return
	end
	local species, mutation = pickAnimal(player)
	local def = AnimalConfig.Animals[species]
	local product = MonetizationConfig.ProductsByKey[TruckConfig.ProductKey]
	local robux = if product then product.Robux else 200

	-- Trucks come from the far end of the road (away from the plaza) and drive on toward it.
	local outward = if entrance.Position.Z >= 0 then 1 else -1
	local parkPos = entrance.Position + TruckConfig.ParkOffset * outward
	local facing = Vector3.new(0, 0, -outward)
	local park = CFrame.lookAt(parkPos, parkPos + facing)
	local start = park + Vector3.new(0, 0, outward * TruckConfig.StartDistance)
	local leave = park - Vector3.new(0, 0, outward * TruckConfig.StartDistance)

	local model, truckParts = buildTruck()
	local bed = truckParts.Bed
	model:PivotTo(start)
	model.Parent = bay

	-- The animal rides on the bed, sideways so the zoo can see it.
	local animal = AnimalService.buildZooAnimal(species, mutation)
	local _, size = animal:GetBoundingBox()
	local length = math.max(size.X, size.Z)
	if length > TruckConfig.MaxAnimalLength then
		animal:ScaleTo(TruckConfig.MaxAnimalLength / length)
	end
	-- A child of the truck, so it rides along whenever the truck is pivoted.
	animal:PivotTo(bed.CFrame * CFrame.new(0, bed.Size.Y / 2, 0) * CFrame.Angles(0, math.rad(-90), 0))
	animal.Parent = model

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TruckPrompt"
	prompt.ActionText = `Buy ({robux} ROBUX)`
	prompt.ObjectText = (if mutation == MutationConfig.Default then "" else mutation .. " ") .. def.DisplayName
	prompt.HoldDuration = 0 -- the Robux dialog is the confirmation
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = bed

	local sign = Instance.new("BillboardGui")
	sign.Size = UDim2.fromOffset(220, 50)
	sign.StudsOffset = Vector3.new(0, 1.9, 0)
	sign.MaxDistance = 120
	sign.Parent = truckParts.Sign
	local timer = Instance.new("TextLabel")
	timer.Size = UDim2.fromScale(1, 1)
	timer.Parent = sign
	UIStyle.text(timer, TruckConfig.Colors.Trim, nil, 3)
	timer.Text = "DELIVERY!"

	local truck: Truck = { Model = model, Animal = animal, Prompt = prompt, Timer = timer, LeaveAt = 0 }
	trucks[player] = truck

	driveTo(model, truckParts, start, park, TruckConfig.DriveSeconds)
	settle(model, park)

	-- Parked: write the offer the server will honour, then count down.
	local saved = truckData(player)
	if saved then
		saved.Offer = { Species = species, Mutation = mutation, Expires = os.time() + TruckConfig.ParkSeconds }
	end
	prompt.Enabled = true
	truck.LeaveAt = os.clock() + TruckConfig.ParkSeconds
	-- No screen banner: the truck's own sign and the guide trail point the player at it.
	local flash = false
	while os.clock() < truck.LeaveAt and model.Parent do
		local left = math.max(0, math.ceil(truck.LeaveAt - os.clock()))
		timer.Text = if truck.Animal then `DELIVERY! 0:{string.format("%02d", left)}` else "SOLD!"
		flash = not flash
		flashBeacon(truckParts.Beacon, flash)
		task.wait(0.25)
	end
	flashBeacon(truckParts.Beacon, false)

	prompt.Enabled = false
	saved = truckData(player)
	if saved then
		saved.Offer = nil
	end
	timer.Text = "BYE!"
	driveTo(model, truckParts, park, leave, TruckConfig.DriveSeconds)
	model:Destroy()
	if trucks[player] == truck then
		trucks[player] = nil
	end
end

local function run(player: Player, bay: Model)
	if toolTier(player) >= TruckConfig.UnlockToolTier then
		task.wait(TruckConfig.FirstArrivalSeconds)
	else
		-- No trucks until the second hose upgrade; the first one follows soon after it.
		while toolTier(player) < TruckConfig.UnlockToolTier do
			task.wait(1)
			if not player.Parent or not bay.Parent then
				return
			end
		end
		task.wait(TruckConfig.FirstAfterUnlockSeconds)
	end
	while player.Parent and bay.Parent do
		local ok, err = pcall(visit, player, bay)
		if not ok then
			warn(`[DeliveryTruck] visit failed: {err}`)
		end
		task.wait(TruckConfig.IntervalSeconds)
	end
end

local function stop(player: Player)
	local thread = threads[player]
	threads[player] = nil
	if thread and coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
		task.cancel(thread)
	end
	local truck = trucks[player]
	trucks[player] = nil
	if truck then
		truck.Model:Destroy()
	end
end

function DeliveryTruck.init()
	Hooks.on("BayAssigned", function(player: Player, bay: Model)
		stop(player)
		threads[player] = task.spawn(run, player, bay)
	end)
	Hooks.on("PlayerLeaving", function(player: Player)
		local saved = truckData(player)
		if saved then
			saved.Offer = nil -- the truck leaves with them
		end
	end)
	Players.PlayerRemoving:Connect(stop)

	-- The truck's prompt is server-side: only the zoo's owner can buy from it.
	Hooks.on("TruckPurchased", function(player: Player)
		local truck = trucks[player]
		if truck and truck.Animal then
			local animal = truck.Animal
			truck.Animal = nil
			truck.Prompt.Enabled = false
			AnimalService.poof(animal)
			truck.LeaveAt = math.min(truck.LeaveAt, os.clock() + 2)
		end
	end)
	game:GetService("ProximityPromptService").PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if prompt.Name ~= "TruckPrompt" then
			return
		end
		local truck = trucks[who]
		if truck and truck.Prompt == prompt and truck.Animal then
			Hooks.fire("TruckBuyRequested", who)
		end
	end)
end

return DeliveryTruck
