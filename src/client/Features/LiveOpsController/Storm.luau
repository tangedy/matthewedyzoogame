-- Mud Storm on the client. The server owns the storm: MudStormActive turns the sky and the
-- rain on and off. The countdown sits in the shared top-bar counter, not a second banner.
-- Hitting 0:00 locally does not end the sky; the next replicated MudStormActive does.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local Storm = {}

local FADE = TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local EVENT_SCALE = 1.5 -- playtesters missed the storm splash at the old size

local folder: Instance
local topGui: ScreenGui

local active = false
local grade: ColorCorrectionEffect? = nil
local saved: { [Instance]: { [string]: any } }? = nil -- lighting values from before the storm
local fadeToken = 0
local rain: Part? = nil
local rainConnection: RBXScriptConnection? = nil
local function playSound(id: string, volume: number)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
end

-- Lighting ------------------------------------------------------------------------------

local function remember(instance: Instance, props: { string })
	if not saved then
		return
	end
	local values = {}
	for _, prop in props do
		values[prop] = (instance :: any)[prop]
	end
	saved[instance] = values
end

local function tintOn()
	fadeToken += 1
	if not saved then
		saved = {}
		remember(Lighting, { "OutdoorAmbient", "Ambient", "Brightness" })
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		if atmosphere then
			remember(atmosphere, { "Color", "Decay", "Density", "Haze" })
		end
	end
	if not grade then
		local effect = Instance.new("ColorCorrectionEffect")
		effect.Name = "LiveOpsStormGrade"
		effect.Parent = Lighting
		grade = effect
	end
	TweenService:Create(grade :: ColorCorrectionEffect, FADE, {
		TintColor = Color3.fromRGB(255, 205, 160),
		Saturation = -0.2,
		Brightness = -0.06,
		Contrast = 0.05,
	}):Play()
	TweenService:Create(Lighting, FADE, {
		OutdoorAmbient = Color3.fromRGB(150, 115, 85),
		Ambient = Color3.fromRGB(120, 95, 75),
		Brightness = 1.5,
	}):Play()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere and saved and saved[atmosphere] then
		TweenService:Create(atmosphere, FADE, {
			Color = Color3.fromRGB(175, 125, 75),
			Decay = Color3.fromRGB(125, 80, 40),
			Density = 0.42,
			Haze = 2.5,
		}):Play()
	end
end

local function tintOff()
	fadeToken += 1
	local token = fadeToken
	if saved then
		for instance, values in saved do
			if instance.Parent then
				TweenService:Create(instance, FADE, values):Play()
			end
		end
	end
	local effect = grade
	if effect then
		TweenService:Create(effect, FADE, {
			TintColor = Color3.new(1, 1, 1),
			Saturation = 0,
			Brightness = 0,
			Contrast = 0,
		}):Play()
	end
	task.delay(FADE.Time + 0.1, function()
		if token ~= fadeToken then
			return -- a new storm started while fading out; keep the saved originals
		end
		saved = nil
		if grade then
			grade:Destroy()
			grade = nil
		end
	end)
end

-- Mud rain -----------------------------------------------------------------------------

local function rainOn()
	if rain then
		return
	end
	local part = Instance.new("Part")
	part.Name = "LiveOpsMudRain"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(80, 1, 80)
	local emitter = Instance.new("ParticleEmitter")
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Rate = 220
	emitter.Speed = NumberRange.new(45, 60)
	emitter.Lifetime = NumberRange.new(1.2, 1.6)
	emitter.Acceleration = Vector3.new(0, -20, 0)
	emitter.SpreadAngle = Vector2.new(6, 6)
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Size = NumberSequence.new(0.22)
	emitter.Squash = NumberSequence.new(1.5) -- stretched into drops
	emitter.Color = ColorSequence.new(Color3.fromRGB(115, 75, 40), Color3.fromRGB(150, 100, 55))
	emitter.Transparency = NumberSequence.new(0.15)
	emitter.LightInfluence = 1
	emitter.Parent = part
	part.Parent = Workspace.CurrentCamera or Workspace
	rain = part
	rainConnection = RunService.RenderStepped:Connect(function()
		local camera = Workspace.CurrentCamera
		if camera then
			part.CFrame = CFrame.new(camera.CFrame.Position + Vector3.new(0, 25, 0))
		end
	end)
end

local function rainOff()
	local part = rain
	rain = nil
	if rainConnection then
		rainConnection:Disconnect()
		rainConnection = nil
	end
	if part then
		local emitter = part:FindFirstChildOfClass("ParticleEmitter")
		if emitter then
			emitter.Enabled = false -- let the last drops land
		end
		task.delay(2, function()
			part:Destroy()
		end)
	end
end

-- Big "MUD STORM!" splash when a storm begins (or is already raging when you join).
local function splash()
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.4)
	frame.Size = UDim2.new(0.9 / EVENT_SCALE, 0, 0, 110) -- the scale below brings it back to 0.9 of the screen at most
	frame.BackgroundTransparency = 1
	frame.Parent = topGui
	local fit = Instance.new("UISizeConstraint")
	fit.MaxSize = Vector2.new(620, 110)
	fit.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Scale = 0.7
	scale.Parent = frame
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 70)
	title.Text = "Mud Storm!"
	title.Parent = frame
	UIStyle.text(title, Color3.fromRGB(255, 190, 90), Color3.fromRGB(60, 30, 10), 2.5)
	local sub = Instance.new("TextLabel")
	sub.Position = UDim2.fromOffset(0, 72)
	sub.Size = UDim2.new(1, 0, 0, 30)
	sub.Text = "Rare animals & mutations x3!"
	sub.Parent = frame
	UIStyle.text(sub, Color3.new(1, 1, 1), nil, 1.5)
	-- A little under full size and eased in, like the other banners.
	TweenService
		:Create(
			scale,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 0.8 * EVENT_SCALE }
		)
		:Play()
	task.delay(3, function()
		local tween = TweenService:Create(
			scale,
			TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Scale = 0 }
		)
		tween.Completed:Once(function()
			frame:Destroy()
		end)
		tween:Play()
	end)
end

-- State --------------------------------------------------------------------------------

local function apply()
	local nowActive = folder:GetAttribute("MudStormActive") == true
	if nowActive == active then
		return
	end
	active = nowActive
	if active then
		tintOn()
		rainOn()
		playSound("rbxasset://sounds/impact_water.mp3", 0.8)
		splash()
	else
		tintOff()
		rainOff()
	end
end

function Storm.isActive(): boolean
	return active
end

function Storm.start(gui: ScreenGui)
	topGui = gui
	folder = ReplicatedStorage:WaitForChild("LiveOpsState")
	folder:GetAttributeChangedSignal("MudStormActive"):Connect(apply)
	apply()

	local nextRefresh = 0
	RunService.Heartbeat:Connect(function()
		local t = os.clock()
		if t >= nextRefresh then
			nextRefresh = t + 0.25
			apply() -- sky follows the replicated flag, even if the change signal was missed
		end
	end)
end

return Storm
