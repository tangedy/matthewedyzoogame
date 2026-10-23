-- Animal roster. Each species has a fixed rarity tier (Steal a Brainrot style) and earns
-- Income cash per second while it lives in one of your pens (times its mutation multiplier).
-- SpawnWeight is relative. RequiredToolTier and RarityConfig.RequiredCleaningPower both gate
-- which animals can walk in, so a hose only rolls animals it has the clean power to wash.
-- Scripted walk-ins of a rarity this hose cannot wash skip that gate.
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
	-- Which pens can hold this animal. Standard fits a face stall. Larger classes need a
	-- barn pen built for them (see AnimalConfig.fits).
	BodyClass: "Standard" | "Large" | "ExtraLarge" | "Giant" | "Gargantuan",
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
		BodyClass = "Standard",
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
		Cow = animal("Cow", "Epic", 18, 6, 3, 1.8),
		Donkey = animal("Donkey", "Epic", 20, 6, 3, 1.6),
		Penguin = animal("Penguin", "Epic", 22, 6, 3, 1.0),
		Fox = animal("Fox", "Epic", 25, 6, 3, 1.0),
		-- Legendary
		Llama = animal("Llama", "Legendary", 55, 2, 4, 1.9),
		Zebra = animal("Zebra", "Legendary", 65, 2, 4, 2.2),
		Horse = animal("Horse", "Legendary", 70, 2, 4, 2.2),
		Panda = animal("Panda", "Legendary", 80, 2, 4, 2.0),
		Griffon = animal("Griffon", "Legendary", 90, 1.5, 4, 2.3),
		-- Mythic
		Lion = animal("Lion", "Mythic", 180, 0.6, 5, 2.4),
		Hippo = animal("Hippo", "Mythic", 220, 0.6, 5, 3.0),
		Giraffe = animal("Giraffe", "Mythic", 250, 0.6, 5, 2.8),
		Phoenix = animal("Phoenix", "Mythic", 280, 0.5, 5, 2.2),
		Kitsune = animal("Kitsune", "Mythic", 300, 0.5, 5, 2.4),
		Axolotl = limited(animal("Axolotl", "Mythic", 400, 0, 1, 1.2)),
		-- Zoo God
		Elephant = animal("Elephant", "ZooGod", 800, 0.15, 6, 4.0),
		Unicorn = animal("Unicorn", "ZooGod", 1000, 0.15, 6, 2.6),
		Dragon = animal("Dragon", "ZooGod", 1200, 0.12, 6, 4.2),
		-- Secret
		TRex = animal("T-Rex", "Secret", 3000, 0.03, 7, 4.5),
		Kaiju = animal("Kaiju", "Secret", 5000, 0.02, 7, 5.0),
	} :: { [string]: AnimalDefinition },
}
AnimalConfig.Animals.TRex.TemplateName = "TRex"

local BODY: { [string]: string } = {
	Cow = "Large",
	Donkey = "Large",
	Horse = "Large",
	Llama = "Large",
	Zebra = "Large",
	Panda = "Large",
	Lion = "Large",
	Giraffe = "ExtraLarge",
	Hippo = "ExtraLarge",
	Griffon = "ExtraLarge",
	Phoenix = "ExtraLarge",
	Kitsune = "ExtraLarge",
	Elephant = "Giant",
	Unicorn = "Giant",
	Dragon = "Gargantuan",
	TRex = "Gargantuan",
	Kaiju = "Gargantuan",
}
for key, class in BODY do
	AnimalConfig.Animals[key].BodyClass = class
end

-- Pen classes accept every body class at or below this rank.
local BODY_RANK = { Standard = 1, Large = 2, ExtraLarge = 3, Giant = 4, Gargantuan = 5 }
local PEN_ACCEPTS = { Standard = 1, Medium = 3, Large = 3, Giant = 4, Gargantuan = 5 }

-- The pasture behind the barns is only for medium and large animals.
-- Medium animals are BodyClass Large (cow, horse, lion). Large animals are ExtraLarge.
-- PastureFlex holds two mediums or one large: a medium spends 1 slot, a large spends 2.
local PASTURE_ONLY = {
	PastureMedium = "Large",
	PastureLarge = "ExtraLarge",
}
local FLEX_SLOTS = { Large = 1, ExtraLarge = 2 }
local FLEX_CAPACITY = 2

function AnimalConfig.fits(bodyClass: string, penClass: string): boolean
	if penClass == "PastureFlex" then
		return FLEX_SLOTS[bodyClass] ~= nil
	end
	local only = PASTURE_ONLY[penClass]
	if only then
		return bodyClass == only
	end
	return (BODY_RANK[bodyClass] or 1) <= (PEN_ACCEPTS[penClass] or 1)
end

-- Slots a flex pasture spends on this body. Nil when the body cannot go in one.
function AnimalConfig.flexSlots(bodyClass: string): number?
	return FLEX_SLOTS[bodyClass]
end

function AnimalConfig.flexCapacity(): number
	return FLEX_CAPACITY
end

-- Prompt text when a carried animal does not fit the pen under the cursor.
function AnimalConfig.placementHint(bodyClass: string, penClass: string): string
	if penClass == "PastureMedium" and bodyClass == "ExtraLarge" then
		return "Use a large pen"
	elseif penClass == "PastureLarge" and bodyClass == "Large" then
		return "Use a medium pen"
	elseif penClass == "PastureFlex" then
		return "Only medium or large animals"
	end
	return `Needs a {AnimalConfig.penNeeded(bodyClass)} pen`
end

-- The smallest pen that can hold this body, named for the prompt.
function AnimalConfig.penNeeded(bodyClass: string): string
	if bodyClass == "Gargantuan" then
		return "gargantuan"
	elseif bodyClass == "Giant" then
		return "giant"
	elseif bodyClass == "ExtraLarge" or bodyClass == "Large" then
		return "medium"
	end
	return "stall"
end

return AnimalConfig
