-- Builds the cleaning tool in the player's right hand, one look per tier, so upgrades are
-- felt: a sponge, a scrub brush, a garden hose, a yellow pressure-washer gun, a foam cannon
-- with a bubble bottle, and a fire-hose nozzle.
--
-- Players get a real Tool (see WashTool.find). Its Handle carries the "Nozzle" attachment the
-- client draws the spray from and a "Feed" attachment the station's hose clips onto.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local WashTool = require(ReplicatedStorage.Shared.WashTool)

local HoseBuilder = {}

local function piece(
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	parent: BasePart,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Shape = shape or Enum.PartType.Block
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CFrame = parent.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = parent
	weld.Part1 = p
	weld.Parent = p
	p.Parent = parent
	return p
end

-- A cylinder lying along the hose (local Z axis).
local function tube(
	name: string,
	length: number,
	diameter: number,
	z: number,
	color: Color3,
	parent: BasePart,
	y: number?
): Part
	return piece(
		name,
		Vector3.new(length, diameter, diameter),
		CFrame.new(0, y or 0, z) * CFrame.Angles(0, math.rad(90), 0),
		color,
		parent,
		Enum.PartType.Cylinder
	)
end

local function glint(parent: BasePart, color: Color3)
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Rate = 3
	sparkle.Lifetime = NumberRange.new(0.4, 0.7)
	sparkle.Speed = NumberRange.new(0.3, 0.8)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Size = NumberSequence.new(0.25, 0)
	sparkle.Color = ColorSequence.new(color)
	sparkle.LightEmission = 1
	sparkle.Parent = parent
end

type Design = {
	BodySize: Vector3,
	BodyColor: Color3,
	NozzleZ: number,
	Decorate: (body: BasePart, character: Model) -> (),
}

local BRASS = Color3.fromRGB(230, 180, 60)
local STEEL = Color3.fromRGB(190, 195, 205)

local DESIGNS: { [number]: Design } = {
	-- 1: Sponge, a yellow kitchen sponge with a green scrub pad on top
	{
		BodySize = Vector3.new(1.1, 0.75, 1.5),
		BodyColor = Color3.fromRGB(255, 220, 70),
		NozzleZ = -0.8,
		Decorate = function(body)
			body.Material = Enum.Material.Sand
			piece("ScrubPad", Vector3.new(1.14, 0.2, 1.54), CFrame.new(0, 0.47, 0), Color3.fromRGB(60, 170, 80), body).Material =
				Enum.Material.Fabric
			local suds = piece(
				"Suds",
				Vector3.new(0.5, 0.5, 0.5),
				CFrame.new(0.3, 0.2, -0.6),
				Color3.new(1, 1, 1),
				body,
				Enum.PartType.Ball
			)
			suds.Transparency = 0.3
			glint(body, Color3.fromRGB(220, 245, 255))
		end,
	},
	-- 2: Scrub Brush, a wooden handle with a wide brush head and white bristles
	{
		BodySize = Vector3.new(0.3, 0.3, 1.6),
		BodyColor = Color3.fromRGB(170, 115, 60),
		NozzleZ = -1.35,
		Decorate = function(body)
			body.Material = Enum.Material.Wood
			piece(
				"BrushHead",
				Vector3.new(1.1, 0.35, 0.8),
				CFrame.new(0, -0.05, -1.05),
				Color3.fromRGB(200, 60, 50),
				body
			)
			piece(
				"Bristles",
				Vector3.new(1.0, 0.35, 0.7),
				CFrame.new(0, -0.38, -1.05),
				Color3.fromRGB(245, 240, 225),
				body
			).Material =
				Enum.Material.Fabric
		end,
	},
	-- 3: Garden Hose, green with brass rings and a yellow spray gun; a hose runs back to the reel
	{
		BodySize = Vector3.new(0.42, 0.42, 1.9),
		BodyColor = Color3.fromRGB(60, 170, 80),
		NozzleZ = -1.45,
		Decorate = function(body)
			tube("RingBack", 0.15, 0.55, 0.5, BRASS, body)
			tube("RingFront", 0.15, 0.55, -0.6, BRASS, body)
			tube("Tip", 0.55, 0.5, -1.15, Color3.fromRGB(255, 210, 60), body)
		end,
	},
	-- 4: Power Washer, yellow gun with a red trigger and a long steel lance
	{
		BodySize = Vector3.new(0.5, 0.9, 1.1),
		BodyColor = Color3.fromRGB(255, 205, 40),
		NozzleZ = -2.75,
		Decorate = function(body)
			piece(
				"Grip",
				Vector3.new(0.4, 0.8, 0.45),
				CFrame.new(0, -0.65, 0.3) * CFrame.Angles(math.rad(-15), 0, 0),
				Color3.fromRGB(40, 40, 45),
				body
			)
			piece(
				"Trigger",
				Vector3.new(0.15, 0.35, 0.15),
				CFrame.new(0, -0.5, -0.1),
				Color3.fromRGB(230, 50, 40),
				body
			)
			tube("Lance", 2.0, 0.16, -1.5, STEEL, body, 0.15)
			tube("LanceTip", 0.3, 0.3, -2.55, Color3.fromRGB(230, 50, 40), body, 0.15)
		end,
	},
	-- 5: Foam Cannon, chunky purple body, pink bubble bottle on top, wide flared tip
	{
		BodySize = Vector3.new(0.7, 0.7, 1.6),
		BodyColor = Color3.fromRGB(150, 90, 230),
		NozzleZ = -1.35,
		Decorate = function(body)
			local bottle = piece(
				"FoamBottle",
				Vector3.new(0.9, 0.75, 0.75),
				CFrame.new(0, 0.75, 0.15) * CFrame.Angles(0, 0, math.rad(90)),
				Color3.fromRGB(255, 150, 220),
				body,
				Enum.PartType.Cylinder
			)
			bottle.Material = Enum.Material.Glass
			bottle.Transparency = 0.25
			tube("Flare", 0.4, 0.9, -1.0, Color3.fromRGB(255, 150, 220), body)
			glint(bottle, Color3.fromRGB(255, 220, 250))
		end,
	},
	-- 6: Fire Hose, big red nozzle with a brass tip; the hose runs back to the fire truck
	{
		BodySize = Vector3.new(0.7, 0.7, 2.0),
		BodyColor = Color3.fromRGB(220, 40, 40),
		NozzleZ = -1.75,
		Decorate = function(body)
			tube("BrassTip", 0.6, 0.85, -1.25, BRASS, body)
			tube("Grip", 0.25, 0.9, 0.3, Color3.fromRGB(40, 40, 45), body)
			glint(body, BRASS)
		end,
	},
}

local function removeOld(character: Model)
	local old = WashTool.find(character)
	if old then
		local tool = old.Parent
		if tool and tool:IsA("Tool") then
			tool:Destroy()
		else
			old:Destroy()
		end
	end
end

local function build(tier: number, name: string, cframe: CFrame?): (BasePart, Design)
	local design = DESIGNS[tier] or DESIGNS[1]
	local body = Instance.new("Part")
	body.Name = name
	body.Size = design.BodySize
	body.Color = design.BodyColor
	body.Material = Enum.Material.SmoothPlastic
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.Massless = true
	if cframe then
		body.CFrame = cframe
	end
	body:SetAttribute("Tier", tier)

	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, if tier == 4 then 0.15 else 0, design.NozzleZ)
	nozzle.Parent = body
	-- Where the station's hose (StationProps) clips onto the tool.
	local feed = Instance.new("Attachment")
	feed.Name = "Feed"
	feed.Position = Vector3.new(0, -0.1, design.BodySize.Z / 2)
	feed.Parent = body
	return body, design
end

-- The cutscene avatar: no backpack, so the tool is welded straight to the hand.
function HoseBuilder.equip(character: Model, tier: number)
	local hand = character:WaitForChild("RightHand", 5) or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") or not character.Parent then
		return
	end
	removeOld(character)
	local body, design = build(tier, "Hose", hand.CFrame * CFrame.new(0, -0.2, -0.6))
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = body
	weld.Parent = body
	design.Decorate(body, character)
	body.Parent = character
end

-- The tool on its own, anchored, for a picture (the gear shop's viewport). Pivoted on the
-- handle, nozzle toward -Z.
function HoseBuilder.preview(tier: number): Model
	local model = Instance.new("Model")
	model.Name = "GearPreview"
	local body, design = build(tier, "Handle", CFrame.new())
	body.Parent = model
	design.Decorate(body, model)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	model.PrimaryPart = body
	return model
end

-- A player's cleaning tool: a real Tool named after the tier, so the hotbar shows "Sponge",
-- "Fire Hose" and so on. It is always equipped; putting it away puts it straight back.
function HoseBuilder.give(player: Player, character: Model, tier: number)
	if not character.Parent then
		return
	end
	removeOld(character)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, item in backpack:GetChildren() do
			if item:IsA("Tool") and item:GetAttribute(WashTool.ATTRIBUTE) == true then
				item:Destroy()
			end
		end
	end
	local tool = Instance.new("Tool")
	local info = ToolConfig[tier] or ToolConfig[1]
	tool.Name = info.Name
	tool.ToolTip = `Tier {info.Tier} cleaning gear`
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute(WashTool.ATTRIBUTE, true)
	tool:SetAttribute("Tier", tier)
	local body, design = build(tier, "Handle", nil)
	body.Parent = tool
	-- Decorations weld to the handle where it is built, before the grip moves it.
	body.CFrame = CFrame.new()
	design.Decorate(body, character)
	tool.Unequipped:Connect(function()
		task.defer(function()
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if
				tool.Parent
				and tool.Parent ~= character
				and player.Character == character
				and humanoid
				and humanoid.Health > 0
			then
				humanoid:EquipTool(tool)
			end
		end)
	end)
	tool.Parent = character
end

return HoseBuilder
