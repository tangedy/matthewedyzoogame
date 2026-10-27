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
	WalkSpeed = 16 * 1.35, -- player characters, 1.35x Roblox's default 16

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
	-- A patch only takes water when its surface faces the spray: normal · -direction above this.
	-- The server enforces it; the client's aim lock uses it too, or it locks onto far-side mud.
	PatchFacingDot = 0.15,

	-- Touch/gamepad aiming (client only; the server still validates every spray)
	CenterAimHeight = 0.4, -- reticle height as a fraction of the screen, above the character
	AimAssistRadius = 0.18, -- snap to a dirty patch within this fraction of the screen's short side

	-- Dirt
	-- Seconds of continuous on-target spraying a 1.0x animal needs with the tier 1 hose, if
	-- each hit cleaned only one patch. Hits clean an area (ToolConfig.SprayRadius), so mud
	-- pops off almost instantly; walking around the animal is most of the wash.
	BaseWashSeconds = 2.5,
	PatchCleanThreshold = 0.05, -- a patch below this fraction snaps to clean
	-- Progress at which remaining patches glow and show through the body: as soon as any mud
	-- comes off, so players see the mud left on the far side and walk round to it.
	HintProgress = 0.001,
	AlmostCleanProgress = 0.85, -- the HUD switches to "Almost clean!" from here
	-- The owner's own spray finishes the wash once this much mud is off (the auto-wash pad
	-- still has to take all of it).
	WashedProgress = 0.85,

	-- Lifecycle timings (seconds). Kept short so there's almost always an animal to wash:
	-- about 6 s between finishing one animal and being able to spray the next.
	DepartDuration = 2,
	CelebrationDuration = 1.5,
	StartingCoins = 0, -- a new player's cash; the opening washes pay for the first upgrade
	NextAnimalDelay = 0.5,
	StepUpDelay = 0.35, -- after a wash's hop ends, before the line steps forward behind it
	-- New animals run in from the far end of Main Street to the driveway, and sold or let-go
	-- animals run off to the other end before they vanish. Speed in studs a second; StreetEnd
	-- is how far along the road (from its middle) they appear and disappear.
	StreetRun = { Speed = 50, StreetEnd = 340 },

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
	-- Most uncollected cash a pen's pad holds, by pen class (bigger pen, bigger pad). A full pad
	-- stops filling until it is collected. These are base caps: the Pen Storage upgrade
	-- (Shared.StatUpgrades) multiplies every pen's cap by +0.25x per level.
	PenCashCap = {
		Standard = 2000, -- small stall
		Medium = 20000,
		Large = 20000, -- same footprint as Medium
		PastureMedium = 20000,
		Giant = 100000,
		PastureLarge = 100000,
		Gargantuan = 1000000,
	},

	-- Zoo. Pens 1-6 are the face stalls beside the sidewalk. Each later step is a barn.
	Zoo = {
		MaxPens = 22,
		StartPens = 6,
		-- The old road cages are gone. The list stays (empty) because the save migration reads it.
		RoadCages = {} :: { { Side: string, Class: string, Unlock: string } },
		-- In order along the walkway, one pen per side per step so both sides stay even. Each
		-- step's index is its UnlockSpot in WorldBuilder.
		Expansions = {
			-- The first barn is part of the first loop: right after the starter gear and stats.
			{ Pens = 8, Price = 3000, Barn = "Small" }, -- 2 medium pens, one each side
			{ Pens = 12, Price = 25000, Barn = "Medium" }, -- 4 medium pens, two each side
			{ Pens = 18, Price = 150000, Barn = "Grand" }, -- 6 medium pens, three each side
			{ Pens = 20, Price = 1000000, Barn = "Large" }, -- a giant pen each side
			{ Pens = 22, Price = 5000000, Barn = "Gargantuan" }, -- a gargantuan yard each side
		} :: { { Pens: number?, RoadCages: boolean?, Price: number, Barn: string } },
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

	-- Display size by body class. An animal keeps this one size everywhere: at the wash, in
	-- the cache and overflow, carried over your head, and in its pen. It never shrinks.
	-- The placeholder models are all built to fit a stall, so the big ones are scaled up here
	-- to look the part. (Pets that follow the avatar stay at built size.)
	BodyScale = {
		Standard = 1,
		Large = 1,
		ExtraLarge = 1.12,
		Giant = 1.6,
		Gargantuan = 2.9, -- a T-Rex then fills most of a 38-by-48 yard
	},
	-- Every animal is drawn this much bigger than its BodyScale (or DisplayScale), so the
	-- mud is a bigger target to swipe. Capped at MaxBodyScale so a T-Rex still fits its yard.
	AnimalSizeBoost = 1.3,
	MaxBodyScale = 2.9,
	-- Animals below Legendary are drawn this much smaller, so the rare ones stand out.
	BelowLegendaryScale = 0.85,

	-- Cache: a washed animal waits here until the owner picks it up and carries it to a pen.
	-- A later wash does not remove it. The new animal is an overflow the owner keeps
	-- (carries to a pen) or auto-sells.
	Cache = {
		Slots = 2,
		SlotSpacing = 7,
	},

	-- A new player's opening. The whole loop is open from the first second: wash, carry to a
	-- pen, earn. Openers are the first walk-ins for a player who has never washed, in order
	-- (no mutation); after them the normal spawn curve takes over.
	-- AutoSellCount 0 turns off the older scripted opening (auto-sold commons with the pens
	-- hidden, then a Showcase keeper). Above 0 it brings that back and counts every opening
	-- wash, the keeper included (saved as IntroWashesLeft).
	Intro = {
		Openers = { "Pig", "Chicken" },
		AutoSellCount = 0,
		WashTimeMultiplier = 1,
		PayoutIncome = 2, -- what an auto-sold opener pays, whatever common it was
		ShowcaseRarity = "Rare",
		ShowcaseMutation = "Diamond",
		-- On touch, a hand swipes over the mud with SWIPE THE DIRT! until this many lifetime washes.
		SwipeHintWashes = 3,
	},

	-- Spawn cutscene, in the real world: you sponge a muddy piglet at your own starter bay, the
	-- ground shakes, the camera whip-pans across the road to a fully upgraded farm and pulls
	-- back to show a top player on a crane rig fire-hosing a Kaiju at its wash. That player
	-- wears AvatarUserId's look (a stand-in if it fails to load); no name is ever shown.
	-- Beat times are seconds from the start; Duration ends it; E skips after SkipAfter.
	-- Read through Shared.CutsceneSettings, which fills in any key missing here.
	Cutscene = {
		Duration = 15,
		SkipAfter = 5,
		AvatarUserId = 140258990,
		Species = "Kaiju",
		PigletScale = 0.75,
		Beats = { Shake = 3.0, Whip = 4.4, Reveal = 5.2, Hero = 11.0 },
		Sounds = {
			Rumble = "rbxasset://sounds/impact_explosion_03.mp3",
			Whoosh = "rbxasset://sounds/action_falling.ogg",
			Cannon = "rbxasset://sounds/impact_water.mp3",
		},
	},

	-- Shop
	ShopCloseDistance = 14, -- the shop panel closes when you walk this far from the station

	-- Walk-in share per rarity tier (see Shared.SpawnCurve). Each tier the hose can wash
	-- past StartTop (Rare, the sponge) moves the peak PeakPerTier tiers right and widens
	-- both sides. PeakOffset moves the whole peak (in tiers; it never goes left of Common).
	-- Species inside a tier still split its share by SpawnWeight.
	-- Rough shares: sponge 80/20 Common/Rare; Power Washer 67/30/3, Legendary 0.06%;
	-- Fire Hose Titan Spec peaks on Rare and Epic, with Common ~22% and Secret ~0.01%.
	SpawnCurve = {
		StartTop = 2,
		PeakPerTier = 0.44,
		PeakOffset = -1,
		LeftWidth = 1.0,
		LeftWidthPerTier = 0.12,
		RightWidth = 0.6,
		RightWidthPerTier = 0.1,
		Floor = 0.08, -- lowest height a tier left of the peak can have
	},

	-- The next rarity this hose cannot wash starts at 0%. Every completed wash adds
	-- ChancePerWash to that one rarity, taken from Common, until one unwashable walks in.
	-- Every rarity above that next one is FlatChance on every walk-in, and that does not grow.
	CleanGate = {
		ChancePerWash = 0.001,
		FlatChance = 0.001,
	},

	-- The auto-wash pad beside the spawn. While the owner stands on it, the animal on the
	-- wash spot cleans itself: a Common takes BaseSeconds and each rarity above it doubles
	-- that (3, 6, 12, ...). The Auto-Wash Speed upgrade (StatUpgrades) divides it. Animals the
	-- player's gear cannot wash are let go after SkipUnwashableSeconds on the pad (Let Go
	-- still works straight away), and mud shakes don't knock the
	-- player off the pad (Tension skips anyone with the AutoWashing attribute).
	AutoClean = {
		BaseSeconds = 3,
		RarityFactor = 2,
		PadSize = 8, -- studs, square
		TickSeconds = 0.2,
		SkipUnwashableSeconds = 30,
	},

	-- Developer shortcuts (C / G). Honored in Studio and for the place owner only.
	DevCoinGrant = 1000000,

	-- Placeholder sounds. Swap in real asset ids (rbxassetid://...) when available.
	Sounds = {
		Spray = "rbxasset://sounds/impact_water.mp3",
		Complete = "rbxasset://sounds/electronicpingshort.wav",
		PatchClear = "rbxasset://sounds/impact_water.mp3",
		-- Legendary+ fanfare layers (RarityFanfare): pitched and stacked into the walk-in reveal
		-- and the wash-complete hit.
		RareWhoosh = "rbxasset://sounds/action_falling.ogg",
		RareBoom = "rbxasset://sounds/impact_explosion_03.mp3",
		RareChime = "rbxasset://sounds/electronicpingshort.wav",
		-- Licensed Roblox audio (ProSoundEffects library: free to use in any experience).
		Collect = "rbxassetid://9113728625", -- Cash Register 1: the ca-ching on a collect pad
		ShopClick = "rbxassetid://9120917438", -- soft temple-block tap on shop buttons
		ShopBuy = "rbxassetid://9116394545", -- soft chime cluster when a purchase goes through
		Buzzer = "rbxassetid://9113085764", -- Alarm Buzzer 5, cut into "eh-ehhh" (CleaningController)
	},

	-- Background music: licensed APM lo-fi tracks (free in any Roblox experience), shuffled and
	-- looped by the BackgroundMusic client feature. All "Bed" versions (the lead melody taken
	-- out) or no-percussion cuts, so it sits softly under the game.
	Music = {
		Volume = 0.100, -- about 20% of the first pass (0.22)
		FadeSeconds = 3,
		Tracks = {
			"rbxassetid://1842935711", -- Cocoon, bed version, no percussion (Max Cameron Concors)
			"rbxassetid://9046863235", -- Mellow Mind, bed version (Fabian Graetz)
			"rbxassetid://9046864509", -- Violet Clouds, bed version (Fabian Graetz)
			"rbxassetid://9046863956", -- Thoughtbound, bed version (Fabian Graetz)
			"rbxassetid://9046862941", -- Sunset Chill, bed version (Queens Road)
			"rbxassetid://9046863325", -- Poolside, bed version (Max Cameron Concors)
			"rbxassetid://9046862672", -- Birdland, bed version (Max Cameron Concors)
			"rbxassetid://9046865270", -- Glowing Light, bed version (Max Cameron Concors)
		},
	},
}

return GameConfig
