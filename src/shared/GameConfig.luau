-- Global gameplay and tuning values. Keep magic numbers here, not in services.

local GameConfig = {
	-- World
	-- Eight plots: four on each side of a center road. Bays are built only while a player
	-- owns one. BayCount caps how many; set the place's Max Players to match.
	BayCount = 8,
	-- Along Z. Width is 126 and the gap between plots stays 20, the same gap the old
	-- 150-by-130 grid used, so fences, the road, and the truck still clear every plot.
	BaySpacing = 146,
	-- The dirt road runs along Z through the middle. Plots grow away from it (east +X, west -X)
	-- so a barn can expand backward without crossing the street or a neighbor.
	RoadX = 0,
	RoadWidth = 45, -- five times the old 9-stud road
	SidewalkWidth = 14, -- the path behind the wash; the six stalls open onto it from both sides
	-- Mega pens reach 60 studs from the plot centre. Half of 126 leaves a 3-stud margin.
	PlotWidth = 126,
	-- From the road edge through the mega barn, plus a short pasture. The old 490 included
	-- empty ground behind that barn.
	PlotDepth = 440,
	GroundSize = Vector3.new(1000, 2, 760), -- plots, the road, and the board at the south end
	WashQueue = 3, -- animals standing in the square lane; only the front one is washed

	-- Spraying (shared by client and server so both use the same nozzle origin)
	NozzleOffset = Vector3.new(0, 1.5, 0), -- from HumanoidRootPart
	RequestRateHz = 15, -- client cleaning request cadence
	MinRequestInterval = 0.04, -- server drops requests arriving faster than this
	-- Spraying aims along the camera ray, so any side visible on screen can be washed from
	-- wherever the player stands. The hit must still be within the hose's Range (+ slack)
	-- of the player, and the camera within this distance of them.
	AimReachSlack = 4,
	MaxAimCameraDistance = 160,
	MaxAcceptedStep = 0.1, -- max seconds of cleaning credited per request
	SprayRadius = 1.6, -- aim assist: a patch counts as reachable if the ray lands this close

	-- Touch/gamepad aiming (client only; the server still validates every spray)
	CenterAimHeight = 0.4, -- reticle height as a fraction of the screen, above the character
	AimAssistRadius = 0.18, -- snap to a dirty patch within this fraction of the screen's short side

	-- Dirt
	-- Seconds of continuous on-target spraying a 1.0x animal needs with the tier 1 hose, if
	-- each hit cleaned only one patch. Hits clean an area (ToolConfig.SprayRadius), so mud
	-- pops off almost instantly; walking around the animal is most of the wash.
	BaseWashSeconds = 2.5,
	PatchCleanThreshold = 0.05, -- a patch below this fraction snaps to clean
	HintProgress = 0.85, -- progress at which remaining patches get highlighted

	-- Lifecycle timings (seconds). Kept short so there's almost always an animal to wash:
	-- about 6 s between finishing one animal and being able to spray the next.
	ArriveDuration = 3.5, -- from the road (x -54) to the wash spot
	DepartDuration = 2,
	CelebrationDuration = 1.5,
	StartingCoins = 90, -- a new player's cash, $10 short of the Scrub Brush
	NextAnimalDelay = 0.5,

	-- Persistence. ProfileService owns the live store. The older DataStore names stay so a
	-- profile's first load can copy a save from before that switch. Studio uses its own
	-- names so test data never touches live players.
	DataStoreName = "PlayerData_v1",
	StudioDataStoreName = "PlayerData_Studio_v1",
	ProfileStoreName = "WashZoo_Profile_v1",
	StudioProfileStoreName = "WashZoo_Profile_Studio_v1",
	AutosaveInterval = 60, -- also refreshes the session lock
	SessionLockExpiry = 300, -- a lock not refreshed for this long is considered abandoned
	LockRetryAttempts = 6,
	LockRetryDelay = 4,

	-- Economy (cash). An animal's value is expressed in seconds of its income.
	WashRewardSeconds = 15, -- finishing a wash pays this many seconds of the animal's income
	SellValueSeconds = 60, -- selling (or swapping out) an animal pays this many seconds of income
	DiscoveryBonusMultiplier = 1, -- first wash of a species+mutation pays this much extra
	IncomeTickSeconds = 1, -- how often pens accumulate cash

	-- Zoo. Pens 1-6 are the face stalls beside the sidewalk. Each later step is a barn.
	Zoo = {
		MaxPens = 24,
		StartPens = 6,
		-- Two pens the size of a large pasture, left and right of the path at the road,
		-- in front of the six stalls. Each holds two medium animals or one large animal.
		-- The left opens with any Robux spend. The right is 99 Robux, or the Axolotl.
		FlexPasturePens = 2,
		Expansions = {
			{ Pens = 10, Price = 100000, Barn = "Small" }, -- +4 standard lanes, two each side
			{ Pens = 14, Price = 500000, Barn = "Medium" }, -- outer lanes at 1.5x, fits through extra large
			{ Pens = 17, Price = 2500000, Barn = "Large" }, -- 2 small barns, then a giant barn behind
			{ Pens = 22, Price = 10000000, Barn = "Gargantuan" }, -- open gargantuan pen, 3 skinny medium barns
			{ Pens = 24, Price = 50000000, Barn = "Mega" }, -- two gargantuan pens behind that barn
		},
	},

	-- Co-op wash. Extra sprayers speed the job up, and large bodies gain more per helper.
	-- Helpers cannot take the last dirt: only the owner finishing pays out and fills the cache.
	Coop = {
		ActiveWindow = 1.25, -- a player still counts as helping this long after a hit
		FinishReserve = 0.03, -- fraction of one patch a helper has to leave behind
		HelperBonus = {
			Standard = 0.45,
			Large = 0.85,
			ExtraLarge = 1.25,
			Giant = 1.7,
			Gargantuan = 2.2,
		},
	},

	-- Display size by body class, applied at the wash and in pens. The placeholder models are
	-- all built to fit a stall, so the big ones are scaled up here to look the part. Each
	-- class still fits the smallest pen it can go in (see AnimalConfig.fits). The cache,
	-- overflow, pets and carrying keep animals at their built size (CacheMaxLength caps it).
	BodyScale = {
		Standard = 1,
		Large = 1,
		ExtraLarge = 1.12,
		Giant = 1.6,
		Gargantuan = 3.2,
	},

	-- Cache: a washed animal waits here until the owner picks it up and carries it to a pen.
	-- A later wash does not remove it. The new animal is an overflow the owner keeps
	-- (carries to a pen) or auto-sells.
	Cache = {
		Slots = 1,
		SlotSpacing = 7,
		CarryTilt = 45, -- degrees: carried animals are held full size, tipped up in the left hand
		MaxLength = 10, -- studs: a bigger animal shrinks to this while it waits in the cache
	},

	-- A new player's opening washes. The first ones are random commons that auto-sell, with
	-- the pens hidden. The last one is a keeper, a Showcase-rarity animal with the Showcase
	-- mutation, and finishing it reveals the pens so it can be carried into one.
	-- AutoSellCount counts every opening wash, the keeper included (saved as IntroWashesLeft).
	Intro = {
		AutoSellCount = 3,
		WashTimeMultiplier = 1,
		PayoutIncome = 3, -- what an auto-sold opener pays, whatever common it was
		ShowcaseRarity = "Rare",
		ShowcaseMutation = "Diamond",
	},

	-- Unskippable spawn cutscene. AvatarUserId is KreekCraft, a public Roblox creator;
	-- the avatar is loaded at runtime and a stand-in is used if that load fails.
	Cutscene = {
		Duration = 12,
		AvatarUserId = 140258990,
		Species = "TRex",
		Scale = 1.35,
		HoseTier = 6,
	},

	-- Shop
	ShopCloseDistance = 14, -- the shop panel closes when you walk this far from the station

	-- The next rarity this hose cannot wash starts at 0%. Every completed wash adds
	-- ChancePerWash to that one rarity, taken from Common, until one unwashable walks in.
	-- Every rarity above that next one is FlatChance on every walk-in, and that does not grow.
	CleanGate = {
		ChancePerWash = 0.001,
		FlatChance = 0.001,
	},

	-- Developer shortcuts (C / G). Honored in Studio and for the place owner only.
	DevCoinGrant = 1000000,

	-- Placeholder sounds. Swap in real asset ids (rbxassetid://...) when available.
	Sounds = {
		Spray = "rbxasset://sounds/impact_water.mp3",
		Complete = "rbxasset://sounds/electronicpingshort.wav",
		PatchClear = "rbxasset://sounds/impact_water.mp3",
	},
}

return GameConfig
