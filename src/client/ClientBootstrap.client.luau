-- Client entry point: fetches initial state once, then starts the controllers.
-- UIPlatform starts first so ScreenGuis are scaled as soon as they are created
-- and action bindings see the real input mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIPlatform = require(script.Parent.UI)
local Controllers = script.Parent.Controllers
local HUDController = require(Controllers.HUDController)
local CleaningController = require(Controllers.CleaningController)
local ShopController = require(Controllers.ShopController)
local DevController = require(Controllers.DevController)
local OnboardingController = require(Controllers.OnboardingController)
local CutsceneController = require(Controllers.CutsceneController)
local OverflowController = require(Controllers.OverflowController)
local CleanGateController = require(Controllers.CleanGateController)
local ZooController = require(Controllers.ZooController)
local IndexController = require(Controllers.IndexController)
local PenCashController = require(Controllers.PenCashController)
local PromptController = require(Controllers.PromptController)

local ok, initial = pcall(function()
	return Remotes.func("RequestInitialState"):InvokeServer()
end)
if not ok or typeof(initial) ~= "table" then
	warn("[Client] Could not load initial state:", initial)
	initial = {
		DataStatus = "Failed",
		Coins = 0,
		ToolTier = 1,
		ToolName = "Sponge",
		ToolUpgrade = 0,
		TutorialCompleted = false,
		GuideStep = "Done",
		PlayCutscene = false,
		IntroWashesLeft = 0,
		Bay = nil,
	}
end

UIPlatform.start()

HUDController.init(initial)
CleaningController.init(initial)
ShopController.init(initial)
OnboardingController.init(initial)
CutsceneController.init(initial)
OverflowController.init()
CleanGateController.init(initial)
ZooController.init(initial)
IndexController.init(initial)
PenCashController.init()
PromptController.init()
DevController.init()

-- Feature controllers (src/client/Features): each is required and init(initial) called.
for _, module in script.Parent.Features:GetChildren() do
	if module:IsA("ModuleScript") then
		local started, err = pcall(function()
			local feature = require(module) :: any
			if typeof(feature) == "table" and typeof(feature.init) == "function" then
				feature.init(initial)
			end
		end)
		if not started then
			warn(`[Features] {module.Name} failed to start: {err}`)
		end
	end
end
