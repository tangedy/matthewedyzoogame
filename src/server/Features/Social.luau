-- Social flex: one washed animal (three, after any Robux spend) follows the avatar,
-- spenders get the Vip attribute (chat and leaderboards read it), and playtime or
-- washes unlock a trail and a glow on the hose. None of this changes clean power,
-- income, or tool tier.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WashTool = require(ReplicatedStorage.Shared.WashTool)
local Services = script.Parent.Parent.Services
local AnimalService = require(Services.AnimalService)
local Hooks = require(Services.Hooks)
local MonetizationState = require(script.Parent.MonetizationState)
local PlayerDataService = require(Services.PlayerDataService)

local Social = {}

local TICK = 15

type Tier = {
	Name: string,
	Washes: number,
	Seconds: number,
	Color: Color3,
	Light: number,
	Rate: number,
}

-- Either bar unlocks the tier. A long session and a fast washer both show it,
-- and neither bar grants a hose or cash.
local TIERS: { Tier } = {
	{
		Name = "Soap",
		Washes = 10,
		Seconds = 8 * 60,
		Color = Color3.fromRGB(170, 220, 255),
		Light = 0.6,
		Rate = 6,
	},
	{
		Name = "Keeper",
		Washes = 40,
		Seconds = 40 * 60,
		Color = Color3.fromRGB(130, 255, 170),
		Light = 1.3,
		Rate = 10,
	},
	{
		Name = "Star",
		Washes = 150,
		Seconds = 3 * 3600,
		Color = Color3.fromRGB(255, 210, 90),
		Light = 2.1,
		Rate = 16,
	},
	{
		Name = "Legend",
		Washes = 500,
		Seconds = 8 * 3600,
		Color = Color3.fromRGB(255, 140, 230),
		Light = 3.2,
		Rate = 22,
	},
}

type SocialData = {
	PlaySeconds: number,
	Pets: { string },
}

local followers: { [Player]: { Model } } = {}
local followerKey: { [Player]: string } = {}
local sessionStart: { [Player]: number } = {}
local folder: Folder

local function ensure(data: PlayerDataService.SavedData): SocialData
	local raw = data.Extra.Social
	local state: SocialData = { PlaySeconds = 0, Pets = {} }
	if typeof(raw) == "table" then
		if typeof(raw.PlaySeconds) == "number" and raw.PlaySeconds > 0 and raw.PlaySeconds < 1e9 then
			state.PlaySeconds = raw.PlaySeconds
		end
		if typeof(raw.Pets) == "table" then
			for _, id in raw.Pets do
				if typeof(id) == "string" then
					table.insert(state.Pets, id)
				end
			end
		end
	end
	data.Extra.Social = state
	return state
end

function Social.petCap(player: Player): number
	local saved = MonetizationState.saved(player)
	if saved and saved.PastureUnlocked then
		return 3
	end
	return 1
end

function Social.petCount(player: Player): number
	local data = PlayerDataService.get(player)
	if not data then
		return 0
	end
	return #ensure(data).Pets
end

function Social.isPet(player: Player, animalId: string): boolean
	local data = PlayerDataService.get(player)
	if not data then
		return false
	end
	for _, id in ensure(data).Pets do
		if id == animalId then
			return true
		end
	end
	return false
end

local function tierFor(player: Player): Tier?
	local data = PlayerDataService.get(player)
	if not data then
		return nil
	end
	local seconds = ensure(data).PlaySeconds
	local best: Tier? = nil
	for _, tier in TIERS do
		if data.LifetimeAnimalsWashed >= tier.Washes or seconds >= tier.Seconds then
			best = tier
		end
	end
	return best
end

local function applyVip(player: Player)
	local saved = MonetizationState.saved(player)
	local vip = MonetizationState.ownsPass(player, "VIPKeeper") or (saved ~= nil and saved.PastureUnlocked == true)
	player:SetAttribute("Vip", vip)
	local head = player.Character and player.Character:FindFirstChild("Head")
	local tag = head and head:FindFirstChild("VIPTag")
	if tag then
		tag:Destroy()
	end
end

local function clearCosmetic(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	local trail = root and root:FindFirstChild("FlexTrail")
	if trail then
		trail:Destroy()
	end
	local hose = WashTool.find(character)
	if not hose then
		return
	end
	local glow = hose:FindFirstChild("FlexGlow")
	if glow then
		glow:Destroy()
	end
	local sparks = hose:FindFirstChild("FlexSparks")
	if sparks then
		sparks:Destroy()
	end
end

local function applyCosmetic(player: Player)
	local character = player.Character
	if not character then
		return
	end
	clearCosmetic(character)
	local tier = tierFor(player)
	player:SetAttribute("FlexTier", if tier then tier.Name else nil)
	if not tier then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local attachment = Instance.new("Attachment")
		attachment.Name = "FlexTrail"
		attachment.Position = Vector3.new(0, 0.2, 0.8)
		attachment.Parent = root
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Trail"
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Rate = tier.Rate
		emitter.Lifetime = NumberRange.new(0.4, 0.8)
		emitter.Speed = NumberRange.new(0.4, 1.4)
		emitter.SpreadAngle = Vector2.new(18, 18)
		emitter.EmissionDirection = Enum.NormalId.Back
		emitter.Drag = 2
		emitter.LightEmission = 0.85
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.45),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new(0.15, 1)
		emitter.Color = ColorSequence.new(tier.Color)
		emitter.Parent = attachment
	end
	local hose = WashTool.find(character)
	if hose then
		local light = Instance.new("PointLight")
		light.Name = "FlexGlow"
		light.Color = tier.Color
		light.Brightness = tier.Light
		light.Range = 8 + tier.Light * 3
		light.Parent = hose
		local sparks = Instance.new("ParticleEmitter")
		sparks.Name = "FlexSparks"
		sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparks.Rate = 3 + tier.Light
		sparks.Lifetime = NumberRange.new(0.3, 0.6)
		sparks.Speed = NumberRange.new(0.2, 0.8)
		sparks.SpreadAngle = Vector2.new(180, 180)
		sparks.LightEmission = 1
		sparks.Size = NumberSequence.new(0.28, 0)
		sparks.Color = ColorSequence.new(tier.Color)
		sparks.Parent = hose
	end
end

local function destroyFollowers(player: Player)
	local list = followers[player]
	if list then
		for _, model in list do
			model:Destroy()
		end
	end
	followers[player] = nil
	followerKey[player] = nil
end

local function rebuild(player: Player)
	local data = PlayerDataService.get(player)
	if not data or not player.Parent then
		destroyFollowers(player)
		return
	end
	local state = ensure(data)
	local owned: { [string]: PlayerDataService.OwnedAnimal } = {}
	for _, animal in data.Animals do
		owned[animal.Id] = animal
	end
	local cap = Social.petCap(player)
	local ids: { string } = {}
	local changed = false
	for _, id in state.Pets do
		if owned[id] and #ids < cap then
			table.insert(ids, id)
		else
			changed = true
		end
	end
	if changed then
		state.Pets = ids
		PlayerDataService.markDirty(player)
	end
	local key = table.concat(ids, ",") .. ":" .. tostring(player.Character)
	if key == followerKey[player] then
		return
	end
	destroyFollowers(player)
	followerKey[player] = key
	local list: { Model } = {}
	for _, id in ids do
		local animal = owned[id]
		if not animal then
			continue
		end
		local model = AnimalService.buildZooAnimal(animal.Species, animal.Mutation)
		model.Name = "Pet"
		model:SetAttribute("IsPet", true)
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
			end
		end
		local head = model:FindFirstChild("Head")
		local plate = head and head:FindFirstChild("Nameplate")
		if plate and plate:IsA("BillboardGui") then
			plate.MaxDistance = 160
		end
		-- Clients walk the pet after its owner (client/Features/PetFollow). Moving it here
		-- every frame replicated every part's CFrame to every player, 60 times a second.
		model:SetAttribute("PetOwner", player.UserId)
		model:SetAttribute("PetIndex", #list + 1)
		model:SetAttribute("PetCount", #ids)
		-- It never moves on the server, so streaming must not drop it where it was parked.
		model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			model:PivotTo(root.CFrame * CFrame.new((#list - 1) * 4, 0, 8))
		else
			model:PivotTo(CFrame.new(0, -200, 0))
		end
		model.Parent = folder
		table.insert(list, model)
	end
	followers[player] = list
end

function Social.togglePet(player: Player, animalId: string)
	local data = PlayerDataService.get(player)
	if not data then
		return
	end
	local owned = false
	for _, animal in data.Animals do
		if animal.Id == animalId then
			owned = true
			break
		end
	end
	if not owned then
		return
	end
	local state = ensure(data)
	for index, id in state.Pets do
		if id == animalId then
			table.remove(state.Pets, index)
			PlayerDataService.saveNow(player)
			rebuild(player)
			return
		end
	end
	local cap = Social.petCap(player)
	while #state.Pets >= cap do
		table.remove(state.Pets, 1)
	end
	table.insert(state.Pets, animalId)
	PlayerDataService.saveNow(player)
	rebuild(player)
end

local function accrue(player: Player, seconds: number)
	local data = PlayerDataService.get(player)
	if not data or seconds <= 0 then
		return
	end
	local state = ensure(data)
	state.PlaySeconds += seconds
	PlayerDataService.markDirty(player)
	-- Rebuild the trail and glow only when the tier changes, so particles don't reset every tick.
	local tier = tierFor(player)
	if (if tier then tier.Name else nil) ~= player:GetAttribute("FlexTier") then
		applyCosmetic(player)
	end
	applyVip(player)
end

local function watch(player: Player, character: Model)
	if player.Character ~= character then
		return
	end
	applyVip(player)
	applyCosmetic(player)
	rebuild(player)
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child:GetAttribute(WashTool.ATTRIBUTE) == true and player.Character == character then
			task.defer(applyCosmetic, player)
		end
	end)
end

function Social.init()
	folder = Instance.new("Folder")
	folder.Name = "Pets"
	folder.Parent = Workspace

	Hooks.on("PlayerLoaded", function(player: Player)
		sessionStart[player] = os.clock()
		applyVip(player)
		applyCosmetic(player)
		rebuild(player)
	end)
	Hooks.on("AnimalSold", function(player: Player)
		rebuild(player)
	end)
	Hooks.on("AnimalPlaced", function(player: Player)
		rebuild(player)
	end)
	Hooks.on("PlayerLeaving", function(player: Player)
		local started = sessionStart[player]
		if not started then
			return
		end
		local elapsed = os.clock() - started
		sessionStart[player] = os.clock()
		accrue(player, elapsed)
	end)

	local function bind(player: Player)
		player.CharacterAdded:Connect(function(character)
			task.defer(watch, player, character)
		end)
		if player.Character then
			task.defer(watch, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(bind)
	for _, player in Players:GetPlayers() do
		bind(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		destroyFollowers(player)
		sessionStart[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(TICK)
			for _, player in Players:GetPlayers() do
				local started = sessionStart[player]
				if started then
					local elapsed = os.clock() - started
					sessionStart[player] = os.clock()
					accrue(player, elapsed)
				end
			end
		end
	end)
end

return Social
