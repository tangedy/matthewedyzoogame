-- 2x luck while a Roblox friend is in the same server (FriendLuckConfig). Friendship is
-- checked once per pair when someone joins; the count lives on the FriendLuck attribute
-- so the client box can show it without a remote.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local Config = require(ReplicatedStorage.Shared.FeatureConfig.FriendLuckConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Hooks = require(script.Parent.Parent.Services.Hooks)

local FriendLuck = {}

-- friends[player][other] is true when the two are Roblox friends.
local friends: { [Player]: { [Player]: boolean } } = {}

local function publish(player: Player)
	local count = 0
	local mine: { [Player]: boolean } = friends[player] or {}
	for other in mine do
		if other.Parent then
			count += 1
		end
	end
	player:SetAttribute("FriendLuck", count)
end

-- IsFriendsWith is a web call: it yields and can fail. A failure counts as not friends.
local function check(a: Player, b: Player)
	local ok, result = pcall(function()
		return a:IsFriendsWith(b.UserId)
	end)
	if not ok or result ~= true or not a.Parent or not b.Parent then
		return
	end
	if friends[a] and friends[b] then
		friends[a][b] = true
		friends[b][a] = true
		publish(a)
		publish(b)
	end
end

local function onJoin(player: Player)
	friends[player] = {}
	player:SetAttribute("FriendLuck", 0)
	for _, other in Players:GetPlayers() do
		if other ~= player and friends[other] then
			task.spawn(check, player, other)
		end
	end
end

function FriendLuck.active(player: Player): boolean
	return (player:GetAttribute("FriendLuck") or 0) > 0
end

function FriendLuck.init()
	Players.PlayerAdded:Connect(onJoin)
	for _, player in Players:GetPlayers() do
		onJoin(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local mine: { [Player]: boolean } = friends[player] or {}
		friends[player] = nil
		for other in mine do
			if friends[other] then
				friends[other][player] = nil
				publish(other)
			end
		end
	end)

	Hooks.modify("SpawnWeight", function(weight: number, player: Player, species: string): number
		if not FriendLuck.active(player) then
			return weight
		end
		local def = AnimalConfig.Animals[species]
		local rarity = def and RarityConfig.ByKey[def.Rarity]
		return if rarity and rarity.Order >= Config.MinRarityOrder
			then weight * Config.SpawnWeightMultiplier
			else weight
	end)
end

return FriendLuck
