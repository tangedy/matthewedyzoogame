-- Pen tiers by how much cash the pen's pad can hold (GameConfig.PenCashCap). Each tier has
-- its own fence wood, so a richer pen reads as richer from across the farm, and the same
-- colour marks the MAX line on its cash counter. Used by the server (fence colour) and the
-- client (counter).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local PenTiers = {}

export type Tier = {
	Name: string,
	MinCap: number, -- the tier applies from this cap up
	Wood: Color3, -- fence colour
	Text: Color3, -- MAX label colour, readable over the sky and grass
}

-- Lowest first. Base caps today: stall 2K, medium 20K, giant 100K, gargantuan 1M (the Pen
-- Storage upgrade raises them up to 2.5x).
PenTiers.List = {
	{ Name = "Oak", MinCap = 0, Wood = Color3.fromRGB(150, 110, 70), Text = Color3.fromRGB(230, 200, 160) },
	{ Name = "Redwood", MinCap = 10000, Wood = Color3.fromRGB(170, 66, 44), Text = Color3.fromRGB(255, 140, 110) },
	{ Name = "Golden", MinCap = 100000, Wood = Color3.fromRGB(232, 182, 52), Text = Color3.fromRGB(255, 215, 80) },
	{ Name = "Royal", MinCap = 1000000, Wood = Color3.fromRGB(132, 86, 214), Text = Color3.fromRGB(200, 160, 255) },
} :: { Tier }

function PenTiers.forCap(cap: number): Tier
	local found = PenTiers.List[1]
	for _, tier in PenTiers.List do
		if cap >= tier.MinCap then
			found = tier
		end
	end
	return found
end

function PenTiers.capForClass(class: string?): number
	local caps: { [string]: number } = GameConfig.PenCashCap
	return caps[class or "Standard"] or caps.Standard
end

function PenTiers.forClass(class: string?): Tier
	return PenTiers.forCap(PenTiers.capForClass(class))
end

return PenTiers
