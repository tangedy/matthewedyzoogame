-- Developer shortcuts. The server decides whether they do anything.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DevController = {}

local FARM_LEVEL_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
}

function DevController.init()
	local devCommand = Remotes.event("DevCommand")
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.C then
			devCommand:FireServer("clean")
		elseif input.KeyCode == Enum.KeyCode.G then
			devCommand:FireServer("grant")
		elseif input.KeyCode == Enum.KeyCode.V then
			devCommand:FireServer("gallery") -- animal gallery in the sky; again to come back
		elseif FARM_LEVEL_KEYS[input.KeyCode] then
			-- Farm level 1-6 is barn tier 0-5.
			devCommand:FireServer("farmLevel", FARM_LEVEL_KEYS[input.KeyCode] - 1)
		end
	end)
end

return DevController
