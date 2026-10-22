-- One short strip in the top bar: what's live now, and the next event.
-- Sits in the free centre of the Roblox top bar (about 22px tall). The server titles
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

local function place()
	local inset = GuiService:GetGuiInset()
	local camera = Workspace.CurrentCamera
	local width = if camera then camera.ViewportSize.X else 800
	-- Leave the Roblox menu buttons on both ends of the top bar alone.
	local maxWidth = math.clamp(width - 200, 180, 440)
	strip.Size = UDim2.fromOffset(maxWidth, 22)
	local y = if inset.Y >= 26 then inset.Y / 2 else 14
	strip.Position = UDim2.fromScale(0.5, 0) + UDim2.fromOffset(0, y)
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
	created.TextSize = 13
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
	for _, name in { "VariantEventTitle", "VariantEventEndsAt", "VariantEventNextTitle", "VariantEventNextAt", "MudStormActive", "MudStormEndsAt", "MudStormNextAt" } do
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
