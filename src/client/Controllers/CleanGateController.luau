-- When the animal in the bay needs more clean power than the hose has (Super Soap included),
-- spraying does nothing. This offers the two ways forward: send it away, or pay to clean it now.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Modals = require(script.Parent.Parent.UI.Modals)

local player = Players.LocalPlayer

local CleanGateController = {}

local tier = 1
local soapEndsAt = 0
local bay: Types.BaySnapshot? = nil
local nextClickAt = 0
local cleanKey = "CleanNow"

local panel: Frame
local title: TextLabel
local body: TextLabel
local cleanButton: TextButton
local marker: BillboardGui

local function hosePower(): number
	local tool = ToolConfig[tier] or ToolConfig[1]
	local boosted = soapEndsAt > Workspace:GetServerTimeNow()
	local mult = if boosted then MonetizationConfig.SuperSoap.PowerMultiplier else 1
	return tool.CleaningPower * mult
end

local function animalHead(): BasePart?
	if not bay or not bay.BayName then
		return nil
	end
	local bays = Workspace:FindFirstChild("WashBays")
	local model = bays and bays:FindFirstChild(bay.BayName)
	local animal = model and model:FindFirstChild("Animal")
	local head = animal and animal:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

local function soapOnly(): boolean
	local species = bay and bay.Species
	local def = if typeof(species) == "string" then AnimalConfig.Animals[species] else nil
	return def ~= nil and def.RequiresSoap == true
end

local function refresh()
	local rarityKey = bay and bay.Rarity
	local soaped = soapEndsAt > Workspace:GetServerTimeNow()
	local needsSoap = soapOnly() and not soaped
	local blocked = bay ~= nil
		and bay.State == "Washing"
		and typeof(rarityKey) == "string"
		and (not CleanPower.canClean(hosePower(), rarityKey) or needsSoap)
	player:SetAttribute("CleanBlocked", blocked)
	panel.Visible = blocked
	local head = if blocked then animalHead() else nil
	marker.Adornee = head
	marker.Enabled = head ~= nil
	if head then
		UIStyle.overhead(marker, head, UIStyle.Overhead.Callout)
	end
	if not blocked or typeof(rarityKey) ~= "string" then
		return
	end
	local rarity = RarityConfig.ByKey[rarityKey]
	local name = if rarity then rarity.DisplayName else rarityKey
	title.Text = `{name} is too dirty!`
	title.TextColor3 = if not rarity
			or rarity.Key == "Secret"
			or rarity.Rainbow
		then Color3.new(1, 1, 1)
		else rarity.Color
	if needsSoap and CleanPower.canClean(hosePower(), rarityKey) then
		cleanKey = MonetizationConfig.ProductsByKey.CleanNow.Key
		local offer = MonetizationConfig.ProductsByKey.CleanNow
		title.Text = `{bay and bay.AnimalName or "This animal"} needs Super Soap!`
		cleanButton.Text = `Clean Now · {offer.Robux} R$`
		body.Text =
			"Magic mud: no hose gets it off alone. Turn on Super Soap from the shop, let it go, or clean it now."
		return
	end
	local have = hosePower()
	local need = CleanPower.required(rarityKey)
	local hose = CleanPower.hoseName(rarityKey)
	local steps = CleanPower.stepsAbove(have, rarityKey) or 0
	local offer = MonetizationConfig.productForCleanSteps(steps) or MonetizationConfig.ProductsByKey.CleanNow
	cleanKey = offer.Key
	cleanButton.Text = `Clean Now · {offer.Robux} R$`
	local powerLine = `Needs {CleanPower.format(need)} clean power. Your hose has {CleanPower.format(have)}.`
	local above = if steps == 1 then "1 rarity above" else `{steps} rarities above`
	local priceLine = if steps > 0 then `\n{above} the next one you can't wash, so this is {offer.Robux} R$.` else ""
	if hose then
		body.Text = `{powerLine}\nThe {hose} can wash this. Let it go, or clean it now.{priceLine}`
	else
		body.Text = `{powerLine}\nNo hose can wash this yet. Let it go, or clean it now.{priceLine}`
	end
end

local function button(text: string, color: Color3, textColor: Color3, x: number): TextButton
	local created = Instance.new("TextButton")
	created.AnchorPoint = Vector2.new(0.5, 1)
	created.Position = UDim2.new(x, 0, 1, -12)
	created.Size = UDim2.fromOffset(188, 42)
	created.BackgroundColor3 = color
	created.Text = text
	created.AutoButtonColor = true
	created.Parent = panel
	UIStyle.text(created, textColor, nil, 2.5)
	UIStyle.border(created, 3)
	return created
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "CleanGate"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	gui.Parent = player:WaitForChild("PlayerGui")

	panel = Instance.new("Frame")
	panel.Name = "Prompt"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -16)
	panel.Size = UDim2.fromOffset(440, 196)
	panel.BackgroundColor3 = Color3.fromRGB(28, 32, 48)
	panel.Visible = false
	panel.Parent = gui
	Modals.holdCursor(panel)
	UIStyle.border(panel, 4)

	title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 10)
	title.Size = UDim2.new(1, -32, 0, 36)
	title.Parent = panel
	UIStyle.text(title, Color3.new(1, 1, 1), nil, 3)

	body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(16, 48)
	body.Size = UDim2.new(1, -32, 0, 78)
	body.TextWrapped = true
	body.Parent = panel
	UIStyle.text(body, Color3.fromRGB(230, 236, 255), nil, 2)
	body.TextScaled = false
	body.TextSize = 18

	local leave = button("Let it go", Color3.fromRGB(88, 98, 120), Color3.new(1, 1, 1), 0.27)
	cleanButton = button("Clean Now", Color3.fromRGB(255, 196, 48), Color3.fromRGB(40, 28, 8), 0.73)
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

	marker = Instance.new("BillboardGui")
	marker.Name = "TooDirty"
	marker.Size = UDim2.fromOffset(180, 48)
	marker.AlwaysOnTop = true
	marker.Enabled = false
	marker.ResetOnSpawn = false
	marker.Parent = player:WaitForChild("PlayerGui")
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "TOO DIRTY!"
	label.Parent = marker
	UIStyle.text(label, Color3.fromRGB(255, 80, 80), nil, 3)
end

function CleanGateController.init(initial: Types.InitialState)
	tier = initial.ToolTier
	build()
	bay = initial.Bay
	refresh()

	Remotes.event("BayStateChanged").OnClientEvent:Connect(function(snapshot: Types.BaySnapshot)
		bay = snapshot
		refresh()
	end)
	Remotes.event("ToolTierChanged").OnClientEvent:Connect(function(value: number)
		tier = value
		refresh()
	end)
	Remotes.event("MonetizationState").OnClientEvent:Connect(function(state)
		if typeof(state) == "table" and typeof(state.SoapEndsAt) == "number" then
			soapEndsAt = state.SoapEndsAt
			refresh()
		end
	end)
end

return CleanGateController
