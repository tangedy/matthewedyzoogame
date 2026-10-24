-- Delivery truck (TruckConfig): every few minutes a truck drives down the dirt road, parks at
-- the player's zoo for ParkSeconds carrying one high-rarity animal, then drives on.
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
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
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

-- A high-rarity species (weighted by spawn weight) and a mutation roll.
local function pickAnimal(): (string, string)
	local minOrder = RarityConfig.ByKey[TruckConfig.MinRarity].Order
	local pool, total = {}, 0
	for key, def in AnimalConfig.Animals do
		local rarity = RarityConfig.ByKey[def.Rarity]
		if rarity and rarity.Order >= minOrder and not def.Limited and def.SpawnWeight > 0 then
			table.insert(pool, key)
			total += def.SpawnWeight
		end
	end
	table.sort(pool)
	local roll = rng:NextNumber(0, total)
	local species = pool[#pool]
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

-- A chunky cartoon pickup truck built around a Root at road level, facing -Z.
local function buildTruck(): (Model, BasePart)
	local colors = TruckConfig.Colors
	local model = Instance.new("Model")
	model.Name = "DeliveryTruck"
	local root = part({ Name = "Root", Size = Vector3.new(1, 1, 1), Transparency = 1 }, model)
	model.PrimaryPart = root
	part({ Name = "Chassis", Size = Vector3.new(6, 1, 13), CFrame = CFrame.new(0, 1.6, 0), Color = colors.Trim }, model)
	part({ Name = "Cab", Size = Vector3.new(6, 4, 4.5), CFrame = CFrame.new(0, 4.1, -4.2), Color = colors.Cab }, model)
	part({
		Name = "Windshield",
		Size = Vector3.new(5.2, 2, 0.2),
		CFrame = CFrame.new(0, 4.9, -6.5),
		Color = Color3.fromRGB(160, 220, 255),
		Material = Enum.Material.Glass,
		Transparency = 0.2,
	}, model)
	part({ Name = "Hood", Size = Vector3.new(6, 2, 2), CFrame = CFrame.new(0, 3.1, -7.2), Color = colors.Cab }, model)
	local bed = part(
		{ Name = "Bed", Size = Vector3.new(6, 0.6, 8), CFrame = CFrame.new(0, 2.4, 2.2), Color = colors.Bed },
		model
	)
	for _, side in { -1, 1 } do
		part({
			Name = "Rail",
			Size = Vector3.new(0.4, 1.2, 8),
			CFrame = CFrame.new(side * 2.8, 3.3, 2.2),
			Color = colors.Cab,
		}, model)
		for _, z in { -5, 4 } do
			part({
				Name = "Wheel",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.9, 2.4, 2.4),
				CFrame = CFrame.new(side * 3, 1.2, z),
				Color = Color3.fromRGB(35, 35, 40),
			}, model)
		end
		part({
			Name = "Headlight",
			Size = Vector3.new(0.9, 0.6, 0.2),
			CFrame = CFrame.new(side * 2, 3.3, -8.25),
			Color = Color3.fromRGB(255, 250, 200),
			Material = Enum.Material.Neon,
		}, model)
	end
	return model, bed
end

local function driveTo(model: Model, from: CFrame, to: CFrame, seconds: number)
	local elapsed = 0
	while elapsed < seconds and model.Parent do
		elapsed += task.wait()
		local t = math.min(elapsed / seconds, 1)
		local eased = t * t * (3 - 2 * t)
		model:PivotTo(from:Lerp(to, eased) + Vector3.new(0, math.abs(math.sin(elapsed * 14)) * 0.08, 0))
	end
	if model.Parent then
		model:PivotTo(to)
	end
end

-- One visit: drive in, park with the offer, drive on. Yields for the whole visit.
local function visit(player: Player, bay: Model)
	local entrance = bay:FindFirstChild("Entrance")
	if not entrance or not entrance:IsA("BasePart") then
		return
	end
	local species, mutation = pickAnimal()
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

	local model, bed = buildTruck()
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
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = bed

	local sign = Instance.new("BillboardGui")
	sign.Size = UDim2.fromOffset(220, 50)
	sign.StudsOffset = Vector3.new(0, 4.5, 0)
	sign.MaxDistance = 120
	sign.Parent = model:FindFirstChild("Cab")
	local timer = Instance.new("TextLabel")
	timer.Size = UDim2.fromScale(1, 1)
	timer.Parent = sign
	UIStyle.text(timer, TruckConfig.Colors.Trim, nil, 3)
	timer.Text = "DELIVERY!"

	local truck: Truck = { Model = model, Animal = animal, Prompt = prompt, Timer = timer, LeaveAt = 0 }
	trucks[player] = truck

	driveTo(model, start, park, TruckConfig.DriveSeconds)

	-- Parked: write the offer the server will honour, then count down.
	local saved = truckData(player)
	if saved then
		saved.Offer = { Species = species, Mutation = mutation, Expires = os.time() + TruckConfig.ParkSeconds }
	end
	prompt.Enabled = true
	truck.LeaveAt = os.clock() + TruckConfig.ParkSeconds
	-- No screen banner: the truck's own sign and the guide trail point the player at it.
	while os.clock() < truck.LeaveAt and model.Parent do
		local left = math.max(0, math.ceil(truck.LeaveAt - os.clock()))
		timer.Text = if truck.Animal then `DELIVERY! 0:{string.format("%02d", left)}` else "SOLD!"
		task.wait(0.25)
	end

	prompt.Enabled = false
	saved = truckData(player)
	if saved then
		saved.Offer = nil
	end
	timer.Text = "BYE!"
	driveTo(model, park, leave, TruckConfig.DriveSeconds)
	model:Destroy()
	if trucks[player] == truck then
		trucks[player] = nil
	end
end

local function run(player: Player, bay: Model)
	task.wait(TruckConfig.FirstArrivalSeconds)
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
