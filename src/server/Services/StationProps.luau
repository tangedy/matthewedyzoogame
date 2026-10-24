-- The gear parked at a player's wash station, one set per tool tier, so an upgrade changes
-- the whole station and not just the thing in their hand:
--   1 Sponge        a wooden bucket of suds with a sponge on the rim
--   2 Scrub Brush   the bucket plus a brush caddy and a soap bottle
--   3 Garden Hose   a hose reel on a spigot post
--   4 Power Washer  a yellow pressure-washer cart with an engine on top
--   5 Foam Cannon   a big foam tank on a cart
--   6 Fire Hose     a fire truck parked behind the gear shop, with a hydrant
-- From tier 3 up a hose line (a Beam) runs from the gear to the tool's "Feed" attachment.
-- It hides while the owner is far from the station, so it never stretches across the map.
--
-- Gear stands at the bay's GearSpot marker (local -Z faces the wash). The fire truck parks at
-- TruckSpot (local -Z is the truck's nose).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WashTool = require(ReplicatedStorage.Shared.WashTool)

local StationProps = {}

local GEAR_NAME = "StationGear"
local LINE_NAME = "SupplyHose"
local LINE_REACH = 55 -- studs from the gear before the hose line hides
local GEAR_SCALE = 1.4

local RED = Color3.fromRGB(220, 40, 40)
local WOOD = Color3.fromRGB(170, 115, 60)
local STEEL = Color3.fromRGB(190, 195, 205)
local TIRE = Color3.fromRGB(35, 35, 40)
local WHITE = Color3.fromRGB(245, 245, 240)

type Kit = {
	Model: Model,
	Frame: CFrame,
}

local function add(kit: Kit, name: string, size: Vector3, offset: CFrame, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Size = size
	part.Shape = shape or Enum.PartType.Block
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = kit.Frame * offset
	part.Parent = kit.Model
	return part
end

-- Upright cylinder: Roblox cylinders run along X, so turn it onto Y.
local function drum(kit: Kit, name: string, height: number, diameter: number, at: Vector3, color: Color3): Part
	return add(
		kit,
		name,
		Vector3.new(height, diameter, diameter),
		CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		Enum.PartType.Cylinder
	)
end

-- A wheel whose axle runs along local X, or along local Z for the carts.
local function wheel(kit: Kit, at: Vector3, diameter: number, width: number, axleZ: boolean?)
	local turn = if axleZ then CFrame.Angles(0, math.rad(90), 0) else CFrame.identity
	add(kit, "Wheel", Vector3.new(width, diameter, diameter), CFrame.new(at) * turn, TIRE, Enum.PartType.Cylinder)
	add(
		kit,
		"Hub",
		Vector3.new(width + 0.05, diameter * 0.4, diameter * 0.4),
		CFrame.new(at) * turn,
		STEEL,
		Enum.PartType.Cylinder
	)
end

-- Where the hose line leaves the gear. Pointing down makes the line sag.
local function outlet(part: BasePart, worldPos: Vector3)
	local attachment = Instance.new("Attachment")
	attachment.Name = "HoseOut"
	attachment.Parent = part -- before WorldPosition, which is only world-relative once parented
	attachment.WorldPosition = worldPos
	attachment.Axis = part.CFrame:VectorToObjectSpace(Vector3.new(0, -1, 0))
	attachment.SecondaryAxis = part.CFrame:VectorToObjectSpace(Vector3.new(1, 0, 0))
end

local function suds(part: BasePart, color: Color3, rate: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Rate = rate
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(0.5, 1.5)
	emitter.SpreadAngle = Vector2.new(25, 25)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Size = NumberSequence.new(0.35, 0)
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.4
	emitter.Parent = part
end

local function bucket(kit: Kit, at: Vector3)
	drum(kit, "Bucket", 2, 2.4, at + Vector3.new(0, 1, 0), WOOD).Material = Enum.Material.Wood
	drum(kit, "BucketBand", 0.25, 2.5, at + Vector3.new(0, 1.5, 0), STEEL)
	local water = drum(kit, "Water", 0.1, 2.1, at + Vector3.new(0, 1.95, 0), Color3.fromRGB(110, 190, 255))
	water.Transparency = 0.2
	water.Material = Enum.Material.Glass
	for i = 0, 3 do
		local angle = i * math.pi / 2
		local bubble = add(
			kit,
			"Suds",
			Vector3.new(0.7, 0.7, 0.7),
			CFrame.new(at + Vector3.new(math.cos(angle) * 0.6, 2.05, math.sin(angle) * 0.6)),
			WHITE,
			Enum.PartType.Ball
		)
		bubble.Transparency = 0.15
	end
	suds(water, Color3.fromRGB(230, 245, 255), 3)
end

local BUILDERS: { [number]: (kit: Kit, truck: Kit?) -> () } = {
	-- 1: Sponge
	function(kit)
		bucket(kit, Vector3.zero)
		add(
			kit,
			"Sponge",
			Vector3.new(1.4, 0.8, 1),
			CFrame.new(1.2, 2.2, 0) * CFrame.Angles(0, 0, math.rad(-20)),
			Color3.fromRGB(255, 220, 70)
		).Material =
			Enum.Material.Sand
		add(
			kit,
			"ScrubPad",
			Vector3.new(1.4, 0.2, 1),
			CFrame.new(1.33, 2.65, 0) * CFrame.Angles(0, 0, math.rad(-20)),
			Color3.fromRGB(60, 170, 80)
		)
	end,
	-- 2: Scrub Brush
	function(kit)
		bucket(kit, Vector3.new(-1.5, 0, 0))
		-- A little caddy with brushes standing in it, and a soap bottle.
		add(kit, "Caddy", Vector3.new(2.4, 1.4, 1.6), CFrame.new(1.6, 0.7, 0), Color3.fromRGB(80, 160, 230))
		for i, x in { 1.0, 1.6, 2.2 } do
			add(
				kit,
				"BrushHandle",
				Vector3.new(0.25, 2.2, 0.25),
				CFrame.new(x, 2, 0) * CFrame.Angles(0, 0, math.rad((i - 2) * 10)),
				WOOD
			)
			add(
				kit,
				"BrushHead",
				Vector3.new(0.7, 0.35, 0.9),
				CFrame.new(x + (i - 2) * 0.18, 3.1, 0),
				Color3.fromRGB(200, 60, 50)
			)
		end
		drum(kit, "SoapBottle", 1.6, 0.8, Vector3.new(-1.5, 0.8, -1.8), Color3.fromRGB(255, 120, 200))
		drum(kit, "SoapCap", 0.3, 0.4, Vector3.new(-1.5, 1.75, -1.8), WHITE)
	end,
	-- 3: Garden Hose
	function(kit)
		add(kit, "Spigot", Vector3.new(0.8, 3.6, 0.8), CFrame.new(-1.8, 1.8, 0.6), Color3.fromRGB(150, 150, 160))
		add(kit, "Tap", Vector3.new(0.4, 0.4, 0.9), CFrame.new(-1.8, 3.2, 0.1), Color3.fromRGB(230, 180, 60))
		add(kit, "ReelStand", Vector3.new(0.4, 2.4, 2), CFrame.new(-0.9, 1.2, 0), Color3.fromRGB(60, 60, 70))
		add(kit, "ReelStand", Vector3.new(0.4, 2.4, 2), CFrame.new(1.3, 1.2, 0), Color3.fromRGB(60, 60, 70))
		for _, x in { -0.65, 1.05 } do
			add(kit, "ReelSide", Vector3.new(0.2, 3, 3), CFrame.new(x, 2.4, 0), RED, Enum.PartType.Cylinder)
		end
		local coil = add(
			kit,
			"Coil",
			Vector3.new(1.5, 2.3, 2.3),
			CFrame.new(0.2, 2.4, 0),
			Color3.fromRGB(60, 170, 80),
			Enum.PartType.Cylinder
		)
		add(kit, "Crank", Vector3.new(0.6, 0.25, 0.25), CFrame.new(1.5, 2.4, 0.9), STEEL)
		outlet(coil, (kit.Frame * CFrame.new(0.2, 1.4, -0.9)).Position)
	end,
	-- 4: Power Washer
	function(kit)
		local body =
			add(kit, "WasherBody", Vector3.new(3, 2.2, 2.2), CFrame.new(0, 1.9, 0), Color3.fromRGB(255, 205, 40))
		add(kit, "Engine", Vector3.new(1.8, 1.2, 1.6), CFrame.new(-0.3, 3.6, 0), Color3.fromRGB(45, 45, 50))
		drum(kit, "FuelCap", 0.3, 0.6, Vector3.new(0.9, 3.15, 0.3), RED)
		add(kit, "Gauge", Vector3.new(0.15, 0.7, 0.7), CFrame.new(1.55, 2.3, 0), WHITE, Enum.PartType.Cylinder)
		add(kit, "HandleBar", Vector3.new(0.25, 0.25, 2.4), CFrame.new(1.9, 3.8, 0), STEEL)
		for _, z in { -0.9, 0.9 } do
			add(kit, "HandlePost", Vector3.new(0.25, 2.6, 0.25), CFrame.new(1.7, 2.6, z), STEEL)
		end
		wheel(kit, Vector3.new(-1, 0.75, 1.3), 1.5, 0.5, true)
		wheel(kit, Vector3.new(-1, 0.75, -1.3), 1.5, 0.5, true)
		add(kit, "Foot", Vector3.new(0.4, 0.8, 1.6), CFrame.new(1.2, 0.4, 0), TIRE)
		-- Coiled black hose on the side.
		add(
			kit,
			"HoseCoil",
			Vector3.new(0.5, 1.6, 1.6),
			CFrame.new(0, 1.9, 1.35) * CFrame.Angles(0, math.rad(90), 0),
			TIRE,
			Enum.PartType.Cylinder
		)
		outlet(body, (kit.Frame * CFrame.new(0, 1.6, -1.1)).Position)
	end,
	-- 5: Foam Cannon
	function(kit)
		add(kit, "CartBed", Vector3.new(4.2, 0.5, 3), CFrame.new(0, 1.2, 0), Color3.fromRGB(70, 70, 80))
		wheel(kit, Vector3.new(-1.4, 0.75, 1.6), 1.5, 0.5, true)
		wheel(kit, Vector3.new(-1.4, 0.75, -1.6), 1.5, 0.5, true)
		wheel(kit, Vector3.new(1.4, 0.75, 1.6), 1.5, 0.5, true)
		wheel(kit, Vector3.new(1.4, 0.75, -1.6), 1.5, 0.5, true)
		local tank = drum(kit, "FoamTank", 4, 2.8, Vector3.new(-0.4, 3.45, 0), Color3.fromRGB(150, 90, 230))
		add(
			kit,
			"TankDome",
			Vector3.new(2.8, 2.8, 2.8),
			CFrame.new(-0.4, 5.45, 0),
			Color3.fromRGB(255, 150, 220),
			Enum.PartType.Ball
		)
		drum(kit, "TankBand", 0.3, 2.95, Vector3.new(-0.4, 2.4, 0), WHITE)
		drum(kit, "TankBand", 0.3, 2.95, Vector3.new(-0.4, 4.4, 0), WHITE)
		local window = add(
			kit,
			"FoamWindow",
			Vector3.new(0.2, 2.4, 0.8),
			CFrame.new(-0.4, 3.4, -1.38) * CFrame.Angles(0, math.rad(90), 0),
			Color3.fromRGB(255, 220, 250)
		)
		window.Material = Enum.Material.Neon
		add(kit, "Pump", Vector3.new(1.2, 1.2, 1.4), CFrame.new(1.4, 2, 0), Color3.fromRGB(45, 45, 50))
		suds(tank, Color3.fromRGB(255, 220, 250), 6)
		outlet(tank, (kit.Frame * CFrame.new(1.4, 2.2, -0.8)).Position)
	end,
	-- 6: Fire Hose: a hydrant at the gear spot and the truck behind the shop.
	function(kit, truck)
		drum(kit, "Hydrant", 2.4, 1.2, Vector3.new(0, 1.2, 0), RED)
		add(kit, "HydrantCap", Vector3.new(1.3, 1.3, 1.3), CFrame.new(0, 2.5, 0), RED, Enum.PartType.Ball)
		add(
			kit,
			"HydrantNozzle",
			Vector3.new(1.8, 0.5, 0.5),
			CFrame.new(0, 1.6, 0),
			Color3.fromRGB(230, 180, 60),
			Enum.PartType.Cylinder
		)
		if not truck then
			return
		end
		-- Chassis along local Z, nose at -Z.
		add(truck, "Chassis", Vector3.new(7, 1, 20), CFrame.new(0, 1.6, 0), Color3.fromRGB(60, 60, 65))
		add(truck, "Body", Vector3.new(7, 4.6, 13), CFrame.new(0, 4.4, 2.8), RED)
		add(truck, "Stripe", Vector3.new(7.1, 0.6, 13), CFrame.new(0, 3.4, 2.8), WHITE)
		add(truck, "Cab", Vector3.new(7, 5.2, 5.6), CFrame.new(0, 4.7, -6.7), RED)
		local windshield =
			add(truck, "Windshield", Vector3.new(6, 2, 0.2), CFrame.new(0, 5.8, -9.5), Color3.fromRGB(150, 200, 230))
		windshield.Material = Enum.Material.Glass
		windshield.Transparency = 0.2
		for _, x in { -3.55, 3.55 } do
			local side = add(
				truck,
				"SideWindow",
				Vector3.new(0.2, 1.8, 2.6),
				CFrame.new(x, 5.8, -7),
				Color3.fromRGB(150, 200, 230)
			)
			side.Material = Enum.Material.Glass
			side.Transparency = 0.2
		end
		add(truck, "Bumper", Vector3.new(7.4, 0.8, 0.6), CFrame.new(0, 1.8, -10.2), STEEL)
		for _, x in { -2.4, 2.4 } do
			local lamp = add(
				truck,
				"Headlight",
				Vector3.new(1, 0.7, 0.2),
				CFrame.new(x, 3.2, -9.55),
				Color3.fromRGB(255, 250, 200)
			)
			lamp.Material = Enum.Material.Neon
		end
		local red =
			add(truck, "Siren", Vector3.new(1.2, 0.6, 0.8), CFrame.new(-1.6, 7.6, -7.2), Color3.fromRGB(255, 60, 60))
		red.Material = Enum.Material.Neon
		local blue =
			add(truck, "Siren", Vector3.new(1.2, 0.6, 0.8), CFrame.new(1.6, 7.6, -7.2), Color3.fromRGB(70, 120, 255))
		blue.Material = Enum.Material.Neon
		-- Silver ladder on the roof.
		for _, x in { -1.2, 1.2 } do
			add(truck, "LadderRail", Vector3.new(0.3, 0.3, 14), CFrame.new(x, 7.1, 2.2), STEEL)
		end
		for i = 0, 9 do
			add(truck, "LadderRung", Vector3.new(2.4, 0.2, 0.2), CFrame.new(0, 7.1, -4.6 + i * 1.5), STEEL)
		end
		for _, z in { -6.6, 4.6, 7.8 } do
			for _, x in { -3.3, 3.3 } do
				wheel(truck, Vector3.new(x, 1.5, z), 3, 1)
			end
		end
		-- Hose reel on the side that faces the wash (the truck's right).
		local reel = add(
			truck,
			"Reel",
			Vector3.new(1, 3.2, 3.2),
			CFrame.new(3.9, 4.4, 3),
			Color3.fromRGB(230, 200, 140),
			Enum.PartType.Cylinder
		)
		add(truck, "ReelHub", Vector3.new(1.1, 1.2, 1.2), CFrame.new(3.9, 4.4, 3), STEEL, Enum.PartType.Cylinder)
		outlet(reel, (truck.Frame * CFrame.new(4.4, 3.2, 3)).Position)
	end,
}

local linked: { [Player]: Beam } = {}

local function bayOf(player: Player): Model?
	local bays = Workspace:FindFirstChild("WashBays")
	if not bays then
		return nil
	end
	for _, bay in bays:GetChildren() do
		if bay:GetAttribute("OwnerUserId") == player.UserId then
			return bay :: Model
		end
	end
	return nil
end

-- Rebuilds the station gear when the tier changes. Cheap to call again with the same tier.
function StationProps.refresh(player: Player, tier: number)
	local bay = bayOf(player)
	local spot = bay and bay:FindFirstChild("GearSpot")
	if not bay or not spot or not spot:IsA("BasePart") then
		return
	end
	local existing = bay:FindFirstChild(GEAR_NAME)
	if existing and existing:GetAttribute("Tier") == tier then
		return
	end
	if existing then
		existing:Destroy()
	end
	local gear = Instance.new("Model")
	gear.Name = GEAR_NAME
	gear:SetAttribute("Tier", tier)
	local kitModel = Instance.new("Model")
	kitModel.Name = "Kit"
	kitModel.Parent = gear
	local kit: Kit = { Model = kitModel, Frame = spot.CFrame }
	local truckSpot = bay:FindFirstChild("TruckSpot")
	local truck: Kit? = nil
	if truckSpot and truckSpot:IsA("BasePart") then
		local truckModel = Instance.new("Model")
		truckModel.Name = "FireTruck"
		truckModel.Parent = gear
		truck = { Model = truckModel, Frame = truckSpot.CFrame }
	end
	local build = BUILDERS[math.clamp(tier, 1, #BUILDERS)]
	build(kit, truck)
	-- The props are modelled at hand-tool scale; this sizes them up next to the animals.
	kitModel.WorldPivot = spot.CFrame
	kitModel:ScaleTo(GEAR_SCALE)
	gear.Parent = bay
	StationProps.link(player)
end

-- Runs the hose line from the gear to the tool in the player's hand, when this tier has one.
function StationProps.link(player: Player)
	local old = linked[player]
	if old then
		old:Destroy()
		linked[player] = nil
	end
	local bay = bayOf(player)
	local gear = bay and bay:FindFirstChild(GEAR_NAME)
	local out = gear and gear:FindFirstChild("HoseOut", true)
	local handle = WashTool.find(player.Character)
	local feed = handle and handle:FindFirstChild("Feed")
	if not gear or not out or not out:IsA("Attachment") or not feed or not feed:IsA("Attachment") then
		return
	end
	local tier = gear:GetAttribute("Tier")
	local beam = Instance.new("Beam")
	beam.Name = LINE_NAME
	beam.Attachment0 = out
	beam.Attachment1 = feed
	beam.Segments = 24
	beam.CurveSize0 = 6
	beam.CurveSize1 = 0
	beam.FaceCamera = true
	beam.Width0 = if tier == 6 then 0.75 elseif tier == 5 then 0.5 else 0.35
	beam.Width1 = beam.Width0 * 0.8
	beam.Color = ColorSequence.new(
		if tier == 6
			then Color3.fromRGB(235, 215, 170)
			elseif tier == 5 then Color3.fromRGB(255, 150, 220)
			elseif tier == 4 then Color3.fromRGB(35, 35, 40)
			else Color3.fromRGB(60, 170, 80)
	)
	beam.LightInfluence = 1
	beam.Transparency = NumberSequence.new(0)
	beam.Parent = gear
	linked[player] = beam
end

function StationProps.init()
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 0.25 then
			return
		end
		elapsed = 0
		for player, beam in linked do
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			local out = beam.Attachment0
			if not beam.Parent or not root or not root:IsA("BasePart") or not out then
				beam.Enabled = false
				continue
			end
			beam.Enabled = (root.Position - out.WorldPosition).Magnitude <= LINE_REACH
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		linked[player] = nil
	end)
end

return StationProps
