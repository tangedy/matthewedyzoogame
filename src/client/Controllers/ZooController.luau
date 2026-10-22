-- Zoo client side:
--   * keeps other players' pen/cache/expand prompts out of reach (only your bay's work),
--   * shows what you're carrying and what to do with it,
--   * nudges you when the cache is full,
--   * animates every rainbow label (Zoo God tier, Rainbow mutation).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
}

local myBay: string? = nil
local latestBay: Types.BaySnapshot? = nil
local carryBanner: Frame
local carryName: TextLabel
local carryRarity: TextLabel
local carryHint: TextLabel
local cacheHint: TextLabel
local touchCluster: Frame
local pickupButton: TextButton
local pickupLabel: TextLabel
local sellButton: TextButton
local sellLabel: TextLabel
local sellFill: Frame

local touchMode = false
local sellHolding = false
local sellHoldStarted = 0
local heldSell: ProximityPrompt? = nil
local activePickup: ProximityPrompt? = nil
local activeSell: ProximityPrompt? = nil
local shownPrompts: { [ProximityPrompt]: boolean } = {}

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

	-- "CARRYING / Gold Pig / Rare / Place it in a pen" above the bottom toast
	carryBanner = Instance.new("Frame")
	carryBanner.AnchorPoint = Vector2.new(0.5, 1)
	carryBanner.Position = UDim2.new(0.5, 0, 1, -190)
	carryBanner.Size = UDim2.fromOffset(420, 96)
	carryBanner.BackgroundTransparency = 1
	carryBanner.Visible = false
	carryBanner.Parent = gui
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Parent = carryBanner
	local function line(order: number, height: number): TextLabel
		local label = Instance.new("TextLabel")
		label.LayoutOrder = order
		label.Size = UDim2.new(1, 0, 0, height)
		label.Parent = carryBanner
		UIStyle.text(label)
		return label
	end
	local title = line(1, 22)
	title.Text = "CARRYING"
	carryName = line(2, 30)
	carryRarity = line(3, 20)
	carryHint = line(4, 22)
	carryHint.TextColor3 = Color3.fromRGB(255, 230, 120)
	carryHint.Text = "Take it to a pen: Place or Swap"

	cacheHint = Instance.new("TextLabel")
	cacheHint.AnchorPoint = Vector2.new(0.5, 1)
	cacheHint.Position = UDim2.new(0.5, 0, 1, -190)
	cacheHint.Size = UDim2.new(0.9, 0, 0, 34)
	cacheHint.Visible = false
	cacheHint.Parent = gui
	UIStyle.text(cacheHint, Color3.fromRGB(110, 200, 255))
	cacheHint.Text = "Cache full! Pick up an animal (E) and put it in a pen, or sell it (F)."
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(720, 34)
	constraint.Parent = cacheHint

	-- Touch has no E / F, and the two prompts would draw on the same spot. Two buttons instead:
	-- pick up on top, sell underneath.
	touchCluster = Instance.new("Frame")
	touchCluster.Name = "CacheActions"
	touchCluster.AnchorPoint = Vector2.new(1, 1)
	touchCluster.Position = UDim2.new(1, -108, 1, -28)
	touchCluster.Size = UDim2.fromOffset(180, 124)
	touchCluster.BackgroundTransparency = 1
	touchCluster.Visible = false
	touchCluster.Parent = gui
	local actions = Instance.new("UIListLayout")
	actions.SortOrder = Enum.SortOrder.LayoutOrder
	actions.Padding = UDim.new(0, 8)
	actions.HorizontalAlignment = Enum.HorizontalAlignment.Center
	actions.Parent = touchCluster

	local function actionButton(name: string, order: number, color: Color3): (TextButton, TextLabel, Frame)
		local button = Instance.new("TextButton")
		button.Name = name
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(180, 56)
		button.BackgroundColor3 = color
		button.Text = ""
		button.AutoButtonColor = true
		button.ClipsDescendants = true
		button.Parent = touchCluster
		UIStyle.border(button, 3)
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = Color3.new(1, 1, 1)
		fill.BackgroundTransparency = 0.7
		fill.BorderSizePixel = 0
		fill.ZIndex = 1
		fill.Parent = button
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.fromScale(1, 1)
		label.ZIndex = 2
		label.Parent = button
		UIStyle.text(label)
		return button, label, fill
	end

	pickupButton, pickupLabel = actionButton("Pickup", 1, Color3.fromRGB(70, 160, 230))
	sellButton, sellLabel, sellFill = actionButton("Sell", 2, Color3.fromRGB(230, 150, 40))
end

local function placeCluster(profile: UIPlatform.Profile)
	local fromRight = if profile.formFactor == "Mobile" then 108 else 160
	local fromBottom = if profile.formFactor == "Mobile" then 28 else 48
	touchCluster.Position = UDim2.new(1, -fromRight, 1, -fromBottom)
end

local function promptPoint(prompt: ProximityPrompt): Vector3?
	local parent = prompt.Parent
	if parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	elseif parent and parent:IsA("BasePart") then
		return parent.Position
	end
	return nil
end

local function playerPosition(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function releaseSell()
	if sellHolding and heldSell and heldSell.Parent then
		heldSell:InputHoldEnd()
	end
	sellHolding = false
	heldSell = nil
	sellFill.Size = UDim2.fromScale(0, 1)
end

-- The nearest cache slot that is showing a prompt. One pickup and one sell, so the
-- buttons stay a pair for the animal you're standing at.
local function refreshTouchButtons()
	if not touchMode then
		touchCluster.Visible = false
		releaseSell()
		activePickup = nil
		activeSell = nil
		return
	end
	local origin = playerPosition()
	local bestParent: Instance? = nil
	local bestDistance = math.huge
	for prompt in shownPrompts do
		if prompt.Enabled and prompt.Parent and (prompt.Name == "PickupPrompt" or prompt.Name == "SellPrompt") then
			local point = promptPoint(prompt)
			local distance = if origin and point then (point - origin).Magnitude else 0
			if distance < bestDistance then
				bestDistance = distance
				bestParent = prompt.Parent
			end
		end
	end
	local pickup: ProximityPrompt? = nil
	local sell: ProximityPrompt? = nil
	if bestParent then
		for prompt in shownPrompts do
			if prompt.Parent == bestParent and prompt.Enabled then
				if prompt.Name == "PickupPrompt" then
					pickup = prompt
				elseif prompt.Name == "SellPrompt" then
					sell = prompt
				end
			end
		end
	end
	if heldSell and heldSell ~= sell then
		releaseSell()
	end
	activePickup = pickup
	activeSell = sell
	pickupButton.Visible = pickup ~= nil
	sellButton.Visible = sell ~= nil
	if pickup then
		pickupLabel.Text = pickup.ActionText
	end
	if sell then
		sellLabel.Text = sell.ActionText
	end
	touchCluster.Visible = pickup ~= nil or sell ~= nil
end

local function cachePrompt(prompt: ProximityPrompt): boolean
	return prompt.Name == "PickupPrompt" or prompt.Name == "SellPrompt"
end

local function applyPromptStyle(prompt: ProximityPrompt)
	if not cachePrompt(prompt) then
		return
	end
	-- Custom hides the billboard prompt. The two screen buttons replace it on touch.
	prompt.Style = if touchMode then Enum.ProximityPromptStyle.Custom else Enum.ProximityPromptStyle.Default
end

local function applyPromptStyles()
	local bays = Workspace:FindFirstChild("WashBays")
	if not bays then
		return
	end
	for _, descendant in bays:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			applyPromptStyle(descendant)
		end
	end
end

-- The default billboard is created on PromptShown. Toggling Enabled rebuilds it after Style changes.
local function bounceVisibleCachePrompts()
	local origin = playerPosition()
	local bays = Workspace:FindFirstChild("WashBays")
	local mine = if bays and myBay then bays:FindFirstChild(myBay) else nil
	if not origin or not mine then
		return
	end
	for _, descendant in mine:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and cachePrompt(descendant) and descendant.Enabled then
			local point = promptPoint(descendant)
			if point and (point - origin).Magnitude <= descendant.MaxActivationDistance then
				descendant.Enabled = false
				descendant.Enabled = true
			end
		end
	end
end

-- PromptShown does not re-fire when the input mode changes while you're already in range.
local function rescanShown()
	table.clear(shownPrompts)
	if not touchMode then
		refreshTouchButtons()
		return
	end
	local origin = playerPosition()
	local bays = Workspace:FindFirstChild("WashBays")
	local mine = if bays and myBay then bays:FindFirstChild(myBay) else nil
	if not origin or not mine then
		refreshTouchButtons()
		return
	end
	for _, descendant in mine:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and cachePrompt(descendant) and descendant.Enabled then
			local point = promptPoint(descendant)
			if point and (point - origin).Magnitude <= descendant.MaxActivationDistance then
				shownPrompts[descendant] = true
			end
		end
	end
	refreshTouchButtons()
end

local function onCarry(info: Types.CarryInfo?)
	if info then
		carryName.Text = info.Label
		UIStyle.rarity(carryRarity, info.Rarity)
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
	local holding = carryBanner.Visible
	cacheHint.Visible = bay.State == "CacheFull" and not holding
	if cacheHint.Visible then
		cacheHint.Text = if touchMode
			then "Cache full! Pick up an animal and put it in a pen, or hold Sell."
			else "Cache full! Pick up an animal (E) and put it in a pen, or hold F to sell."
	end
end

function ZooController.init(initial: Types.InitialState)
	buildGui()
	local profile = UIPlatform.get()
	touchMode = profile.inputMode == "Touch"
	placeCluster(profile)
	onBay(initial.Bay)

	pickupButton.Activated:Connect(function()
		local prompt = activePickup
		if not prompt or not prompt.Enabled then
			return
		end
		prompt:InputHoldBegin()
		task.defer(function()
			if prompt.Parent then
				prompt:InputHoldEnd()
			end
		end)
	end)
	sellButton.InputBegan:Connect(function(input: InputObject)
		if input.UserInputState ~= Enum.UserInputState.Begin then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local prompt = activeSell
		if not prompt or not prompt.Enabled or sellHolding then
			return
		end
		sellHolding = true
		heldSell = prompt
		sellHoldStarted = os.clock()
		prompt:InputHoldBegin()
	end)
	sellButton.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		releaseSell()
	end)

	-- With streaming, other bays' prompts arrive later; apply the same rule as they do.
	local bays = Workspace:WaitForChild("WashBays")
	bays.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") then
			applyPromptReach(descendant)
			applyPromptStyle(descendant)
		end
	end)
	applyPromptStyles()
	bounceVisibleCachePrompts()
	UIPlatform.onChanged(function(nextProfile)
		local wasTouch = touchMode
		touchMode = nextProfile.inputMode == "Touch"
		placeCluster(nextProfile)
		if wasTouch ~= touchMode then
			releaseSell()
			applyPromptStyles()
			bounceVisibleCachePrompts()
			rescanShown()
		end
		onBay(latestBay)
	end)
	Remotes.event("BayStateChanged").OnClientEvent:Connect(onBay)
	Remotes.event("CarryChanged").OnClientEvent:Connect(onCarry)

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if touchMode and cachePrompt(prompt) then
			shownPrompts[prompt] = true
			refreshTouchButtons()
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		if shownPrompts[prompt] then
			shownPrompts[prompt] = nil
			refreshTouchButtons()
		end
	end)
	rescanShown()

	-- Rainbow labels: slide every tagged gradient along so the colours flow.
	RunService.RenderStepped:Connect(function()
		local offset = (os.clock() * 0.6) % 2 - 1
		for _, gradient in CollectionService:GetTagged(UIStyle.RainbowTag) do
			(gradient :: UIGradient).Offset = Vector2.new(offset, 0)
		end
		if sellHolding and activeSell then
			local duration = math.max(activeSell.HoldDuration, 0.05)
			local alpha = math.clamp((os.clock() - sellHoldStarted) / duration, 0, 1)
			sellFill.Size = UDim2.fromScale(alpha, 1)
		end
	end)
end

return ZooController
