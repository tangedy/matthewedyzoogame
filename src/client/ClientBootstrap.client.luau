-- Client entry point: fetches initial state once, then starts the controllers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Controllers = script.Parent.Controllers
local HUDController = require(Controllers.HUDController)
local CleaningController = require(Controllers.CleaningController)

local ok, initial = pcall(function()
	return Remotes.func("RequestInitialState"):InvokeServer()
end)
if not ok or typeof(initial) ~= "table" then
	warn("[Client] Could not load initial state:", initial)
	initial = { Coins = 0, ToolTier = 1, ToolName = "Basic Hose", TutorialCompleted = false, Bay = nil }
end

HUDController.init(initial)
CleaningController.init(initial)
