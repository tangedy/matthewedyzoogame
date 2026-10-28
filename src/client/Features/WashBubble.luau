-- A freshly washed animal says something happy in a little chat bubble: a heart, a grin, or
-- its own noise ("meow 😺"). Every client draws it, so the whole server sees the wash.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AnimalSounds = require(ReplicatedStorage.Shared.AnimalSounds)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local WashBubble = {}

local SHOW_SECONDS = 2.4
local BUBBLE_SIZE = Vector2.new(150, 60)
local BUBBLE_COLOR = Color3.new(1, 1, 1)
local TEXT_COLOR = Color3.fromRGB(40, 40, 55)

local GENERIC =
	{ "❤️", "😊", "🥰", "💖", "✨😄✨", "😍", "💕💕", "yay! 😁", "so fresh ✨", "🧼😌🧼" }
local NOISES: { [string]: { string } } = {
	Cat = { "meow 😺", "purr ❤️" },
	Dog = { "woof! 🐶", "arf arf 💖" },
	Pig = { "oink 🐷", "oink oink 💕" },
	Cow = { "moo 💕", "mooo 😊" },
	Duck = { "quack 🦆", "quack! 💛" },
	Chicken = { "bawk! 🐔", "cluck ❤️" },
	Sheep = { "baa ✨", "baaa 🥰" },
	Goat = { "meh 😌", "bleat! 💖" },
	Horse = { "neigh! 💖" },
	Donkey = { "hee-haw! 😁" },
	Rabbit = { "*nose wiggle* 🐰" },
	Lion = { "rawr ❤️" },
	Penguin = { "noot noot 🐧" },
	Fox = { "yip! 🦊" },
}

local random = Random.new()

local function pick(list: { string }): string
	return list[random:NextInteger(1, #list)]
end

local function lineFor(model: Model): string
	local species = model:GetAttribute("AnimalKey")
	local noises = typeof(species) == "string" and NOISES[species] or nil
	if noises and random:NextNumber() < 0.6 then
		return pick(noises)
	end
	return pick(GENERIC)
end

local function findWashed(jobId: string): Model?
	local bays = Workspace:FindFirstChild("WashBays")
	if not bays then
		return nil
	end
	for _, model in bays:GetDescendants() do
		if model:IsA("Model") and model:GetAttribute("JobId") == jobId then
			return model
		end
	end
	return nil
end

local function show(model: Model)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local board = Instance.new("BillboardGui")
	board.Name = "WashBubble"
	board.Size = UDim2.fromOffset(BUBBLE_SIZE.X, BUBBLE_SIZE.Y)
	board.MaxDistance = 2000
	board.ResetOnSpawn = false
	board.Adornee = head
	UIStyle.overhead(board, head, UIStyle.Overhead.Bubble)

	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = board

	local bubble = Instance.new("Frame")
	bubble.AnchorPoint = Vector2.new(0.5, 0)
	bubble.Position = UDim2.fromScale(0.5, 0)
	bubble.Size = UDim2.new(1, 0, 1, -12)
	bubble.BackgroundColor3 = BUBBLE_COLOR
	bubble.Parent = board
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = bubble
	local outline = Instance.new("UIStroke")
	outline.Color = Color3.fromRGB(60, 60, 80)
	outline.Thickness = 2.5
	outline.Parent = bubble

	-- The little tail pointing down at the animal.
	local tail = Instance.new("Frame")
	tail.AnchorPoint = Vector2.new(0.5, 0.5)
	tail.Position = UDim2.new(0.5, 0, 1, -13)
	tail.Size = UDim2.fromOffset(14, 14)
	tail.Rotation = 45
	tail.BackgroundColor3 = BUBBLE_COLOR
	tail.BorderSizePixel = 0
	tail.ZIndex = 0
	tail.Parent = board
	local tailOutline = Instance.new("UIStroke")
	tailOutline.Color = outline.Color
	tailOutline.Thickness = 2.5
	tailOutline.Parent = tail

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(10, 6)
	label.Size = UDim2.new(1, -20, 1, -12)
	label.Font = UIStyle.Font
	label.TextScaled = true
	label.TextColor3 = TEXT_COLOR
	label.Text = lineFor(model)
	label.ZIndex = 2
	label.Parent = bubble

	-- Directly under PlayerGui: a BillboardGui nested inside a ScreenGui is never drawn.
	board.Parent = player:WaitForChild("PlayerGui")
	local species = model:GetAttribute("AnimalKey")
	if typeof(species) == "string" then
		AnimalSounds.play(species, head)
	end
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	task.delay(SHOW_SECONDS, function()
		local out = TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Scale = 0,
		})
		out:Play()
		out.Completed:Wait()
		board:Destroy()
	end)
end

function WashBubble.init(_initial: Types.InitialState)
	Remotes.event("WashCelebrated").OnClientEvent:Connect(function(jobId: string)
		local model = findWashed(jobId)
		if not model then
			return
		end
		-- After the Squeaky clean! banner, which uses the same row above the nameplate.
		task.delay(GameConfig.CelebrationDuration, function()
			if model.Parent then
				show(model)
			end
		end)
	end)
end

return WashBubble
