-- Zoo client side:
--   * keeps other players' pen/cache/expand prompts out of reach (only your bay's work),
--   * shows what you're carrying, with Put Down / Sell buttons (Q / X on keyboard),
--   * puts a Pick up card on your washed animals while they walk to the cache,
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
local AnimalFocus = require(script.Parent.Parent.Features.AnimalFocus)

local player = Players.LocalPlayer

local ZooController = {}

-- Pick up on a cache animal (waiting, or still walking there) reaches much further than the
-- other cards, so you can grab it from the wash without walking over. ZooService's
-- WALK_REACH must stay above this.
local PICKUP_REACH = 30

local OWN_PROMPTS = {
	PenPrompt = 10,
	PickupPrompt = PICKUP_REACH,
	SellPrompt = 10,
	PenSellPrompt = 10,
	PetPrompt = 10,
	PenPrompt2 = 10,
	PetPrompt2 = 10,
	ExpandPrompt = 10,
	TruckPrompt = 12, -- the delivery truck parks under your bay model
}

local myBay: string? = nil
local latestBay: Types.BaySnapshot? = nil
local carryBanner: Frame
local cacheHint: TextLabel
local carrySellButton: TextButton
local carryAction = Remotes.event("CarryAction")
local walkPickup = Remotes.event("WalkPickup")
local carrying = false

-- Washed animals on their way to the cache carry WalkPickupId (ZooService). The card lives
-- only on this client: the server's copy of a walking model stays where the walk started,
-- so the grab goes up as a remote and the server checks the distance itself.
local WALK_PICKUP = "WalkPickupId"
local walkPrompts: { [Model]: ProximityPrompt } = {}

-- An animal's Pick up / Sell / Set pet card only comes up while you look at that animal,
-- like its nameplate (AnimalFocus): in a pen, or waiting in a cache slot. Carrying one,
-- every pen's Place / Swap stays in reach.
local function penCardAllowed(prompt: ProximityPrompt): boolean
	local holder = prompt.Parent
	if not holder or carrying then
		return true
	end
	local head = AnimalFocus.focusedHead()
	if holder.Name == "GatePost" then
		return head ~= nil and holder.Parent ~= nil and head:IsDescendantOf(holder.Parent)
	end
	local cache = holder.Parent
	if cache and cache.Name == "Cache" and holder:IsA("BasePart") and string.match(holder.Name, "^Slot%d+$") then
		local model = head and head.Parent
		if not model or not model:IsA("Model") or not model:IsDescendantOf(cache) then
			return false
		end
		local offset = model:GetPivot().Position - holder.Position
		return Vector2.new(offset.X, offset.Z).Magnitude < 3
	end
	return true
end

-- The server never changes MaxActivationDistance, so this local override sticks even as it
-- toggles Enabled. Other players' prompts are set to 0 reach.
local function applyPromptReach(prompt: ProximityPrompt)
	local reach = OWN_PROMPTS[prompt.Name]
	local bays = Workspace:FindFirstChild("WashBays")
	if not reach or not bays or not myBay then
		return
	end
	local mine = bays:FindFirstChild(myBay)
	local own = mine and prompt:IsDescendantOf(mine)
	prompt.MaxActivationDistance = if own and penCardAllowed(prompt) then reach else 0
end

local function applyPenPrompts()
	local bays = Workspace:FindFirstChild("WashBays")
	local mine = bays and myBay and bays:FindFirstChild(myBay)
	local zoo = mine and mine:FindFirstChild("Zoo")
	local cache = mine and mine:FindFirstChild("Cache")
	if cache then
		for _, prompt in cache:GetDescendants() do
			if prompt:IsA("ProximityPrompt") then
				applyPromptReach(prompt)
			end
		end
	end
	if zoo then
		for _, prompt in zoo:GetDescendants() do
			if prompt:IsA("ProximityPrompt") then
				applyPromptReach(prompt)
			end
		end
	end
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

local function dropWalkPrompt(model: Model)
	local prompt = walkPrompts[model]
	walkPrompts[model] = nil
	if prompt then
		prompt:Destroy()
	end
end

local watchedWalkers: { [Model]: boolean } = {}
local updateWalker: { [Model]: () -> () } = {}

-- Washed animals stand straight under their bay model, so only those are watched.
local function watchWalker(model: Instance)
	local bay = model.Parent
	if
		not model:IsA("Model")
		or watchedWalkers[model]
		or not bay
		or bay.Parent ~= Workspace:FindFirstChild("WashBays")
	then
		return
	end
	watchedWalkers[model] = true
	local function update()
		local id = model:GetAttribute(WALK_PICKUP)
		local bays = Workspace:FindFirstChild("WashBays")
		local mine = bays and myBay and bays:FindFirstChild(myBay)
		local head = model:FindFirstChild("Head")
		if
			typeof(id) ~= "string"
			or not mine
			or not model:IsDescendantOf(mine)
			or not head
			or not head:IsA("BasePart")
		then
			dropWalkPrompt(model)
			return
		end
		local prompt = walkPrompts[model]
		if not prompt then
			prompt = Instance.new("ProximityPrompt")
			prompt.Name = "WalkPickupPrompt"
			prompt.Style = Enum.ProximityPromptStyle.Custom -- PromptController draws the card
			prompt.ActionText = "Pick up"
			prompt.HoldDuration = 0
			prompt.RequiresLineOfSight = false
			prompt.MaxActivationDistance = PICKUP_REACH
			prompt.Triggered:Connect(function()
				local current = model:GetAttribute(WALK_PICKUP)
				if typeof(current) == "string" then
					walkPickup:FireServer(current)
				end
			end)
			prompt.Parent = head
			walkPrompts[model] = prompt
		end
		local label = model:GetAttribute("WalkPickupLabel")
		prompt.ObjectText = if typeof(label) == "string" then label else ""
		prompt.Enabled = not carrying
	end
	updateWalker[model] = update
	model:GetAttributeChangedSignal(WALK_PICKUP):Connect(update)
	model.AncestryChanged:Connect(function()
		if not model.Parent then
			dropWalkPrompt(model)
			watchedWalkers[model] = nil
			updateWalker[model] = nil
		end
	end)
	update()
end

local function refreshWalkPrompts()
	for _, prompt in walkPrompts do
		prompt.Enabled = not carrying
	end
end

-- Auto-pickup: with empty hands, coming within AUTO_REACH of your washed animal (walking to
-- the cache or waiting in it) picks it up, so a fresh wash lands straight in your hands. It
-- goes up as WalkPickup and the server checks the distance. After you put one down, nothing
-- is grabbed again until you have stepped clear of every waiting animal, so Put Down by the
-- cache sticks. With every pen taken there's nowhere to put it, so nothing is grabbed.
local AUTO_REACH = 6 -- studs from the animal's edge
local AUTO_CHECK = 0.15
local pensFull = false
local autoHold = false
local autoNextAt = 0
local autoSentUntil = 0
local animalRadius: { [Model]: number } = {}

local function autoCandidates(mine: Instance): { Model }
	local list: { Model } = {}
	for model in walkPrompts do
		if model.Parent and typeof(model:GetAttribute(WALK_PICKUP)) == "string" then
			table.insert(list, model)
		end
	end
	local cache = mine:FindFirstChild("Cache")
	if cache and mine:GetAttribute("YardRevealed") == true then
		for _, child in cache:GetChildren() do
			if
				child:IsA("Model")
				and child.Name == "CachedAnimal"
				and typeof(child:GetAttribute("AnimalId")) == "string"
			then
				table.insert(list, child)
			end
		end
	end
	return list
end

local function autoPickup()
	local now = os.clock()
	if now < autoNextAt then
		return
	end
	autoNextAt = now + AUTO_CHECK
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local bays = Workspace:FindFirstChild("WashBays")
	local mine = bays and myBay and bays:FindFirstChild(myBay)
	if
		carrying
		or pensFull
		or not root
		or not mine
		or player:GetAttribute("InCutscene") == true
		or now < autoSentUntil
	then
		return
	end
	local best: Model?, bestGap = nil, math.huge
	for _, model in autoCandidates(mine) do
		local radius = animalRadius[model]
		if not radius then
			local size = model:GetExtentsSize()
			radius = math.max(size.X, size.Z) * 0.5
			animalRadius[model] = radius
			model.AncestryChanged:Connect(function()
				if not model.Parent then
					animalRadius[model] = nil
				end
			end)
		end
		local offset = model:GetPivot().Position - root.Position
		local gap = Vector2.new(offset.X, offset.Z).Magnitude - radius
		if gap <= AUTO_REACH and gap < bestGap then
			best, bestGap = model, gap
		end
	end
	if not best then
		autoHold = false
		return
	end
	if autoHold then
		return
	end
	local id = best:GetAttribute(WALK_PICKUP) or best:GetAttribute("AnimalId")
	if typeof(id) == "string" then
		autoSentUntil = now + 1
		walkPickup:FireServer(id)
	end
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Zoo"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Just the two choices while carrying: put it down (in the nearest free pen it fits, or
	-- back in the cache if that is closer), or sell it.
	carryBanner = Instance.new("Frame")
	carryBanner.AnchorPoint = Vector2.new(0.5, 1)
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
	local carryButtons: { TextButton } = {}
	local function carryButton(text: string, color: Color3, action: string): TextButton
		local button = Instance.new("TextButton")
		table.insert(carryButtons, button)
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
		UIPlatform.Feedback.button(button)
		return button
	end
	carryButton("PUT DOWN", UIStyle.Colors.Action, "drop")
	carrySellButton = carryButton("SELL", UIStyle.Colors.Cash, "sell")

	cacheHint = Instance.new("TextLabel")
	cacheHint.AnchorPoint = Vector2.new(0.5, 1)
	cacheHint.Size = UDim2.new(0.9, 0, 0, 34)
	cacheHint.Visible = false
	cacheHint.Parent = gui
	UIStyle.text(cacheHint, Color3.fromRGB(110, 200, 255))
	cacheHint.Text = "Cache full! Place or sell one."
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(720, 34)
	constraint.Parent = cacheHint

	-- Low in the middle on phones, between the thumbstick and WASH; higher on desktop.
	UIPlatform.Layout.watch(function(spec)
		carryBanner.Position = UDim2.new(0.5, 0, 1, -spec.bannerLift)
		local size = spec.carryButton
		carryBanner.Size = UDim2.fromOffset(math.max(420, size.X * #carryButtons + 12), size.Y + 8)
		for _, button in carryButtons do
			button.Size = UDim2.fromOffset(size.X, size.Y)
		end
		cacheHint.Position = UDim2.new(0.5, 0, 1, -spec.bannerLift)
	end)
end

local function onCarry(info: Types.CarryInfo?)
	if carrying and not info then
		autoHold = true -- just put one down (or placed / sold it): wait until clear
	end
	autoSentUntil = 0
	carrying = info ~= nil
	applyPenPrompts()
	refreshWalkPrompts()
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
		for _, update in updateWalker do
			update()
		end
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
		elseif descendant:IsA("Model") then
			watchWalker(descendant)
		end
	end)
	for _, descendant in bays:GetDescendants() do
		if descendant:IsA("Model") then
			watchWalker(descendant)
		end
	end
	UIPlatform.onChanged(function()
		onBay(latestBay)
	end)
	Remotes.event("BayStateChanged").OnClientEvent:Connect(onBay)
	Remotes.event("CarryChanged").OnClientEvent:Connect(onCarry)
	AnimalFocus.onChanged(applyPenPrompts)
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
	local function applyZoo(summary: Types.ZooSummary?)
		if summary then
			pensFull = summary.Count >= summary.ZooSize
		end
	end
	applyZoo(initial.Zoo)
	Remotes.event("ZooChanged").OnClientEvent:Connect(applyZoo)
	RunService.Heartbeat:Connect(autoPickup)

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
