-- First-cycle guide: wash -> pick up from the cache -> place in a pen -> visit the hose
-- stand -> done. The client draws the rainbow arrows; this only stores the step so leaving
-- and rejoining resumes the same arrow.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local GuideService = {}

local guideStepChanged = Remotes.event("GuideStepChanged")

local function advance(player: Player, from: string, to: string)
	local data = PlayerDataService.get(player)
	if not data or data.GuideStep ~= from then
		return
	end
	data.GuideStep = to
	PlayerDataService.markDirty(player)
	guideStepChanged:FireClient(player, to)
end

function GuideService.onWashCompleted(player: Player)
	advance(player, "Wash", "Pickup")
end

function GuideService.onPickedUp(player: Player)
	advance(player, "Pickup", "Place")
end

function GuideService.onPlaced(player: Player)
	advance(player, "Place", "Upgrade")
end

-- Died or respawned while carrying: the animal is back in the cache, so point there again.
function GuideService.onCarryReturned(player: Player)
	advance(player, "Place", "Pickup")
end

function GuideService.onReachedUpgrade(player: Player)
	advance(player, "Upgrade", "Done")
end

return GuideService
