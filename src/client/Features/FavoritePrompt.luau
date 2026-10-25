-- Shows Roblox's "favourite this experience" dialog when the server asks (FavoritePrompt on
-- the server: right after the player's first Legendary wash, once ever).

local AvatarEditorService = game:GetService("AvatarEditorService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local FavoritePrompt = {}

function FavoritePrompt.init(_initial: any)
	Remotes.event("FavoritePrompt").OnClientEvent:Connect(function()
		-- An unpublished place (Studio) has PlaceId 0 and nothing to favourite.
		if game.PlaceId == 0 then
			return
		end
		local ok, err = pcall(function()
			AvatarEditorService:PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)
		end)
		if not ok then
			warn(`[FavoritePrompt] {err}`)
		end
	end)
end

return FavoritePrompt
