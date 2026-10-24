-- Zoo client side:
--   * keeps other players' pen/cache/expand prompts out of reach (only your bay's work),
--   * shows what you're carrying, with Put Down / Sell buttons (Q / X on keyboard),
--     (PromptController draws the cache, pen and shop prompts on every platform),
--   * animates every rainbow label (Zoo God tier, Rainbow mutation).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local UIPlatform = require(script.Parent.Parent.UI)

local player = Players.LocalPlayer

local ZooController = {}

local OWN_PROMPTS = {
	PenPrompt = 10,
	PickupPrompt = 10,
	SellPrompt = 10,
	ExpandPrompt = 10,
	TruckPrompt = 12, -- the delivery truck parks under your bay model
}

local myBay: string? = nil
local latestBay: Types.BaySnapshot? = nil
local carryBanner: Frame
local cacheHint: TextLabel
local carrySellButton: TextButton
local carryAction = Remotes.event("CarryAction")

-- The server never changes MaxActivationDistance, so this local override sticks even as it
-- toggles Enabled. Other players' prompts are set to 0 reach.
local function applyPromptReach(prompt: ProximityPrompt)
	local reach = OWN_PROMPTS[prompt.Name]
	local bays = Workspace:FindFirstChild("WashBays")
	if not reach or not bays or not myBay then
		return
	end
	local mine = bays:FindFirstChild(myBay)
	prompt.MaxActivationDistance = if mine and prompt:IsDescendantOf(mine) then reach else 0
end

local function applyAllPrompts()
	local bays = Workspace:FindFirstChild("WashBays")
	if bays then
		for _, prompt in bays:GetDescendants() do
			if prompt:IsA("ProximityPrompt") then
				applyPromptReach(prompt)
			end
		end
	end
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Zoo"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Just the two choices while carrying: put it back in the cache, or sell it.
	carryBanner = Instance.new("Frame")
	carryBanner.AnchorPoint = Vector2.new(0.5, 1)
	carryBanner.Position = UDim2.new(0.5, 0, 1, -190)
	carryBanner.Size = UDim2.fromOffset(420, 52)
	carryBanner.BackgroundTransparency = 1
	carryBanner.Visible = false
	carryBanner.Parent = gui

	local row = Instance.new("Frame")
	row.Size = UDim2.fromScale(1, 1)
	row.BackgroundTransparency = 1
	row.Parent = carryBanner
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	rowLayout.Padding = UDim.new(0, 12)
	rowLayout.Parent = row
	local function carryButton(text: string, color: Color3, action: string): TextButton
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(170, 44)
		button.BackgroundColor3 = color
		button.AutoButtonColor = true
		button.Parent = row
		UIStyle.text(button)
		UIStyle.border(button, 3)
		button.Text = text
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 6)
		pad.PaddingBottom = UDim.new(0, 6)
		pad.Parent = button
		button.Activated:Connect(function()
			carryAction:FireServer(action)
		end)
		return button
	end
	carryButton("PUT DOWN", Color3.fromRGB(80, 160, 255), "drop")
	carrySellButton = carryButton("SELL", Color3.fromRGB(70, 190, 90), "sell")

	cacheHint = Instance.new("TextLabel")
	cacheHint.AnchorPoint = Vector2.new(0.5, 1)
	cacheHint.Position = UDim2.new(0.5, 0, 1, -190)
	cacheHint.Size = UDim2.new(0.9, 0, 0, 34)
	cacheHint.Visible = false
	cacheHint.Parent = gui
	UIStyle.text(cacheHint, Color3.fromRGB(110, 200, 255))
	cacheHint.Text = "Cache full! Pick up an animal and put it in a pen, or sell it."
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(720, 34)
	constraint.Parent = cacheHint
end

local function onCarry(info: Types.CarryInfo?)
	if info then
		carrySellButton.Text = "SELL " .. UIStyle.formatMoney(info.SellValue or 0)
		carryBanner.Visible = true
		cacheHint.Visible = false
	else
		carryBanner.Visible = false
	end
end

local function onBay(bay: Types.BaySnapshot?)
	if not bay then
		return
	end
	latestBay = bay
	if bay.BayName ~= myBay then
		myBay = bay.BayName
		applyAllPrompts()
	end
	cacheHint.Visible = false
end

function ZooController.init(initial: Types.InitialState)
	buildGui()
	onBay(initial.Bay)

	-- With streaming, other bays' prompts arrive later; apply the same rule as they do.
	local bays = Workspace:WaitForChild("WashBays")
	bays.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") then
			applyPromptReach(descendant)
		end
	end)
	UIPlatform.onChanged(function()
		onBay(latestBay)
	end)
	Remotes.event("BayStateChanged").OnClientEvent:Connect(onBay)
	Remotes.event("CarryChanged").OnClientEvent:Connect(onCarry)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not carryBanner.Visible then
			return
		end
		if input.KeyCode == Enum.KeyCode.Q then
			carryAction:FireServer("drop")
		elseif input.KeyCode == Enum.KeyCode.X then
			carryAction:FireServer("sell")
		end
	end)

	-- Rainbow labels: slide every tagged gradient along so the colours flow.
	-- The tagged sets are tracked through signals instead of fetched fresh every frame.
	local function tracked(tag: string): { [Instance]: true }
		local set: { [Instance]: true } = {}
		for _, inst in CollectionService:GetTagged(tag) do
			set[inst] = true
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
			set[inst] = true
		end)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(inst)
			set[inst] = nil
		end)
		return set
	end
	local gradients = tracked(UIStyle.RainbowTag)
	local rings = tracked(UIStyle.RainbowRingTag)
	RunService.RenderStepped:Connect(function()
		local offset = Vector2.new((os.clock() * 0.6) % 2 - 1, 0)
		for gradient in gradients do
			(gradient :: UIGradient).Offset = offset
		end
		local hue = Color3.fromHSV((os.clock() * 0.25) % 1, 0.55, 1)
		for ring in rings do
			(ring :: BasePart).Color = hue
		end
	end)
end

return ZooController
