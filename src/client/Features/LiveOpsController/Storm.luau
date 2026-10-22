-- Mud Storm on the client. Reads the server's storm state from the attributes on
-- ReplicatedStorage.LiveOpsState and shows:
--   * a banner in the free centre of the top bar: "MUD STORM! 12:34" while one is active,
--     or "NEXT MUD STORM IN 42m 10s" when the next one is less than an hour away,
--   * murky brown-orange lighting (tweened in, and restored to what it was afterwards),
--   * mud "rain" falling around the camera.

local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local Storm = {}

local STORM_COLORS = ColorSequence.new(Color3.fromRGB(230, 150, 60), Color3.fromRGB(120, 70, 30))
local TEASER_COLORS = ColorSequence.new(Color3.fromRGB(80, 70, 60), Color3.fromRGB(40, 35, 30))
local FADE = TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

local folder: Instance
local topGui: ScreenGui
local banner: Frame
local bannerText: TextLabel
local bannerScale: UIScale
local bannerGradient: UIGradient

local active = false
local grade: ColorCorrectionEffect? = nil
local saved: { [Instance]: { [string]: any } }? = nil -- lighting values from before the storm
local fadeToken = 0
local rain: Part? = nil
local rainConnection: RBXScriptConnection? = nil
local popUntil = 0

local function formatClock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function formatDuration(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s >= 3600 then
		return `{s // 3600}h {(s % 3600) // 60}m`
	end
	return `{s // 60}m {s % 60}s`
end

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

local function buildBanner(gui: ScreenGui)
	banner = Instance.new("Frame")
	banner.Name = "StormBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Size = UDim2.fromOffset(270, 42)
	banner.BackgroundColor3 = Color3.new(1, 1, 1)
	banner.Visible = false
	banner.Parent = gui
	UIStyle.border(banner, 3)
	bannerGradient = Instance.new("UIGradient")
	bannerGradient.Rotation = 90
	bannerGradient.Color = STORM_COLORS
	bannerGradient.Parent = banner
	bannerScale = Instance.new("UIScale")
	bannerScale.Parent = banner
	bannerText = Instance.new("TextLabel")
	bannerText.AnchorPoint = Vector2.new(0.5, 0.5)
	bannerText.Position = UDim2.fromScale(0.5, 0.5)
	bannerText.Size = UDim2.new(1, -16, 1, -8)
	bannerText.Parent = banner
	UIStyle.text(bannerText)

	-- Centre it in the top bar strip (above the core HUD's wash card).
	local function place()
		local inset = GuiService:GetGuiInset()
		local height = if inset.Y >= 30 then math.clamp(inset.Y - 8, 30, 44) else 40
		banner.Size = UDim2.fromOffset(270, height)
		banner.Position = UDim2.fromOffset(0, math.max(4, (inset.Y - height) / 2)) + UDim2.fromScale(0.5, 0)
	end
	place()
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(place)
	end
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
	frame.Size = UDim2.new(0.9, 0, 0, 110)
	frame.BackgroundTransparency = 1
	frame.Parent = topGui
	local fit = Instance.new("UISizeConstraint")
	fit.MaxSize = Vector2.new(620, 110)
	fit.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = frame
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 70)
	title.Text = "MUD STORM!"
	title.Parent = frame
	UIStyle.text(title, Color3.fromRGB(255, 190, 90), Color3.fromRGB(60, 30, 10), 5)
	local sub = Instance.new("TextLabel")
	sub.Position = UDim2.fromOffset(0, 72)
	sub.Size = UDim2.new(1, 0, 0, 30)
	sub.Text = "Rare animals & mutations x3!"
	sub.Parent = frame
	UIStyle.text(sub, Color3.new(1, 1, 1), nil, 3)
	TweenService:Create(scale, TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
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
		bannerScale.Scale = 0.4
		popUntil = os.clock() + 0.5
		TweenService:Create(bannerScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	else
		tintOff()
		rainOff()
	end
end

local function numberAttribute(name: string): number
	local value = folder:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function refreshBanner()
	local now = Workspace:GetServerTimeNow()
	if active then
		banner.Visible = true
		bannerGradient.Color = STORM_COLORS
		bannerText.Text = `MUD STORM! {formatClock(numberAttribute("MudStormEndsAt") - now)}`
		bannerText.TextColor3 = Color3.new(1, 1, 1)
		return
	end
	local untilNext = numberAttribute("MudStormNextAt") - now
	if untilNext > 0 and untilNext < LiveOpsConfig.MudStorm.TeaserSeconds then
		banner.Visible = true
		bannerGradient.Color = TEASER_COLORS
		bannerText.Text = `NEXT MUD STORM IN {formatDuration(untilNext)}`
		bannerText.TextColor3 = Color3.fromRGB(255, 200, 120)
	else
		banner.Visible = false
	end
end

function Storm.isActive(): boolean
	return active
end

function Storm.start(gui: ScreenGui)
	topGui = gui
	buildBanner(gui)
	folder = ReplicatedStorage:WaitForChild("LiveOpsState")
	folder:GetAttributeChangedSignal("MudStormActive"):Connect(apply)
	apply()
	refreshBanner()

	local nextRefresh = 0
	RunService.Heartbeat:Connect(function()
		local t = os.clock()
		if active and t > popUntil then
			bannerScale.Scale = 1 + math.sin(t * 5) * 0.04 -- gentle throb while the storm rages
		end
		if t >= nextRefresh then
			nextRefresh = t + 0.25
			refreshBanner()
		end
	end)
end

return Storm
