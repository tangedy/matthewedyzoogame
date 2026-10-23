-- Unskippable spawn cutscene. A public creator avatar washes a T-Rex at a maxed station
-- so the first thing a new player sees is the endgame, then they wash a baby elephant.
-- The 3D set lives far from the plots. The client only moves its camera here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local AnimalBuilder = require(script.Parent.AnimalBuilder)
local HoseBuilder = require(script.Parent.HoseBuilder)
local PlayerDataService = require(script.Parent.PlayerDataService)

local CutsceneService = {}

local readyAt: { [Player]: number } = {}
local janitor = Janitor.new()

local ORIGIN = CFrame.new(0, 3, 1800)

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

local function cameraPart(parent: Instance, name: string, position: Vector3, lookAt: Vector3)
	local cam = part({
		Name = name,
		Size = Vector3.new(1, 1, 1),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CFrame = CFrame.lookAt(position, lookAt),
		Parent = parent,
	})
	return cam
end

local function label(adornee: BasePart, text: string, offset: Vector3, color: Color3)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(140, 28)
	billboard.StudsOffset = offset
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 80
	billboard.Parent = adornee
	local gui = Instance.new("TextLabel")
	gui.Size = UDim2.fromScale(1, 1)
	gui.BackgroundTransparency = 1
	gui.Text = text
	gui.Parent = billboard
	UIStyle.text(gui, color, Color3.fromRGB(20, 20, 30), 3)
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

local function loadAvatar(parent: Instance, focus: Vector3)
	local cfg = GameConfig.Cutscene
	local description: HumanoidDescription? = nil
	local ok, loaded = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(cfg.AvatarUserId)
	end)
	if ok and typeof(loaded) == "Instance" and loaded:IsA("HumanoidDescription") then
		description = loaded
	else
		description = Instance.new("HumanoidDescription")
	end
	local avatar = createAvatar(description)
	if not avatar then
		return
	end
	avatar.Name = "ShowcaseKeeper"
	local root = avatar:FindFirstChild("HumanoidRootPart") :: BasePart?
	avatar.Parent = parent
	if root then
		root.Anchored = true
		root.CFrame = CFrame.lookAt(ORIGIN.Position + Vector3.new(-8, 2.5, 4), focus)
	end
	HoseBuilder.equip(avatar, cfg.HoseTier)
	local head = avatar:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local name = "Top Keeper"
		local named, userName = pcall(function()
			return Players:GetNameFromUserIdAsync(cfg.AvatarUserId)
		end)
		if named and typeof(userName) == "string" then
			name = userName
		end
		label(head, name, Vector3.new(0, 3, 0), Color3.fromRGB(255, 230, 120))
	end
	local hose = avatar:FindFirstChild("Hose")
	local nozzle = hose and hose:FindFirstChild("Nozzle")
	local animal = parent:FindFirstChild("ShowcaseAnimal")
	local body = animal and animal:FindFirstChild("Body")
	if nozzle and nozzle:IsA("Attachment") and body and body:IsA("BasePart") then
		local target = Instance.new("Attachment")
		target.Name = "SprayTarget"
		target.Position = Vector3.new(0, 1, 0)
		target.Parent = body
		local beam = Instance.new("Beam")
		beam.Attachment0 = nozzle
		beam.Attachment1 = target
		beam.Width0 = 0.6
		beam.Width1 = 1.4
		beam.FaceCamera = true
		beam.LightEmission = 0.6
		beam.Color = ColorSequence.new(Color3.fromRGB(160, 220, 255))
		beam.Parent = hose
		janitor:Add(RunService.Heartbeat:Connect(function()
			local pulse = 0.7 + math.sin(os.clock() * 18) * 0.25
			beam.Width0 = pulse
			if root and root.Parent then
				local base = CFrame.lookAt(ORIGIN.Position + Vector3.new(-8, 2.5, 4), focus)
				root.CFrame = base * CFrame.new(0, math.sin(os.clock() * 2) * 0.12, 0)
			end
		end))
	end
	parent:SetAttribute("Ready", true)
end

function CutsceneService.init()
	if Workspace:FindFirstChild("CutsceneShowcase") then
		return
	end
	local cfg = GameConfig.Cutscene
	local folder = Instance.new("Folder")
	folder.Name = "CutsceneShowcase"
	folder.Parent = Workspace

	part({
		Name = "Ground",
		Size = Vector3.new(80, 2, 80),
		Color = Color3.fromRGB(106, 168, 79),
		Material = Enum.Material.Grass,
		CFrame = ORIGIN * CFrame.new(0, -1, 8),
		Parent = folder,
	})
	part({
		Name = "MaxedStation",
		Size = Vector3.new(16, 1, 22),
		Color = Color3.fromRGB(255, 196, 60),
		Material = Enum.Material.Neon,
		CFrame = ORIGIN * CFrame.new(0, 0, 10),
		Parent = folder,
	})
	local built = AnimalBuilder.build(cfg.Species, { Mutation = "Normal", Rarity = "Secret" })
	built.Name = "ShowcaseAnimal"
	if cfg.Scale > 0 then
		built:ScaleTo(cfg.Scale)
	end
	built:PivotTo(ORIGIN * CFrame.new(0, 0, 12))
	built.Parent = folder

	local focus = ORIGIN.Position + Vector3.new(0, 7, 12)
	cameraPart(folder, "CameraWide", ORIGIN.Position + Vector3.new(26, 16, -4), focus)
	cameraPart(folder, "CameraClose", ORIGIN.Position + Vector3.new(-14, 6, 2), focus)
	cameraPart(folder, "CameraHero", ORIGIN.Position + Vector3.new(6, 4, 28), focus + Vector3.new(0, 2, 0))

	task.spawn(loadAvatar, folder, focus)

	janitor:Add(Remotes.event("CutsceneFinished").OnServerEvent:Connect(function(player: Player)
		local data = PlayerDataService.get(player)
		local at = readyAt[player]
		if not data or data.CutsceneSeen or at == nil or os.clock() + 0.25 < at then
			return
		end
		data.CutsceneSeen = true
		PlayerDataService.markDirty(player)
		PlayerDataService.saveNow(player)
		player:SetAttribute("InCutscene", false)
	end))
	janitor:Add(Players.PlayerRemoving:Connect(function(player)
		readyAt[player] = nil
	end))
end

-- True only while the opening shot is still inside its timer. A missed clear used to leave
-- the hose locked after the camera had already come back.
function CutsceneService.blocksCleaning(player: Player): boolean
	if player:GetAttribute("InCutscene") ~= true then
		return false
	end
	local at = readyAt[player]
	if at == nil or os.clock() >= at then
		player:SetAttribute("InCutscene", false)
		return false
	end
	return true
end

function CutsceneService.begin(player: Player)
	local data = PlayerDataService.get(player)
	if not data or data.CutsceneSeen then
		player:SetAttribute("InCutscene", false)
		return
	end
	player:SetAttribute("InCutscene", true)
	readyAt[player] = os.clock() + GameConfig.Cutscene.Duration
	task.delay(GameConfig.Cutscene.Duration, function()
		if player.Parent then
			player:SetAttribute("InCutscene", false)
		end
	end)
end

return CutsceneService
