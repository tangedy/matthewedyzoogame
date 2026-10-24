-- GameConfig.Cutscene laid over defaults, so a missing or older config key can never break
-- the opening shot (a nil scale used to error the server bootstrap and freeze the game).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local DEFAULTS = {
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
}

local function merge(defaults: { [string]: any }, overrides: any): { [string]: any }
	local out = {}
	for key, value in defaults do
		local given = if typeof(overrides) == "table" then overrides[key] else nil
		if typeof(value) == "table" then
			out[key] = merge(value, given)
		elseif typeof(given) == typeof(value) then
			out[key] = given
		else
			out[key] = value
		end
	end
	return out
end

return merge(DEFAULTS, (GameConfig :: any).Cutscene)
