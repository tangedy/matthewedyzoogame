-- Animal roster. Each species has a fixed rarity tier (Steal a Brainrot style) and earns
-- Income cash per second while it lives in one of your pens (times its mutation multiplier).
-- SpawnWeight is relative. RequiredToolTier and RarityConfig.RequiredCleaningPower both gate
-- which animals can walk in, so a hose only rolls animals it has the clean power to wash.
-- Scripted teases (the 10th animal, and one rarity ahead after each upgrade) skip that gate.
-- WashTimeMultiplier scales total dirt relative to BaseWashSeconds.
-- Values are tuning proposals, not final economy.

export type AnimalDefinition = {
	DisplayName: string,
	TemplateName: string,
	Rarity: string,
	Income: number,
	SpawnWeight: number,
	RequiredToolTier: number,
	WashTimeMultiplier: number,
	Limited: boolean?, -- sold, never spawns (SpawnWeight 0); see the monetization feature
}

local function animal(
	name: string,
	rarity: string,
	income: number,
	weight: number,
	toolTier: number,
	washTime: number
): AnimalDefinition
	return {
		DisplayName = name,
		TemplateName = name,
		Rarity = rarity,
		Income = income,
		SpawnWeight = weight,
		RequiredToolTier = toolTier,
		WashTimeMultiplier = washTime,
	}
end

-- Never walks in (SpawnWeight 0); sold by the monetization feature with a global stock.
local function limited(def: AnimalDefinition): AnimalDefinition
	def.Limited = true
	return def
end

local AnimalConfig = {
	FirstAnimal = "Pig", -- the first animal of a session is deterministic (and Normal)

	Animals = {
		-- Common
		Chicken = animal("Chicken", "Common", 1, 40, 1, 0.6),
		Duck = animal("Duck", "Common", 1, 40, 1, 0.7),
		Rabbit = animal("Rabbit", "Common", 2, 40, 1, 0.75),
		Pig = animal("Pig", "Common", 3, 40, 1, 1.0),
		-- Rare
		Sheep = animal("Sheep", "Rare", 6, 15, 1, 1.3),
		Goat = animal("Goat", "Rare", 7, 15, 1, 1.25),
		Dog = animal("Dog", "Rare", 8, 15, 1, 1.1),
		Cat = animal("Cat", "Rare", 9, 15, 1, 0.9),
		-- Epic
		Cow = animal("Cow", "Epic", 18, 6, 2, 1.8),
		Donkey = animal("Donkey", "Epic", 20, 6, 2, 1.6),
		Penguin = animal("Penguin", "Epic", 22, 6, 2, 1.0),
		Fox = animal("Fox", "Epic", 25, 6, 2, 1.0),
		-- Legendary
		Llama = animal("Llama", "Legendary", 55, 2, 3, 1.9),
		Zebra = animal("Zebra", "Legendary", 65, 2, 3, 2.2),
		Horse = animal("Horse", "Legendary", 70, 2, 3, 2.2),
		Panda = animal("Panda", "Legendary", 80, 2, 3, 2.0),
		Griffon = animal("Griffon", "Legendary", 90, 1.5, 3, 2.3),
		-- Mythic
		Lion = animal("Lion", "Mythic", 180, 0.6, 4, 2.4),
		Hippo = animal("Hippo", "Mythic", 220, 0.6, 4, 3.0),
		Giraffe = animal("Giraffe", "Mythic", 250, 0.6, 4, 2.8),
		Phoenix = animal("Phoenix", "Mythic", 280, 0.5, 4, 2.2),
		Kitsune = animal("Kitsune", "Mythic", 300, 0.5, 4, 2.4),
		Axolotl = limited(animal("Axolotl", "Mythic", 400, 0, 1, 1.2)),
		-- Zoo God
		Elephant = animal("Elephant", "ZooGod", 800, 0.15, 5, 4.0),
		Unicorn = animal("Unicorn", "ZooGod", 1000, 0.15, 5, 2.6),
		Dragon = animal("Dragon", "ZooGod", 1200, 0.12, 5, 4.2),
		-- Secret
		TRex = animal("T-Rex", "Secret", 3000, 0.03, 6, 4.5),
		Kaiju = animal("Kaiju", "Secret", 5000, 0.02, 6, 5.0),
	} :: { [string]: AnimalDefinition },
}
AnimalConfig.Animals.TRex.TemplateName = "TRex"

return AnimalConfig
