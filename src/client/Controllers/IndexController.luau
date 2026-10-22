-- The index: every species x mutation. Rows are grouped by rarity tier (Common ... Secret),
-- columns are mutations (Normal, Gold, Diamond, Rainbow). Discovered cells light up.
-- A button under the cash shows progress ("INDEX 3/88"); new discoveries pop a toast.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local IndexController = {}

local UNKNOWN_COLOR = Color3.fromRGB(55, 58, 72)

local index: { [string]: boolean } = {}
local speciesOrder: { string } = {}

local button: TextButton
local panel: Frame
local toast: TextLabel
local cells: { [string]: TextLabel } = {}
local toastToken = 0

local function total(): number
	return #speciesOrder * #MutationConfig.List
end

local function count(): number
	local n = 0
	for key in index do
		if cells[key] then
			n += 1
		end
	end
	return n
end

local function refresh()
	button.Text = `INDEX {count()}/{total()}`
	for key, cell in cells do
		local mutationKey = string.match(key, ":(%w+)$") or "Normal"
		local mutation = MutationConfig.ByKey[mutationKey]
		if index[key] then
			cell.BackgroundColor3 = if mutation.Key == "Normal" then Color3.fromRGB(90, 200, 90) else mutation.Color
			cell.Text = "✓"
		else
			cell.BackgroundColor3 = UNKNOWN_COLOR
			cell.Text = "?"
		end
	end
end

local function showToast(text: string)
	toastToken += 1
	local token = toastToken
	toast.Text = text
	toast.Visible = true
	task.delay(4, function()
		if toastToken == token then
			toast.Visible = false
		end
	end)
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Index"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Under the cash display, left side
	button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0, 0.5)
	button.Position = UDim2.new(0, 16, 0.5, 14)
	button.Size = UDim2.fromOffset(170, 40)
	button.BackgroundColor3 = Color3.fromRGB(255, 190, 40)
	button.Parent = gui
	UIStyle.text(button)
	UIStyle.border(button, 3)
	local buttonPad = Instance.new("UIPadding")
	buttonPad.PaddingTop = UDim.new(0, 6)
	buttonPad.PaddingBottom = UDim.new(0, 6)
	buttonPad.Parent = button

	panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.92, 0.82)
	panel.BackgroundColor3 = UIStyle.PanelColor
	panel.BackgroundTransparency = 0.05
	panel.Visible = false
	panel.Parent = gui
	UIStyle.border(panel, 4)
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(600, 560)
	constraint.Parent = panel

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(16, 10)
	title.Size = UDim2.new(1, -80, 0, 38)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = panel
	UIStyle.text(title, Color3.fromRGB(255, 205, 40))
	title.Text = "ANIMAL INDEX"

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -12, 0, 10)
	close.Size = UDim2.fromOffset(40, 40)
	close.BackgroundColor3 = Color3.fromRGB(230, 70, 70)
	close.Parent = panel
	UIStyle.text(close)
	UIStyle.border(close, 3)
	close.Text = "X"
	close.Activated:Connect(function()
		panel.Visible = false
	end)

	-- Header: mutation names
	local nameWidth = 0.4
	local cellWidth = (1 - nameWidth) / #MutationConfig.List
	local header = Instance.new("Frame")
	header.Position = UDim2.fromOffset(14, 56)
	header.Size = UDim2.new(1, -28, 0, 24)
	header.BackgroundTransparency = 1
	header.Parent = panel
	for i, mutation in MutationConfig.List do
		local l = Instance.new("TextLabel")
		l.Position = UDim2.fromScale(nameWidth + (i - 1) * cellWidth, 0)
		l.Size = UDim2.fromScale(cellWidth, 1)
		l.Parent = header
		UIStyle.mutation(l, mutation.Key)
	end

	local grid = Instance.new("ScrollingFrame")
	grid.Position = UDim2.fromOffset(14, 84)
	grid.Size = UDim2.new(1, -28, 1, -96)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.CanvasSize = UDim2.new()
	grid.Parent = panel
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = grid

	for order, species in speciesOrder do
		local def = AnimalConfig.Animals[species]
		local row = Instance.new("Frame")
		row.LayoutOrder = order
		row.Size = UDim2.new(1, -8, 0, 40)
		row.BackgroundTransparency = 1
		row.Parent = grid
		local name = Instance.new("TextLabel")
		name.Size = UDim2.new(nameWidth, -4, 0.6, 0)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Parent = row
		UIStyle.text(name)
		name.Text = def.DisplayName
		local rarity = Instance.new("TextLabel")
		rarity.Position = UDim2.fromScale(0, 0.6)
		rarity.Size = UDim2.new(nameWidth, -4, 0.4, 0)
		rarity.TextXAlignment = Enum.TextXAlignment.Left
		rarity.Parent = row
		UIStyle.rarity(rarity, def.Rarity)
		for i, mutation in MutationConfig.List do
			local cell = Instance.new("TextLabel")
			cell.Position = UDim2.new(nameWidth + (i - 1) * cellWidth, 3, 0, 2)
			cell.Size = UDim2.new(cellWidth, -6, 1, -4)
			cell.Parent = row
			UIStyle.text(cell)
			cell.BackgroundTransparency = 0
			UIStyle.border(cell, 2)
			cells[species .. ":" .. mutation.Key] = cell
		end
	end

	toast = Instance.new("TextLabel")
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, 214)
	toast.Size = UDim2.new(0.9, 0, 0, 30)
	toast.Visible = false
	toast.Parent = gui
	UIStyle.text(toast, Color3.fromRGB(255, 230, 120))
	local toastConstraint = Instance.new("UISizeConstraint")
	toastConstraint.MaxSize = Vector2.new(600, 30)
	toastConstraint.Parent = toast

	button.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
end

function IndexController.init(initial: Types.InitialState)
	for key in AnimalConfig.Animals do
		table.insert(speciesOrder, key)
	end
	-- Common first, Secret last; within a tier, lowest income first.
	table.sort(speciesOrder, function(a, b)
		local da, db = AnimalConfig.Animals[a], AnimalConfig.Animals[b]
		local ra, rb = RarityConfig.ByKey[da.Rarity].Order, RarityConfig.ByKey[db.Rarity].Order
		if ra ~= rb then
			return ra < rb
		end
		return da.Income < db.Income
	end)
	index = initial.Index or {}
	buildGui()
	refresh()

	Remotes.event("IndexChanged").OnClientEvent:Connect(function(newIndex: { [string]: boolean }, newKey: string?)
		index = newIndex
		refresh()
		if newKey then
			local species, mutationKey = string.match(newKey, "^(%w+):(%w+)$")
			local def = species and AnimalConfig.Animals[species]
			if def and mutationKey then
				local name = if mutationKey == MutationConfig.Default
					then def.DisplayName
					else `{mutationKey} {def.DisplayName}`
				showToast(`NEW! {name} added to your index (bonus cash!)`)
			end
		end
	end)
end

return IndexController
