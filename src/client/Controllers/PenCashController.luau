-- Makes the cash counter above each pen's collect pad feel rewarding: it hovers and bobs,
-- glows, counts up smoothly with a bounce every time it rises, and pops a floating "+$X"
-- with a sparkle burst. Collecting gives a bigger burst and a "COLLECTED!" pop.
--
-- The server only publishes numbers (pad attributes "Cash" and "Rate"); all of the counter's
-- text and animation lives here, on the client.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local PenCashController = {}

local ANIMATE_DISTANCE = 90 -- only animate counters this close to the camera
local BOB_HEIGHT = 0.35
local BASE_OFFSET = Vector3.new(0, 2.6, 0)

type Counter = {
	Pad: BasePart,
	Billboard: BillboardGui,
	Label: TextLabel,
	Glow: TextLabel,
	Scale: UIScale,
	Burst: ParticleEmitter,
	Shown: number,
	Target: number,
	Phase: number,
	Connection: RBXScriptConnection,
}

local counters: { [BasePart]: Counter } = {}

local function setText(counter: Counter, value: number)
	local text = if counter.Pad:GetAttribute("Cash") == nil then "" else UIStyle.formatMoney(value)
	counter.Label.Text = text
	counter.Glow.Text = text
end

-- "+$12" rising and fading above the counter.
local function floatingText(counter: Counter, text: string, color: Color3, big: boolean)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(if big then 220 else 120, if big then 44 else 30)
	billboard.StudsOffset = BASE_OFFSET + Vector3.new(0, 1.2, 0)
	billboard.MaxDistance = ANIMATE_DISTANCE
	billboard.Adornee = counter.Pad
	billboard.Parent = counter.Billboard.Parent -- the pad (local-only child)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = billboard
	UIStyle.text(label, color)
	label.Text = text
	local info = TweenInfo.new(if big then 1.1 else 0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(billboard, info, { StudsOffset = BASE_OFFSET + Vector3.new(0, if big then 4 else 3, 0) }):Play()
	local fade = TweenService:Create(label, info, { TextTransparency = 1 })
	fade.Completed:Once(function()
		billboard:Destroy()
	end)
	fade:Play() -- the outline follows the fade (UIStyle.text)
end

local function bounce(counter: Counter, size: number)
	counter.Scale.Scale = size
	TweenService:Create(counter.Scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
end

-- Smooth count from what's shown to the new value.
local function countTo(counter: Counter, target: number)
	local from = counter.Shown
	counter.Target = target
	local start = os.clock()
	local duration = 0.35
	task.spawn(function()
		while counter.Target == target and os.clock() - start < duration do
			local t = (os.clock() - start) / duration
			counter.Shown = from + (target - from) * (1 - (1 - t) ^ 3)
			setText(counter, counter.Shown)
			RunService.Heartbeat:Wait()
		end
		if counter.Target == target then
			counter.Shown = target
			setText(counter, target)
		end
	end)
end

local function inRange(pad: BasePart): boolean
	local camera = Workspace.CurrentCamera
	return camera ~= nil and (camera.CFrame.Position - pad.Position).Magnitude <= ANIMATE_DISTANCE
end

local function onCashChanged(counter: Counter)
	local value = counter.Pad:GetAttribute("Cash")
	if typeof(value) ~= "number" then
		counter.Shown, counter.Target = 0, 0
		setText(counter, 0)
		return
	end
	local previous = counter.Target
	if not inRange(counter.Pad) then
		counter.Shown, counter.Target = value, value
		setText(counter, value)
		return
	end
	if value > previous then
		countTo(counter, value)
		bounce(counter, 1.35)
		floatingText(counter, "+" .. UIStyle.formatMoney(value - previous), UIStyle.CashColor, false)
		counter.Burst:Emit(4)
	elseif value < previous then
		-- Collected: snap down with a big pop.
		counter.Shown, counter.Target = value, value
		setText(counter, value)
		bounce(counter, 1.6)
		floatingText(counter, "COLLECTED!", Color3.fromRGB(255, 230, 90), true)
		counter.Burst:Emit(24)
	end
end

local function setup(pad: Instance)
	if not pad:IsA("BasePart") or counters[pad] then
		return
	end
	local billboard = pad:WaitForChild("Cash", 10) :: BillboardGui?
	local label = billboard and billboard:WaitForChild("Label", 10) :: TextLabel?
	if not billboard or not label then
		return
	end
	billboard.LightInfluence = 0

	-- Glow: a softer, fatter copy of the text behind the real one.
	local glow = label:Clone()
	glow.Name = "Glow"
	glow.ZIndex = 0
	glow.TextTransparency = 0.55
	glow.TextColor3 = Color3.fromRGB(160, 255, 140)
	local glowStroke = glow:FindFirstChildOfClass("UIStroke")
	if glowStroke then
		glowStroke.Color = Color3.fromRGB(80, 255, 80)
		glowStroke.Thickness = 7
		glowStroke.Transparency = 0.6
	end
	glow.Parent = billboard
	label.ZIndex = 1

	local scale = Instance.new("UIScale")
	scale.Parent = billboard

	local attachment = Instance.new("Attachment")
	attachment.Position = Vector3.new(0, 2.4, 0)
	attachment.Parent = pad
	local burst = Instance.new("ParticleEmitter")
	burst.Enabled = false
	burst.Speed = NumberRange.new(4, 8)
	burst.SpreadAngle = Vector2.new(60, 60)
	burst.EmissionDirection = Enum.NormalId.Top
	burst.Acceleration = Vector3.new(0, -18, 0)
	burst.Lifetime = NumberRange.new(0.5, 0.8)
	burst.Size = NumberSequence.new(0.4, 0.1)
	burst.Color = ColorSequence.new(Color3.fromRGB(255, 220, 60), UIStyle.CashColor)
	burst.LightEmission = 0.8
	burst.Parent = attachment

	local counter: Counter = {
		Pad = pad,
		Billboard = billboard,
		Label = label,
		Glow = glow,
		Scale = scale,
		Burst = burst,
		Shown = 0,
		Target = 0,
		Phase = math.random() * math.pi * 2,
		Connection = pad:GetAttributeChangedSignal("Cash"):Connect(function()
			local c = counters[pad]
			if c then
				onCashChanged(c)
			end
		end),
	}
	counters[pad] = counter
	local value = pad:GetAttribute("Cash")
	counter.Shown = if typeof(value) == "number" then value else 0
	counter.Target = counter.Shown
	setText(counter, counter.Shown)
end

local function teardown(pad: Instance)
	local counter = counters[pad :: BasePart]
	if counter then
		counter.Connection:Disconnect()
		counters[pad :: BasePart] = nil
	end
end

-- The $/s already lives in the animal's nameplate. Pop that one label so a second
-- billboard doesn't draw over it.
local function popIncome(model: Model)
	local head = model:FindFirstChild("Head", true)
	local plate = head and head:FindFirstChild("Nameplate")
	if not plate or not plate:IsA("BillboardGui") then
		return
	end
	local scale = plate:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = plate
	end
	scale.Scale = 1.12
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

function PenCashController.init()
	for _, pad in CollectionService:GetTagged("CollectPad") do
		task.spawn(setup, pad)
	end
	CollectionService:GetInstanceAddedSignal("CollectPad"):Connect(function(pad)
		task.spawn(setup, pad)
	end)
	CollectionService:GetInstanceRemovedSignal("CollectPad"):Connect(teardown)

	-- Hover and bob, slightly out of step with each other so a row of pens ripples.
	RunService.RenderStepped:Connect(function()
		local t = os.clock()
		for pad, counter in counters do
			if inRange(pad) then
				counter.Billboard.StudsOffset = BASE_OFFSET
					+ Vector3.new(0, math.sin(t * 2.2 + counter.Phase) * BOB_HEIGHT, 0)
			end
		end
	end)

	-- Each second, the nameplate pops from the left of the row to the right.
	task.spawn(function()
		while true do
			local row = {}
			local camera = Workspace.CurrentCamera
			local origin = if camera then camera.CFrame.Position else nil
			for pad in counters do
				local pen = pad.Parent
				local rate = pad:GetAttribute("Rate")
				local animal = pen and pen:FindFirstChild("ZooAnimal")
				if
					origin
					and pen
					and animal
					and animal:IsA("Model")
					and typeof(rate) == "number"
					and rate > 0
					and (pad.Position - origin).Magnitude <= ANIMATE_DISTANCE
				then
					table.insert(row, { animal = animal, rate = rate, x = pad.Position.X })
				end
			end
			table.sort(row, function(a, b)
				return a.x < b.x
			end)
			for _, entry in row do
				popIncome(entry.animal)
				task.wait(0.16)
			end
			task.wait(if #row == 0 then 1 else 0.7)
		end
	end)
end

return PenCashController
