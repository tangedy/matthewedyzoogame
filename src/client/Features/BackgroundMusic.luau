-- Background music: GameConfig.Music's lo-fi tracks, shuffled, one after another, fading in
-- at the start of each. Client only, so each player hears their own playlist from the top.
-- Everything plays through a "Music" SoundGroup, so one volume sets the whole playlist.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local BackgroundMusic = {}

local function shuffled(list: { string }): { string }
	local copy = table.clone(list)
	local rng = Random.new()
	for i = #copy, 2, -1 do
		local j = rng:NextInteger(1, i)
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

function BackgroundMusic.init(_initial: any)
	local config = GameConfig.Music
	if not config or #config.Tracks == 0 then
		return
	end
	local group = Instance.new("SoundGroup")
	group.Name = "Music"
	group.Volume = config.Volume
	group.Parent = SoundService

	local sound = Instance.new("Sound")
	sound.Name = "BackgroundMusic"
	sound.SoundGroup = group
	sound.Volume = 0
	sound.Parent = SoundService

	task.spawn(function()
		local queue = {}
		local last: string? = nil
		while true do
			if #queue == 0 then
				queue = shuffled(config.Tracks)
				-- Never the same track twice in a row across a reshuffle.
				if #queue > 1 and queue[1] == last then
					queue[1], queue[#queue] = queue[#queue], queue[1]
				end
			end
			local id = table.remove(queue, 1) :: string
			last = id
			sound.SoundId = id
			sound.TimePosition = 0
			sound.Volume = 0
			sound:Play()
			TweenService:Create(sound, TweenInfo.new(config.FadeSeconds), { Volume = 1 }):Play()
			-- A track that fails to load never ends; move on after a while instead.
			local ended = false
			local connection = sound.Ended:Once(function()
				ended = true
			end)
			local waited = 0
			while not ended and waited < 600 do
				waited += task.wait(1)
				if not sound.IsLoaded and waited > 15 then
					break
				end
			end
			connection:Disconnect()
			sound:Stop()
			task.wait(1)
		end
	end)
end

return BackgroundMusic
