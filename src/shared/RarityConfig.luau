-- Rarity tiers, following Steal a Brainrot's ladder. Each species belongs to one tier
-- (AnimalConfig); tiers set the nameplate colour and whether a walk-in is announced.
-- "Farm God" (key ZooGod) is our Brainrot God: an animated rainbow label. Secret is white with a black edge.
-- RequiredCleaningPower is the hose power (GearLadder step CleaningPower) needed to wash
-- that tier. A walk-in above the player's power can be let go, or cleaned
-- with the Clean Now product.

export type Rarity = {
	Key: string,
	Order: number,
	DisplayName: string,
	Color: Color3, -- label colour (ignored for Rainbow-styled tiers)
	StrokeColor: Color3,
	Rainbow: boolean, -- animated rainbow gradient label (Zoo God)
	Announce: boolean, -- server-wide announcement when one walks in
	RequiredCleaningPower: number,
}

local list: { Rarity } = {
	{
		Key = "Common",
		Order = 1,
		DisplayName = "Common",
		Color = Color3.fromRGB(200, 200, 200),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = false,
		RequiredCleaningPower = 0,
	},
	{
		Key = "Rare",
		Order = 2,
		DisplayName = "Rare",
		Color = Color3.fromRGB(60, 140, 255),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = false,
		RequiredCleaningPower = 0,
	},
	{
		Key = "Epic",
		Order = 3,
		DisplayName = "Epic",
		Color = Color3.fromRGB(170, 70, 255),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = false,
		RequiredCleaningPower = 0.85, -- Garden Hose (0.9). Sponge and Scrub Brush cannot.
	},
	{
		Key = "Legendary",
		Order = 4,
		DisplayName = "Legendary",
		Color = Color3.fromRGB(255, 205, 40),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = false,
		RequiredCleaningPower = 1.25, -- Power Washer (1.4). Garden Hose (0.9) cannot.
	},
	{
		Key = "Mythic",
		Order = 5,
		DisplayName = "Mythic",
		Color = Color3.fromRGB(255, 50, 50),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = true,
		RequiredCleaningPower = 2.15, -- Foam Cannon (2.2). Power Washer cannot.
	},
	{
		Key = "ZooGod",
		Order = 6,
		DisplayName = "Farm God",
		Color = Color3.fromRGB(255, 255, 255),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = true,
		Announce = true,
		RequiredCleaningPower = 3.4, -- Fire Hose (3.5). Foam Cannon cannot.
	},
	{
		Key = "Secret",
		Order = 7,
		DisplayName = "Secret",
		Color = Color3.new(1, 1, 1),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = true,
		RequiredCleaningPower = 6, -- only the fully upgraded Fire Hose (Titan Spec, 6)
	},
}

local byKey: { [string]: Rarity } = {}
for _, rarity in list do
	byKey[rarity.Key] = rarity
end

return {
	List = list,
	ByKey = byKey,
}
