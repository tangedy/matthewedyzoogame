-- Client side of the live-ops systems:
--   Storm         mud storm sky and rain (the countdown lives in the top-bar counter)
--   VariantBanner one short top-bar strip: current event and the next one
--   Popups        WELCOME BACK offline earnings panel and the DAILY DIRTY ANIMAL banner
-- Everything shown comes from the server (replicated attributes and LiveOps remotes); the
-- client never decides an outcome. Developers can press M to start or stop a Mud Storm.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Popups = require(script.Popups)
local Storm = require(script.Storm)
local VariantBanner = require(script.VariantBanner)

local player = Players.LocalPlayer

local LiveOpsController = {}

local function screenGui(name: string, ignoreInset: boolean, order: number): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = ignoreInset
	gui.DisplayOrder = order
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- The storm banner is placed against the topbar inset in viewport pixels.
	if name == "LiveOpsTop" then
		gui:SetAttribute("UIPlatformExclude", true)
	end
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

local function bindDevKey()
	if not (RunService:IsStudio() or (game.CreatorId ~= 0 and player.UserId == game.CreatorId)) then
		return
	end
	local devEvent = Remotes.event("LiveOpsDev")
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.M then
			devEvent:FireServer(if Storm.isActive() then "stormStop" else "stormStart")
		end
	end)
end

local function start()
	local top = screenGui("LiveOpsTop", true, 5) -- sits in the top bar's free centre
	local hud = screenGui("LiveOps", false, 2)
	local modal = screenGui("LiveOpsPopups", false, 20)

	Storm.start(top)
	VariantBanner.start(top)
	Popups.start(hud, modal)
	bindDevKey()

	-- Anything the server computed before we were listening (e.g. offline earnings).
	local ok, pulled = pcall(function()
		return Remotes.func("LiveOpsSync"):InvokeServer()
	end)
	if ok and typeof(pulled) == "table" then
		local welcome = pulled.WelcomeBack
		if typeof(welcome) == "table" then
			Popups.welcomeBack(welcome.Amount, welcome.Seconds)
		end
	end
end

function LiveOpsController.init(_initial: Types.InitialState)
	-- The bootstrap starts features one after another, so never yield here.
	task.spawn(function()
		local ok, err = pcall(start)
		if not ok then
			warn(`[LiveOps] Client failed to start: {err}`)
		end
	end)
end

return LiveOpsController
