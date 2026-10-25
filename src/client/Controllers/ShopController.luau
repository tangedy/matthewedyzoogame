-- Hose upgrade shop: opens from the station's ProximityPrompt, never automatically.
-- Shows the current and next step on the gear ladder (hoses and their sub-tiers, GearLadder),
-- the wash speed gain, perks and price; the server validates purchases.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local GearLadder = require(ReplicatedStorage.Shared.GearLadder)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Modals = require(script.Parent.Parent.UI.Modals)
local Layout = require(script.Parent.Parent.UI.Layout)
local HoseBuilder = require(ReplicatedStorage.Shared.HoseBuilder)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local player = Players.LocalPlayer

local ShopController = {}

local FONT = UIStyle.Font
local PANEL_COLOR = UIStyle.Colors.Panel
local PANEL_HEIGHT = 464
local BUY_COLOR = UIStyle.Colors.Cash
local ROBUX_COLOR = UIStyle.Colors.Robux
local DISABLED_COLOR = UIStyle.Colors.Disabled
local ERROR_COLOR = UIStyle.Colors.ErrorText
local OK_COLOR = UIStyle.CashColor

local purchaseRemote = Remotes.event("PurchaseToolUpgrade")

local coins = 0
local tier = 1
local level = 0 -- sub-tier on the current hose
local openStation: BasePart? = nil
local awaitingResult = false
local preview: ViewportFrame
local previewCamera: Camera
local previewModel: Model? = nil
local previewTier = 0
local previewDistance = 6
local previewCentre = Vector3.zero -- the preview never moves, so its centre is measured once
local lastSentAt = 0

local panel: Frame
local currentLabel: TextLabel
local nextLabel: TextLabel
local gainLabel: TextLabel
local buyButton: TextButton
local robuxButton: TextButton
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

-- Rarities this gear can wash that the previous one could not.
local function unlocksText(toolTier: number): string
	local tool = ToolConfig[toolTier]
	local prev = ToolConfig[toolTier - 1]
	if not tool then
		return ""
	end
	local prevPower = if prev then prev.CleaningPower else 0
	local groups = {}
	for _, rarity in RarityConfig.List do
		local need = rarity.RequiredCleaningPower
		if need > prevPower + 1e-4 and CleanPower.canClean(tool.CleaningPower, rarity.Key) then
			for _, def in AnimalConfig.Animals do
				if def.Rarity == rarity.Key and not def.Limited and def.SpawnWeight > 0 then
					table.insert(groups, rarity.DisplayName)
					break
				end
			end
		end
	end
	return if #groups > 0 then `\nUnlocks {table.concat(groups, ", ")}` else ""
end

-- The panel ends just under its last button; the Robux button only shows when cash is short.
local function fitPanel()
	local bottom = if robuxButton.Visible then 416 else 366
	messageLabel.Position = UDim2.fromOffset(18, bottom)
	local height = bottom + 48
	panel.Size = UDim2.new(0.9, 0, 0, height)
	local constraint = panel:FindFirstChildOfClass("UISizeConstraint")
	if constraint then
		constraint.MaxSize = Vector2.new(360, height)
	end
end

-- Shows the next gear (or the current one once fully upgraded) in the viewport.
local function showPreview(showTier: number)
	if not preview or previewTier == showTier then
		return
	end
	previewTier = showTier
	if previewModel then
		previewModel:Destroy()
	end
	local model = HoseBuilder.preview(showTier)
	local box, size = model:GetBoundingBox()
	previewCentre = box.Position
	local radius = size.Magnitude / 2
	previewDistance = radius / math.tan(math.rad(previewCamera.FieldOfView / 2)) * 1.15
	model.Parent = preview
	previewModel = model
end

local function refresh()
	if not panel then
		return
	end
	local current = GearLadder.get(tier, level)
	local nextStep = GearLadder.next(tier, level)
	showPreview(if nextStep then nextStep.Tier else current.Tier)
	currentLabel.Text = `Now: {current.Label} · {CleanPower.format(current.Speed)}x`
	if nextStep then
		local gain = math.floor((nextStep.Speed / current.Speed - 1) * 100 + 0.5)
		nextLabel.Text = `Next: {nextStep.Label}`
		local reach = if nextStep.Range > current.Range then ` · Reach {nextStep.Range}` else ""
		local perk = if nextStep.Perk then `\n{nextStep.Perk}` else ""
		-- Only a new hose raises clean power, so only a new hose unlocks rarer animals.
		local unlocks = if nextStep.Level == 0 then unlocksText(nextStep.Tier) else ""
		gainLabel.Text = `{CleanPower.format(nextStep.Speed)}x speed (+{gain}%){reach}{perk}{unlocks}`
		buyButton.Visible = true
		buyButton.Text = `BUY {UIStyle.formatMoney(nextStep.Price)}`
		local affordable = coins >= nextStep.Price
		buyButton.BackgroundColor3 = if affordable and not awaitingResult then BUY_COLOR else DISABLED_COLOR
		-- Robux buys exactly the next hose, never a sub-tier. The Fire Hose has no product, so it
		-- stays cash-only.
		local robux = if nextStep.Level == 0 then MonetizationConfig.productForHoseTier(nextStep.Tier) else nil
		local showRobux = robux ~= nil and not affordable
		robuxButton.Visible = showRobux
		if robux and showRobux then
			robuxButton.Text = `BUY R$ {robux.Robux}`
		end
	else
		nextLabel.Text = "Max gear!"
		gainLabel.Text = ""
		buyButton.Visible = false
		robuxButton.Visible = false
	end
	fitPanel()
end

local function setMessage(text: string, ok: boolean)
	messageLabel.Text = text
	messageLabel.TextColor3 = if ok then OK_COLOR else ERROR_COLOR
end

local dim: TextButton
local panelScale: UIScale

-- The panel is authored at desktop size, so at phone scale its text is a few pixels tall.
-- On touch it grows to fill most of the screen height (never past 1.45x), measured when
-- it opens so it matches the HUD's current ResponsiveScale.
local function scalePanel()
	if Layout.get().key ~= "Touch" then
		panelScale.Scale = 1
		return
	end
	local gui = panel:FindFirstAncestorOfClass("ScreenGui")
	local responsive = gui and gui:FindFirstChild("ResponsiveScale")
	local factor = if responsive and responsive:IsA("UIScale") and responsive.Scale > 0.05 then responsive.Scale else 1
	local height = math.max(panel.Size.Y.Offset, 1)
	local room = if gui then gui.AbsoluteSize.Y / factor * 0.94 else height
	panelScale.Scale = math.clamp(room / height, 1, 1.45)
end

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
	scalePanel()
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
	panel.Size = UDim2.fromOffset(360, PANEL_HEIGHT)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0
	panel.Visible = false
	panel.ZIndex = 5
	panel.Parent = gui
	round(panel, 14)
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(360, PANEL_HEIGHT)
	constraint.Parent = panel
	panel.Size = UDim2.new(0.9, 0, 0, PANEL_HEIGHT)
	panelScale = Instance.new("UIScale")
	panelScale.Parent = panel

	label({
		Position = UDim2.fromOffset(18, 12),
		Size = UDim2.new(1, -70, 0, 34),
		Text = "Gear Shop",
		TextColor3 = Color3.fromRGB(255, 220, 90),
		Parent = panel,
	})
	local closeButton = Instance.new("TextButton")
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -12, 0, 12)
	closeButton.Size = UDim2.fromOffset(36, 36)
	closeButton.BackgroundColor3 = UIStyle.Colors.Close
	closeButton.Text = "X"
	closeButton.Font = FONT
	closeButton.TextScaled = true
	closeButton.TextColor3 = Color3.new(1, 1, 1)
	closeButton.Parent = panel
	round(closeButton, 8)
	closeButton.Activated:Connect(close)
	Layout.closeTarget(closeButton, close)

	-- A turning picture of the next gear: the real tool model, built the same way as the one
	-- that ends up in the player's hand (HoseBuilder).
	preview = Instance.new("ViewportFrame")
	preview.Name = "GearPreview"
	preview.Position = UDim2.fromOffset(18, 54)
	preview.Size = UDim2.new(1, -36, 0, 150)
	preview.BackgroundColor3 = Color3.fromRGB(40, 48, 72)
	preview.Ambient = Color3.fromRGB(170, 170, 185)
	preview.LightColor = Color3.new(1, 1, 1)
	preview.LightDirection = Vector3.new(-1, -1.2, -0.6)
	preview.Parent = panel
	round(preview, 10)
	previewCamera = Instance.new("Camera")
	previewCamera.FieldOfView = 30
	previewCamera.Parent = preview
	preview.CurrentCamera = previewCamera

	nextLabel = label({ Position = UDim2.fromOffset(18, 212), Size = UDim2.new(1, -36, 0, 30), Parent = panel })
	gainLabel = label({
		Position = UDim2.fromOffset(18, 244),
		Size = UDim2.new(1, -36, 0, 40),
		TextColor3 = Color3.fromRGB(150, 220, 255),
		TextWrapped = true,
		Parent = panel,
	})
	currentLabel = label({
		Position = UDim2.fromOffset(18, 288),
		Size = UDim2.new(1, -36, 0, 20),
		TextColor3 = Color3.fromRGB(190, 195, 215),
		Parent = panel,
	})

	buyButton = Instance.new("TextButton")
	buyButton.Position = UDim2.fromOffset(18, 316)
	buyButton.Size = UDim2.new(1, -36, 0, 44)
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

	robuxButton = Instance.new("TextButton")
	robuxButton.Name = "RobuxBuy"
	robuxButton.Position = UDim2.fromOffset(18, 366)
	robuxButton.Size = UDim2.new(1, -36, 0, 44)
	robuxButton.BackgroundColor3 = ROBUX_COLOR
	robuxButton.Font = FONT
	robuxButton.TextScaled = true
	robuxButton.TextColor3 = Color3.new(1, 1, 1)
	robuxButton.Visible = false
	robuxButton.Text = "BUY R$"
	robuxButton.Parent = panel
	round(robuxButton, 10)
	local robuxPad = Instance.new("UIPadding")
	robuxPad.PaddingTop = UDim.new(0, 6)
	robuxPad.PaddingBottom = UDim.new(0, 6)
	robuxPad.Parent = robuxButton

	messageLabel = label({
		Position = UDim2.fromOffset(18, 416),
		Size = UDim2.new(1, -36, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		TextWrapped = true,
		Parent = panel,
	})

	buyButton.Activated:Connect(function()
		local nextStep = GearLadder.next(tier, level)
		if not nextStep or awaitingResult then
			return
		end
		-- The server owns the balance and always answers, so even a stale local balance
		-- can't block a purchase. The timeout re-enables Buy if a reply is ever lost.
		awaitingResult = true
		refresh()
		purchaseRemote:FireServer()
		local sentAt = os.clock()
		lastSentAt = sentAt
		task.delay(3, function()
			if awaitingResult and lastSentAt == sentAt then
				awaitingResult = false
				refresh()
			end
		end)
	end)
	robuxButton.Activated:Connect(function()
		local nextStep = GearLadder.next(tier, level)
		local product = nextStep and nextStep.Level == 0 and MonetizationConfig.productForHoseTier(nextStep.Tier)
		if not product or not nextStep or coins >= nextStep.Price then
			return
		end
		Remotes.event("MonetizationBuy"):FireServer(product.Key)
	end)
end

function ShopController.init(initial: Types.InitialState)
	coins = initial.Coins
	tier = initial.ToolTier
	level = initial.ToolUpgrade or 0
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
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(value: number, _name: string, newLevel: number?)
		tier = value
		level = newLevel or 0
		refresh()
	end)
	Remotes.event("PurchaseResult").OnClientEvent:Connect(function(success: boolean, message: string)
		awaitingResult = false
		setMessage(message, success)
		refresh()
	end)

	-- Close when the player walks away from the station.
	-- Turn the gear picture slowly while the shop is open.
	RunService.RenderStepped:Connect(function()
		if not panel.Visible or not previewModel then
			return
		end
		local centre = previewCentre
		local angle = os.clock() * 0.8
		local eye = centre + Vector3.new(math.sin(angle), 0.45, math.cos(angle)).Unit * previewDistance
		previewCamera.CFrame = CFrame.lookAt(eye, centre)
	end)

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
