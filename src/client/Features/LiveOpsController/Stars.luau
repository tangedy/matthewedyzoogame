-- Zoo star rating widget, just above the cash counter: "ZOO ★★★☆☆". The rating is the
-- server's (the "ZooStars" Player attribute); the widget pops and chimes when it goes up.
-- Display only, so it never blocks touches to the thumbstick.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local Stars = {}

local ATTRIBUTE = "ZooStars"
local MAX_STARS = #LiveOpsConfig.Stars.StarPoints

local label: TextLabel
local scale: UIScale
local burst: TextLabel
local shown: number? = nil

local function richText(stars: number): string
	return `<font color="#FFFFFF">ZOO </font><font color="#FFD02A">{string.rep("★", stars)}</font>`
		.. `<font color="#4A4A55">{string.rep("★", MAX_STARS - stars)}</font>`
end

local function celebrate(stars: number)
	scale.Scale = 1.6
	TweenService:Create(scale, TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxasset://sounds/electronicpingshort.wav"
	sound.Volume = 0.8
	sound.PlaybackSpeed = 1.25
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	burst.Text = `{stars} STAR ZOO!`
	burst.Visible = true
	burst.TextTransparency = 0
	burst.Position = UDim2.fromOffset(0, 0)
	local tween = TweenService:Create(burst, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(0, -34),
		TextTransparency = 1,
	})
	tween.Completed:Once(function(state)
		if state == Enum.PlaybackState.Completed then
			burst.Visible = false
		end
	end)
	tween:Play()
end

local function refresh()
	local value = player:GetAttribute(ATTRIBUTE)
	if typeof(value) ~= "number" then
		return
	end
	local stars = math.clamp(math.floor(value), 1, MAX_STARS)
	label.Text = richText(stars)
	label.Visible = true
	if shown and stars > shown then
		celebrate(stars)
	end
	shown = stars
end

function Stars.start(gui: ScreenGui)
	-- Top of the left column, just above the INDEX button (the wallet is bottom left).
	label = Instance.new("TextLabel")
	label.Name = "ZooStars"
	label.AnchorPoint = Vector2.new(0, 1)
	label.Position = UDim2.new(0, 16, 0.5, -10)
	label.Size = UDim2.fromOffset(170, 30)
	label.RichText = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Visible = false
	label.Parent = gui
	UIStyle.text(label, nil, nil, 2.5)
	scale = Instance.new("UIScale")
	scale.Parent = label

	burst = Instance.new("TextLabel")
	burst.Size = UDim2.fromScale(1, 1)
	burst.Visible = false
	burst.TextXAlignment = Enum.TextXAlignment.Left
	burst.Parent = label
	UIStyle.text(burst, Color3.fromRGB(255, 208, 42))

	player:GetAttributeChangedSignal(ATTRIBUTE):Connect(refresh)
	refresh()
end

return Stars
