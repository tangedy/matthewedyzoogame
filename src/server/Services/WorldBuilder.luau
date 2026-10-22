-- Builds the placeholder map: ground plus a row of wash bays under Workspace.WashBays.
-- Each bay model exposes Entrance, WashPosition and Exit markers (LookVector = travel
-- direction), a SpawnLocation, and a sign with a BayLabel TextLabel.

local Workspace = game:GetService("Workspace")

local GameConfig = require(game:GetService("ReplicatedStorage").Shared.GameConfig)

local WorldBuilder = {}

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

local function ensureGround()
	if Workspace:FindFirstChild("Baseplate") or Workspace:FindFirstChild("Ground") then
		return
	end
	makePart({
		Name = "Ground",
		Size = Vector3.new(512, 2, 512),
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

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(200, 40)
	billboard.StudsOffset = Vector3.new(0, 6.5, 0)
	billboard.MaxDistance = 80
	billboard.Parent = counter
	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, 1)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeTransparency = 0.3
	title.TextScaled = true
	title.Font = Enum.Font.FredokaOne
	title.Text = "HOSE UPGRADES"
	title.Parent = billboard

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "UpgradePrompt"
	prompt.ActionText = "Upgrade Hose"
	prompt.ObjectText = "Hose Shop"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter

	station.Parent = parent
end

local function buildBay(index: number, center: Vector3, parent: Instance): Model
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

	-- Animals walk along +X: in at the entrance, stop at the drain, out at the exit.
	local function laneCFrame(x: number): CFrame
		local pos = Vector3.new(center.X + x, padTop, center.Z)
		return CFrame.lookAt(pos, pos + Vector3.xAxis)
	end
	makeMarker("Entrance", laneCFrame(-halfLength - 6), bay)
	makeMarker("WashPosition", laneCFrame(0), bay)
	makeMarker("Exit", laneCFrame(halfLength + 6), bay)

	local spawnPos = Vector3.new(center.X, padTop + 0.1, center.Z + 11)
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
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Sign"
	billboard.Size = UDim2.fromOffset(220, 50)
	billboard.StudsOffset = Vector3.new(0, 5.5, 0)
	billboard.MaxDistance = 150
	billboard.Parent = post
	local label = Instance.new("TextLabel")
	label.Name = "BayLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.Text = "Wash Bay " .. index
	label.Parent = billboard
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = label

	buildUpgradeStation(Vector3.new(center.X - 14, padTop, center.Z + 12), bay)

	bay:SetAttribute("BayIndex", index)
	bay.Parent = parent
	return bay
end

function WorldBuilder.build(): { Model }
	ensureGround()

	local existing = Workspace:FindFirstChild("WashBays")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "WashBays"
	folder.Parent = Workspace

	local bays = {}
	local count = GameConfig.BayCount
	for i = 1, count do
		local z = (i - (count + 1) / 2) * GameConfig.BaySpacing
		table.insert(bays, buildBay(i, Vector3.new(0, 0, z), folder))
	end
	return bays
end

return WorldBuilder
