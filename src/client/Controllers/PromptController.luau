-- Our own look for every world interaction (pick up, sell, place, gear shop, barn, truck,
-- kiosks). Each ProximityPrompt is switched to the Custom style, so Roblox draws nothing,
-- and this draws a card instead: the object's name over one rounded button per action.
-- Prompts on the same part share one card (a cache animal's Pick up and Sell).
--
-- Buttons work three ways: the prompt's key (the engine still handles it for Custom
-- prompts), a click, or a tap. Prompts with a HoldDuration fill their button while held.
-- Robux purchases still go through Roblox's own purchase dialog after the prompt fires.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local PromptController = {}

local CARD_WIDTH = 230
local TITLE_HEIGHT = 26
local BUTTON_HEIGHT = 44
local BUTTON_GAP = 6

-- Button colour by what the action does. Anything unlisted is the neutral blue.
local SELL = Color3.fromRGB(70, 190, 90)
local BUY = Color3.fromRGB(70, 200, 100)
local NEUTRAL = Color3.fromRGB(70, 150, 240)
local COLORS: { [string]: Color3 } = {
	SellPrompt = SELL,
	PenPrompt = SELL,
	PenPrompt2 = SELL,
	UpgradePrompt = Color3.fromRGB(255, 190, 40),
	ExpandPrompt = Color3.fromRGB(120, 200, 80),
	TruckPrompt = BUY,
	UnlockPrompt = BUY,
	RobuxShopPrompt = Color3.fromRGB(0, 140, 255),
	PetPrompt = Color3.fromRGB(190, 120, 255),
	PetPrompt2 = Color3.fromRGB(190, 120, 255),
}

-- Prompts whose object needs no name over the button.
local NO_TITLE: { [string]: boolean } = {
	UpgradePrompt = true,
	RobuxShopPrompt = true,
}

type Button = {
	Prompt: ProximityPrompt,
	Frame: TextButton,
	Label: TextLabel,
	Key: TextLabel,
	Fill: Frame,
	HoldStart: number?,
	Connections: { RBXScriptConnection },
}

type Card = {
	Gui: BillboardGui,
	Title: TextLabel,
	List: Frame,
	Scale: UIScale,
	Buttons: { [ProximityPrompt]: Button },
}

local cards: { [Instance]: Card } = {}
local holding: { [ProximityPrompt]: boolean } = {}

local function keyText(prompt: ProximityPrompt): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "TAP"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		local name = prompt.GamepadKeyCode.Name
		return string.gsub(name, "^Button", "")
	end
	return prompt.KeyboardKeyCode.Name
end

local function colorFor(prompt: ProximityPrompt): Color3
	return COLORS[prompt.Name] or NEUTRAL
end

local function layout(card: Card)
	local count = 0
	local title = ""
	local ordered: { Button } = {}
	for _, button in card.Buttons do
		table.insert(ordered, button)
	end
	-- Higher in the old native stack (more negative UIOffset.Y) goes first.
	table.sort(ordered, function(a, b)
		return a.Prompt.UIOffset.Y < b.Prompt.UIOffset.Y
	end)
	for index, button in ordered do
		button.Frame.LayoutOrder = index
		count += 1
		-- The shop sign already names the gear shop, so its card is just the button.
		if title == "" and button.Prompt.ObjectText ~= "" and not NO_TITLE[button.Prompt.Name] then
			title = button.Prompt.ObjectText
		end
	end
	card.Title.Text = title
	card.Title.Visible = title ~= ""
	local titleRoom = if title ~= "" then TITLE_HEIGHT + 4 else 0
	local height = titleRoom + count * BUTTON_HEIGHT + math.max(0, count - 1) * BUTTON_GAP
	card.Gui.Size = UDim2.fromOffset(CARD_WIDTH, math.max(height, 1))
	card.List.Position = UDim2.fromOffset(0, titleRoom)
	card.List.Size = UDim2.new(1, 0, 1, -titleRoom)
end

local function refreshButton(button: Button)
	local prompt = button.Prompt
	button.Label.Text = string.upper(prompt.ActionText)
	button.Key.Text = keyText(prompt)
	button.Frame.BackgroundColor3 = colorFor(prompt)
end

local function trigger(prompt: ProximityPrompt)
	if not prompt.Enabled or not prompt.Parent then
		return
	end
	prompt:InputHoldBegin()
	if prompt.HoldDuration <= 0 then
		task.defer(function()
			if prompt.Parent then
				prompt:InputHoldEnd()
			end
		end)
	else
		holding[prompt] = true
	end
end

local function release(prompt: ProximityPrompt)
	if holding[prompt] then
		holding[prompt] = nil
		if prompt.Parent then
			prompt:InputHoldEnd()
		end
	end
end

local function makeCard(parent: Instance): Card
	local board = Instance.new("BillboardGui")
	board.Name = "PromptCard"
	board.AlwaysOnTop = true
	board.LightInfluence = 0
	board.MaxDistance = 60
	board.ResetOnSpawn = false
	board.Active = true
	board.StudsOffset = Vector3.new(0, 2.5, 0)
	board.Adornee = if parent:IsA("Attachment") then nil else parent :: any
	if parent:IsA("Attachment") then
		board.Adornee = parent.Parent :: any
		board.StudsOffsetWorldSpace = (parent :: Attachment).Position
	end
	board.Size = UDim2.fromOffset(CARD_WIDTH, BUTTON_HEIGHT)
	-- Straight under PlayerGui: a BillboardGui nested in a ScreenGui is never drawn.
	board.Parent = player:WaitForChild("PlayerGui")

	local scale = Instance.new("UIScale")
	scale.Scale = 0.6
	scale.Parent = board

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT)
	title.Parent = board
	UIStyle.text(title, Color3.new(1, 1, 1), nil, 2.5)

	local list = Instance.new("Frame")
	list.Name = "Buttons"
	list.BackgroundTransparency = 1
	list.Parent = board
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, BUTTON_GAP)
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Parent = list

	TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	return { Gui = board, Title = title, List = list, Scale = scale, Buttons = {} }
end

local function makeButton(card: Card, prompt: ProximityPrompt): Button
	local frame = Instance.new("TextButton")
	frame.Name = prompt.Name
	frame.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
	frame.Text = ""
	frame.AutoButtonColor = true
	frame.ClipsDescendants = true
	frame.Parent = card.List
	UIStyle.border(frame, 3)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.new(1, 1, 1)
	fill.BackgroundTransparency = 0.65
	fill.BorderSizePixel = 0
	fill.Parent = frame

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 7, 0.5, 0)
	badge.Size = UDim2.fromOffset(40, 30)
	badge.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	badge.BackgroundTransparency = 0.15
	badge.ZIndex = 2
	badge.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = badge
	local key = Instance.new("TextLabel")
	key.Size = UDim2.fromScale(1, 1)
	key.ZIndex = 3
	key.Parent = badge
	UIStyle.text(key, Color3.new(1, 1, 1), nil, 1.5)

	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromOffset(54, 6)
	label.Size = UDim2.new(1, -62, 1, -12)
	label.ZIndex = 2
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = frame
	UIStyle.text(label, Color3.new(1, 1, 1), nil, 2)

	local button: Button = {
		Prompt = prompt,
		Frame = frame,
		Label = label,
		Key = key,
		Fill = fill,
		HoldStart = nil,
		Connections = {},
	}
	table.insert(
		button.Connections,
		frame.InputBegan:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				trigger(prompt)
			end
		end)
	)
	table.insert(
		button.Connections,
		frame.InputEnded:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				release(prompt)
			end
		end)
	)
	for _, property in { "ActionText", "ObjectText", "KeyboardKeyCode", "UIOffset" } do
		table.insert(
			button.Connections,
			prompt:GetPropertyChangedSignal(property):Connect(function()
				refreshButton(button)
				layout(card)
			end)
		)
	end
	refreshButton(button)
	return button
end

local function hide(prompt: ProximityPrompt)
	release(prompt)
	for parent, card in cards do
		local button = card.Buttons[prompt]
		if button then
			for _, connection in button.Connections do
				connection:Disconnect()
			end
			button.Frame:Destroy()
			card.Buttons[prompt] = nil
			if next(card.Buttons) == nil then
				card.Gui:Destroy()
				cards[parent] = nil
			else
				layout(card)
			end
			return
		end
	end
end

local function show(prompt: ProximityPrompt)
	local parent = prompt.Parent
	if not parent then
		return
	end
	local card = cards[parent]
	if not card then
		card = makeCard(parent)
		cards[parent] = card
	end
	if card.Buttons[prompt] then
		return
	end
	card.Buttons[prompt] = makeButton(card, prompt)
	layout(card)
end

local function adopt(prompt: ProximityPrompt)
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		prompt.Style = Enum.ProximityPromptStyle.Custom
		-- A prompt already on screen keeps its native billboard until it is shown again.
		if prompt.Enabled then
			prompt.Enabled = false
			prompt.Enabled = true
		end
	end
end

function PromptController.init()
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			adopt(descendant)
		end
	end
	Workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") then
			adopt(descendant)
		end
	end)

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if prompt.Style == Enum.ProximityPromptStyle.Custom then
			show(prompt)
		end
	end)
	ProximityPromptService.PromptHidden:Connect(hide)
	ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt: ProximityPrompt)
		for _, card in cards do
			local button = card.Buttons[prompt]
			if button then
				button.HoldStart = os.clock()
			end
		end
	end)
	ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt: ProximityPrompt)
		for _, card in cards do
			local button = card.Buttons[prompt]
			if button then
				button.HoldStart = nil
				button.Fill.Size = UDim2.fromScale(0, 1)
			end
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
		holding[prompt] = nil
		for _, card in cards do
			local button = card.Buttons[prompt]
			if button then
				button.HoldStart = nil
				button.Fill.Size = UDim2.fromScale(0, 1)
				-- A quick press pop so the tap reads as done.
				card.Scale.Scale = 0.92
				TweenService:Create(card.Scale, TweenInfo.new(0.18, Enum.EasingStyle.Back), { Scale = 1 }):Play()
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		for _, card in cards do
			for prompt, button in card.Buttons do
				if button.HoldStart and prompt.HoldDuration > 0 then
					local alpha = math.clamp((os.clock() - button.HoldStart) / prompt.HoldDuration, 0, 1)
					button.Fill.Size = UDim2.fromScale(alpha, 1)
				end
			end
		end
	end)
end

return PromptController
