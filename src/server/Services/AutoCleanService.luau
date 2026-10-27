-- The auto-wash pad across the wash spot from the walkway (WorldBuilder's AutoCleanPad). While the owner
-- stands on it, the animal on the wash spot cleans itself over AutoClean.seconds (rarity and
-- the Auto-Wash Speed upgrade), and one their gear cannot wash is let go so the line keeps
-- moving. Off during the opening washes, which teach the hose. While on the pad the player
-- carries the AutoWashing attribute, which mud shakes and lunges respect (no knockout).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AutoClean = require(ReplicatedStorage.Shared.AutoClean)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local BayService = require(script.Parent.BayService)
local CleaningService = require(script.Parent.CleaningService)
local CutsceneService = require(script.Parent.CutsceneService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ZooService = require(script.Parent.ZooService)

local AutoCleanService = {}

local IDLE_TEXT = "Stand here to wash hands-free"

local function padOf(player: Player): BasePart?
	local bay = BayService.getModel(player)
	local pad = bay and bay:FindFirstChild("AutoCleanPad")
	return if pad and pad:IsA("BasePart") then pad else nil
end

local function setStatus(pad: BasePart, text: string)
	local gui = pad:FindFirstChild("AutoCleanSign")
	local label = gui and gui:FindFirstChild("Status")
	if label and label:IsA("TextLabel") and label.Text ~= text then
		label.Text = text
	end
end

local function standingOn(player: Player, pad: BasePart): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or humanoid.Health <= 0 or not root then
		return false
	end
	local half = GameConfig.AutoClean.PadSize / 2 + 0.5
	local here = pad.CFrame:PointToObjectSpace(root.Position)
	return math.abs(here.X) <= half and math.abs(here.Z) <= half and here.Y > -1 and here.Y < 8
end

local function step(player: Player, dt: number)
	local pad = padOf(player)
	local onPad = pad ~= nil and standingOn(player, pad)
	if player:GetAttribute("AutoWashing") ~= onPad then
		player:SetAttribute("AutoWashing", onPad)
	end
	if not pad then
		return
	end
	if not onPad then
		setStatus(pad, IDLE_TEXT)
		return
	end
	if ZooService.introRemaining(player) > 0 then
		setStatus(pad, "Finish your first washes by hand")
		return
	end
	if CutsceneService.blocksCleaning(player) then
		return
	end
	local job = CleaningService.getActiveJob(player)
	if not job then
		setStatus(pad, "Waiting for the next animal...")
		return
	end
	-- Gear too weak (or Super Soap missing): send it on its way.
	if CleaningService.isBlocked(player) then
		setStatus(pad, "Skipped an animal your gear can't wash")
		BayService.abandonWash(player)
		return
	end
	local data = PlayerDataService.get(player)
	local seconds = AutoClean.seconds(job.Rarity, if data then data.AutoWashLevel else 0)
	local rarity = RarityConfig.ByKey[job.Rarity]
	local name = if rarity then rarity.DisplayName else job.Rarity
	local left = math.max(0, math.ceil(seconds * (1 - job.Progress)))
	setStatus(pad, `Washing {name}... {left}s`)
	CleaningService.autoClean(player, dt / seconds)
end

function AutoCleanService.init()
	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(GameConfig.AutoClean.TickSeconds)
			local now = os.clock()
			-- Capped, so a server hitch cannot finish a wash in one tick.
			local dt = math.min(now - last, GameConfig.AutoClean.TickSeconds * 3)
			last = now
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(step, player, dt)
				if not ok then
					warn(`[AutoCleanService] {player.Name}: {err}`)
				end
			end
		end
	end)
end

return AutoCleanService
