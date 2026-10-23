-- Builds the map. Bays are built on demand: one appears when a player is given a slot and is
-- destroyed when they leave, so empty lanes never show. Slots alternate either side of the
-- world origin (+Z, -Z, +Z ...), leaving the origin clear for the default spawn.
--
-- Each bay exposes:
--   Entrance, WashPosition, Exit   lane markers (LookVector = travel direction)
--   Spawn                          the owner's SpawnLocation
--   SignPost.Sign.BayLabel         owner name
--   UpgradeStation.Counter         hose shop prompt
--   Cache.Slot{i}                  where washed animals wait (PickupPrompt, SellPrompt)
--   Zoo.Pen{i}                     Floor, Slot, Gate, GatePost.PenPrompt, CollectPad (+ Cash label)
--   Zoo.ExpandCounter              zoo expansion prompt

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local WorldBuilder = {}

local folder: Folder

local function makePart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(part :: any)[key] = value
	end
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
	return prompt
end

-- Outlined floating label (Steal a Brainrot style).
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
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = billboard
	UIStyle.text(label, color)
	label.Text = text
	return label
end

local function ensureGround()
	if Workspace:FindFirstChild("Baseplate") or Workspace:FindFirstChild("Ground") then
		return
	end
	makePart({
		Name = "Ground",
		Size = Vector3.new(512, 2, 1024),
		Position = Vector3.new(0, -1, 0),
		Color = Color3.fromRGB(106, 168, 79),
		Material = Enum.Material.Grass,
		Parent = Workspace,
	})
end

-- Hose upgrade counter. The client opens the shop panel when its ProximityPrompt fires;
-- purchases still go through the server.
local function buildUpgradeStation(base: Vector3, parent: Instance)
	local station = Instance.new("Model")
	station.Name = "UpgradeStation"

	local counter = makePart({
		Name = "Counter",
		Size = Vector3.new(6, 3, 3),
		Position = base + Vector3.new(0, 1.5, 0),
		Color = Color3.fromRGB(60, 150, 230),
		Material = Enum.Material.SmoothPlastic,
		Parent = station,
	})
	makePart({
		Name = "Awning",
		Size = Vector3.new(7, 0.4, 4),
		Position = base + Vector3.new(0, 6.5, 0),
		Color = Color3.fromRGB(255, 210, 70),
		Material = Enum.Material.SmoothPlastic,
		Parent = station,
	})
	for _, side in { -1, 1 } do
		makePart({
			Name = "Pole",
			Size = Vector3.new(0.4, 3.5, 0.4),
			Position = base + Vector3.new(side * 3.2, 4.75, 0),
			Color = Color3.fromRGB(240, 240, 240),
			Material = Enum.Material.SmoothPlastic,
			Parent = station,
		})
	end
	-- No static sign: the owner's client floats a bobbing "UPGRADE!" over this counter.
	local prompt = makePrompt("UpgradePrompt", "Upgrade Hose", 0, counter)
	prompt.ObjectText = "Hose Shop"

	station.Parent = parent
end

-- Washed animals wait here. ZooService enables each slot's prompts while it holds an animal.
local function buildCache(center: Vector3, padTop: number, bay: Model)
	local cfg = GameConfig.Cache
	local cache = Instance.new("Folder")
	cache.Name = "Cache"
	local first = center + cfg.Origin
	local width = (cfg.Slots - 1) * cfg.SlotSpacing + 6
	makePart({
		Name = "CacheFloor",
		Size = Vector3.new(width, 0.2, 9),
		Position = Vector3.new(first.X + (cfg.Slots - 1) * cfg.SlotSpacing / 2, padTop + 0.1, first.Z),
		Color = Color3.fromRGB(110, 200, 255),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
		Parent = cache,
	})
	for i = 1, cfg.Slots do
		local pos = Vector3.new(first.X + (i - 1) * cfg.SlotSpacing, padTop, first.Z)
		local slot = makeMarker("Slot" .. i, CFrame.lookAt(pos, pos + Vector3.zAxis), cache)
		slot:SetAttribute("SlotIndex", i)
		makePrompt("PickupPrompt", "Pick up", 0, slot).Enabled = false
		-- Below the pickup prompt, and a hold, so the two labels don't draw on top of each other.
		local sell = makePrompt("SellPrompt", "Sell", 1.5, slot, Enum.KeyCode.F)
		-- Positive Y shifts the billboard up. Negative puts Sell under Pick up.
		sell.UIOffset = Vector2.new(0, -110)
		sell.GamepadKeyCode = Enum.KeyCode.ButtonY
		sell.Enabled = false
	end
	cache.Parent = bay
end

-- One row of pens behind the pad (toward -Z), gates facing the pad. ZooService fills them,
-- locks/unlocks them, drives the prompts and the cash labels.
local function buildZoo(center: Vector3, padTop: number, bay: Model)
	local cfg = GameConfig.Zoo
	local zoo = Instance.new("Folder")
	zoo.Name = "Zoo"
	local size = cfg.PenSize
	local fenceColor = Color3.fromRGB(150, 110, 70)
	for i = 1, cfg.MaxPens do
		local pen = Instance.new("Model")
		pen.Name = "Pen" .. i
		pen:SetAttribute("PenIndex", i)
		local x = center.X + (i - (cfg.MaxPens + 1) / 2) * cfg.PenSpacing
		local z = center.Z + cfg.PenRowZ
		local floor = makePart({
			Name = "Floor",
			Size = size,
			Position = Vector3.new(x, padTop - size.Y / 2, z),
			Color = Color3.fromRGB(120, 170, 80),
			Material = Enum.Material.Grass,
			Parent = pen,
		})
		-- Fence: back and sides solid, front split around a 4-stud gate.
		local h = 2.5
		local y = padTop + h / 2
		local halfX, halfZ = size.X / 2, size.Z / 2
		local rails = {
			{ Vector3.new(size.X, h, 0.3), Vector3.new(x, y, z - halfZ) },
			{ Vector3.new(0.3, h, size.Z), Vector3.new(x - halfX, y, z) },
			{ Vector3.new(0.3, h, size.Z), Vector3.new(x + halfX, y, z) },
			{ Vector3.new((size.X - 4) / 2, h, 0.3), Vector3.new(x - halfX + (size.X - 4) / 4, y, z + halfZ) },
			{ Vector3.new((size.X - 4) / 2, h, 0.3), Vector3.new(x + halfX - (size.X - 4) / 4, y, z + halfZ) },
		}
		for _, rail in rails do
			makePart({
				Name = "Fence",
				Size = rail[1],
				Position = rail[2],
				Color = fenceColor,
				Material = Enum.Material.Wood,
				CanQuery = false,
				Parent = pen,
			})
		end
		local slotPos = Vector3.new(x, padTop, z)
		makeMarker("Slot", CFrame.lookAt(slotPos, slotPos + Vector3.zAxis), pen)
		local gatePos = Vector3.new(x, padTop, z + halfZ + 4)
		makeMarker("Gate", CFrame.lookAt(gatePos, gatePos - Vector3.zAxis), pen)

		local post = makePart({
			Name = "GatePost",
			Size = Vector3.new(0.6, 3.5, 0.6),
			Position = Vector3.new(x + 2.4, padTop + 1.75, z + halfZ + 0.4),
			Color = Color3.fromRGB(240, 240, 240),
			Material = Enum.Material.SmoothPlastic,
			Parent = pen,
		})
		makePrompt("PenPrompt", "Sell", 1, post).Enabled = false

		-- Step on the pad to collect the pen's earnings.
		local pad = makePart({
			Name = "CollectPad",
			Size = Vector3.new(3.4, 0.3, 3.4),
			Position = Vector3.new(x - 3, padTop + 0.15, z + halfZ + 2.4),
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
		CollectionService:AddTag(pad, "CollectPad") -- PenCashController animates these

		local status = billboardLabel(floor, "", Vector3.new(0, 4, 0), Vector2.new(80, 18))
		local stroke = status:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Thickness = 1.25
		end
		(status.Parent :: Instance).Name = "Status"
		pen.Parent = zoo
	end

	-- Zoo expansion stand on the pad, next to the pens
	local standPos = Vector3.new(center.X + 16, padTop, center.Z - 12)
	local counter = makePart({
		Name = "ExpandCounter",
		Size = Vector3.new(5, 3, 2.5),
		Position = standPos + Vector3.new(0, 1.5, 0),
		Color = Color3.fromRGB(120, 170, 80),
		Material = Enum.Material.SmoothPlastic,
		Parent = zoo,
	})
	billboardLabel(counter, "ZOO EXPANSION", Vector3.new(0, 4, 0), Vector2.new(190, 36))
	makePrompt("ExpandPrompt", "Expand Zoo", 0.5, counter).ObjectText = "Zoo Expansion"

	zoo.Parent = bay
end

-- Slot 1 at +Z, slot 2 at -Z, slot 3 further +Z, and so on.
local function slotCenter(index: number): Vector3
	local row = math.ceil(index / 2)
	local side = if index % 2 == 1 then 1 else -1
	return Vector3.new(0, 0, side * (row - 0.5) * GameConfig.BaySpacing)
end

function WorldBuilder.buildBay(index: number): Model
	local center = slotCenter(index)
	local bay = Instance.new("Model")
	bay.Name = "Bay" .. index

	local padSize = GameConfig.BayPadSize
	local padTop = center.Y + padSize.Y / 2
	local halfLength = padSize.X / 2

	makePart({
		Name = "Pad",
		Size = padSize,
		Position = center,
		Color = Color3.fromRGB(200, 200, 205),
		Material = Enum.Material.Concrete,
		Parent = bay,
	})

	-- Drain under the wash position, a visual cue for where animals stop.
	makePart({
		Name = "Drain",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.1, 10, 10),
		CFrame = CFrame.new(center.X, padTop + 0.05, center.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(90, 140, 190),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
		Parent = bay,
	})

	-- Animals walk along +X: in at the entrance, stop at the drain.
	local function laneCFrame(x: number): CFrame
		local pos = Vector3.new(center.X + x, padTop, center.Z)
		return CFrame.lookAt(pos, pos + Vector3.xAxis)
	end
	makeMarker("Entrance", laneCFrame(GameConfig.RoadX - center.X), bay) -- on the road
	makeMarker("WashPosition", laneCFrame(0), bay)
	makeMarker("Exit", laneCFrame(halfLength + 6), bay)

	local spawnPos = Vector3.new(center.X - 4, padTop + 0.1, center.Z + 11)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(5, 0.2, 5)
	spawn.CFrame = CFrame.lookAt(spawnPos, Vector3.new(center.X, spawnPos.Y, center.Z))
	spawn.Color = Color3.fromRGB(120, 190, 255)
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.CanCollide = false
	spawn.Parent = bay

	local post = makePart({
		Name = "SignPost",
		Size = Vector3.new(1, 8, 1),
		Position = Vector3.new(center.X, padTop + 4, center.Z - padSize.Z / 2 + 1),
		Color = Color3.fromRGB(120, 85, 60),
		Material = Enum.Material.Wood,
		Parent = bay,
	})
	local sign = billboardLabel(post, "", Vector3.new(0, 5.5, 0), Vector2.new(260, 50))
	sign.Name = "BayLabel"
	(sign.Parent :: BillboardGui).Name = "Sign"
	(sign.Parent :: BillboardGui).MaxDistance = 80

	buildUpgradeStation(Vector3.new(center.X - 14, padTop, center.Z + 12), bay)
	buildCache(center, padTop, bay)
	buildZoo(center, padTop, bay)

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
