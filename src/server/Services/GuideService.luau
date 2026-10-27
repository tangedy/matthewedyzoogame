-- First-cycle guide: wash, and only wash. Pickup, pens, and the hose stand are not part of
-- the opening lesson. The client draws the arrow; this stores the step so a rejoin resumes it.

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
	setStep(player, "Done")
end

function GuideService.onPickedUp(player: Player)
	Hooks.fire("AnimalPickedUp", player)
end

function GuideService.onPlaced(_player: Player) end

function GuideService.onCarryReturned(_player: Player) end

function GuideService.onReachedUpgrade(player: Player)
	setStep(player, "Done")
end

return GuideService
