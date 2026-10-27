-- Asks the player to favourite the game right after they buy their first barn upgrade, a
-- moment they have clearly committed to the farm. Once per player, ever: the flag lives in
-- data.Extra.FavoritePrompted. The server only decides when; the client shows Roblox's own
-- favourite dialog (AvatarEditorService), which only a LocalScript can open.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Services = script.Parent.Parent.Services
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)

local FavoritePrompt = {}

local DELAY = 3 -- seconds; the new barn goes up first

function FavoritePrompt.init()
	local remote = Remotes.event("FavoritePrompt") -- () server -> client

	Hooks.on("ZooExpanded", function(player: Player)
		local data = PlayerDataService.get(player)
		if not data or data.Extra.FavoritePrompted == true then
			return
		end
		data.Extra.FavoritePrompted = true
		PlayerDataService.markDirty(player)
		task.delay(DELAY, function()
			if player.Parent then
				remote:FireClient(player)
			end
		end)
	end)
end

return FavoritePrompt
