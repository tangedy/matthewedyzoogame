-- Global gameplay and tuning values. Keep magic numbers here, not in services.

local GameConfig = {
	-- World
	BayCount = 4, -- set the place's Max Players to match (Game Settings > Places)
	BaySpacing = 70,
	BayPadSize = Vector3.new(44, 1, 34),

	-- Spraying (shared by client and server so both use the same nozzle origin)
	NozzleOffset = Vector3.new(0, 1.5, 0), -- from HumanoidRootPart
	RequestRateHz = 10, -- client cleaning request cadence
	MinRequestInterval = 0.06, -- server drops requests arriving faster than this
	MaxAcceptedStep = 0.15, -- max seconds of cleaning credited per request
	SprayRadius = 1.6, -- studs around a body hit that can clean the nearest patch

	-- Touch/gamepad aiming (client only; the server still validates every spray)
	CenterAimHeight = 0.4, -- reticle height as a fraction of the screen, above the character
	AimAssistRadius = 0.18, -- snap to a dirty patch within this fraction of the screen's short side

	-- Dirt
	-- Seconds of continuous on-target spraying a 1.0x animal needs with the tier 1 hose.
	-- Walking around adds on top; doc target is 30-45 s for the first wash.
	BaseWashSeconds = 24,
	PatchCleanThreshold = 0.05, -- a patch below this fraction snaps to clean
	HintProgress = 0.85, -- progress at which remaining patches get highlighted

	-- Lifecycle timings (seconds)
	ArriveDuration = 3,
	DepartDuration = 3,
	CelebrationDuration = 1.5,
	NextAnimalDelay = 1,

	-- Persistence. Studio uses a separate store so test data never touches live players.
	DataStoreName = "PlayerData_v1",
	StudioDataStoreName = "PlayerData_Studio_v1",
	AutosaveInterval = 60, -- also refreshes the session lock
	SessionLockExpiry = 300, -- a lock not refreshed for this long is considered abandoned
	LockRetryAttempts = 6,
	LockRetryDelay = 4,

	-- Shop
	ShopCloseDistance = 14, -- the shop panel closes when you walk this far from the station

	-- Developer shortcuts (C / G). Honored in Studio and for the place owner only.
	DevCoinGrant = 1000000,

	-- Placeholder sounds. Swap in real asset ids (rbxassetid://...) when available.
	Sounds = {
		Spray = "rbxasset://sounds/impact_water.mp3",
		Complete = "rbxasset://sounds/electronicpingshort.wav",
	},
}

return GameConfig
