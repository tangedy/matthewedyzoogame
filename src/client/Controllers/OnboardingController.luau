-- Contextual onboarding, fired by triggers instead of up-front menus:
--   * First cycle: a rainbow trail of arrows on the ground — wash, pick up, stable, collect,
--     hose stand, then back to the next animal. The server remembers the step.
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

local GUIDE_TEXT = {
	Wash = "Follow the arrows — wash the animal!",
	Pickup = "Follow the arrows — pick up your animal!",
	Place = "Follow the arrows — bring it to your stable!",
	Collect = "Follow the arrows — collect the cash!",
	Upgrade = "Follow the arrows — check hose upgrades!",
	Repeat = "Follow the arrows — wash the next one!",
}

local ARROW_COUNT = 14
local ARROW_SPACING = 3.6

local tutorialCompleted = false
local guideStep = "Done"
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
local guideLabel: TextLabel
local trailFolder: Folder
type GuideArrow = { Parts: { BasePart }, Offsets: { CFrame } }

local arrows: { GuideArrow } = {}
local nextAdvanceAt = 0
local guideAdvance = Remotes.event("GuideAdvance")

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

local function hideArrow(arrow: GuideArrow)
	for _, piece in arrow.Parts do
		piece.Transparency = 1
	end
end

-- A chevron head (two blades meeting at a point) plus a narrow tail, flat on the ground.
-- lookAt faces the point, so the arrow aims along the trail.
local function makeArrow(parent: Instance): GuideArrow
	local arrow: GuideArrow = { Parts = {}, Offsets = {} }
	local function piece(size: Vector3, offset: CFrame)
		local created = Instance.new("Part")
		created.Anchored = true
		created.CanCollide = false
		created.CanQuery = false
		created.CanTouch = false
		created.CastShadow = false
		created.Material = Enum.Material.Neon
		created.Size = size
		created.Transparency = 1
		created.Parent = parent
		table.insert(arrow.Parts, created)
		table.insert(arrow.Offsets, offset)
	end
	local angle = math.rad(36)
	local length = 1.7
	local half = length / 2
	local tip = -0.95
	local blade = Vector3.new(0.55, 0.12, length)
	local flank = math.sin(angle) * half
	local along = tip + math.cos(angle) * half
	piece(blade, CFrame.new(-flank, 0, along) * CFrame.Angles(0, angle, 0))
	piece(blade, CFrame.new(flank, 0, along) * CFrame.Angles(0, -angle, 0))
	piece(Vector3.new(0.28, 0.12, 1.05), CFrame.new(0, 0, 0.78))
	return arrow
end

local function guideTarget(): BasePart?
	if guideStep == "Done" then
		return nil
	end
	local bay = bayModel()
	if not bay then
		return nil
	end
	local function partNamed(parent: Instance?, name: string): BasePart?
		local found = parent and parent:FindFirstChild(name)
		return if found and found:IsA("BasePart") then found else nil
	end
	if guideStep == "Wash" or guideStep == "Repeat" then
		local animal = bay:FindFirstChild("Animal")
		if animal and animal:IsA("Model") and animal.PrimaryPart then
			return animal.PrimaryPart
		end
		return partNamed(bay, "WashPosition")
	elseif guideStep == "Pickup" then
		return partNamed(bay:FindFirstChild("Cache"), "Slot1")
	elseif guideStep == "Place" then
		local zoo = bay:FindFirstChild("Zoo")
		return partNamed(zoo and zoo:FindFirstChild("Pen1"), "GatePost")
	elseif guideStep == "Collect" then
		local zoo = bay:FindFirstChild("Zoo")
		if not zoo then
			return nil
		end
		for _, pen in zoo:GetChildren() do
			if pen:FindFirstChild("ZooAnimal") then
				local pad = partNamed(pen, "CollectPad")
				if pad then
					return pad
				end
			end
		end
		return partNamed(zoo:FindFirstChild("Pen1"), "CollectPad")
	elseif guideStep == "Upgrade" then
		return partNamed(bay:FindFirstChild("UpgradeStation"), "Counter")
	end
	return nil
end

local function updateTrail()
	if guideStep == "Done" then
		return
	end
	local target = guideTarget()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local function hideAll()
		for _, arrow in arrows do
			hideArrow(arrow)
		end
	end
	if not target or not root then
		hideAll()
		return
	end
	if guideStep == "Upgrade" and os.clock() >= nextAdvanceAt then
		if (root.Position - target.Position).Magnitude <= 8 then
			nextAdvanceAt = os.clock() + 2
			guideAdvance:FireServer()
		end
	end
	local flat = Vector3.new(target.Position.X - root.Position.X, 0, target.Position.Z - root.Position.Z)
	local distance = flat.Magnitude
	if distance < 5 then
		hideAll()
		return
	end
	local direction = flat.Unit
	local usable = math.max(distance - 4, ARROW_SPACING)
	local count = math.clamp(math.floor(usable / ARROW_SPACING), 1, ARROW_COUNT)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { character :: Instance, trailFolder }
	local bay = bayModel()
	local animal = bay and bay:FindFirstChild("Animal")
	if animal then
		table.insert(ignore, animal)
	end
	params.FilterDescendantsInstances = ignore
	local hueShift = os.clock() * 0.18
	for i = 1, ARROW_COUNT do
		local arrow = arrows[i]
		if i > count then
			hideArrow(arrow)
			continue
		end
		local along = 2.5 + (i - 0.5) * (usable / count)
		local point = root.Position + direction * along
		local hit = Workspace:Raycast(point + Vector3.new(0, 12, 0), Vector3.new(0, -40, 0), params)
		local y = if hit then hit.Position.Y else point.Y
		local bob = math.sin(os.clock() * 3 + i * 0.7) * 0.05
		local pos = Vector3.new(point.X, y + 0.14 + bob, point.Z)
		local cf = CFrame.lookAt(pos, pos + direction)
		local color = Color3.fromHSV((i / count + hueShift) % 1, 0.85, 1)
		for index, piece in arrow.Parts do
			piece.CFrame = cf * arrow.Offsets[index]
			piece.Color = color
			piece.Transparency = 0.05
		end
	end
end

local function applyGuide(step: string)
	guideStep = step
	local text = GUIDE_TEXT[step]
	if guideLabel then
		guideLabel.Visible = text ~= nil
		guideLabel.Text = text or ""
	end
	if step ~= "Upgrade" then
		nextAdvanceAt = 0
	end
	if step == "Done" then
		for _, arrow in arrows do
			hideArrow(arrow)
		end
	end
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

	guideLabel = banner:Clone()
	guideLabel.Name = "Guide"
	guideLabel.Position = UDim2.new(0.5, 0, 0, 248)
	guideLabel.AnchorPoint = Vector2.new(0.5, 0)
	guideLabel.BackgroundColor3 = Color3.fromRGB(255, 120, 190)
	guideLabel.Visible = false
	guideLabel.Parent = gui

	trailFolder = Instance.new("Folder")
	trailFolder.Name = "GuideTrail"
	trailFolder.Parent = Workspace
	for _ = 1, ARROW_COUNT do
		table.insert(arrows, makeArrow(trailFolder))
	end

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
	applyGuide(initial.GuideStep or "Done")
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
	Remotes.event("GuideStepChanged").OnClientEvent:Connect(applyGuide)
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
		updateTrail()
	end)
end

return OnboardingController
