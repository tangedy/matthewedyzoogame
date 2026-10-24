-- Owner-only live-ops popups:
--   * WELCOME BACK: a bouncy panel saying what the zoo earned while away. The cash is already
--     on the pen pads (the server put it there); COLLECT just closes the panel.
--   * DAILY DIRTY ANIMAL: a big banner when today's guaranteed Rare+ animal walks in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Janitor = require(ReplicatedStorage.Shared.Janitor)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Modals = require(script.Parent.Parent.Parent.UI.Modals)

local Popups = {}

local BOUNCE = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SHRINK = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In)
-- Banners land a little under full size and ease in, so they read without shouting.
local BANNER_SCALE = 0.85
local BANNER_IN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local hudGui: ScreenGui
local modalGui: ScreenGui
local welcomeOpen = false
local welcomeCash: TextLabel? = nil
local welcomeDouble: TextButton? = nil
local dailyToken = 0

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

local function textLabel(parent: Instance, props: { [string]: any }, color: Color3?, stroke: number?): TextLabel
	local l = Instance.new("TextLabel")
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	UIStyle.text(l, color, nil, stroke)
	return l
end

local function formatAway(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local h = s // 3600
	local m = (s % 3600) // 60
	if h > 0 then
		return if m > 0 then `{h}h {m}m` else `{h}h`
	end
	return `{math.max(1, m)}m`
end

function Popups.welcomeBack(amount: any, seconds: any)
	if typeof(amount) ~= "number" or amount ~= amount or amount < 1 or welcomeOpen then
		return
	end
	welcomeOpen = true
	local away = if typeof(seconds) == "number" and seconds == seconds then seconds else 0

	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 1
	dim.Active = true -- swallow taps behind the panel
	dim.Parent = modalGui
	Modals.holdCursor(dim)
	TweenService:Create(dim, TweenInfo.new(0.3), { BackgroundTransparency = 0.45 }):Play()

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0.92, 0, 0, 280)
	panel.BackgroundColor3 = Color3.new(1, 1, 1)
	panel.Parent = dim
	UIStyle.border(panel, 5)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(120, 190, 255), Color3.fromRGB(60, 90, 200))
	gradient.Parent = panel
	local fit = Instance.new("UISizeConstraint") -- shrinks on narrow phones
	fit.MaxSize = Vector2.new(420, 280)
	fit.Parent = panel
	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = panel

	local title = textLabel(panel, {
		Position = UDim2.fromOffset(12, 10),
		Size = UDim2.new(1, -24, 0, 50),
		Text = "WELCOME BACK!",
	}, Color3.fromRGB(255, 230, 120), 4)
	local shine = Instance.new("UIGradient")
	shine.Rotation = 90
	shine.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(255, 200, 60))
	shine.Parent = title
	textLabel(panel, {
		Position = UDim2.fromOffset(16, 64),
		Size = UDim2.new(1, -32, 0, 24),
		Text = `Your farm earned while you were away ({formatAway(away)}):`,
	})
	local cash = textLabel(panel, {
		Position = UDim2.fromOffset(16, 88),
		Size = UDim2.new(1, -32, 0, 48),
		Text = UIStyle.formatMoney(amount),
	}, UIStyle.CashColor, 4)
	welcomeCash = cash
	textLabel(panel, {
		Position = UDim2.fromOffset(16, 140),
		Size = UDim2.new(1, -32, 0, 36),
		Text = "It's waiting on your pen pads.",
		TextWrapped = true,
	}, Color3.fromRGB(220, 235, 255), 2)

	local product = MonetizationConfig.ProductsByKey.OfflineDouble
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0, 1)
	button.Position = UDim2.new(0, 16, 1, -14)
	button.Size = UDim2.new(0.46, -8, 0, 50)
	button.BackgroundColor3 = Color3.fromRGB(80, 220, 90)
	button.Text = "COLLECT"
	button.Parent = panel
	UIStyle.text(button, Color3.new(1, 1, 1), nil, 3)
	UIStyle.border(button, 4)
	local buttonScale = Instance.new("UIScale")
	buttonScale.Parent = button

	local doubleButton = Instance.new("TextButton")
	doubleButton.AnchorPoint = Vector2.new(1, 1)
	doubleButton.Position = UDim2.new(1, -16, 1, -14)
	doubleButton.Size = UDim2.new(0.46, -8, 0, 50)
	doubleButton.BackgroundColor3 = Color3.fromRGB(255, 170, 40)
	doubleButton.Text = if product then `2X FOR {product.Robux} R$` else "2X"
	doubleButton.Parent = panel
	UIStyle.text(doubleButton, Color3.new(1, 1, 1), nil, 3)
	UIStyle.border(doubleButton, 4)
	welcomeDouble = doubleButton

	local janitor = Janitor.new()

	TweenService:Create(scale, BOUNCE, { Scale = 1 }):Play()
	playSound("rbxasset://sounds/electronicpingshort.wav", 0.7)
	-- The cash counts up for a bit of juice.
	janitor:Add(
		task.spawn(function()
			local steps = 20
			for i = 1, steps do
				if not cash.Parent then
					return
				end
				cash.Text = UIStyle.formatMoney(amount * i / steps)
				task.wait(0.03)
			end
		end),
		true
	)
	janitor:Add(
		task.spawn(function()
			while button.Parent do
				TweenService:Create(buttonScale, TweenInfo.new(0.5, Enum.EasingStyle.Sine), { Scale = 1.06 }):Play()
				task.wait(0.5)
				TweenService:Create(buttonScale, TweenInfo.new(0.5, Enum.EasingStyle.Sine), { Scale = 1 }):Play()
				task.wait(0.5)
			end
		end),
		true
	)

	doubleButton.Activated:Connect(function()
		if not product or not doubleButton.Active then
			return
		end
		playSound("rbxasset://sounds/electronicpingshort.wav", 0.5)
		Remotes.event("MonetizationBuy"):FireServer(product.Key)
	end)

	local closing = false
	local function close()
		if closing then
			return
		end
		closing = true
		playSound("rbxasset://sounds/electronicpingshort.wav", 0.5)
		TweenService:Create(dim, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		local tween = TweenService:Create(scale, SHRINK, { Scale = 0 })
		tween.Completed:Once(function()
			janitor:Cleanup()
			dim:Destroy()
			welcomeCash = nil
			welcomeDouble = nil
			welcomeOpen = false
		end)
		tween:Play()
	end
	button.Activated:Connect(close)
end

function Popups.offlineDoubled(total: any)
	if typeof(total) ~= "number" or total ~= total or not welcomeCash or not welcomeCash.Parent then
		return
	end
	welcomeCash.Text = UIStyle.formatMoney(total)
	if welcomeDouble then
		welcomeDouble.Text = "DOUBLED"
		welcomeDouble.Active = false
		welcomeDouble.AutoButtonColor = false
		welcomeDouble.BackgroundColor3 = Color3.fromRGB(120, 120, 130)
	end
end

local function showDaily(name: any, rarity: any, mutation: any, rewardMultiplier: any)
	if typeof(name) ~= "string" or typeof(rarity) ~= "string" then
		return
	end
	dailyToken += 1
	local token = dailyToken
	local old = hudGui:FindFirstChild("DailyBanner")
	if old then
		old:Destroy()
	end

	local frame = Instance.new("Frame")
	frame.Name = "DailyBanner"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, 0, 0.5, 20) -- below the wash card, over the bay
	frame.Size = UDim2.new(0.9, 0, 0, 124)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	frame.BackgroundTransparency = 0.25
	frame.Parent = hudGui
	UIStyle.border(frame, 2)
	local fit = Instance.new("UISizeConstraint")
	fit.MaxSize = Vector2.new(560, 124)
	fit.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Scale = 0.7
	scale.Parent = frame

	textLabel(frame, { Size = UDim2.new(1, 0, 0, 50), Text = "Daily Dirty Animal" }, Color3.fromRGB(255, 220, 140), 2)

	local mutationKey = if typeof(mutation) == "string" and MutationConfig.ByKey[mutation]
		then mutation
		else MutationConfig.Default
	local prefix = if mutationKey == MutationConfig.Default
		then ""
		else MutationConfig.ByKey[mutationKey].DisplayName .. " "
	textLabel(frame, { Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 0, 30), Text = prefix .. name })
	local rarityLabel =
		textLabel(frame, { Position = UDim2.new(0.5, -100, 0, 80), Size = UDim2.fromOffset(200, 20), Text = "" })
	UIStyle.rarity(rarityLabel, rarity)
	local bonus = if typeof(rewardMultiplier) == "number" and rewardMultiplier > 1
		then `EXTRA MUDDY  -  {rewardMultiplier}x WASH REWARD`
		else "EXTRA MUDDY"
	textLabel(frame, {
		Position = UDim2.fromOffset(0, 100),
		Size = UDim2.new(1, 0, 0, 18),
		Text = bonus,
	}, Color3.fromRGB(235, 225, 190), 1.5)

	playSound("rbxasset://sounds/electronicpingshort.wav", 0.5)
	TweenService:Create(scale, BANNER_IN, { Scale = BANNER_SCALE }):Play()
	task.delay(4.5, function()
		if token ~= dailyToken or not frame.Parent then
			return
		end
		local tween = TweenService:Create(scale, SHRINK, { Scale = 0 })
		tween.Completed:Once(function()
			frame:Destroy()
		end)
		tween:Play()
	end)
end

-- Once per profile, as the new-player Kaiju walks the road: the boost and how long it runs.
local function showNewPlayer(minutes: any, multiplier: any)
	if typeof(minutes) ~= "number" or typeof(multiplier) ~= "number" then
		return
	end
	dailyToken += 1
	local token = dailyToken
	local old = hudGui:FindFirstChild("DailyBanner")
	if old then
		old:Destroy()
	end

	local frame = Instance.new("Frame")
	frame.Name = "DailyBanner" -- shares the slot, so it never stacks on the daily banner
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, 0, 0.5, 20)
	frame.Size = UDim2.new(0.9, 0, 0, 124)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	frame.BackgroundTransparency = 0.25
	frame.Parent = hudGui
	UIStyle.border(frame, 2)
	local fit = Instance.new("UISizeConstraint")
	fit.MaxSize = Vector2.new(560, 124)
	fit.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Scale = 0.7
	scale.Parent = frame

	textLabel(frame, { Size = UDim2.new(1, 0, 0, 50), Text = "New Player Boost" }, Color3.fromRGB(160, 230, 170), 2)
	local rarityLabel =
		textLabel(frame, { Position = UDim2.new(0.5, -140, 0, 52), Size = UDim2.fromOffset(280, 26), Text = "" })
	UIStyle.rarity(rarityLabel, "Secret")
	rarityLabel.Text = "A Secret Kaiju walks by!"
	local times = if multiplier % 1 == 0 then tostring(multiplier) else string.format("%.1f", multiplier)
	textLabel(frame, {
		Position = UDim2.fromOffset(0, 84),
		Size = UDim2.new(1, 0, 0, 30),
		Text = `{times}x odds on every rarity for {minutes} min`,
	}, Color3.fromRGB(235, 225, 190), 1.5)

	playSound("rbxasset://sounds/impact_explosion_03.mp3", 0.35)
	playSound("rbxasset://sounds/electronicpingshort.wav", 0.5)
	TweenService:Create(scale, BANNER_IN, { Scale = BANNER_SCALE }):Play()
	task.delay(6, function()
		if token ~= dailyToken or not frame.Parent then
			return
		end
		local tween = TweenService:Create(scale, SHRINK, { Scale = 0 })
		tween.Completed:Once(function()
			frame:Destroy()
		end)
		tween:Play()
	end)
end

function Popups.start(hud: ScreenGui, modal: ScreenGui)
	hudGui = hud
	modalGui = modal
	Remotes.event("LiveOpsWelcomeBack").OnClientEvent:Connect(Popups.welcomeBack)
	Remotes.event("LiveOpsOfflineDoubled").OnClientEvent:Connect(Popups.offlineDoubled)
	Remotes.event("LiveOpsDaily").OnClientEvent:Connect(showDaily)
	Remotes.event("LiveOpsNewPlayer").OnClientEvent:Connect(showNewPlayer)
end

return Popups
