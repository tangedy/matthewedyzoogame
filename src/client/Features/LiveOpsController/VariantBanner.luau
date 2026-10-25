-- One short strip in the top bar: what's live now, and the next event.
-- Sits in the free part of the Roblox top bar (or just under it), at EVENT_SCALE of its original 22px. The server titles
-- decide what is current; the clocks only count down.
-- Odds and pity counters are not shown. Mud Storm shares this strip when it is the
-- thing happening now or the soonest thing coming up.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local VariantBanner = {}

local STORM_NAME = "Mud Storm"
local STORM_COLOR = Color3.fromRGB(255, 176, 90)
local REST_TRANSPARENCY = 0.45
local EVENT_SCALE = 1.5 -- playtesters missed the events at the old size (22px strip, 13px text)
local HOVER_FADE = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local folder: Instance
local strip: Frame
local nowLabel: TextLabel
local nextLabel: TextLabel
local shownTitle = ""
local fadeTween: Tween? = nil

local function formatClock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s >= 3600 then
		return `{s // 3600}h {(s % 3600) // 60}m`
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

local function numberAttribute(name: string): number
	local value = folder:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function textAttribute(name: string): string
	local value = folder:GetAttribute(name)
	return if typeof(value) == "string" then value else ""
end

local function colorOf(): Color3
	local value = folder:GetAttribute("VariantEventColor")
	return if typeof(value) == "Color3" then value else Color3.fromRGB(255, 210, 70)
end

-- GuiService.TopbarInset is the strip of the top bar Roblox leaves free (between its
-- own buttons on the left and right). The counter fits inside it. When that strip is
-- too narrow (a phone's top bar is mostly menu buttons), it drops just under the bar,
-- centred, so it never sits on the menu, chat or voice buttons.
local MIN_INSIDE_WIDTH = 300
local MARGIN = 8

local function place()
	local camera = Workspace.CurrentCamera
	local screenWidth = if camera then camera.ViewportSize.X else 800
	local height = math.round(22 * EVENT_SCALE)
	local wanted = 440 * EVENT_SCALE
	local free = GuiService.TopbarInset
	local freeWidth = free.Max.X - free.Min.X - MARGIN * 2
	local textSize = math.round(13 * EVENT_SCALE)
	if free.Height > 0 and freeWidth >= MIN_INSIDE_WIDTH then
		local width = math.min(wanted, freeWidth)
		strip.Size = UDim2.fromOffset(width, height)
		strip.Position = UDim2.fromOffset((free.Min.X + free.Max.X) / 2, (free.Min.Y + free.Max.Y) / 2)
	else
		-- Half the screen: clear of the cash on the left and the invite box on the right.
		local width = math.clamp(screenWidth * 0.5, 180, wanted)
		local below = if free.Height > 0 then free.Max.Y else GuiService:GetGuiInset().Y
		strip.Size = UDim2.fromOffset(width, height)
		strip.Position = UDim2.fromOffset(screenWidth / 2, below + MARGIN + height / 2)
		textSize = math.round(12 * EVENT_SCALE)
	end
	for _, child in strip:GetChildren() do
		if child:IsA("TextLabel") then
			child.TextSize = textSize
		end
	end
end

local function label(name: string, color: Color3): TextLabel
	local created = Instance.new("TextLabel")
	created.Name = name
	created.BackgroundTransparency = 1
	created.Size = UDim2.new(0.5, -6, 1, 0)
	created.TextXAlignment = Enum.TextXAlignment.Center
	created.TextTruncate = Enum.TextTruncate.AtEnd
	created.Text = ""
	created.Parent = strip
	UIStyle.text(created, color, Color3.new(0, 0, 0), 1.5)
	created.TextScaled = false
	created.TextSize = math.round(13 * EVENT_SCALE)
	return created
end

local function build(gui: ScreenGui)
	strip = Instance.new("Frame")
	strip.Name = "LiveEventCounter"
	strip.AnchorPoint = Vector2.new(0.5, 0.5)
	strip.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
	strip.BackgroundTransparency = REST_TRANSPARENCY
	strip.Active = true
	strip.Visible = false
	strip.Parent = gui
	UIStyle.border(strip, 2)
	local stroke = strip:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0.55
	end
	local function fade(solid: boolean)
		if fadeTween then
			fadeTween:Cancel()
		end
		local background = if solid then 0 else REST_TRANSPARENCY
		fadeTween = TweenService:Create(strip, HOVER_FADE, { BackgroundTransparency = background })
		fadeTween:Play()
		local outline = strip:FindFirstChildOfClass("UIStroke")
		if outline then
			TweenService:Create(outline, HOVER_FADE, { Transparency = if solid then 0 else 0.55 }):Play()
		end
	end
	strip.MouseEnter:Connect(function()
		fade(true)
	end)
	strip.MouseLeave:Connect(function()
		fade(false)
	end)

	nowLabel = label("Now", Color3.new(1, 1, 1))
	nextLabel = label("Next", Color3.fromRGB(210, 214, 220))
	nowLabel.Position = UDim2.fromOffset(8, 0)
	nextLabel.Position = UDim2.new(0.5, 4, 0, 0)

	place()
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(place)
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(place)
	end
end

local function refresh()
	local now = Workspace:GetServerTimeNow()
	local title = textAttribute("VariantEventTitle")
	local eventLeft = numberAttribute("VariantEventEndsAt") - now
	local nextTitle = textAttribute("VariantEventNextTitle")
	local nextIn = numberAttribute("VariantEventNextAt") - now
	local stormOn = folder:GetAttribute("MudStormActive") == true
	local stormLeft = numberAttribute("MudStormEndsAt") - now
	local stormNext = numberAttribute("MudStormNextAt") - now

	local nowParts = {}
	if title ~= "" then
		table.insert(nowParts, `{title} {formatClock(math.max(eventLeft, 0))}`)
	end
	if stormOn then
		table.insert(nowParts, `{STORM_NAME} {formatClock(math.max(stormLeft, 0))}`)
	end

	local nextName = ""
	local nextLeft = math.huge
	if nextTitle ~= "" and nextIn > -1 and nextIn < nextLeft then
		nextName = nextTitle
		nextLeft = nextIn
	end
	if not stormOn and stormNext > 0 and stormNext < nextLeft then
		nextName = STORM_NAME
		nextLeft = stormNext
	end

	local hasNow = #nowParts > 0
	local hasNext = nextName ~= ""
	strip.Visible = hasNow or hasNext
	nowLabel.Visible = hasNow
	nextLabel.Visible = hasNext
	if hasNow and hasNext then
		nowLabel.Position = UDim2.fromOffset(6, 0)
		nowLabel.Size = UDim2.new(0.5, -8, 1, 0)
		nextLabel.Position = UDim2.new(0.5, 2, 0, 0)
		nextLabel.Size = UDim2.new(0.5, -8, 1, 0)
	elseif hasNow then
		nowLabel.Position = UDim2.fromOffset(6, 0)
		nowLabel.Size = UDim2.new(1, -12, 1, 0)
	else
		nextLabel.Position = UDim2.fromOffset(6, 0)
		nextLabel.Size = UDim2.new(1, -12, 1, 0)
	end
	if hasNow then
		nowLabel.Text = "NOW  " .. table.concat(nowParts, " · ")
		local color = if title ~= "" then colorOf() else STORM_COLOR
		nowLabel.TextColor3 = color
	end
	if hasNext then
		nextLabel.Text = `NEXT  {nextName} {formatClock(math.max(nextLeft, 0))}`
	end

	if title ~= shownTitle then
		shownTitle = title
	end
end

function VariantBanner.start(gui: ScreenGui)
	build(gui)
	folder = ReplicatedStorage:WaitForChild("LiveOpsState")
	for _, name in
		{
			"VariantEventTitle",
			"VariantEventEndsAt",
			"VariantEventNextTitle",
			"VariantEventNextAt",
			"MudStormActive",
			"MudStormEndsAt",
			"MudStormNextAt",
		}
	do
		folder:GetAttributeChangedSignal(name):Connect(refresh)
	end
	refresh()
	local nextRefresh = 0
	RunService.Heartbeat:Connect(function()
		local t = os.clock()
		if t >= nextRefresh then
			nextRefresh = t + 0.25
			refresh()
		end
	end)
end

return VariantBanner
