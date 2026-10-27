-- Custom HUD icons, drawn from rounded frames so they need no uploaded images and no emoji
-- (emoji draw differently on every device). Every icon is a square that fills whatever box
-- it is given and keeps one thick black outline around the whole shape: each shape is
-- drawn twice, once black and a little bigger (the outline pass), then in its colour.
--
--   Icons.make(name, parent, options?)  a new icon Frame (Size 1,1; set Position/Size after)
--   Icons.setTransparency(icon, t)      fades every piece of an icon together
--   Icons.has(name)                     whether an icon by that name exists
--
-- Coordinates below are fractions of the icon square: x/y is the shape's centre.

local Icons = {}

export type Options = {
	outline: number?, -- outline width in design units (default 3)
	zIndex: number?, -- base ZIndex (default: one above the parent)
}

type Shape = {
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3,
	rot: number?,
	round: number?, -- corner radius as a fraction of the short side; 0.5 is a circle or pill
	z: number?, -- fill layer, 1 by default; details sit higher
	bare: boolean?, -- no outline (inner details)
	text: string?, -- a letter or number drawn in the shape instead of a fill
}

local WHITE = Color3.fromRGB(255, 255, 255)
local DARK = Color3.fromRGB(46, 50, 62)
local GOLD = Color3.fromRGB(255, 205, 60)
local GOLD_DEEP = Color3.fromRGB(214, 140, 20)
local GREEN = Color3.fromRGB(92, 214, 96)
local GREEN_DEEP = Color3.fromRGB(38, 140, 60)
local MINT = Color3.fromRGB(190, 255, 190)
local RED = Color3.fromRGB(240, 70, 80)
local RED_LIGHT = Color3.fromRGB(255, 110, 120)
local BLUE = Color3.fromRGB(90, 200, 255)
local BLUE_DEEP = Color3.fromRGB(40, 130, 230)
local PINK = Color3.fromRGB(255, 110, 170)
local GREY = Color3.fromRGB(200, 206, 218)
local BROWN = Color3.fromRGB(190, 96, 52)
local TAN = Color3.fromRGB(222, 178, 108)
local STEEL = Color3.fromRGB(150, 158, 176)

local HEX_R = 0.42 -- Robux hexagon circumradius: three R x R*sqrt(3) bars at 0/60/120 degrees

local SHAPES: { [string]: { Shape } } = {
	Cart = {
		{ x = 0.2, y = 0.24, w = 0.24, h = 0.1, color = WHITE, round = 0.5 },
		{ x = 0.31, y = 0.4, w = 0.09, h = 0.34, color = WHITE, rot = -18, round = 0.5 },
		{ x = 0.6, y = 0.48, w = 0.56, h = 0.34, color = WHITE, round = 0.18 },
		{ x = 0.58, y = 0.7, w = 0.52, h = 0.09, color = WHITE, round = 0.5 },
		{ x = 0.5, y = 0.48, w = 0.05, h = 0.22, color = GREY, bare = true, z = 2 },
		{ x = 0.62, y = 0.48, w = 0.05, h = 0.22, color = GREY, bare = true, z = 2 },
		{ x = 0.74, y = 0.48, w = 0.05, h = 0.22, color = GREY, bare = true, z = 2 },
		{ x = 0.4, y = 0.84, w = 0.16, h = 0.16, color = DARK, round = 0.5 },
		{ x = 0.74, y = 0.84, w = 0.16, h = 0.16, color = DARK, round = 0.5 },
	},
	Book = {
		{ x = 0.5, y = 0.56, w = 0.9, h = 0.64, color = BROWN, round = 0.12 },
		{ x = 0.3, y = 0.5, w = 0.38, h = 0.62, color = WHITE, rot = -5, round = 0.1, z = 2 },
		{ x = 0.7, y = 0.5, w = 0.38, h = 0.62, color = WHITE, rot = 5, round = 0.1, z = 2 },
		{ x = 0.3, y = 0.38, w = 0.24, h = 0.05, color = GREY, rot = -5, bare = true, z = 3 },
		{ x = 0.3, y = 0.5, w = 0.24, h = 0.05, color = GREY, rot = -5, bare = true, z = 3 },
		{ x = 0.3, y = 0.62, w = 0.24, h = 0.05, color = GREY, rot = -5, bare = true, z = 3 },
		{ x = 0.7, y = 0.38, w = 0.24, h = 0.05, color = GREY, rot = 5, bare = true, z = 3 },
		{ x = 0.7, y = 0.5, w = 0.24, h = 0.05, color = GREY, rot = 5, bare = true, z = 3 },
		{ x = 0.7, y = 0.62, w = 0.24, h = 0.05, color = GREY, rot = 5, bare = true, z = 3 },
	},
	Gift = {
		{ x = 0.5, y = 0.66, w = 0.7, h = 0.48, color = RED, round = 0.1 },
		{ x = 0.5, y = 0.4, w = 0.84, h = 0.18, color = RED_LIGHT, round = 0.15, z = 2 },
		{ x = 0.5, y = 0.62, w = 0.14, h = 0.56, color = GOLD, bare = true, z = 3 },
		{ x = 0.37, y = 0.22, w = 0.26, h = 0.16, color = GOLD, rot = -28, round = 0.5 },
		{ x = 0.63, y = 0.22, w = 0.26, h = 0.16, color = GOLD, rot = 28, round = 0.5 },
		{ x = 0.5, y = 0.28, w = 0.14, h = 0.14, color = GOLD_DEEP, round = 0.5, z = 3 },
	},
	Bolt = {
		{ x = 0.58, y = 0.29, w = 0.24, h = 0.46, color = GOLD, rot = 24, round = 0.12 },
		{ x = 0.5, y = 0.5, w = 0.5, h = 0.15, color = GOLD, rot = -12, round = 0.2 },
		{ x = 0.42, y = 0.71, w = 0.22, h = 0.46, color = GOLD, rot = 24, round = 0.12 },
	},
	Cash = {
		{ x = 0.45, y = 0.42, w = 0.8, h = 0.46, color = GREEN_DEEP, rot = -12, round = 0.14 },
		{ x = 0.55, y = 0.58, w = 0.8, h = 0.46, color = GREEN, rot = -4, round = 0.14, z = 2 },
		{ x = 0.55, y = 0.58, w = 0.28, h = 0.28, color = MINT, round = 0.5, bare = true, z = 3 },
		{ x = 0.55, y = 0.585, w = 0.26, h = 0.26, color = GREEN_DEEP, text = "$", bare = true, z = 4 },
	},
	-- Cash with a red "2X" badge: 2x Cash Forever.
	Cash2x = {
		{ x = 0.4, y = 0.38, w = 0.72, h = 0.42, color = GREEN_DEEP, rot = -12, round = 0.14 },
		{ x = 0.46, y = 0.5, w = 0.72, h = 0.42, color = GREEN, rot = -4, round = 0.14, z = 2 },
		{ x = 0.46, y = 0.5, w = 0.24, h = 0.24, color = MINT, round = 0.5, bare = true, z = 3 },
		{ x = 0.46, y = 0.505, w = 0.22, h = 0.22, color = GREEN_DEEP, text = "$", bare = true, z = 4 },
		{ x = 0.72, y = 0.74, w = 0.5, h = 0.42, color = Color3.new(0, 0, 0), round = 0.5, bare = true, z = 5 },
		{ x = 0.72, y = 0.74, w = 0.44, h = 0.36, color = RED, round = 0.5, z = 6 },
		{ x = 0.72, y = 0.745, w = 0.34, h = 0.26, color = WHITE, text = "2X", bare = true, z = 7 },
	},
	MoneyBag = {
		{ x = 0.5, y = 0.64, w = 0.74, h = 0.62, color = TAN, round = 0.5 },
		{ x = 0.5, y = 0.3, w = 0.3, h = 0.16, color = TAN, round = 0.3 },
		{ x = 0.37, y = 0.17, w = 0.22, h = 0.16, color = TAN, rot = -30, round = 0.4 },
		{ x = 0.63, y = 0.17, w = 0.22, h = 0.16, color = TAN, rot = 30, round = 0.4 },
		{ x = 0.5, y = 0.34, w = 0.38, h = 0.07, color = BROWN, round = 0.5, bare = true, z = 2 },
		{ x = 0.5, y = 0.66, w = 0.34, h = 0.34, color = GREEN_DEEP, text = "$", bare = true, z = 3 },
	},
	Vault = {
		{ x = 0.5, y = 0.5, w = 0.84, h = 0.78, color = GREY, round = 0.12 },
		{ x = 0.25, y = 0.92, w = 0.14, h = 0.08, color = DARK },
		{ x = 0.75, y = 0.92, w = 0.14, h = 0.08, color = DARK },
		{ x = 0.5, y = 0.5, w = 0.66, h = 0.6, color = STEEL, round = 0.08, bare = true, z = 2 },
		{ x = 0.5, y = 0.5, w = 0.38, h = 0.38, color = DARK, round = 0.5, bare = true, z = 3 },
		{ x = 0.5, y = 0.5, w = 0.3, h = 0.3, color = GOLD, round = 0.5, bare = true, z = 4 },
		{ x = 0.5, y = 0.5, w = 0.06, h = 0.26, color = GOLD_DEEP, rot = 45, bare = true, z = 5 },
		{ x = 0.5, y = 0.5, w = 0.06, h = 0.26, color = GOLD_DEEP, rot = -45, bare = true, z = 5 },
		{ x = 0.8, y = 0.5, w = 0.06, h = 0.2, color = DARK, round = 0.5, bare = true, z = 3 },
	},
	-- Winged sneaker: 2x Speed.
	Shoe = {
		{ x = 0.24, y = 0.4, w = 0.3, h = 0.12, color = WHITE, rot = -22, round = 0.5 },
		{ x = 0.2, y = 0.52, w = 0.26, h = 0.1, color = WHITE, rot = -8, round = 0.5 },
		{ x = 0.44, y = 0.5, w = 0.36, h = 0.36, color = RED, round = 0.3 },
		{ x = 0.58, y = 0.66, w = 0.68, h = 0.26, color = RED, round = 0.45 },
		{ x = 0.58, y = 0.8, w = 0.72, h = 0.09, color = WHITE, round = 0.5 },
		{ x = 0.46, y = 0.46, w = 0.16, h = 0.05, color = WHITE, rot = -20, bare = true, z = 2 },
		{ x = 0.5, y = 0.55, w = 0.16, h = 0.05, color = WHITE, rot = -20, bare = true, z = 2 },
		{ x = 0.1, y = 0.68, w = 0.14, h = 0.05, color = WHITE, round = 0.5 },
		{ x = 0.14, y = 0.78, w = 0.1, h = 0.05, color = WHITE, round = 0.5 },
	},
	Magnet = {
		{ x = 0.29, y = 0.46, w = 0.2, h = 0.5, color = RED },
		{ x = 0.71, y = 0.46, w = 0.2, h = 0.5, color = RED },
		{ x = 0.5, y = 0.72, w = 0.62, h = 0.22, color = RED, round = 0.5 },
		{ x = 0.29, y = 0.2, w = 0.2, h = 0.14, color = GREY, z = 2 },
		{ x = 0.71, y = 0.2, w = 0.2, h = 0.14, color = GREY, z = 2 },
		{ x = 0.5, y = 0.38, w = 0.2, h = 0.2, color = GOLD, round = 0.5 },
	},
	Crown = {
		{ x = 0.22, y = 0.38, w = 0.2, h = 0.2, color = GOLD, rot = 45, round = 0.1 },
		{ x = 0.5, y = 0.3, w = 0.22, h = 0.22, color = GOLD, rot = 45, round = 0.1 },
		{ x = 0.78, y = 0.38, w = 0.2, h = 0.2, color = GOLD, rot = 45, round = 0.1 },
		{ x = 0.5, y = 0.56, w = 0.66, h = 0.26, color = GOLD, round = 0.08, z = 2 },
		{ x = 0.5, y = 0.73, w = 0.74, h = 0.16, color = GOLD_DEEP, round = 0.3, z = 3 },
		{ x = 0.3, y = 0.73, w = 0.1, h = 0.1, color = RED, round = 0.5, bare = true, z = 4 },
		{ x = 0.5, y = 0.73, w = 0.1, h = 0.1, color = BLUE, round = 0.5, bare = true, z = 4 },
		{ x = 0.7, y = 0.73, w = 0.1, h = 0.1, color = RED, round = 0.5, bare = true, z = 4 },
	},
	Robux = {
		{ x = 0.5, y = 0.5, w = HEX_R, h = HEX_R * math.sqrt(3), color = GOLD },
		{ x = 0.5, y = 0.5, w = HEX_R, h = HEX_R * math.sqrt(3), color = GOLD, rot = 60 },
		{ x = 0.5, y = 0.5, w = HEX_R, h = HEX_R * math.sqrt(3), color = GOLD, rot = 120 },
		{ x = 0.5, y = 0.5, w = 0.3, h = 0.3, color = GOLD_DEEP, round = 0.12, bare = true, z = 2 },
		{ x = 0.5, y = 0.5, w = 0.14, h = 0.14, color = GOLD, round = 0.1, bare = true, z = 3 },
	},
	Drop = {
		{ x = 0.5, y = 0.62, w = 0.6, h = 0.6, color = BLUE, round = 0.5 },
		{ x = 0.5, y = 0.45, w = 0.36, h = 0.36, color = BLUE, rot = 45, round = 0.08 },
		{ x = 0.4, y = 0.62, w = 0.13, h = 0.13, color = WHITE, round = 0.5, bare = true, z = 2 },
	},
	Heart = {
		{ x = 0.34, y = 0.4, w = 0.4, h = 0.4, color = PINK, round = 0.5 },
		{ x = 0.66, y = 0.4, w = 0.4, h = 0.4, color = PINK, round = 0.5 },
		{ x = 0.5, y = 0.56, w = 0.42, h = 0.42, color = PINK, rot = 45, round = 0.08 },
		{ x = 0.32, y = 0.36, w = 0.12, h = 0.12, color = WHITE, round = 0.5, bare = true, z = 2 },
	},
	Sparkle = {
		{ x = 0.46, y = 0.54, w = 0.18, h = 0.8, color = GOLD, round = 0.5 },
		{ x = 0.46, y = 0.54, w = 0.8, h = 0.18, color = GOLD, round = 0.5 },
		{ x = 0.46, y = 0.54, w = 0.32, h = 0.32, color = GOLD, rot = 45, round = 0.1 },
		{ x = 0.8, y = 0.2, w = 0.1, h = 0.3, color = WHITE, round = 0.5 },
		{ x = 0.8, y = 0.2, w = 0.3, h = 0.1, color = WHITE, round = 0.5 },
	},
	Lock = {
		{ x = 0.5, y = 0.34, w = 0.46, h = 0.46, color = GREY, round = 0.5 },
		{ x = 0.5, y = 0.38, w = 0.22, h = 0.3, color = DARK, round = 0.5, bare = true, z = 2 },
		{ x = 0.5, y = 0.66, w = 0.68, h = 0.46, color = GOLD, round = 0.14, z = 3 },
		{ x = 0.5, y = 0.64, w = 0.1, h = 0.18, color = DARK, round = 0.5, bare = true, z = 4 },
	},
	Water = {
		{ x = 0.5, y = 0.5, w = 0.84, h = 0.84, color = BLUE_DEEP, round = 0.5 },
		{ x = 0.5, y = 0.55, w = 0.46, h = 0.46, color = BLUE, round = 0.5, bare = true, z = 2 },
	},
}

local function addCorner(frame: GuiObject, round: number?)
	if round and round > 0 then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(round, 0)
		corner.Parent = frame
	end
end

local function piece(parent: Frame, shape: Shape, grow: number, color: Color3, zIndex: number): GuiObject
	local object: GuiObject
	if shape.text then
		local label = Instance.new("TextLabel")
		label.Text = shape.text
		label.Font = Enum.Font.LuckiestGuy
		label.TextScaled = true
		label.TextColor3 = color
		label.BackgroundTransparency = 1
		object = label
	else
		local frame = Instance.new("Frame")
		frame.BackgroundColor3 = color
		frame.BorderSizePixel = 0
		object = frame
	end
	object.AnchorPoint = Vector2.new(0.5, 0.5)
	object.Position = UDim2.fromScale(shape.x, shape.y)
	object.Size = UDim2.new(shape.w, grow * 2, shape.h, grow * 2)
	object.Rotation = shape.rot or 0
	object.ZIndex = zIndex
	object.Parent = parent
	if not shape.text then
		addCorner(object, shape.round)
	end
	return object
end

function Icons.has(name: string): boolean
	return SHAPES[name] ~= nil
end

function Icons.make(name: string, parent: Instance?, options: Options?): Frame
	local shapes = SHAPES[name] or SHAPES.Sparkle
	local outline = if options and options.outline then options.outline else 3
	local base = if options and options.zIndex
		then options.zIndex
		elseif parent and parent:IsA("GuiObject") then parent.ZIndex + 1
		else 1

	local icon = Instance.new("Frame")
	icon.Name = `Icon{name}`
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.ZIndex = base
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = icon

	-- Outline pass first, under every fill, so overlapping shapes read as one silhouette.
	for _, shape in shapes do
		if not shape.bare and not shape.text then
			piece(icon, shape, outline, Color3.new(0, 0, 0), base)
		end
	end
	for _, shape in shapes do
		piece(icon, shape, 0, shape.color, base + (shape.z or 1))
	end
	icon.Parent = parent
	return icon
end

function Icons.setTransparency(icon: Instance, transparency: number)
	for _, item in icon:GetChildren() do
		if item:IsA("TextLabel") then
			item.TextTransparency = transparency
		elseif item:IsA("Frame") then
			item.BackgroundTransparency = transparency
		end
	end
end

return Icons
