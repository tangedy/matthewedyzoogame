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

local function rainbow(label: GuiObject)
	local gradient = label:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)),
		ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 50)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(90, 255, 90)),
		ColorSequenceKeypoint.new(0.6, Color3.fromRGB(70, 200, 255)),
		ColorSequenceKeypoint.new(0.8, Color3.fromRGB(180, 90, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 70, 70)),
	})
	gradient.Parent = label
	CollectionService:AddTag(gradient, UIStyle.RainbowTag)
end

-- Colours a label for a rarity tier: tier colour, Zoo God rainbow, Secret black/white.
function UIStyle.rarity(label: TextLabel, rarityKey: string)
	local rarity = RarityConfig.ByKey[rarityKey] or RarityConfig.ByKey.Common
	UIStyle.text(label, if rarity.Rainbow then Color3.new(1, 1, 1) else rarity.Color, rarity.StrokeColor)
	label.Text = rarity.DisplayName
	if rarity.Rainbow then
		rainbow(label)
	end
end

function UIStyle.mutation(label: TextLabel, mutationKey: string)
	local mutation = MutationConfig.ByKey[mutationKey] or MutationConfig.ByKey.Normal
	UIStyle.text(label, if mutation.Rainbow then Color3.new(1, 1, 1) else mutation.Color)
	label.Text = mutation.DisplayName
	if mutation.Rainbow then
		rainbow(label)
	end
end

export type NameplateInfo = {
	Name: string,
	Rarity: string,
	Mutation: string,
	IncomePerSecond: number,
}

local function hex(color: Color3): string
	return string.format("#%02X%02X%02X", math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255))
end

local function escapeRich(text: string): string
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	return text
end

-- One label, so the stacked strokes don't artifact. A mutation line is included when set.
function UIStyle.nameplate(adornee: BasePart, info: NameplateInfo, maxDistance: number): BillboardGui
	local rarity = RarityConfig.ByKey[info.Rarity] or RarityConfig.ByKey.Common
	local mutation = MutationConfig.ByKey[info.Mutation] or MutationConfig.ByKey.Normal
	local mutated = info.Mutation ~= MutationConfig.Default
	local rainbowLabel = rarity.Rainbow or (mutated and mutation.Rainbow)
	local lines = if mutated then 4 else 3

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Nameplate"
	billboard.Size = UDim2.fromOffset(220, lines * 24)
	billboard.StudsOffset = Vector3.new(0, adornee.Size.Y / 2 + 2.6, 0)
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

	local rows = {}
	if mutated then
		table.insert(rows, span(mutation.Color, mutation.DisplayName))
	end
	table.insert(rows, escapeRich(info.Name))
	table.insert(rows, span(rarity.Color, rarity.DisplayName))
	table.insert(rows, span(UIStyle.CashColor, UIStyle.formatMoney(info.IncomePerSecond) .. "/s"))
	label.Text = table.concat(rows, "\n")
	if rainbowLabel then
		rainbow(label)
	end
	return billboard
end

return UIStyle
