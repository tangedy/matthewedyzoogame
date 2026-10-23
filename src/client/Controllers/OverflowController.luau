-- Full-cache prompt. The animal that didn't fit stays in the world. Keep puts it in the
-- player's hands so they can carry it to a pen. Auto-Sell pays them and walks it off.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Janitor = require(ReplicatedStorage.Shared.Janitor)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local OverflowController = {}

function OverflowController.init()
	local janitor = Janitor.new()
	local gui = Instance.new("ScreenGui")
	gui.Name = "OverflowPrompt"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 30
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	janitor:Add(gui)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -150)
	panel.Size = UDim2.fromOffset(420, 118)
	panel.BackgroundColor3 = UIStyle.PanelColor
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(12, 8)
	title.Size = UDim2.new(1, -24, 0, 28)
	title.Text = "Cache is full"
	title.Parent = panel
	UIStyle.text(title, Color3.new(1, 1, 1))

	local detail = Instance.new("TextLabel")
	detail.BackgroundTransparency = 1
	detail.Position = UDim2.fromOffset(12, 36)
	detail.Size = UDim2.new(1, -24, 0, 24)
	detail.Parent = panel
	UIStyle.text(detail, Color3.fromRGB(180, 220, 255))

	local function button(text: string, x: number, color: Color3): TextButton
		local control = Instance.new("TextButton")
		control.Position = UDim2.new(x, 0, 1, -46)
		control.Size = UDim2.new(0.46, 0, 0, 36)
		control.BackgroundColor3 = color
		control.Text = text
		control.AutoButtonColor = true
		control.Parent = panel
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0, 8)
		round.Parent = control
		UIStyle.text(control, Color3.new(1, 1, 1))
		return control
	end

	local keep = button("KEEP", 0.03, Color3.fromRGB(70, 150, 90))
	local sell = button("AUTO-SELL", 0.51, Color3.fromRGB(190, 90, 70))
	janitor:Add(keep.MouseButton1Click:Connect(function()
		Remotes.event("OverflowChoice"):FireServer("keep")
	end))
	janitor:Add(sell.MouseButton1Click:Connect(function()
		Remotes.event("OverflowChoice"):FireServer("sell")
	end))

	janitor:Add(Remotes.event("OverflowPrompt").OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.Label) ~= "string" then
			gui.Enabled = false
			return
		end
		local value = if typeof(payload.SellValue) == "number" then payload.SellValue else 0
		local waiting = if typeof(payload.Waiting) == "number" then payload.Waiting else 1
		local extra = if waiting > 1 then ` ({waiting} waiting)` else ""
		detail.Text = `{payload.Label}{extra}  ·  sell {UIStyle.formatMoney(value)}`
		gui.Enabled = true
	end))
end

return OverflowController
