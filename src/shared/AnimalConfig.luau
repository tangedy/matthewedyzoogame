-- Animal roster. Values are initial tuning proposals from the design doc, not final economy.
-- WashTimeMultiplier scales total dirt relative to GameConfig.BaseWashSeconds
-- (doc: Pig 1.0x, Sheep 1.3x, Cow 1.8x), independent of how many patches the model has.

export type AnimalDefinition = {
	DisplayName: string,
	TemplateName: string,
	BaseReward: number,
	SelectionWeight: number,
	RequiredToolTier: number,
	WashTimeMultiplier: number,
}

local AnimalConfig = {
	FirstAnimal = "Pig", -- the first animal of a session is deterministic

	Animals = {
		Pig = {
			DisplayName = "Pig",
			TemplateName = "Pig",
			BaseReward = 25,
			SelectionWeight = 60,
			RequiredToolTier = 1,
			WashTimeMultiplier = 1.0,
		},
		Sheep = {
			DisplayName = "Sheep",
			TemplateName = "Sheep",
			BaseReward = 35,
			SelectionWeight = 30,
			RequiredToolTier = 1,
			WashTimeMultiplier = 1.3,
		},
		Cow = {
			DisplayName = "Cow",
			TemplateName = "Cow",
			BaseReward = 50,
			SelectionWeight = 10,
			RequiredToolTier = 1,
			WashTimeMultiplier = 1.8,
		},
	} :: { [string]: AnimalDefinition },
}

return AnimalConfig
