-- Loading screen: runs from ReplicatedFirst before anything else replicates, so it builds its
-- own UI instead of requiring UIStyle (the colours and font below are copied from there).
-- Stays up until ClientBootstrap sets the ProfileReady attribute, or MAX_WAIT seconds pass,
-- then fades out.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

local MAX_WAIT = 20
local FADE_TIME = 0.6

local FONT = Enum.Font.LuckiestGuy -- UIStyle.Font
local GREEN = Color3.fromRGB(56, 170, 90) -- UIStyle.Colors.Cash
local BLUE = Color3.fromRGB(58, 118, 196) -- UIStyle.Colors.Action

local player = Players.LocalPlayer

local gui = Instance.new("ScreenGui")
gui.Name = "LoadingScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local background = Instance.new("Frame")
background.Size = UDim2.fromScale(1, 1)
background.BackgroundColor3 = Color3.new(1, 1, 1)
background.BorderSizePixel = 0
background.Parent = gui

local gradient = Instance.new("UIGradient")
gradient.Color = ColorSequence.new(GREEN, BLUE)
gradient.Rotation = 90 -- green on top, blue below
gradient.Parent = background

-- Chunky white text with a thick black outline, like UIStyle.text.
local function label(text: string, position: UDim2, size: UDim2, thickness: number): (TextLabel, UIStroke)
	local textLabel = Instance.new("TextLabel")
	textLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	textLabel.Position = position
	textLabel.Size = size
	textLabel.BackgroundTransparency = 1
	textLabel.Font = FONT
	textLabel.Text = text
	textLabel.TextColor3 = Color3.new(1, 1, 1)
	textLabel.TextScaled = true
	textLabel.Parent = background
	local outline = Instance.new("UIStroke")
	outline.Color = Color3.new(0, 0, 0)
	outline.Thickness = thickness
	outline.LineJoinMode = Enum.LineJoinMode.Round
	outline.Parent = textLabel
	return textLabel, outline
end

local title, titleOutline = label("Wash the Farm Animals", UDim2.fromScale(0.5, 0.42), UDim2.fromScale(0.8, 0.16), 4)
local status, statusOutline = label("Loading", UDim2.fromScale(0.5, 0.58), UDim2.fromScale(0.4, 0.06), 2.5)

gui.Parent = player:WaitForChild("PlayerGui")
ReplicatedFirst:RemoveDefaultLoadingScreen()

local deadline = os.clock() + MAX_WAIT
local dots = 0
while not player:GetAttribute("ProfileReady") and os.clock() < deadline do
	dots = (dots + 1) % 4
	status.Text = "Loading" .. string.rep(".", dots)
	task.wait(0.4)
end

local fade = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
TweenService:Create(background, fade, { BackgroundTransparency = 1 }):Play()
for _, target in { title, status } do
	TweenService:Create(target, fade, { TextTransparency = 1 }):Play()
end
for _, target in { titleOutline, statusOutline } do
	TweenService:Create(target, fade, { Transparency = 1 }):Play()
end
task.wait(FADE_TIME)
gui:Destroy()
