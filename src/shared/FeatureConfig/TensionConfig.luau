-- Tuning for the tension feature (src/server/Features/Tension): animal moods, the patience
-- meter, the mud shake, grumpy lunges, and the wander-off timer on Mythic and rarer animals.
--
-- Each species gets a profile: its rarity's defaults with any per-species override on top.
-- Patience is sized from the wash itself: at wash start the server estimates how long one
-- patch at a time would take with the player's hose,
--   expected = BaseWashSeconds * ToolConfig[1].CleaningPower * WashTimeMultiplier / hose power
-- (an upper bound: a spray usually hits several patches), then
--   patience = clamp(expected * PatienceFactor + PatienceSlack, MinPatience, PatienceSeconds).
-- Common/Rare stay generous; Mythic and rarer are tight but beatable, so the shake actually
-- happens in normal play rather than only when a player goes AFK.

export type Mood = "Calm" | "Ticklish" | "Grumpy"

export type Profile = {
	Mood: Mood,
	PatienceSeconds: number, -- cap on patience (seconds from full to empty; drains at 1 per second)
	PatienceFactor: number, -- patience = expected wash seconds * this + PatienceSlack ...
	PatienceSlack: number, -- ... seconds of walking/aiming time on top
	MinPatience: number, -- floor, in seconds
	ShakeRedirty: number, -- fraction of the already-clean patches the shake muddies again
	ShakeRadius: number, -- studs from the animal; every character inside is flung and splatted
	Knockback: number, -- horizontal fling speed (studs/s) at the animal; falls off with distance
	KnockUp: number, -- upward fling speed (studs/s)
	WanderOffSeconds: number, -- 0 = never wanders off; otherwise the cap on the wander-off timer
}

export type ProfileOverride = {
	Mood: Mood?,
	PatienceSeconds: number?,
	PatienceFactor: number?,
	PatienceSlack: number?,
	MinPatience: number?,
	ShakeRedirty: number?,
	ShakeRadius: number?,
	Knockback: number?,
	KnockUp: number?,
	WanderOffSeconds: number?,
}

local TensionConfig = {
	-- No tension at all until the player has finished this many washes (LifetimeAnimalsWashed),
	-- and never on the first animal of a session.
	GraceWashes = 3,

	RefillFraction = 0.7, -- patience refills to this after a shake
	LowFraction = 0.2, -- below this: warning UI, and the "PatienceLow" hook fires (once per wash)
	MaxCalmSeconds = 600, -- a single Calm Treat can't freeze patience for longer than this
	StateSendInterval = 0.2,
	-- Wander-off timer = clamp(expected wash seconds * WanderFactor, MinWanderSeconds,
	-- WanderOffSeconds). It runs through shakes, so a player who lets it shake twice can lose it.
	WanderFactor = 4,
	MinWanderSeconds = 30, -- seconds between patience updates sent to the washing player

	Squirm = { -- Ticklish
		IntervalMin = 1,
		IntervalMax = 2,
		Duration = 0.45,
		MaxYawDegrees = 10,
		MaxRollDegrees = 6,
		MaxShift = 0.2, -- studs sideways; the animal never leaves its wash spot
	},

	Lunge = { -- Grumpy, only while patience is below BelowFraction
		BelowFraction = 0.4,
		CooldownMin = 3.5,
		CooldownMax = 5.5,
		Range = 14, -- studs: it only lunges at a player this close
		WindUp = 0.6, -- telegraph: rears back and shakes
		Strike = 0.15,
		Hold = 0.1,
		Return = 0.35,
		Distance = 1, -- studs toward the target
		RearBack = 0.4, -- studs away from the target during the wind-up
		HitDistance = 2.5, -- studs between a character and the animal's box that counts as touching
		Knockback = 55,
		KnockUp = 28,
		RagdollSeconds = 1.2,
	},

	Shake = {
		Duration = 0.9, -- the full-body wiggle
		ExplodeAt = 0.15, -- seconds into the wiggle when the mud flies
		WiggleDegrees = 14,
		WiggleHz = 16,
		Particles = 90, -- scaled up with the shake radius
		Puddles = 8, -- mud splats left on the ground
		PuddleSeconds = 4,
		RagdollSeconds = 1.6,
		MinFalloff = 0.55, -- fling strength at the edge of the radius, as a fraction of full
		CameraShakeRange = 2.2, -- times ShakeRadius: clients this close get a camera shake
		CameraShakeIntensity = 1,
		CameraShakeSeconds = 0.7,
	},

	Sounds = {
		Shake = "rbxasset://sounds/impact_water.mp3",
		WindUp = "rbxasset://sounds/impact_water.mp3",
		Fling = "rbxasset://sounds/uuhhh.mp3", -- played locally on each flung player
		Warning = "rbxasset://sounds/electronicpingshort.wav",
	},

	MudColors = {
		Color3.fromRGB(110, 72, 40),
		Color3.fromRGB(92, 60, 34),
		Color3.fromRGB(130, 88, 50),
		Color3.fromRGB(75, 50, 28),
	},

	-- Sent only to the owner when their Mythic+ animal gives up. {name} = the animal's name.
	WanderOffLines = {
		"Your {name} got bored and wandered off. Rude!",
		"Your {name} left to find a better car wash.",
		"Your {name} said 'nah' and walked away covered in mud.",
		"Your {name} wandered off. It had places to be.",
	},

	ByRarity = {
		Common = {
			Mood = "Calm",
			PatienceSeconds = 40,
			PatienceFactor = 6,
			PatienceSlack = 12,
			MinPatience = 15,
			ShakeRedirty = 0.3,
			ShakeRadius = 14,
			Knockback = 63,
			KnockUp = 31,
			WanderOffSeconds = 0,
		},
		Rare = {
			Mood = "Calm",
			PatienceSeconds = 34,
			PatienceFactor = 5,
			PatienceSlack = 10,
			MinPatience = 13,
			ShakeRedirty = 0.35,
			ShakeRadius = 16,
			Knockback = 72,
			KnockUp = 35,
			WanderOffSeconds = 0,
		},
		Epic = {
			Mood = "Ticklish",
			PatienceSeconds = 28,
			PatienceFactor = 4,
			PatienceSlack = 7,
			MinPatience = 10,
			ShakeRedirty = 0.4,
			ShakeRadius = 18,
			Knockback = 86,
			KnockUp = 39,
			WanderOffSeconds = 0,
		},
		Legendary = {
			Mood = "Ticklish",
			PatienceSeconds = 25,
			PatienceFactor = 3,
			PatienceSlack = 5,
			MinPatience = 8,
			ShakeRedirty = 0.4,
			ShakeRadius = 21,
			Knockback = 99,
			KnockUp = 45,
			WanderOffSeconds = 0,
		},
		Mythic = {
			Mood = "Grumpy",
			PatienceSeconds = 22,
			PatienceFactor = 2.5,
			PatienceSlack = 4,
			MinPatience = 7,
			ShakeRedirty = 0.45,
			ShakeRadius = 24,
			Knockback = 117,
			KnockUp = 53,
			WanderOffSeconds = 100,
		},
		ZooGod = {
			Mood = "Grumpy",
			PatienceSeconds = 26,
			PatienceFactor = 2.5,
			PatienceSlack = 4.5,
			MinPatience = 7.5,
			ShakeRedirty = 0.45,
			ShakeRadius = 29,
			Knockback = 135,
			KnockUp = 59,
			WanderOffSeconds = 110,
		},
		Secret = {
			Mood = "Grumpy",
			PatienceSeconds = 26,
			PatienceFactor = 2.5,
			PatienceSlack = 4.5,
			MinPatience = 7.5,
			ShakeRedirty = 0.5,
			ShakeRadius = 32,
			Knockback = 144,
			KnockUp = 63,
			WanderOffSeconds = 120,
		},
	} :: { [string]: Profile },

	BySpecies = {
		Cat = { Mood = "Ticklish" },
		Goat = { Mood = "Grumpy" },
		Cow = { Mood = "Calm", PatienceSeconds = 32, MinPatience = 18 },
		Donkey = { Mood = "Grumpy" },
		Penguin = { Mood = "Ticklish" },
		Zebra = { Mood = "Grumpy" },
		Panda = { Mood = "Calm", PatienceSeconds = 30, MinPatience = 16 },
		Giraffe = { Mood = "Ticklish" },
		Hippo = { ShakeRadius = 32, Knockback = 153, KnockUp = 67 }, -- the big one for clips
		Elephant = { ShakeRadius = 35, Knockback = 162 },
		Unicorn = { Mood = "Ticklish" },
		-- Bought, not found: a paid animal must never be lost, and stays gentle.
		Axolotl = {
			Mood = "Calm",
			PatienceSeconds = 40,
			PatienceFactor = 6,
			PatienceSlack = 12,
			MinPatience = 20,
			WanderOffSeconds = 0,
		},
	} :: { [string]: ProfileOverride },
}

return TensionConfig
