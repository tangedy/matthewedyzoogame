-- Builds the hose model in the player's right hand, one look per tool tier, so upgrades are
-- felt: a garden hose, an orange spray hose, a brass-ringed strong hose, a yellow pressure-washer gun, a foam
-- cannon with a bubble bottle, and a fire-hose rig with a tank on the back.
--
-- The main part is always named "Hose" (the server's "has a tool" check) and carries the
-- "Nozzle" attachment the client draws the spray from. Everything else is welded to it.

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
	-- 1: Basic Hose, a green garden hose with a yellow spray tip
	{
		BodySize = Vector3.new(0.35, 0.35, 1.6),
		BodyColor = Color3.fromRGB(60, 170, 80),
		NozzleZ = -1.05,
		Decorate = function(body)
			tube("Tip", 0.35, 0.45, -0.9, Color3.fromRGB(255, 210, 60), body)
		end,
	},
	-- 2: Spray Hose, an orange garden hose with a chunky green spray head
	{
		BodySize = Vector3.new(0.38, 0.38, 1.7),
		BodyColor = Color3.fromRGB(240, 130, 40),
		NozzleZ = -1.2,
		Decorate = function(body)
			tube("Tip", 0.45, 0.55, -1.0, Color3.fromRGB(80, 200, 90), body)
		end,
	},
	-- 3: Strong Hose, blue with brass rings and a steel nozzle
	{
		BodySize = Vector3.new(0.42, 0.42, 1.9),
		BodyColor = Color3.fromRGB(60, 120, 230),
		NozzleZ = -1.45,
		Decorate = function(body)
			tube("RingBack", 0.15, 0.55, 0.5, BRASS, body)
			tube("RingFront", 0.15, 0.55, -0.6, BRASS, body)
			tube("Tip", 0.55, 0.4, -1.15, STEEL, body)
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
	-- 6: Fire-Hose Rig, big red nozzle with a brass tip and a tank on the back
	{
		BodySize = Vector3.new(0.7, 0.7, 2.0),
		BodyColor = Color3.fromRGB(220, 40, 40),
		NozzleZ = -1.75,
		Decorate = function(body, character)
			tube("BrassTip", 0.6, 0.85, -1.25, BRASS, body)
			tube("Grip", 0.25, 0.9, 0.3, Color3.fromRGB(40, 40, 45), body)
			glint(body, BRASS)
			local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
			if torso and torso:IsA("BasePart") then
				local tank = piece(
					"HoseTank",
					Vector3.new(2.0, 1.1, 1.1),
					CFrame.new(0, 0.1, torso.Size.Z / 2 + 0.55) * CFrame.Angles(0, 0, math.rad(90)),
					Color3.fromRGB(220, 40, 40),
					torso,
					Enum.PartType.Cylinder
				)
				tank.Name = "HoseTank"
				tube("TankBand", 0.2, 1.2, 0, BRASS, tank)
			end
		end,
	},
}

local function removeOld(character: Model)
	local old = character:FindFirstChild("Hose")
	if old then
		old:Destroy()
	end
	for _, d in character:GetDescendants() do
		if d.Name == "HoseTank" then
			d:Destroy()
		end
	end
end

function HoseBuilder.equip(character: Model, tier: number)
	local hand = character:WaitForChild("RightHand", 5) or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") or not character.Parent then
		return
	end
	removeOld(character)
	local design = DESIGNS[tier] or DESIGNS[1]

	local body = Instance.new("Part")
	body.Name = "Hose"
	body.Size = design.BodySize
	body.Color = design.BodyColor
	body.Material = Enum.Material.SmoothPlastic
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.Massless = true
	body.CFrame = hand.CFrame * CFrame.new(0, -0.2, -0.6)
	body:SetAttribute("Tier", tier)

	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, if tier == 4 then 0.15 else 0, design.NozzleZ)
	nozzle.Parent = body

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = body
	weld.Parent = body
	design.Decorate(body, character)
	body.Parent = character
end

return HoseBuilder
