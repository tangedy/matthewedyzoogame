-- Mutations rolled for every walk-in, Steal a Brainrot style: a variant look plus an income
-- multiplier. Weights are relative. The index tracks every species x mutation.

export type Mutation = {
	Key: string,
	Order: number,
	DisplayName: string,
	Weight: number,
	IncomeMultiplier: number,
	Color: Color3, -- label colour
	Rainbow: boolean, -- animated rainbow label
	Announce: boolean,
}

local list: { Mutation } = {
	{
		Key = "Normal",
		Order = 1,
		DisplayName = "Normal",
		Weight = 85,
		IncomeMultiplier = 1,
		Color = Color3.new(1, 1, 1),
		Rainbow = false,
		Announce = false,
	},
	{
		Key = "Gold",
		Order = 2,
		DisplayName = "Gold",
		Weight = 10,
		IncomeMultiplier = 1.25,
		Color = Color3.fromRGB(255, 200, 40),
		Rainbow = false,
		Announce = false,
	},
	{
		Key = "Diamond",
		Order = 3,
		DisplayName = "Diamond",
		Weight = 4.5,
		IncomeMultiplier = 1.5,
		Color = Color3.fromRGB(110, 230, 255),
		Rainbow = false,
		Announce = false,
	},
	{
		Key = "Rainbow",
		Order = 4,
		DisplayName = "Rainbow",
		Weight = 0.5,
		IncomeMultiplier = 10,
		Color = Color3.new(1, 1, 1),
		Rainbow = true,
		Announce = true,
	},
}

local byKey: { [string]: Mutation } = {}
for _, mutation in list do
	byKey[mutation.Key] = mutation
end

return {
	List = list,
	ByKey = byKey,
	Default = "Normal",
}
