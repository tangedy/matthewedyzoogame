-- First-cycle guide: Wash -> pick up -> place in the stable -> collect -> visit the hose
-- stand -> wash the next animal. The client draws the rainbow arrows; this only stores the
-- step so leaving and rejoining resumes the same arrow.

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
	advance(player, "Place", "Collect")
end

-- Died or respawned while carrying: the animal is back in the cache, so point there again.
function GuideService.onCarryReturned(player: Player)
	advance(player, "Place", "Pickup")
end

function GuideService.onCollected(player: Player)
	advance(player, "Collect", "Upgrade")
end

function GuideService.onReachedUpgrade(player: Player)
	advance(player, "Upgrade", "Repeat")
end

function GuideService.onRepeatWashStarted(player: Player)
	advance(player, "Repeat", "Done")
end

return GuideService
