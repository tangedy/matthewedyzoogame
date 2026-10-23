-- Contextual onboarding. The opening lesson is the wash and nothing else: a trail to the
-- baby elephant and a "Wash me!" marker. Pens, the cache, and the hose stand stay quiet
-- until those opening washes are done. After that the trail only returns for a parked
-- delivery truck or a hose the player can already afford.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local OnboardingController = {}

local FONT = UIStyle.Font

-- Candy path colors. The trail is not the theme accent.
local RAINBOW: { Color3 } = {
	Color3.fromRGB(255, 70, 104),
	Color3.fromRGB(255, 146, 48),
	Color3.fromRGB(255, 214, 64),
	Color3.fromRGB(96, 230, 112),
	Color3.fromRGB(64, 214, 255),
	Color3.fromRGB(92, 124, 255),
	Color3.fromRGB(186, 96, 255),
}
local SEGMENT_LIMIT = 26
local SEGMENT_SPACING = 3.6
local SEGMENT_START = 3.2
local MARCH_SPEED = 8
local ARM_YAW = math.rad(34)
-- Tip meets on -Z, which is the LookVector, so each mark points at the destination.
local LEFT_ARM = CFrame.new(0.87, 0, 0.94) * CFrame.Angles(0, ARM_YAW, 0)
local RIGHT_ARM = CFrame.new(-0.87, 0, 0.94) * CFrame.Angles(0, -ARM_YAW, 0)
-- Clearance above the floor so the marks sit on the path instead of in it.
local APRON_SURFACE = 0.25
-- Each mark looks down from this high above the player's floor. Anything it lands on more
-- than MAX_STEP_UP above the floor is a fence, an animal or a prop, so that mark is skipped
-- rather than drawn on top of it (a gap reads better than an arrow on a fence).
local PROBE_HEIGHT = 4
local MAX_STEP_UP = 0.6

local tutorialCompleted = false
local guideStep = "Done"
local introLeft = 0
local coins = 0
local tier = 1
local bayName: string? = nil
local jobId: string? = nil
local washing = false
local progress = 0
local shopVisitedForTier: { [number]: boolean } = {}

local animalMarker: BillboardGui
local stationMarker: BillboardGui
local trail: Folder
local instruction: TextLabel
local note: TextLabel
local noteUntil = 0
local instructionScale: UIScale
type TrailSegment = { left: Part, right: Part }

local segments: { TrailSegment } = {}
local march = 0
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

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

local function trailArm(name: string): Part
	local block = Instance.new("Part")
	block.Name = name
	block.Size = Vector3.new(1.25, 0.1, 3.1)
	block.Anchored = true
	block.CanCollide = false
	block.CanTouch = false
	block.CanQuery = false
	block.CastShadow = false
	block.Material = Enum.Material.Neon
	block.TopSurface = Enum.SurfaceType.Smooth
	block.BottomSurface = Enum.SurfaceType.Smooth
	block.Transparency = 1
	block.Parent = trail
	return block
end

local function hideTrail()
	for _, segment in segments do
		segment.left.Transparency = 1
		segment.right.Transparency = 1
	end
end

local function partNamed(parent: Instance?, name: string): BasePart?
	local found = parent and parent:FindFirstChild(name)
	return if found and found:IsA("BasePart") then found else nil
end

local function upgradeCounter(): BasePart?
	local bay = bayModel()
	return partNamed(bay and bay:FindFirstChild("UpgradeStation"), "Counter")
end

local function upgradeAffordable(): boolean
	local nextTool = ToolConfig[tier + 1]
	return nextTool ~= nil and coins >= nextTool.Price
end

-- The parked delivery truck's bed while it still has an animal for sale.
local function truckTarget(): BasePart?
	local bay = bayModel()
	local truck = bay and bay:FindFirstChild("DeliveryTruck")
	local prompt = truck and truck:FindFirstChild("TruckPrompt", true)
	if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled then
		local bed = prompt.Parent
		return if bed and bed:IsA("BasePart") then bed else nil
	end
	return nil
end

-- Where the trail leads right now, and the instruction shown at the top of the screen.
local function guideTarget(): (BasePart?, string?)
	local bay = bayModel()
	if not bay then
		return nil, nil
	end
	if guideStep == "Wash" then
		local animal = bay:FindFirstChild("Animal")
		if animal and animal:IsA("Model") and animal.PrimaryPart then
			return animal.PrimaryPart, nil
		end
		return partNamed(bay, "WashPosition"), nil
	end
	-- The wash lesson is the only guided step. Afterwards, point at a truck or an affordable hose.
	local truck = truckTarget()
	if truck then
		return truck, "A DELIVERY TRUCK IS HERE! CHECK IT OUT!"
	end
	if upgradeAffordable() and not shopVisitedForTier[tier] then
		return upgradeCounter(), "YOU CAN AFFORD A HOSE UPGRADE!"
	end
	return nil, nil
end

local shownInstruction: string? = nil
local function setInstruction(text: string?)
	if text == shownInstruction then
		return
	end
	shownInstruction = text
	instruction.Visible = text ~= nil
	if text then
		instruction.Text = text
		instructionScale.Scale = 0.6
		TweenService
			:Create(
				instructionScale,
				TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }
			)
			:Play()
	end
end

local function updateTrail(dt: number)
	local target, text = guideTarget()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	setInstruction(if target then text else nil)
	if not target or not root or not character then
		hideTrail()
		return
	end

	local flat = Vector3.new(target.Position.X - root.Position.X, 0, target.Position.Z - root.Position.Z)
	local span = flat.Magnitude
	-- Stop short of the destination so the last mark points at it instead of sitting on it.
	local reach = math.max(target.Size.X, target.Size.Z) * 0.5
	local travel = span - reach

	march += dt * MARCH_SPEED
	local spacing = SEGMENT_SPACING
	local cycle = spacing * #RAINBOW
	if cycle > 0 and march >= cycle then
		march -= cycle * math.floor(march / cycle)
	end
	local base = march % spacing
	local generation = math.floor(march / spacing)

	rayParams.FilterDescendantsInstances = { trail, character }
	-- The floor under the player is the path's height; pads and ramps may lift a mark a
	-- little, but nothing taller (fences, animals) can.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local feet = root.Position.Y - root.Size.Y * 0.5 - (if humanoid then humanoid.HipHeight else 2)
	local under = Workspace:Raycast(root.Position, Vector3.new(0, -40, 0), rayParams)
	local floorY = if under and under.Position.Y <= feet + 0.5 then under.Position.Y else feet
	local direction = if span > 0.05 then flat.Unit else Vector3.new(0, 0, -1)
	for index, segment in segments do
		local along = SEGMENT_START + base + (index - 1) * spacing
		local blocked = false
		local groundY = floorY
		if span > 0.8 and along <= travel then
			local point = root.Position + direction * along
			local hit = Workspace:Raycast(
				Vector3.new(point.X, floorY + PROBE_HEIGHT, point.Z),
				Vector3.new(0, -(PROBE_HEIGHT + 3), 0),
				rayParams
			)
			if hit and hit.Position.Y >= floorY - 2 then
				groundY = hit.Position.Y
			end
			blocked = groundY > floorY + MAX_STEP_UP or (hit ~= nil and hit.Normal.Y < 0.8)
		end
		if span > 0.8 and along <= travel and not blocked then
			local point = root.Position + direction * along
			local pos = Vector3.new(point.X, groundY + APRON_SURFACE, point.Z)
			local aim = Vector3.new(target.Position.X, pos.Y, target.Position.Z)
			if (aim - pos).Magnitude < 0.05 then
				aim = pos + direction
			end
			-- LookVector is -Z. The chevron tip is on -Z, so the mark points at the pad.
			local basis = CFrame.lookAt(pos, aim)
			local color = RAINBOW[(index - 1 - generation) % #RAINBOW + 1]
			segment.left.Color = color
			segment.right.Color = color
			segment.left.Transparency = 0
			segment.right.Transparency = 0
			segment.left.CFrame = basis * LEFT_ARM
			segment.right.CFrame = basis * RIGHT_ARM
		else
			segment.left.Transparency = 1
			segment.right.Transparency = 1
		end
	end
end

local function applyGuide(step: string)
	guideStep = if step == "Wash" then "Wash" else "Done"
end

local function refreshAnimalMarker()
	local bay = bayModel()
	local animal = bay and bay:FindFirstChild("Animal")
	local head = animal and animal:GetAttribute("JobId") == jobId and animal:FindFirstChild("Head")
	local show = not tutorialCompleted and washing and progress < 0.15 and head ~= nil
	animalMarker.Adornee = if show then head :: BasePart else nil :: any
	animalMarker.Enabled = show
end

local function bobMarker(marker: BillboardGui, offset: Vector3)
	local bob = math.sin(os.clock() * 4)
	local head = marker.Adornee
	if head and head:IsA("BasePart") and head.Name == "Head" then
		-- Over an animal: stack above the nameplate and clean meter instead of on top of them.
		UIStyle.overhead(marker, head, UIStyle.Overhead.Callout, bob * 6)
	else
		marker.StudsOffset = offset + Vector3.new(0, bob * 0.4, 0)
	end
end

local function refreshStationMarker()
	if guideStep == "Wash" or introLeft > 0 then
		stationMarker.Adornee = nil
		stationMarker.Enabled = false
		return
	end
	local counter = if upgradeAffordable() then upgradeCounter() else nil
	stationMarker.Adornee = counter :: any
	stationMarker.Enabled = counter ~= nil
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
	-- Big instruction across the top, under the event bar, while the trail is showing.
	local gui = Instance.new("ScreenGui")
	gui.Name = "GuideInstruction"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 4
	gui.Parent = player:WaitForChild("PlayerGui")
	instruction = Instance.new("TextLabel")
	instruction.Name = "Instruction"
	instruction.AnchorPoint = Vector2.new(0.5, 0)
	instruction.Position = UDim2.new(0.5, 0, 0, 62)
	instruction.Size = UDim2.new(0.9, 0, 0, 58)
	instruction.Visible = false
	instruction.Parent = gui
	UIStyle.text(instruction, Color3.new(1, 1, 1), Color3.fromRGB(20, 40, 90), 4)
	local maxSize = Instance.new("UITextSizeConstraint")
	maxSize.MaxTextSize = 54
	maxSize.Parent = instruction
	instructionScale = Instance.new("UIScale")
	instructionScale.Parent = instruction

	note = Instance.new("TextLabel")
	note.Name = "Note"
	note.AnchorPoint = Vector2.new(0.5, 0)
	note.Position = UDim2.new(0.5, 0, 0, 124)
	note.Size = UDim2.new(0.7, 0, 0, 22)
	note.Visible = false
	note.TextScaled = false
	note.TextSize = 16
	note.Parent = gui
	UIStyle.text(note, Color3.fromRGB(230, 230, 230), Color3.fromRGB(20, 20, 20), 1.5)
	note.TextScaled = false
	note.TextSize = 16

	trail = Instance.new("Folder")
	trail.Name = "GuideTrail"
	trail.Parent = Workspace
	for _ = 1, SEGMENT_LIMIT do
		table.insert(segments, {
			left = trailArm("SegmentLeft"),
			right = trailArm("SegmentRight"),
		})
	end

	animalMarker = makeMarker("Wash me!", Color3.fromRGB(150, 230, 255))
	stationMarker = makeMarker("UPGRADE!", Color3.fromRGB(255, 220, 90))
end

local function showNote(text: string)
	note.Text = text
	note.Visible = true
	noteUntil = os.clock() + 4
end

function OnboardingController.init(initial: Types.InitialState)
	tutorialCompleted = initial.TutorialCompleted
	coins = initial.Coins
	tier = initial.ToolTier
	buildGui()
	applyGuide(initial.GuideStep or "Done")
	applyBay(initial.Bay)
	introLeft = initial.IntroWashesLeft or 0

	Remotes.event("BayStateChanged").OnClientEvent:Connect(applyBay)
	Remotes.event("GuideStepChanged").OnClientEvent:Connect(applyGuide)
	Remotes.event("IntroAutoSold").OnClientEvent:Connect(function(amount: number, remaining: number)
		introLeft = remaining
		showNote(`Sold for {UIStyle.formatMoney(amount)}`)
	end)
	Remotes.event("YardRevealed").OnClientEvent:Connect(function()
		introLeft = 0
		showNote("Pens unlocked")
	end)
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
	end)
	Remotes.event("CoinsChanged").OnClientEvent:Connect(function(value: number)
		coins = value
	end)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(value: number)
		tier = value
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		if prompt.Name == "UpgradePrompt" then
			shopVisitedForTier[tier] = true
		end
	end)

	-- Bob the markers so they catch the eye.
	RunService.Heartbeat:Connect(function(dt)
		if note.Visible and os.clock() >= noteUntil then
			note.Visible = false
		end
		bobMarker(animalMarker, Vector3.new(0, 4, 0))
		refreshStationMarker()
		bobMarker(stationMarker, Vector3.new(0, 6, 0))
		updateTrail(dt)
	end)
end

return OnboardingController
