-- Developer shortcuts. The server decides whether they do anything.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DevController = {}

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
		end
	end)
end

return DevController
