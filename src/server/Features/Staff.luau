-- Marks the game's owners (FeatureConfig/StaffConfig) with the StaffRole and StaffTitle
-- attributes and hangs their title over the avatar. Chat (client/Features/Social), the
-- player list (LiveOps/Leaderboard) and flight (client/Features/Flight) read the attributes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StaffConfig = require(ReplicatedStorage.Shared.FeatureConfig.StaffConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local Staff = {}

local TAG_NAME = "StaffTag"

local function groupRank(player: Player): number
	if game.CreatorType ~= Enum.CreatorType.Group or game.CreatorId == 0 then
		return 0
	end
	local ok, rank = pcall(function()
		return player:GetRankInGroup(game.CreatorId)
	end)
	return if ok and typeof(rank) == "number" then rank else 0
end

local function isStaff(player: Player): boolean
	if table.find(StaffConfig.UserIds, player.UserId) then
		return true
	end
	return groupRank(player) >= StaffConfig.MinRank
end

function Staff.isStaff(player: Player): boolean
	return player:GetAttribute("StaffRole") ~= nil
end

local function addTag(character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") or head:FindFirstChild(TAG_NAME) then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = TAG_NAME
	billboard.Size = UDim2.fromOffset(170, 34)
	billboard.StudsOffset = Vector3.new(0, 2.4, 0) -- above the default display name
	billboard.MaxDistance = StaffConfig.TagMaxDistance
	billboard.LightInfluence = 0
	billboard.Adornee = head
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.Text = StaffConfig.Title
	label.Parent = billboard
	UIStyle.text(label, Color3.new(1, 1, 1), Color3.new(0, 0, 0), 3)
	UIStyle.rainbow(label)
end

local function onPlayer(player: Player)
	if not isStaff(player) or not player.Parent then
		return
	end
	player:SetAttribute("StaffRole", StaffConfig.Role)
	player:SetAttribute("StaffTitle", StaffConfig.Title)
	player.CharacterAdded:Connect(addTag)
	if player.Character then
		task.spawn(addTag, player.Character)
	end
end

function Staff.init()
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return Staff
