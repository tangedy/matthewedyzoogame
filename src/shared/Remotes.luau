-- Creates (server) or waits for (client) the remotes in ReplicatedStorage.Remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EVENTS = {
	-- client -> server
	"CleaningIntent", -- (jobId: string, aimDirection: Vector3)
	"PurchaseToolUpgrade", -- ()
	"DevCommand", -- ("clean" | "grant"); server ignores this outside Studio and for non-owners
	"LetAnimalGo", -- () the owner sends a blocked animal away instead of paying to clean it
	"GuideAdvance", -- () owner reached the hose stand during the first-cycle guide
	"CutsceneFinished", -- () client finished the spawn cutscene (ignored if it arrives early)
	"OverflowChoice", -- ("keep" | "sell")
	-- server -> client
	"BayStateChanged", -- (BaySnapshot)
	"CleaningProgressChanged", -- (jobId: string, progress: number, showHint: boolean)
	"CoinsChanged", -- (coins: number)
	"ToolTierChanged", -- (tier: number, name: string, level: number) level is the GearLadder sub-tier
	"WashCompleted", -- (jobId: string, reward: number, coins: number, discoveryBonus: number)
	"PurchaseResult", -- (success: boolean, message: string)
	"ZooChanged", -- (ZooSummary)
	"IndexChanged", -- (index: { [string]: boolean }, newKey: string?)
	"CarryChanged", -- (CarryInfo?) what the player is carrying, nil when nothing
	"Announcement", -- (text: string, rarity: string) to everyone
	"GuideStepChanged", -- (step: string)
	"OverflowPrompt", -- ({ Label: string, SellValue: number, Waiting: number }?) nil clears it
	"YardRevealed", -- () pens and the cache are visible
	"IntroAutoSold", -- (amount: number, remaining: number)
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

-- Features can use remotes that aren't in the lists above: the server creates them on first
-- use, and the client waits for them (so call these from the server before the client needs them).
local function getOrCreate(name: string, className: string): Instance
	if RunService:IsServer() then
		local existing = folder:FindFirstChild(name)
		if existing then
			return existing
		end
		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(name)
end

function Remotes.event(name: string): RemoteEvent
	return getOrCreate(name, "RemoteEvent") :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	return getOrCreate(name, "RemoteFunction") :: RemoteFunction
end

return Remotes
