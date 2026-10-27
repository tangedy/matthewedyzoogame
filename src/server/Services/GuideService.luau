-- New-player guide, saved so a rejoin resumes it. Two lessons:
--   Wash  the opening washes (the client trails the player to the pig in the bay)
--   Pen   pick the washed animal up from the cache and put it in a pen
-- then Done. The client draws the trail and the instruction; this only stores the step.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Hooks = require(script.Parent.Hooks)
local PlayerDataService = require(script.Parent.PlayerDataService)

local GuideService = {}

local guideStepChanged = Remotes.event("GuideStepChanged")

local function setStep(player: Player, to: string)
	local data = PlayerDataService.get(player)
	if not data or data.GuideStep == to then
		return
	end
	data.GuideStep = to
	PlayerDataService.markDirty(player)
	guideStepChanged:FireClient(player, to)
end

function GuideService.onWashCompleted(player: Player)
	local data = PlayerDataService.get(player)
	if not data or data.GuideStep ~= "Wash" then
		return
	end
	-- Stay on the wash until the opening auto-sells are done.
	if data.IntroWashesLeft > 0 then
		return
	end
	setStep(player, if #data.Animals > 0 then "Done" else "Pen")
end

function GuideService.onPickedUp(player: Player)
	Hooks.fire("AnimalPickedUp", player)
end

-- The first animal in a pen ends the guide.
function GuideService.onPlaced(player: Player)
	local data = PlayerDataService.get(player)
	if data and data.GuideStep ~= "Done" then
		setStep(player, "Done")
	end
end

function GuideService.onCarryReturned(_player: Player) end

function GuideService.onReachedUpgrade(player: Player)
	local data = PlayerDataService.get(player)
	-- The hose stand doesn't skip the pen lesson.
	if data and data.GuideStep == "Wash" and data.IntroWashesLeft <= 0 then
		setStep(player, if #data.Animals > 0 then "Done" else "Pen")
	end
end

return GuideService
