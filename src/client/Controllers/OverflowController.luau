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
	panel.Position = UDim2.new(0.5, 0, 1, -120)
	panel.Size = UDim2.fromOffset(320, 64)
	panel.BackgroundColor3 = UIStyle.PanelColor
	panel.BackgroundTransparency = 0.15
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local detail = Instance.new("TextLabel")
	detail.BackgroundTransparency = 1
	detail.Position = UDim2.fromOffset(10, 4)
	detail.Size = UDim2.new(1, -20, 0, 18)
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextScaled = false
	detail.TextSize = 14
	detail.Parent = panel
	UIStyle.text(detail, Color3.fromRGB(220, 220, 220), Color3.fromRGB(20, 20, 20), 1.5)
	detail.TextScaled = false
	detail.TextSize = 14

	local function button(text: string, x: number): TextButton
		local control = Instance.new("TextButton")
		control.Position = UDim2.new(x, 0, 1, -30)
		control.Size = UDim2.new(0.46, 0, 0, 24)
		control.BackgroundColor3 = UIStyle.Colors.Muted
		control.Text = text
		control.TextScaled = false
		control.TextSize = 14
		control.AutoButtonColor = true
		control.Parent = panel
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0, 6)
		round.Parent = control
		UIStyle.text(control, Color3.new(1, 1, 1), Color3.new(0, 0, 0), 1.5)
		control.TextScaled = false
		control.TextSize = 14
		return control
	end

	local keep = button("Keep", 0.03)
	local sell = button("Sell", 0.51)
	sell.BackgroundColor3 = UIStyle.Colors.Cash
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
		local extra = if waiting > 1 then ` ({waiting})` else ""
		detail.Text = `{payload.Label}{extra} · {UIStyle.formatMoney(value)}`
		gui.Enabled = true
	end))
end

return OverflowController
