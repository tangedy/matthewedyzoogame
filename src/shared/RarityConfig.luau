-- Rarity tiers, following Steal a Brainrot's ladder. Each species belongs to one tier
-- (AnimalConfig); tiers set the nameplate colour and whether a walk-in is announced.
-- "Zoo God" is our Brainrot God: an animated rainbow label. Secret is black with a white edge.

export type Rarity = {
	Key: string,
	Order: number,
	DisplayName: string,
	Color: Color3, -- label colour (ignored for Rainbow-styled tiers)
	StrokeColor: Color3,
	Rainbow: boolean, -- animated rainbow gradient label (Zoo God)
	Announce: boolean, -- server-wide announcement when one walks in
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
	},
	{
		Key = "Rare",
		Order = 2,
		DisplayName = "Rare",
		Color = Color3.fromRGB(60, 140, 255),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = false,
	},
	{
		Key = "Epic",
		Order = 3,
		DisplayName = "Epic",
		Color = Color3.fromRGB(170, 70, 255),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = false,
	},
	{
		Key = "Legendary",
		Order = 4,
		DisplayName = "Legendary",
		Color = Color3.fromRGB(255, 205, 40),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = false,
	},
	{
		Key = "Mythic",
		Order = 5,
		DisplayName = "Mythic",
		Color = Color3.fromRGB(255, 50, 50),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = false,
		Announce = true,
	},
	{
		Key = "ZooGod",
		Order = 6,
		DisplayName = "Zoo God",
		Color = Color3.fromRGB(255, 255, 255),
		StrokeColor = Color3.new(0, 0, 0),
		Rainbow = true,
		Announce = true,
	},
	{
		Key = "Secret",
		Order = 7,
		DisplayName = "Secret",
		Color = Color3.fromRGB(10, 10, 10),
		StrokeColor = Color3.new(1, 1, 1),
		Rainbow = false,
		Announce = true,
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
