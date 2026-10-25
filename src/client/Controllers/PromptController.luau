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
local Workspace = game:GetService("Workspace")

local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local UIPlatform = require(script.Parent.Parent.UI)

local player = Players.LocalPlayer

local PromptController = {}

local CARD_WIDTH = 176
local TITLE_HEIGHT = 20
local BUTTON_HEIGHT = 32
local BUTTON_GAP = 4
local PAD = 6
-- Cards over animals and pens draw at this size so they cover less of the animal. On a
-- phone screen the full-size card swamped the view, so touch draws it smaller too.
local CARD_SCALE_TOUCH = 0.8
local CARD_SCALE = 0.9

-- Button colour by what the action does: muted so the card sits quietly over the world.
-- Anything unlisted is the neutral blue (pick up, place, and other moves).
local CASH = UIStyle.Colors.Cash
local ROBUX = UIStyle.Colors.Robux
local PET = UIStyle.Colors.Pet
local NEUTRAL = UIStyle.Colors.Action
local CARD_COLOR = UIStyle.Colors.Panel
local EDGE_COLOR = UIStyle.Colors.Edge
local COLORS: { [string]: Color3 } = {
	SellPrompt = CASH,
	PenSellPrompt = CASH,
	PenPrompt2 = CASH,
	ExpandPrompt = CASH,
	UnlockPrompt = CASH,
	TruckPrompt = ROBUX,
	RobuxShopPrompt = ROBUX,
	RobuxKioskPrompt = ROBUX,
	PetPrompt = PET,
	PetPrompt2 = PET,
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
	Root: Frame,
	Title: TextLabel,
	List: Frame,
	Scale: UIScale,
	Buttons: { [ProximityPrompt]: Button },
}

local cards: { [Instance]: Card } = {}
local holding: { [ProximityPrompt]: boolean } = {}

-- On touch, the actions that cost you an animal or move it need a short hold, so a
-- thumb brushing past a card can't sell or pick up by accident. The server sets each
-- prompt's own HoldDuration (serverHold); this raises it locally on touch only. The
-- engine runs the hold on the client, so the local value is the one that counts.
local TOUCH_HOLD = 0.75
local TOUCH_HOLD_ACTIONS = { "Sell", "Swap", "Pick up" }
-- Picking up from the cache only moves a washed animal into your hands, so it stays a tap.
local TOUCH_TAP_PROMPTS: { [string]: boolean } = {
	PickupPrompt = true,
}
-- Setting a pet swaps the one following you, so it holds on touch whatever its label says.
local TOUCH_HOLD_PROMPTS: { [string]: boolean } = {
	PetPrompt = true,
	PetPrompt2 = true,
}
local serverHold: { [ProximityPrompt]: number } = {}
-- What we last wrote. Property signals are deferred, so a flag set around the write is
-- already cleared when the change fires; comparing against our own value is not.
local localHold: { [ProximityPrompt]: number } = {}

local function wantsTouchHold(prompt: ProximityPrompt): boolean
	if UIPlatform.get().inputMode ~= "Touch" or TOUCH_TAP_PROMPTS[prompt.Name] then
		return false
	end
	if TOUCH_HOLD_PROMPTS[prompt.Name] then
		return true
	end
	for _, prefix in TOUCH_HOLD_ACTIONS do
		if string.sub(prompt.ActionText, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function applyHold(prompt: ProximityPrompt)
	local base = serverHold[prompt] or prompt.HoldDuration
	local want = if wantsTouchHold(prompt) then math.max(base, TOUCH_HOLD) else base
	if prompt.HoldDuration ~= want then
		localHold[prompt] = want
		prompt.HoldDuration = want
	end
end

local function keyText(prompt: ProximityPrompt): string
	local mode = UIPlatform.get().inputMode
	if mode == "Touch" then
		return if prompt.HoldDuration > 0 then "HOLD" else "TAP"
	end
	if mode == "Gamepad" then
		local name = prompt.GamepadKeyCode.Name
		return string.gsub(name, "^Button", "")
	end
	return prompt.KeyboardKeyCode.Name
end

local function cardScale(): number
	return if UIPlatform.get().inputMode == "Touch" then CARD_SCALE_TOUCH else CARD_SCALE
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
	local titleRoom = if title ~= "" then TITLE_HEIGHT + 2 else 0
	local height = PAD * 2 + titleRoom + count * BUTTON_HEIGHT + math.max(0, count - 1) * BUTTON_GAP
	card.Gui.Size = UDim2.fromOffset(CARD_WIDTH, math.max(height, 1))
	card.Root.Size = card.Gui.Size
	card.List.Position = UDim2.fromOffset(PAD, PAD + titleRoom)
	card.List.Size = UDim2.new(1, -PAD * 2, 1, -(PAD * 2 + titleRoom))
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

	-- A UIScale straight under a BillboardGui does nothing, so the card lives in a centred,
	-- pixel-sized root frame that carries the scale (pop-in, press pop, card size).
	local root = Instance.new("Frame")
	root.Name = "Card"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = board.Size
	root.BackgroundTransparency = 1
	root.Parent = board
	local scale = Instance.new("UIScale")
	scale.Scale = 0.6 * cardScale()
	scale.Parent = root

	-- One dark rounded backing for the whole card, so it reads against any scenery.
	local back = Instance.new("Frame")
	back.Name = "Back"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = CARD_COLOR
	back.BackgroundTransparency = 0.15
	back.Parent = root
	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, 10)
	backCorner.Parent = back
	local backEdge = Instance.new("UIStroke")
	backEdge.Color = EDGE_COLOR
	backEdge.Thickness = 1.5
	backEdge.Parent = back

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.fromOffset(PAD, PAD)
	title.Size = UDim2.new(1, -PAD * 2, 0, TITLE_HEIGHT)
	title.ZIndex = 2
	title.Parent = root
	UIStyle.text(title, Color3.fromRGB(236, 238, 244), EDGE_COLOR, 1.5)

	local list = Instance.new("Frame")
	list.Name = "Buttons"
	list.BackgroundTransparency = 1
	list.ZIndex = 2
	list.Parent = root
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, BUTTON_GAP)
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Parent = list

	TweenService
		:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = cardScale() })
		:Play()
	return { Gui = board, Root = root, Title = title, List = list, Scale = scale, Buttons = {} }
end

local function makeButton(card: Card, prompt: ProximityPrompt): Button
	local frame = Instance.new("TextButton")
	frame.Name = prompt.Name
	frame.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
	frame.Text = ""
	frame.AutoButtonColor = true
	frame.ClipsDescendants = true
	frame.ZIndex = 2
	frame.Parent = card.List
	UIStyle.border(frame, 1.5)
	local edge = frame:FindFirstChildOfClass("UIStroke")
	if edge then
		edge.Color = EDGE_COLOR
	end
	local round = frame:FindFirstChildOfClass("UICorner")
	if round then
		round.CornerRadius = UDim.new(0, 8)
	end

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.ZIndex = 2
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.new(1, 1, 1)
	fill.BackgroundTransparency = 0.65
	fill.BorderSizePixel = 0
	fill.Parent = frame

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 5, 0.5, 0)
	badge.Size = UDim2.fromOffset(30, 22)
	badge.BackgroundColor3 = EDGE_COLOR
	badge.BackgroundTransparency = 0.3
	badge.ZIndex = 3
	badge.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = badge
	local key = Instance.new("TextLabel")
	key.Size = UDim2.fromScale(1, 1)
	key.ZIndex = 4
	key.Parent = badge
	UIStyle.text(key, Color3.new(1, 1, 1), EDGE_COLOR, 1)

	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromOffset(42, 6)
	label.Size = UDim2.new(1, -48, 1, -12)
	label.ZIndex = 3
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = frame
	UIStyle.text(label, Color3.new(1, 1, 1), EDGE_COLOR, 1.2)

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
	for _, property in { "ActionText", "ObjectText", "KeyboardKeyCode", "UIOffset", "HoldDuration" } do
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
	if serverHold[prompt] == nil then
		serverHold[prompt] = prompt.HoldDuration
		-- A replicated change is the server's new value; our own write is not.
		prompt:GetPropertyChangedSignal("HoldDuration"):Connect(function()
			if prompt.HoldDuration == localHold[prompt] then
				return
			end
			localHold[prompt] = nil
			serverHold[prompt] = prompt.HoldDuration
			applyHold(prompt)
		end)
		prompt:GetPropertyChangedSignal("ActionText"):Connect(function()
			applyHold(prompt)
		end)
		prompt.Destroying:Connect(function()
			serverHold[prompt] = nil
			localHold[prompt] = nil
		end)
		applyHold(prompt)
	end
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
	-- Switching between touch and keyboard turns the touch holds on or off.
	UIPlatform.onChanged(function()
		for prompt in serverHold do
			applyHold(prompt)
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
				local size = cardScale()
				card.Scale.Scale = 0.92 * size
				TweenService:Create(card.Scale, TweenInfo.new(0.18, Enum.EasingStyle.Back), { Scale = size }):Play()
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
