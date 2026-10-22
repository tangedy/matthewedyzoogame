-- Creates (server) or waits for (client) the remotes in ReplicatedStorage.Remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EVENTS = {
	-- client -> server
	"CleaningIntent", -- (jobId: string, aimDirection: Vector3)
	-- server -> client
	"BayStateChanged", -- (BaySnapshot)
	"CleaningProgressChanged", -- (jobId: string, progress: number, showHint: boolean)
	"CoinsChanged", -- (coins: number)
	"ToolTierChanged", -- (tier: number, name: string)
	"WashCompleted", -- (jobId: string, reward: number, coins: number)
}

local FUNCTIONS = {
	"RequestInitialState", -- () -> InitialState
}

local Remotes = {}

local folder: Folder

if RunService:IsServer() then
	folder = Instance.new("Folder")
	folder.Name = "Remotes"
	for _, name in EVENTS do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end
	for _, name in FUNCTIONS do
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
	end
	folder.Parent = ReplicatedStorage
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

function Remotes.event(name: string): RemoteEvent
	return folder:WaitForChild(name) :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	return folder:WaitForChild(name) :: RemoteFunction
end

return Remotes
