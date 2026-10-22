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

	-- Placeholder sounds. Swap in real asset ids (rbxassetid://...) when available.
	Sounds = {
		Spray = "rbxasset://sounds/impact_water.mp3",
		Complete = "rbxasset://sounds/electronicpingshort.wav",
	},
}

return GameConfig
