-- Shared look for all text, in Steal a Brainrot style: chunky font, thick black outlines,
-- rarity-coloured labels (animated rainbow for Zoo God and Rainbow mutations), green cash.
-- Used by the server (nameplates, pen pads) and the client (HUD, panels).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)

local UIStyle = {}

UIStyle.Font = Enum.Font.LuckiestGuy
UIStyle.CashColor = Color3.fromRGB(90, 255, 90)
UIStyle.PanelColor = Color3.fromRGB(30, 30, 40)
UIStyle.RainbowTag = "RainbowGradient" -- the client animates every gradient with this tag
UIStyle.RainbowRingTag = "RainbowAuraRing" -- Farm God aura rings; clients cycle their hue

local SUFFIXES = { "", "K", "M", "B", "T", "Qd" }

-- 950 -> "$950", 1234 -> "$1.2K", 15500000 -> "$15.5M"
function UIStyle.formatMoney(amount: number): string
	local n = math.max(0, amount)
	local i = 1
	while n >= 1000 and i < #SUFFIXES do
		n /= 1000
		i += 1
	end
	if i == 1 then
		return "$" .. tostring(math.floor(n))
	end
	local text = if n >= 100 then tostring(math.floor(n)) else string.format("%.1f", math.floor(n * 10) / 10)
	text = string.gsub(text, "%.0$", "")
	return "$" .. text .. SUFFIXES[i]
end

-- Chunky outlined text.
function UIStyle.text(target: TextLabel | TextButton, color: Color3?, stroke: Color3?, thickness: number?)
	local label = target :: any -- both classes share these text properties
	label.Font = UIStyle.Font
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.TextScaled = true
	if not target:IsA("TextButton") then
		label.BackgroundTransparency = 1
	end
	local outline = label:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	outline.Color = stroke or Color3.new(0, 0, 0)
	outline.Thickness = thickness or 2.5
	outline.LineJoinMode = Enum.LineJoinMode.Round
	outline.Parent = label
	-- The outline follows the text, so a fade (a tween on TextTransparency) takes both
	-- instead of leaving a hollow black outline behind. It runs ahead of the fill (square
	-- root): a half-faded fill over a still-solid stroke reads as a dark ring.
	local function follow(ring: UIStroke)
		local t = math.clamp(label.TextTransparency, 0, 1)
		ring.Transparency = math.sqrt(t)
	end
	follow(outline)
	if not label:GetAttribute("StrokeFollowsText") then
		label:SetAttribute("StrokeFollowsText", true)
		label:GetPropertyChangedSignal("TextTransparency"):Connect(function()
			local current = label:FindFirstChildOfClass("UIStroke")
			if current then
				follow(current)
			end
		end)
	end
end

-- Black outline around a frame or button (the "cartoon panel" look).
function UIStyle.border(frame: GuiObject, thickness: number?)
	local outline = Instance.new("UIStroke")
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Color = Color3.new(0, 0, 0)
	outline.Thickness = thickness or 3
	outline.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame
end

-- Bright rainbow that reads on a black chip or a black stroke. The client slides every
-- gradient tagged RainbowTag, so the colours move.
function UIStyle.rainbow(label: GuiObject)
	local gradient = label:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)),
		ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 150, 30)),
		ColorSequenceKeypoint.new(0.34, Color3.fromRGB(255, 240, 60)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(70, 255, 120)),
		ColorSequenceKeypoint.new(0.67, Color3.fromRGB(50, 210, 255)),
		ColorSequenceKeypoint.new(0.84, Color3.fromRGB(190, 80, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 70, 70)),
	})
	gradient.Parent = label
	CollectionService:AddTag(gradient, UIStyle.RainbowTag)
end

-- Chat has no UIGradient, so the same rainbow is baked into rich text with a black stroke.
local VIP_CHAT_COLORS = { "#FF2E46", "#FF9A1A", "#FFE600", "#3DFF6A", "#2AD4FF", "#7B5CFF", "#FF3DCE" }

function UIStyle.vipChatTitle(text: string): string
	local parts = {}
	local count = math.max(#text, 1)
	local step = math.max(1, math.floor(#VIP_CHAT_COLORS / count))
	for i = 1, #text do
		local index = ((i - 1) * step) % #VIP_CHAT_COLORS + 1
		table.insert(parts, `<font color="{VIP_CHAT_COLORS[index]}">{string.sub(text, i, i)}</font>`)
	end
	return `<stroke color="#000000" thickness="2" joins="round">{table.concat(parts)}</stroke>`
end

-- Colours a label for a rarity tier: tier colour, Zoo God rainbow, Secret black/white.
function UIStyle.rarity(label: TextLabel, rarityKey: string)
	local rarity = RarityConfig.ByKey[rarityKey] or RarityConfig.ByKey.Common
	UIStyle.text(label, if rarity.Rainbow then Color3.new(1, 1, 1) else rarity.Color, rarity.StrokeColor)
	label.Text = rarity.DisplayName
	if rarity.Rainbow then
		UIStyle.rainbow(label)
	end
end

function UIStyle.mutation(label: TextLabel, mutationKey: string)
	local mutation = MutationConfig.ByKey[mutationKey] or MutationConfig.ByKey.Normal
	UIStyle.text(label, if mutation.Rainbow then Color3.new(1, 1, 1) else mutation.Color)
	label.Text = mutation.DisplayName
	if mutation.Rainbow then
		UIStyle.rainbow(label)
	end
end

export type NameplateInfo = {
	Name: string,
	Rarity: string,
	Mutation: string,
	IncomePerSecond: number,
	Needs: string?, -- gear it takes to wash this animal (walk-ins only)
}

local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255)
	)
end

local function escapeRich(text: string): string
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	return text
end

-- Everything drawn over an animal hangs from one anchor above its head and is stacked in
-- pixels, so the rows never overlap at any distance. The resting nameplate's bottom edge
-- sits on the anchor, and its real height (3 to 5 lines) is stored on the head as
-- PlateHeight, so every row above it clears it by the same small gap.
-- While washing, bottom to top: clean % bar and patience row, the lifted nameplate, then
-- the daily tag and callouts. After a wash: nameplate, Squeaky clean!, the rising payout;
-- the chat bubble follows once the banner is gone.
UIStyle.Overhead = {
	Meter = "Meter", -- clean bar + patience row, on the anchor
	Name = "Name", -- the lifted nameplate, just above the meter
	Banner = "Banner", -- Squeaky clean! (meter gone, nameplate resting)
	Payout = "Payout", -- +$ rising above the banner
	Bubble = "Bubble", -- the washed animal's chat line, right above the resting nameplate
	Tag = "Tag", -- DAILY DIRTY ANIMAL, above the lifted nameplate
	Callout = "Callout", -- Wash me! / TOO DIRTY! / !, above the tag row
}

local GAP = 6
local METER_ROOM = 60 -- the clean meter billboard (56) plus a gap
local BANNER_ROOM = 56 + GAP
local TAG_ROOM = 34 + GAP
local DEFAULT_PLATE = 72

local function overheadLift(head: BasePart): number
	return head.Size.Y / 2 + 1.2
end

local function slotBottom(head: BasePart, slot: string): number
	local plate = head:GetAttribute("PlateHeight")
	local h = if typeof(plate) == "number" then plate else DEFAULT_PLATE
	if slot == "Meter" then
		return 0
	elseif slot == "Rest" then
		return 0
	elseif slot == "Name" then
		return METER_ROOM
	elseif slot == "Banner" or slot == "Bubble" then
		return h + GAP
	elseif slot == "Payout" then
		return h + GAP + BANNER_ROOM
	elseif slot == "Tag" then
		return METER_ROOM + h + GAP
	end
	return METER_ROOM + h + GAP + TAG_ROOM -- Callout
end

-- Places a pixel-sized billboard so its bottom edge sits in `slot` (UIStyle.Overhead) of the
-- stack above this head. `bob` nudges it up and down in pixels.
function UIStyle.overhead(billboard: BillboardGui, head: BasePart, slot: string, bob: number?)
	local height = math.max(1, billboard.Size.Y.Offset)
	local bottom = slotBottom(head, slot)
	billboard.StudsOffset = Vector3.new(0, overheadLift(head), 0)
	billboard.SizeOffset = Vector2.new(0, (bottom + (bob or 0) + height / 2) / height)
end

-- Lifts the animal's nameplate above the clean meter, or drops it back to rest.
function UIStyle.liftNameplate(head: BasePart, lifted: boolean)
	local plate = head:FindFirstChild("Nameplate")
	if not plate or not plate:IsA("BillboardGui") then
		return
	end
	if lifted then
		UIStyle.overhead(plate, head, UIStyle.Overhead.Name)
	else
		UIStyle.overhead(plate, head, "Rest")
	end
end

-- One label, so the stacked strokes don't artifact. A mutation line is included when set.
function UIStyle.nameplate(adornee: BasePart, info: NameplateInfo, maxDistance: number): BillboardGui
	local rarity = RarityConfig.ByKey[info.Rarity] or RarityConfig.ByKey.Common
	local mutation = MutationConfig.ByKey[info.Mutation] or MutationConfig.ByKey.Normal
	local mutated = info.Mutation ~= MutationConfig.Default
	local rainbowLabel = rarity.Rainbow or (mutated and mutation.Rainbow)
	local lines = (if mutated then 4 else 3) + (if info.Needs then 1 else 0)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Nameplate"
	billboard.Size = UDim2.fromOffset(if info.Needs then 260 else 220, lines * 24)
	-- Rows stacked above (UIStyle.overhead) read this height so they sit just clear of it.
	adornee:SetAttribute("PlateHeight", lines * 24)
	UIStyle.overhead(billboard, adornee, "Rest")
	billboard.MaxDistance = maxDistance
	billboard.Parent = adornee

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = billboard
	local textColor = if rarity.Key == "Secret" then rarity.Color else Color3.new(1, 1, 1)
	UIStyle.text(label, textColor, if rainbowLabel then Color3.new(0, 0, 0) else rarity.StrokeColor, 3.5)
	label.RichText = true

	local function span(color: Color3, text: string): string
		local safe = escapeRich(text)
		if rainbowLabel then
			return safe
		end
		return `<font color="{hex(color)}">{safe}</font>`
	end

	local rows = { escapeRich(info.Name) }
	if mutated then
		table.insert(rows, span(mutation.Color, mutation.DisplayName))
	end
	table.insert(rows, span(rarity.Color, rarity.DisplayName))
	table.insert(rows, span(UIStyle.CashColor, UIStyle.formatMoney(info.IncomePerSecond) .. "/s"))
	if info.Needs then
		table.insert(rows, span(Color3.fromRGB(255, 140, 90), `🔒 {info.Needs}`))
	end
	label.Text = table.concat(rows, "\n")
	if rainbowLabel then
		UIStyle.rainbow(label)
	end
	return billboard
end

return UIStyle
