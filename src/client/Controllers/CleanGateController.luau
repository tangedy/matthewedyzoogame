-- When the animal in the bay needs more clean power than the hose has (at its sub-tier),
-- spraying does nothing. This offers the two ways forward: send it away, or pay to wash it now.
-- The offer floats over the animal and only shows while you stand close to it (within the
-- hose's reach), like a proximity prompt.
-- Also hides the NEEDS gear line on walk-in nameplates once your gear can already wash them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local GearLadder = require(ReplicatedStorage.Shared.GearLadder)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Modals = require(script.Parent.Parent.UI.Modals)

local player = Players.LocalPlayer

local CleanGateController = {}

local NEAR_DISTANCE = 14 -- studs; the offer shows within this or the hose's range, whichever is more
-- The same muted palette as the world prompt cards (PromptController).
local PANEL_COLOR = UIStyle.Colors.Panel
local LEAVE_COLOR = UIStyle.Colors.Muted
local WASH_COLOR = UIStyle.Colors.Robux

local tier = 1
local level = 0 -- sub-tier on the current hose
local bay: Types.BaySnapshot? = nil
local blocked = false
local nextClickAt = 0
local cleanKey = "CleanNow"

local panel: Frame
local title: TextLabel
local cleanButton: TextButton

local function hosePower(): number
	return GearLadder.power(tier, level)
end

local function canWash(def: AnimalConfig.AnimalDefinition): boolean
	return CleanPower.canClean(hosePower(), def.Rarity)
end

local function bayAnimal(): Model?
	if not bay or not bay.BayName then
		return nil
	end
	local bays = Workspace:FindFirstChild("WashBays")
	local model = bays and bays:FindFirstChild(bay.BayName)
	local animal = model and model:FindFirstChild("Animal")
	return if animal and animal:IsA("Model") then animal else nil
end

-- Nameplates (UIStyle.nameplate) keep the text without the lock line in OpenText.
local function applyLock(label: TextLabel)
	local openText = label:GetAttribute("OpenText")
	local lockText = label:GetAttribute("LockText")
	local openLines = label:GetAttribute("OpenLines")
	local lines = label:GetAttribute("Lines")
	local model = label:FindFirstAncestorWhichIsA("Model")
	local species = model and model:GetAttribute("AnimalKey")
	local def = if typeof(species) == "string" then AnimalConfig.Animals[species] else nil
	if typeof(openText) ~= "string" or typeof(lockText) ~= "string" or not def then
		return
	end
	local open = canWash(def)
	label.Text = if open then openText else lockText
	-- The billboard keeps its height; the rows sit at its bottom, on the animal.
	local share = if open and typeof(openLines) == "number" and typeof(lines) == "number" then openLines / lines else 1
	label.AnchorPoint = Vector2.new(0, 1)
	label.Position = UDim2.fromScale(0, 1)
	label.Size = UDim2.fromScale(1, share)
end

local function applyAllLocks()
	local bays = Workspace:FindFirstChild("WashBays")
	if not bays then
		return
	end
	for _, item in bays:GetDescendants() do
		if item:IsA("TextLabel") and item:GetAttribute("OpenText") ~= nil then
			applyLock(item)
		end
	end
end

local function refresh()
	local rarityKey = bay and bay.Rarity
	blocked = bay ~= nil
		and bay.State == "Washing"
		and typeof(rarityKey) == "string"
		and not CleanPower.canClean(hosePower(), rarityKey)
	player:SetAttribute("CleanBlocked", blocked)
	if not blocked or typeof(rarityKey) ~= "string" then
		panel.Visible = false
		return
	end
	-- Kept short: what's wrong, then the two buttons (let it go / wash now for R$).
	local steps = CleanPower.stepsAbove(hosePower(), rarityKey) or 0
	local offer = MonetizationConfig.productForCleanSteps(steps) or MonetizationConfig.ProductsByKey.CleanNow
	cleanKey = offer.Key
	title.Text = "Too dirty!"
	cleanButton.Text = `Wash now · {offer.Robux} R$`
end

-- Every frame while blocked: follow the animal on screen, and show only while you're close.
local function follow()
	local animal = if blocked then bayAnimal() else nil
	local head = animal and animal:FindFirstChild("Head")
	local camera = Workspace.CurrentCamera
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not animal or not head or not head:IsA("BasePart") or not camera or not root or not root:IsA("BasePart") then
		panel.Visible = false
		return
	end
	local tool = ToolConfig[tier] or ToolConfig[1]
	local reach = math.max(NEAR_DISTANCE, tool.Range + 4)
	local near = (root.Position - head.Position).Magnitude <= reach
	local screen, onScreen = camera:WorldToViewportPoint(head.Position + Vector3.new(0, head.Size.Y, 0))
	local show = near and onScreen
	if show then
		local viewport = camera.ViewportSize
		local half = panel.AbsoluteSize / 2
		local x = math.clamp(screen.X, half.X + 8, viewport.X - half.X - 8)
		local y = math.clamp(screen.Y, panel.AbsoluteSize.Y + 8, viewport.Y - 8)
		panel.Position = UDim2.fromOffset(x, y)
	end
	panel.Visible = show
end

local function button(text: string, color: Color3, x: number): TextButton
	local created = Instance.new("TextButton")
	created.AnchorPoint = Vector2.new(0.5, 1)
	created.Position = UDim2.new(x, 0, 1, -8)
	created.Size = UDim2.new(0.5, -12, 0, 30)
	created.BackgroundColor3 = color
	created.Text = text
	created.AutoButtonColor = true
	created.Parent = panel
	UIStyle.text(created, Color3.new(1, 1, 1), Color3.fromRGB(14, 16, 22), 1.2)
	UIStyle.border(created, 1.5)
	return created
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "CleanGate"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- so panel pixels match WorldToViewportPoint
	gui.DisplayOrder = 6
	gui.Parent = player:WaitForChild("PlayerGui")

	panel = Instance.new("Frame")
	panel.Name = "Prompt"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Size = UDim2.fromOffset(260, 72)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.15
	panel.Visible = false
	panel.Parent = gui
	Modals.holdCursor(panel)
	UIStyle.border(panel, 1.5)

	title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(10, 6)
	title.Size = UDim2.new(1, -20, 0, 22)
	title.Parent = panel
	UIStyle.text(title, Color3.fromRGB(240, 242, 248), Color3.fromRGB(20, 22, 30), 1.5)

	local leave = button("Let it go", LEAVE_COLOR, 0.25)
	leave.Position = UDim2.new(0.25, 3, 1, -8)
	cleanButton = button("Wash now", WASH_COLOR, 0.75)
	cleanButton.Position = UDim2.new(0.75, -3, 1, -8)
	leave.Activated:Connect(function()
		if os.clock() < nextClickAt then
			return
		end
		nextClickAt = os.clock() + 0.5
		Remotes.event("LetAnimalGo"):FireServer()
	end)
	cleanButton.Activated:Connect(function()
		if os.clock() < nextClickAt then
			return
		end
		nextClickAt = os.clock() + 0.5
		Remotes.event("MonetizationBuy"):FireServer(cleanKey)
	end)
end

function CleanGateController.init(initial: Types.InitialState)
	tier = initial.ToolTier
	level = initial.ToolUpgrade or 0
	build()
	bay = initial.Bay
	refresh()
	RunService.RenderStepped:Connect(follow)

	local bays = Workspace:WaitForChild("WashBays")
	applyAllLocks()
	bays.DescendantAdded:Connect(function(item)
		if item:IsA("TextLabel") and item:GetAttribute("OpenText") ~= nil then
			applyLock(item)
		end
	end)

	Remotes.event("BayStateChanged").OnClientEvent:Connect(function(snapshot: Types.BaySnapshot)
		bay = snapshot
		refresh()
	end)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(value: number, _name: string, newLevel: number?)
		tier = value
		level = newLevel or 0
		refresh()
		applyAllLocks()
	end)
end

return CleanGateController
