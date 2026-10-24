-- Legendary and rarer get a fanfare when they walk in (RareReveal on the client) and when
-- they are washed (AnimalService.celebrate on the server). Each tier is a step up from the
-- one before: more rings, more particles, a harder camera shake, a longer chord.
--
-- The sound is layered from GameConfig.Sounds.Rare* (a whoosh, a boom, and the chime pitched
-- into a chord and a sparkle tail), so it works with the built-in placeholders. Swap real
-- asset ids into those keys and every fanfare picks them up.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)

export type Style = {
	Title: string, -- the stamp over the animal and across the screen
	Color: Color3, -- beam, rings, flash (Farm God cycles the rainbow instead)
	Glow: Color3, -- sparkles and the beam's core
	Rainbow: boolean,
	Dark: boolean, -- Secret: the screen dips to black and lightning strikes before the flash
	Notes: { number }, -- chime playback speeds, played as a rising (or falling) arpeggio
	NoteGap: number, -- seconds between notes
	Booms: { number }, -- boom playback speeds, one hit each
	Shimmer: number, -- quick high pings after the chord
	Rings: number, -- ground shockwaves
	Particles: number, -- sparkles in the burst
	Shake: number, -- camera shake for the owner, in studs
}

local RarityFanfare = {}

local STYLES: { [string]: Style } = {
	Legendary = {
		Title = "LEGENDARY!",
		Color = Color3.fromRGB(255, 200, 40),
		Glow = Color3.fromRGB(255, 240, 170),
		Rainbow = false,
		Dark = false,
		Notes = { 1, 1.26, 1.5, 2 }, -- major chord up to the octave
		NoteGap = 0.08,
		Booms = { 0.9 },
		Shimmer = 6,
		Rings = 1,
		Particles = 40,
		Shake = 0.15,
	},
	Mythic = {
		Title = "MYTHIC!!",
		Color = Color3.fromRGB(255, 60, 40),
		Glow = Color3.fromRGB(255, 180, 90),
		Rainbow = false,
		Dark = false,
		Notes = { 1, 1.19, 1.5, 1.78, 2 }, -- minor seventh: dramatic
		NoteGap = 0.075,
		Booms = { 0.7, 1 },
		Shimmer = 9,
		Rings = 2,
		Particles = 70,
		Shake = 0.3,
	},
	ZooGod = {
		Title = "FARM GOD!!!",
		Color = Color3.fromRGB(255, 255, 255),
		Glow = Color3.fromRGB(255, 250, 220),
		Rainbow = true,
		Dark = false,
		Notes = { 1, 1.26, 1.5, 2, 2.52, 3 }, -- two octaves of major
		NoteGap = 0.07,
		Booms = { 0.6, 0.85 },
		Shimmer = 14,
		Rings = 3,
		Particles = 110,
		Shake = 0.45,
	},
	Secret = {
		Title = "??? SECRET ???",
		Color = Color3.fromRGB(150, 60, 255),
		Glow = Color3.fromRGB(240, 230, 255),
		Rainbow = false,
		Dark = true,
		Notes = { 2, 1.68, 1.41, 1.19, 1 }, -- diminished, falling: something is wrong
		NoteGap = 0.12,
		Booms = { 0.45, 0.45, 1.2 }, -- two heartbeats, then the crack
		Shimmer = 8,
		Rings = 3,
		Particles = 90,
		Shake = 0.6,
	},
}

local MIN_ORDER = RarityConfig.ByKey.Legendary.Order

-- The tier's fanfare, or nil below Legendary.
function RarityFanfare.style(rarityKey: string): Style?
	local rarity = RarityConfig.ByKey[rarityKey]
	if not rarity or rarity.Order < MIN_ORDER then
		return nil
	end
	return STYLES[rarityKey]
end

local function sound(parent: Instance, id: string, speed: number, volume: number)
	if not parent.Parent then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.PlaybackSpeed = speed
	s.Volume = volume
	s.RollOffMaxDistance = 220
	s.RollOffMinDistance = 15
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 4)
end

-- Plays the tier's fanfare at `parent` (a part for 3D sound; SoundService for flat sound).
-- `volume` scales the whole thing. Returns at once; the notes are scheduled.
function RarityFanfare.play(parent: Instance, rarityKey: string, volume: number?)
	local style = RarityFanfare.style(rarityKey)
	if not style then
		return
	end
	local v = volume or 1
	local sounds = GameConfig.Sounds
	local rng = Random.new()

	sound(parent, sounds.RareWhoosh, if style.Dark then 0.7 else 1.25, 0.5 * v)
	local beat = if style.Dark then 0.32 else 0.22
	for i, speed in style.Booms do
		task.delay(0.15 + (i - 1) * beat, sound, parent, sounds.RareBoom, speed, 0.55 * v)
	end
	local chordAt = 0.15 + #style.Booms * beat * 0.6
	for i, speed in style.Notes do
		task.delay(chordAt + (i - 1) * style.NoteGap, sound, parent, sounds.RareChime, speed, (0.45 + i * 0.06) * v)
	end
	-- The whole chord again, together, as the top note lands: it rings like one big hit.
	local landAt = chordAt + #style.Notes * style.NoteGap
	for _, speed in style.Notes do
		task.delay(landAt, sound, parent, sounds.RareChime, speed * 0.5, 0.3 * v)
	end
	local shimmerAt = landAt + 0.1
	for i = 1, style.Shimmer do
		local speed = rng:NextNumber(2.2, 3.2) * (if style.Dark then 0.6 else 1)
		task.delay(
			shimmerAt + (i - 1) * 0.055,
			sound,
			parent,
			sounds.RareChime,
			speed,
			0.25 * v * (1 - i / (style.Shimmer + 2))
		)
	end
end

return RarityFanfare
