-- Contextual onboarding, fired by triggers instead of up-front menus:
--   * First wash: a bobbing "Wash me!" marker over the animal until the player starts cleaning.
--   * Empty zoo: "Pick me up!" over the cache, then "Place here!" over the first pen while
--     carrying, until the first animal is in a pen.
--   * First time an upgrade is affordable: a banner plus a marker over the bay's upgrade stand,
--     shown until the player opens the shop (once per tier per session).

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local OnboardingController = {}

local FONT = UIStyle.Font
local BANNER_SECONDS = 7

local tutorialCompleted = false
local coins = 0
local tier = 1
local bayName: string? = nil
local jobId: string? = nil
local washing = false
local progress = 0
local shopHintShownForTier: { [number]: boolean } = {}

local gui: ScreenGui
local banner: TextLabel
local animalMarker: BillboardGui
local stationMarker: BillboardGui
local cacheMarker: BillboardGui
local penMarker: BillboardGui
local zooCount = 0
local cacheCount = 0
local carrying = false
local bannerToken = 0

local function makeMarker(text: string, color: Color3): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(160, 90)
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.ResetOnSpawn = false
	-- Directly under PlayerGui: a BillboardGui nested inside a ScreenGui is never drawn.
	billboard.Parent = player:WaitForChild("PlayerGui")
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 0.45)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.Font = FONT
	label.TextColor3 = color
	label.TextStrokeTransparency = 0
	label.Parent = billboard
	local arrow = label:Clone()
	arrow.Position = UDim2.fromScale(0, 0.45)
	arrow.Size = UDim2.fromScale(1, 0.55)
	arrow.Text = "▼"
	arrow.Parent = billboard
	return billboard
end

local function bayModel(): Instance?
	local bays = Workspace:FindFirstChild("WashBays")
	return bays and bayName and bays:FindFirstChild(bayName)
end

local function refreshAnimalMarker()
	local bay = bayModel()
	local animal = bay and bay:FindFirstChild("Animal")
	local head = animal and animal:GetAttribute("JobId") == jobId and animal:FindFirstChild("Head")
	local show = not tutorialCompleted and washing and progress < 0.15 and head ~= nil
	animalMarker.Adornee = if show then head :: BasePart else nil :: any
	animalMarker.Enabled = show
end

local function showBanner(text: string)
	bannerToken += 1
	local token = bannerToken
	banner.Text = text
	banner.Visible = true
	task.delay(BANNER_SECONDS, function()
		if bannerToken == token then
			banner.Visible = false
		end
	end)
end

local function hideShopHint()
	stationMarker.Enabled = false
	stationMarker.Adornee = nil :: any
	banner.Visible = false
	bannerToken += 1
end

local function checkShopHint()
	local nextTool = ToolConfig[tier + 1]
	if not nextTool or shopHintShownForTier[tier] or coins < nextTool.Price then
		return
	end
	shopHintShownForTier[tier] = true
	local bay = bayModel()
	local station = bay and bay:FindFirstChild("UpgradeStation")
	local counter = station and station:FindFirstChild("Counter")
	if counter and counter:IsA("BasePart") then
		stationMarker.Adornee = counter
		stationMarker.Enabled = true
	end
	showBanner(`You can afford the {nextTool.Name}! Visit the HOSE UPGRADES stand.`)
end

-- Until the first animal is in a pen: point at the cache, then at pen 1 while carrying.
local function refreshZooMarkers()
	local bay = bayModel()
	local learning = zooCount == 0
	local cache = bay and bay:FindFirstChild("Cache")
	local slot = cache and cache:FindFirstChild("Slot1")
	local showCache = learning and not carrying and cacheCount > 0 and slot ~= nil
	cacheMarker.Adornee = if showCache then slot :: BasePart else nil :: any
	cacheMarker.Enabled = showCache

	local zoo = bay and bay:FindFirstChild("Zoo")
	local pen = zoo and zoo:FindFirstChild("Pen1")
	local post = pen and pen:FindFirstChild("GatePost")
	local showPen = learning and carrying and post ~= nil
	penMarker.Adornee = if showPen then post :: BasePart else nil :: any
	penMarker.Enabled = showPen
end

local function applyBay(bay: Types.BaySnapshot?)
	if not bay then
		return
	end
	bayName = bay.BayName
	if bay.JobId ~= jobId then
		progress = 0
	end
	jobId = bay.JobId
	washing = bay.State == "Washing"
	progress = bay.Progress or progress
	refreshAnimalMarker()
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "Onboarding"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	banner = Instance.new("TextLabel")
	banner.AnchorPoint = Vector2.new(0.5, 1)
	banner.Position = UDim2.new(0.5, 0, 1, -185)
	banner.Size = UDim2.new(0.9, 0, 0, 40)
	banner.BackgroundColor3 = Color3.fromRGB(255, 200, 60)
	banner.TextColor3 = Color3.fromRGB(40, 30, 10)
	banner.Font = FONT
	banner.TextScaled = true
	banner.Visible = false
	banner.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = banner
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(560, 40)
	constraint.Parent = banner
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = banner

	animalMarker = makeMarker("Wash me!", Color3.fromRGB(150, 230, 255))
	stationMarker = makeMarker("Upgrade!", Color3.fromRGB(255, 220, 90))
	cacheMarker = makeMarker("Pick me up!", Color3.fromRGB(110, 200, 255))
	penMarker = makeMarker("Place here!", Color3.fromRGB(90, 255, 90))
end

function OnboardingController.init(initial: Types.InitialState)
	tutorialCompleted = initial.TutorialCompleted
	coins = initial.Coins
	tier = initial.ToolTier
	buildGui()
	applyBay(initial.Bay)
	checkShopHint()

	if initial.Zoo then
		zooCount = initial.Zoo.Count
		cacheCount = initial.Zoo.CacheCount
	end
	refreshZooMarkers()
	Remotes.event("ZooChanged").OnClientEvent:Connect(function(summary: Types.ZooSummary)
		zooCount = summary.Count
		cacheCount = summary.CacheCount
		refreshZooMarkers()
	end)
	Remotes.event("CarryChanged").OnClientEvent:Connect(function(info: Types.CarryInfo?)
		carrying = info ~= nil
		refreshZooMarkers()
	end)
	Remotes.event("BayStateChanged").OnClientEvent:Connect(applyBay)
	Remotes.event("CleaningProgressChanged").OnClientEvent:Connect(function(id: string, value: number)
		if id == jobId then
			progress = value
			refreshAnimalMarker()
		end
	end)
	Remotes.event("WashCompleted").OnClientEvent:Connect(function(_id: string, _reward: number, value: number)
		tutorialCompleted = true
		coins = value
		refreshAnimalMarker()
		checkShopHint()
	end)
	Remotes.event("CoinsChanged").OnClientEvent:Connect(function(value: number)
		coins = value
		checkShopHint()
	end)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(value: number)
		tier = value
		hideShopHint()
		checkShopHint()
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt.Name == "UpgradePrompt" then
			hideShopHint()
		end
	end)

	-- Bob the markers so they catch the eye.
	RunService.Heartbeat:Connect(function()
		local bob = Vector3.new(0, 4 + math.sin(os.clock() * 4) * 0.4, 0)
		animalMarker.StudsOffset = bob
		stationMarker.StudsOffset = bob + Vector3.new(0, 2, 0)
		cacheMarker.StudsOffset = bob + Vector3.new(0, 3, 0)
		penMarker.StudsOffset = bob
	end)
end

return OnboardingController
