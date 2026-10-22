-- Zoo star rating, 1 to 5. Points come from base income per second, index completion and
-- pens unlocked (thresholds in LiveOpsConfig.Stars); the total points pick the stars.
-- Shown on a billboard above the bay sign, replicated as the Player attribute "ZooStars"
-- (the client HUD widget reads it), and announced server-wide when a zoo reaches a star
-- rating it has never had before.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Common = require(script.Parent.Common)
local Services = script.Parent.Parent.Parent.Services
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)
local ZooService = require(Services.ZooService)

local Config = LiveOpsConfig.Stars
local MAX_STARS = #Config.StarPoints
local FILLED = "#FFD02A"
local EMPTY = "#4A4A55"

local Stars = {}

local current: { [Player]: number } = {}
local signLabels: { [Player]: TextLabel } = {}

local function indexTotal(): number
	local species = 0
	for _, def in AnimalConfig.Animals do
		if not def.Limited then
			species += 1
		end
	end
	return math.max(1, species * #MutationConfig.List)
end

local function countAtLeast(value: number, thresholds: { number }): number
	local points = 0
	for _, threshold in thresholds do
		if value >= threshold then
			points += 1
		end
	end
	return points
end

function Stars.compute(player: Player): number
	local data = PlayerDataService.get(player)
	if not data then
		return 1
	end
	local found = 0
	for key, discovered in data.Index do
		if discovered == true and typeof(key) == "string" then
			found += 1
		end
	end
	local points = countAtLeast(ZooService.totalIncome(player), Config.IncomeThresholds)
		+ countAtLeast(math.min(1, found / indexTotal()), Config.IndexThresholds)
		+ countAtLeast(data.ZooSize, Config.PenThresholds)
	local stars = 1
	for i, need in Config.StarPoints do
		if points >= need then
			stars = i
		end
	end
	return stars
end

function Stars.get(player: Player): number
	return current[player] or 1
end

-- RichText row of gold and grey stars.
function Stars.richText(stars: number): string
	local filled = string.rep("★", stars)
	local empty = string.rep("★", MAX_STARS - stars)
	return `<font color="{FILLED}">{filled}</font><font color="{EMPTY}">{empty}</font>`
end

-- Our own billboard on the SignPost, sitting just above the core "<name>'s Zoo" label.
local function buildSign(player: Player, bay: Model)
	local post = bay:FindFirstChild("SignPost")
	if not post or not post:IsA("BasePart") then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "LiveOpsStars"
	billboard.Size = UDim2.fromOffset(200, 40)
	billboard.StudsOffset = Vector3.new(0, 5.5, 0) -- same anchor as the core Sign
	billboard.SizeOffset = Vector2.new(0, 1.2) -- shifted up by its own height
	billboard.MaxDistance = 80
	billboard.Parent = post
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.RichText = true
	label.Parent = billboard
	UIStyle.text(label, nil, nil, 3)
	label.Text = Stars.richText(Stars.get(player))
	signLabels[player] = label
end

local function update(player: Player)
	local state = Common.state(player)
	if not state then
		return
	end
	local stars = Stars.compute(player)
	local previous = current[player]
	if previous == stars then
		return
	end
	current[player] = stars
	player:SetAttribute(Common.STARS_ATTRIBUTE, stars)
	local label = signLabels[player]
	if label and label.Parent then
		label.Text = Stars.richText(stars)
	end
	if stars > state.BestStars then
		-- The first measurement of a session only records the rating; later gains are news.
		if previous ~= nil then
			local noun = if stars == 1 then "STAR" else "STARS"
			Common.announce(`{player.DisplayName}'s zoo is now {stars} {noun}!`, "Legendary")
		end
		state.BestStars = stars
		PlayerDataService.markDirty(player)
	end
end

function Stars.init()
	Hooks.on("BayAssigned", function(player: Player, bay: Model)
		if player.Parent then
			buildSign(player, bay)
			update(player)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(LiveOpsConfig.Leaderstats.UpdateInterval)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(update, player)
				if not ok then
					warn(`[LiveOps] Star update failed: {err}`)
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		current[player] = nil
		signLabels[player] = nil
	end)
end

return Stars
