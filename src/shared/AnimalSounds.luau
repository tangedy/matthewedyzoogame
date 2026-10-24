-- Animal calls, from Roblox's licensed ProSoundEffects library (free to use in any Roblox
-- experience; search the Creator Store for creator "ProSoundEffects" to find more).
-- Played when an animal is washed (WashBubble) and now and then by animals in pens (PenLife).
--
-- Not every species has a match in the library yet: those stay silent until an id is added.
-- Close relatives borrow a call (a coyote bark pitched up for the dog, a hawk for the
-- griffon). Pitch is PlaybackSpeed; tune by ear in Studio.

export type Call = { Id: string, Pitch: number, Volume: number }

local function call(id: number, pitch: number?, volume: number?): Call
	return { Id = `rbxassetid://{id}`, Pitch = pitch or 1, Volume = volume or 0.6 }
end

local CALLS: { [string]: Call } = {
	Pig = call(9117352464), -- Pig Grunts 3
	Sheep = call(9119066777), -- Sheep Blats 18
	Goat = call(9113442867), -- Billy Goat 7
	Dog = call(9113954868, 1.35), -- Coyotes Gruff Barking 4, pitched up
	Cat = call(9113984526, 1.3, 0.5), -- Creature Purring 5
	Cow = call(9113626093, 1.15), -- Bull Bellows 7
	Donkey = call(9113630351, 1.1), -- Bull Breaths 15: a snort
	Penguin = call(9117282528), -- Penguin Gentoo 1
	Fox = call(9113950627, 1.2), -- Coyote Barks Howls Cries 7
	Llama = call(9113630351, 1.25, 0.5), -- snort
	Zebra = call(9113630351, 1.15, 0.5), -- snort
	Horse = call(9113630351, 1.05, 0.55), -- snort
	Griffon = call(9125598512), -- Hawk Bird Screeching Calls
	Lion = call(9116302511), -- Lion Roar Short Blast 4
	Hippo = call(9113636491, 0.8), -- Bull Monster Groan 2
	Phoenix = call(9125598512, 1.3), -- the hawk, higher
	Kitsune = call(9113950627, 1.4, 0.5), -- the fox, higher
	Axolotl = call(9125409840, 1, 0.5), -- Bubbles Small Underwater
	Elephant = call(9114300941), -- Elephant Trumpets Grunts 1
	Unicorn = call(9113630351, 1.2, 0.55), -- snort
	Dragon = call(9113980319, 0.8, 0.7), -- Creature Mix Giant Monster Roar 1
	TRex = call(9116293487, 0.65, 0.7), -- Lion Roar Big Snarl 2, pitched down
	Kaiju = call(9113980319, 0.6, 0.8), -- the monster roar, lower
}

local AnimalSounds = {}

-- The species' call, or nil if it has none yet.
function AnimalSounds.get(species: string): Call?
	return CALLS[species]
end

-- Plays the call at `parent` (a part, for 3D sound). `volume` scales it. Returns at once.
function AnimalSounds.play(species: string, parent: Instance, volume: number?)
	local c = CALLS[species]
	if not c then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = c.Id
	s.PlaybackSpeed = c.Pitch * Random.new():NextNumber(0.95, 1.05)
	s.Volume = c.Volume * (volume or 1)
	s.RollOffMinDistance = 8
	s.RollOffMaxDistance = 80
	s.Parent = parent
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
	task.delay(8, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

return AnimalSounds
