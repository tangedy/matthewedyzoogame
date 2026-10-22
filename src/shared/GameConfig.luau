-- Global gameplay and tuning values. Keep magic numbers here, not in services.

local GameConfig = {
	-- World
	-- Bays are built only while a player owns one, at fixed slots; BayCount caps how many.
	BayCount = 8, -- set the place's Max Players to match (Game Settings > Places)
	BaySpacing = 70,
	BayPadSize = Vector3.new(44, 1, 34),

	-- Spraying (shared by client and server so both use the same nozzle origin)
	NozzleOffset = Vector3.new(0, 1.5, 0), -- from HumanoidRootPart
	RequestRateHz = 15, -- client cleaning request cadence
	MinRequestInterval = 0.04, -- server drops requests arriving faster than this
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
	ArriveDuration = 2.5,
	DepartDuration = 2,
	CelebrationDuration = 1.5,
	NextAnimalDelay = 0.5,

	-- Persistence. Studio uses a separate store so test data never touches live players.
	DataStoreName = "PlayerData_v1",
	StudioDataStoreName = "PlayerData_Studio_v1",
	AutosaveInterval = 60, -- also refreshes the session lock
	SessionLockExpiry = 300, -- a lock not refreshed for this long is considered abandoned
	LockRetryAttempts = 6,
	LockRetryDelay = 4,

	-- Economy (cash). An animal's value is expressed in seconds of its income.
	WashRewardSeconds = 15, -- finishing a wash pays this many seconds of the animal's income
	SellValueSeconds = 60, -- selling (or swapping out) an animal pays this many seconds of income
	DiscoveryBonusMultiplier = 1, -- first wash of a species+mutation pays this much extra
	IncomeTickSeconds = 1, -- how often pens accumulate cash

	-- Zoo: pens beside each bay, one row along X behind the pad. Each pen earns its animal's
	-- income into a collect pad in front of it; stepping on the pad collects it.
	Zoo = {
		MaxPens = 8,
		StartPens = 4,
		Expansions = { -- bought in order
			{ Pens = 6, Price = 2500 },
			{ Pens = 8, Price = 25000 },
		},
		PenSize = Vector3.new(10, 1, 12), -- interior floor
		PenSpacing = 11,
		PenRowZ = -25, -- pen centres, relative to the bay centre
	},

	-- Cache: every washed animal waits here until the owner picks it up and carries it to a pen.
	-- While the cache is full, no new animal walks in.
	Cache = {
		Slots = 3,
		SlotSpacing = 7,
		Origin = Vector3.new(8, 0, 9), -- first slot, relative to the bay centre; slots run +X
		CarryMaxSize = 3.5, -- carried animals are scaled so their largest side is about this
	},

	-- Shop
	ShopCloseDistance = 14, -- the shop panel closes when you walk this far from the station

	-- Walk-ins the player cannot wash yet. The 10th animal is always Legendary. After each
	-- hose upgrade, the next tease arrives TeaseEvery walk-ins later, starting at Legendary
	-- and stepping up one rarity for every upgrade after the first.
	CleanGate = {
		FirstTeaseAt = 10,
		TeaseEvery = 10,
		FirstTeaseRarity = "Legendary",
		TeaseStartOrder = 4, -- RarityConfig order: Legendary
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
