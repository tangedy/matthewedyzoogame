-- Hose upgrade shop: opens from the station's ProximityPrompt, never automatically.
-- Shows current/next tier, the cleaning speed gain and price; the server validates purchases.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Modals = require(script.Parent.Parent.UI.Modals)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local player = Players.LocalPlayer

local ShopController = {}

local FONT = UIStyle.Font
local PANEL_COLOR = Color3.fromRGB(25, 30, 45)
local BUY_COLOR = Color3.fromRGB(80, 200, 110)
local DISABLED_COLOR = Color3.fromRGB(110, 110, 120)
local ERROR_COLOR = Color3.fromRGB(255, 120, 110)
local OK_COLOR = Color3.fromRGB(130, 240, 140)

local purchaseRemote = Remotes.event("PurchaseToolUpgrade")

local coins = 0
local tier = 1
local openStation: BasePart? = nil
local awaitingResult = false

local panel: Frame
local currentLabel: TextLabel
local nextLabel: TextLabel
local gainLabel: TextLabel
local buyButton: TextButton
local messageLabel: TextLabel

local function round(instance: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function label(props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextScaled = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	for key, value in props do
		(l :: any)[key] = value
	end
	UIStyle.text(l, l.TextColor3)
	return l
end

-- "Unlocks Epic animals" for the tiers of species that first walk in at this hose tier.
local function unlocksText(toolTier: number): string
	local tiers: { [string]: boolean } = {}
	for _, def in AnimalConfig.Animals do
		if def.RequiredToolTier == toolTier and not def.Limited and def.SpawnWeight > 0 then
			tiers[def.Rarity] = true
		end
	end
	local names = {}
	for _, rarity in RarityConfig.List do
		if tiers[rarity.Key] then
			table.insert(names, rarity.DisplayName)
		end
	end
	return if #names > 0 then `, unlocks {table.concat(names, " & ")} animals` else ""
end

local function refresh()
	if not panel then
		return
	end
	local current = ToolConfig[tier] or ToolConfig[1]
	local nextTool = ToolConfig[tier + 1]
	currentLabel.Text = `Current: {current.Name} (Tier {current.Tier})`
	if nextTool then
		local gain = math.floor((nextTool.CleaningPower / current.CleaningPower - 1) * 100 + 0.5)
		nextLabel.Text = `Next: {nextTool.Name}`
		gainLabel.Text = `Cleaning speed +{gain}%{unlocksText(nextTool.Tier)}`
		buyButton.Visible = true
		buyButton.Text = `Buy for {UIStyle.formatMoney(nextTool.Price)}`
		local affordable = coins >= nextTool.Price
		buyButton.BackgroundColor3 = if affordable and not awaitingResult then BUY_COLOR else DISABLED_COLOR
	else
		nextLabel.Text = "Your hose is fully upgraded!"
		gainLabel.Text = ""
		buyButton.Visible = false
	end
end

local function setMessage(text: string, ok: boolean)
	messageLabel.Text = text
	messageLabel.TextColor3 = if ok then OK_COLOR else ERROR_COLOR
end

local dim: TextButton

local function close()
	openStation = nil
	panel.Visible = false
	if dim then
		dim.Visible = false
	end
end

local function open(station: BasePart)
	openStation = station
	setMessage("", true)
	refresh()
	Modals.claim("HoseShop")
	if dim then
		dim.Visible = true
	end
	panel.Visible = true
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Shop"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 32
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	dim = Modals.dim(gui, close)
	Modals.bind("HoseShop", close)

	panel = Instance.new("Frame")
	panel.Name = "ShopPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(360, 250)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0
	panel.Visible = false
	panel.ZIndex = 5
	panel.Parent = gui
	round(panel, 14)
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(360, 250)
	constraint.Parent = panel
	panel.Size = UDim2.new(0.9, 0, 0, 250)

	label({
		Position = UDim2.fromOffset(18, 12),
		Size = UDim2.new(1, -70, 0, 34),
		Text = "Hose Upgrades",
		TextColor3 = Color3.fromRGB(255, 220, 90),
		Parent = panel,
	})
	local closeButton = Instance.new("TextButton")
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -12, 0, 12)
	closeButton.Size = UDim2.fromOffset(36, 36)
	closeButton.BackgroundColor3 = Color3.fromRGB(200, 70, 70)
	closeButton.Text = "X"
	closeButton.Font = FONT
	closeButton.TextScaled = true
	closeButton.TextColor3 = Color3.new(1, 1, 1)
	closeButton.Parent = panel
	round(closeButton, 8)
	closeButton.Activated:Connect(close)

	currentLabel = label({ Position = UDim2.fromOffset(18, 56), Size = UDim2.new(1, -36, 0, 26), Parent = panel })
	nextLabel = label({ Position = UDim2.fromOffset(18, 88), Size = UDim2.new(1, -36, 0, 26), Parent = panel })
	gainLabel = label({
		Position = UDim2.fromOffset(18, 118),
		Size = UDim2.new(1, -36, 0, 22),
		TextColor3 = Color3.fromRGB(150, 220, 255),
		Parent = panel,
	})

	buyButton = Instance.new("TextButton")
	buyButton.Position = UDim2.fromOffset(18, 150)
	buyButton.Size = UDim2.new(1, -36, 0, 50)
	buyButton.BackgroundColor3 = BUY_COLOR
	buyButton.Font = FONT
	buyButton.TextScaled = true
	buyButton.TextColor3 = Color3.new(1, 1, 1)
	buyButton.Parent = panel
	round(buyButton, 10)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = buyButton

	messageLabel = label({
		Position = UDim2.fromOffset(18, 208),
		Size = UDim2.new(1, -36, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		Parent = panel,
	})

	buyButton.Activated:Connect(function()
		local nextTool = ToolConfig[tier + 1]
		if not nextTool or awaitingResult then
			return
		end
		if coins < nextTool.Price then
			-- Instant feedback; the server would reject it anyway.
			setMessage(`Not enough cash. You need {UIStyle.formatMoney(nextTool.Price - coins)} more.`, false)
			return
		end
		awaitingResult = true
		refresh()
		purchaseRemote:FireServer()
	end)
end

function ShopController.init(initial: Types.InitialState)
	coins = initial.Coins
	tier = initial.ToolTier
	buildGui()

	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local station = prompt.Parent
		if prompt.Name == "UpgradePrompt" and station and station:IsA("BasePart") then
			open(station)
		end
	end)

	Remotes.event("CoinsChanged").OnClientEvent:Connect(function(value: number)
		coins = value
		refresh()
	end)
	Remotes.event("WashCompleted").OnClientEvent:Connect(function(_jobId: string, _reward: number, value: number)
		coins = value
		refresh()
	end)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(value: number)
		tier = value
		refresh()
	end)
	Remotes.event("PurchaseResult").OnClientEvent:Connect(function(success: boolean, message: string)
		awaitingResult = false
		setMessage(message, success)
		refresh()
	end)

	-- Close when the player walks away from the station.
	RunService.Heartbeat:Connect(function()
		local station = openStation
		if not station then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if
			not root
			or not station.Parent
			or (root.Position - station.Position).Magnitude > GameConfig.ShopCloseDistance
		then
			close()
		end
	end)
end

return ShopController
