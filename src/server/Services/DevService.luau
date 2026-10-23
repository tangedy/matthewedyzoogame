-- Studio and place-owner shortcuts. A published client cannot grant coins or skip a wash:
-- the server drops DevCommand unless this session is Studio or the sender owns the place.
--   C  finish the current wash      G  grant coins
--   V  toggle the animal gallery: a platform in the sky with every species, one row per
--      rarity, built the first time it's opened. Press again to go back.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local AnimalService = require(script.Parent.AnimalService)

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CleaningService = require(script.Parent.CleaningService)
local EconomyService = require(script.Parent.EconomyService)

local DevService = {}

local GALLERY_ORIGIN = Vector3.new(0, 420, 0)
local GALLERY_GAP = 12 -- studs between animals in a row (room for each nameplate)
local GALLERY_ROW_GAP = 26 -- studs between rows

local gallery: Model? = nil
local galleryStart: CFrame? = nil
local returnTo: { [Player]: CFrame } = {}

local function galleryPart(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	return p
end

local function rowLabel(text: string, rarityKey: string, at: Vector3, parent: Instance)
	local anchor = galleryPart({
		Name = "RowLabel",
		Size = Vector3.new(1, 1, 1),
		Position = at,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		Parent = parent,
	})
	local board = Instance.new("BillboardGui")
	board.Size = UDim2.fromOffset(260, 50)
	board.MaxDistance = 300
	board.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = board
	UIStyle.text(label, nil, nil, 3)
	UIStyle.rarity(label, rarityKey)
	label.Text = text
end

-- Every species on its own pedestal, one row per rarity (Common at the front), facing the
-- player's spawn point at the front edge.
local function buildGallery(): (Model, CFrame)
	local model = Instance.new("Model")
	model.Name = "DevAnimalGallery"
	local z = 0
	local widest = 0
	for _, rarity in RarityConfig.List do
		local keys = {}
		for key, def in AnimalConfig.Animals do
			if def.Rarity == rarity.Key then
				table.insert(keys, key)
			end
		end
		if #keys == 0 then
			continue
		end
		table.sort(keys, function(a, b)
			return AnimalConfig.Animals[a].Income < AnimalConfig.Animals[b].Income
		end)
		local row = {}
		local rowWidth, rowDepth = 0, 0
		for _, key in keys do
			local ok, animal = pcall(AnimalService.buildZooAnimal, key, MutationConfig.Default)
			if ok then
				local _, size = animal:GetBoundingBox()
				table.insert(row, { key = key, animal = animal, width = size.X, depth = size.Z })
				rowWidth += size.X + GALLERY_GAP
				rowDepth = math.max(rowDepth, size.Z)
			else
				warn(`[Dev] Gallery could not build {key}: {animal}`)
			end
		end
		z += rowDepth / 2
		local x = -rowWidth / 2
		for _, entry in row do
			x += entry.width / 2 + GALLERY_GAP / 2
			local at = GALLERY_ORIGIN + Vector3.new(x, 1, z)
			galleryPart({
				Name = "Pedestal",
				Size = Vector3.new(entry.width + 1, 1, entry.depth + 1),
				Position = at - Vector3.new(0, 0.5, 0),
				Color = Color3.fromRGB(235, 235, 240),
				Material = Enum.Material.SmoothPlastic,
				Parent = model,
			})
			entry.animal:PivotTo(CFrame.new(at)) -- faces -Z, toward the front edge
			entry.animal.Parent = model
			x += entry.width / 2 + GALLERY_GAP / 2
		end
		rowLabel(
			`{string.upper(rarity.DisplayName)} ({#row})`,
			rarity.Key,
			GALLERY_ORIGIN + Vector3.new(-rowWidth / 2 - 14, 4, z),
			model
		)
		widest = math.max(widest, rowWidth)
		z += rowDepth / 2 + GALLERY_ROW_GAP
	end
	local floorDepth = z + 30
	galleryPart({
		Name = "Floor",
		Size = Vector3.new(widest + 50, 1, floorDepth),
		Position = GALLERY_ORIGIN + Vector3.new(0, -0.5, z / 2 - 15),
		Color = Color3.fromRGB(120, 200, 110),
		Material = Enum.Material.Grass,
		Parent = model,
	})
	model.Parent = Workspace
	local front = GALLERY_ORIGIN + Vector3.new(0, 4, -20)
	return model, CFrame.lookAt(front, front + Vector3.zAxis)
end

local function toggleGallery(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not root then
		return
	end
	local back = returnTo[player]
	if back then
		returnTo[player] = nil
		character:PivotTo(back)
		return
	end
	if not gallery or not gallery.Parent then
		gallery, galleryStart = buildGallery()
	end
	returnTo[player] = root.CFrame
	character:PivotTo(galleryStart :: CFrame)
end

local function isDeveloper(player: Player): boolean
	return RunService:IsStudio() or (game.CreatorId ~= 0 and player.UserId == game.CreatorId)
end

function DevService.init()
	if RunService:IsStudio() then
		print(
			`[Dev] C cleans the current animal. G grants {GameConfig.DevCoinGrant} coins. V toggles the animal gallery.`
		)
	end
	Remotes.event("DevCommand").OnServerEvent:Connect(function(player: Player, action: any)
		if not isDeveloper(player) or typeof(action) ~= "string" then
			return
		end
		if action == "clean" then
			CleaningService.forceComplete(player)
		elseif action == "grant" then
			EconomyService.grant(player, GameConfig.DevCoinGrant)
		elseif action == "gallery" then
			toggleGallery(player)
		end
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		returnTo[player] = nil
	end)
end

return DevService
