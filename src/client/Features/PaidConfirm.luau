-- Asks before an animal bought with Robux is sold or swapped out of a pen (server: ZooService
-- askPaid). The server sends (token, text) on "PaidSellConfirm"; SELL sends the token back
-- accepted, KEEP IT (or closing) sends it back refused. Nothing is sold without SELL.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Modals = require(script.Parent.Parent.UI.Modals)

local player = Players.LocalPlayer

local PaidConfirm = {}

local remote: RemoteEvent
local panel: Frame
local dim: TextButton
local message: TextLabel
local token: number? = nil

local function answer(accepted: boolean)
	panel.Visible = false
	dim.Visible = false
	if token then
		remote:FireServer(token, accepted)
		token = nil
	end
end

local function button(text: string, color: Color3, x: number): TextButton
	local created = Instance.new("TextButton")
	created.AnchorPoint = Vector2.new(0.5, 1)
	created.Position = UDim2.new(x, 0, 1, -12)
	created.Size = UDim2.new(0.5, -18, 0, 40)
	created.BackgroundColor3 = color
	created.Text = text
	created.AutoButtonColor = true
	created.ZIndex = 6
	created.Parent = panel
	UIStyle.text(created, Color3.new(1, 1, 1), Color3.fromRGB(20, 22, 30), 1.5)
	UIStyle.border(created, 2)
	return created
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PaidConfirm"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 40
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	dim = Modals.dim(gui, function()
		answer(false)
	end)
	Modals.bind("PaidConfirm", function()
		answer(false)
	end)

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0.9, 0, 0, 170)
	panel.BackgroundColor3 = UIStyle.Colors.Panel
	panel.Visible = false
	panel.ZIndex = 5
	panel.Parent = gui
	UIStyle.border(panel, 2)
	local fit = Instance.new("UISizeConstraint")
	fit.MaxSize = Vector2.new(420, 170)
	fit.Parent = panel

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(14, 10)
	title.Size = UDim2.new(1, -28, 0, 30)
	title.Text = "Bought with Robux"
	title.ZIndex = 6
	title.Parent = panel
	UIStyle.text(title, Color3.fromRGB(255, 220, 140), Color3.fromRGB(20, 22, 30), 1.5)

	message = Instance.new("TextLabel")
	message.Position = UDim2.fromOffset(14, 44)
	message.Size = UDim2.new(1, -28, 0, 60)
	message.TextWrapped = true
	message.ZIndex = 6
	message.Parent = panel
	UIStyle.text(message, Color3.fromRGB(235, 238, 245), Color3.fromRGB(20, 22, 30), 1)
	message.TextScaled = false
	message.TextSize = 18

	local keep = button("KEEP", UIStyle.Colors.Muted, 0.25)
	keep.Position = UDim2.new(0.25, 4, 1, -12)
	local sell = button("SELL", UIStyle.Colors.Cash, 0.75)
	sell.Position = UDim2.new(0.75, -4, 1, -12)
	keep.Activated:Connect(function()
		answer(false)
	end)
	sell.Activated:Connect(function()
		answer(true)
	end)
end

local function ask(value: any, text: any)
	if typeof(value) ~= "number" or typeof(text) ~= "string" then
		return
	end
	if token then
		remote:FireServer(token, false) -- a newer question replaces an open one
	end
	token = value
	message.Text = text
	Modals.claim("PaidConfirm")
	dim.Visible = true
	panel.Visible = true
end

function PaidConfirm.init(_initial: any)
	remote = Remotes.event("PaidSellConfirm")
	build()
	remote.OnClientEvent:Connect(ask)
end

return PaidConfirm
