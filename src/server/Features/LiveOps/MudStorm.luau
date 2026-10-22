-- Server-wide Mud Storm ("admin abuse" style event). Storms follow a fixed UTC schedule
-- (LiveOpsConfig.MudStorm.Slots), so every server starts and ends them at the same moment.
-- While one is active: rarer tiers walk in more often, mutations are likelier, and animals
-- come in muddier. Developers can start or stop a storm instantly ("/storm start|stop" in
-- chat, or the LiveOpsDev remote) for testing.
--
-- State is replicated through attributes on ReplicatedStorage.LiveOpsState:
--   MudStormActive (bool) — the sky and the rain follow this, not the client's countdown
--   MudStormEndsAt, MudStormNextAt — GetServerTimeNow() instants (Common.synced), so every
--   client counts down the same clock the server used
-- and announced to features with Hooks "MudStormChanged" (active, endsAt). The schedule
-- itself stays on os.time() so every server starts the storm together.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Common = require(script.Parent.Common)
local Hooks = require(script.Parent.Parent.Parent.Services.Hooks)

local Config = LiveOpsConfig.MudStorm

local MudStorm = {}

local active = false
local endsAt = 0
local manualEndsAt: number? = nil -- developer-started storm
local suppressUntil: number? = nil -- developer-stopped a scheduled storm; skip it until then

-- The end of the scheduled storm covering `now` (nil if none) and the next scheduled start.
local function scheduled(now: number): (number?, number?)
	local today = Common.utcDay(now)
	local currentEnd: number? = nil
	local nextStart: number? = nil
	for day = today - 1, today + 7 do
		local weekday = Common.weekday(day)
		for _, slot in Config.Slots do
			if slot.Weekday == nil or slot.Weekday == weekday then
				local start = day * Common.DAY + slot.Hour * 3600 + slot.Minute * 60
				local finish = start + slot.DurationMinutes * 60
				if start <= now and now < finish then
					currentEnd = math.max(currentEnd or 0, finish)
				elseif start > now and (nextStart == nil or start < nextStart) then
					nextStart = start
				end
			end
		end
	end
	return currentEnd, nextStart
end

local function announceStart(minutes: number)
	Common.announce(`MUD STORM! Rare animals and mutations x3 for {minutes} min!`, Config.MinBoostedRarity)
end

local function evaluate()
	local now = Common.now()
	local scheduledEnd, nextStart = scheduled(now)
	if manualEndsAt and now >= manualEndsAt then
		manualEndsAt = nil
	end
	if suppressUntil and now >= suppressUntil then
		suppressUntil = nil
	end
	local newEnd: number? = if scheduledEnd and not suppressUntil then scheduledEnd else nil
	if manualEndsAt then
		newEnd = math.max(newEnd or 0, manualEndsAt)
	end

	local folder = Common.stateFolder()
	local nowActive = newEnd ~= nil
	local finish = newEnd or 0
	-- Refresh the synced stamps every check. The schedule stays on os.time(); the
	-- attributes stay on GetServerTimeNow(), including if those clocks drift apart.
	folder:SetAttribute("MudStormNextAt", Common.synced(nextStart or 0))
	folder:SetAttribute("MudStormEndsAt", Common.synced(finish))
	if nowActive == active and finish == endsAt then
		return
	end
	local started = nowActive and not active
	local stopped = active and not nowActive
	active = nowActive
	endsAt = finish
	folder:SetAttribute("MudStormActive", active)
	Hooks.fire("MudStormChanged", active, endsAt)
	if started then
		announceStart(math.max(1, math.ceil((endsAt - now) / 60)))
	elseif stopped then
		Common.announce("The Mud Storm has passed. Keep washing!", "Rare")
	end
end

function MudStorm.isActive(): boolean
	return active
end

function MudStorm.start()
	manualEndsAt = Common.now() + Config.DevStormMinutes * 60
	suppressUntil = nil
	evaluate()
end

function MudStorm.stop()
	manualEndsAt = nil
	local scheduledEnd = scheduled(Common.now())
	suppressUntil = scheduledEnd
	evaluate()
end

local lastCommandAt: { [Player]: number } = {}

-- Shared by the remote and both chat paths: developer only, at most one command per second.
local function devCommand(player: Player, action: string)
	if not Common.isDeveloper(player) then
		return
	end
	local clock = os.clock()
	if lastCommandAt[player] and clock - lastCommandAt[player] < 1 then
		return
	end
	lastCommandAt[player] = clock
	if action == "start" then
		MudStorm.start()
	elseif action == "stop" then
		MudStorm.stop()
	end
end

-- "/storm start" and "/storm stop" for developers, in either chat system.
local function setupChatCommand()
	local function parse(player: Player, message: string)
		local action = string.match(string.lower(message), "^/storm%s+(%a+)")
		if action then
			devCommand(player, action)
		end
	end
	local ok, err = pcall(function()
		if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
			return
		end
		local command = Instance.new("TextChatCommand")
		command.Name = "LiveOpsStormCommand"
		command.PrimaryAlias = "/storm"
		command.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player then
				parse(player, text)
			end
		end)
		command.Parent = TextChatService:FindFirstChild("TextChatCommands") or TextChatService
	end)
	if not ok then
		warn(`[LiveOps] Storm chat command unavailable: {err}`)
	end
	local function hookChatted(player: Player)
		player.Chatted:Connect(function(message: string)
			parse(player, message)
		end)
	end
	Players.PlayerAdded:Connect(hookChatted)
	for _, player in Players:GetPlayers() do
		hookChatted(player)
	end
end

function MudStorm.init()
	local minBoosted = (RarityConfig.ByKey[Config.MinBoostedRarity] or RarityConfig.ByKey.Legendary).Order
	Hooks.modify("SpawnWeight", function(weight: number, _player: Player, species: string): number
		if not active then
			return weight
		end
		local def = AnimalConfig.Animals[species]
		local rarity = def and RarityConfig.ByKey[def.Rarity]
		return if rarity and rarity.Order >= minBoosted then weight * Config.RareSpawnMultiplier else weight
	end)
	Hooks.modify("MutationWeight", function(weight: number, _player: Player, mutation: string): number
		return if active and mutation ~= MutationConfig.Default then weight * Config.MutationMultiplier else weight
	end)
	Hooks.modify("WashTimeMultiplier", function(mult: number): number
		return if active then mult * Config.WashTimeMultiplier else mult
	end)
	-- Everyday gold/rainbow odds (DevParams.json) get likelier. Event rates are not stacked on top.
	Hooks.modify("VariantOneIn", function(oneIn: number, _player: Player, mutation: string): number
		if active and mutation ~= MutationConfig.Default and typeof(oneIn) == "number" and oneIn > 1 then
			return math.max(1, math.floor(oneIn / Config.MutationMultiplier))
		end
		return oneIn
	end)

	Remotes.event("LiveOpsDev").OnServerEvent:Connect(function(player: Player, action: any)
		if typeof(action) ~= "string" then
			return
		end
		if action == "stormStart" then
			devCommand(player, "start")
		elseif action == "stormStop" then
			devCommand(player, "stop")
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastCommandAt[player] = nil
	end)
	setupChatCommand()

	local folder = Common.stateFolder()
	folder:SetAttribute("MudStormActive", false)
	folder:SetAttribute("MudStormEndsAt", 0)
	evaluate()
	task.spawn(function()
		while true do
			task.wait(Config.CheckInterval)
			local ok, err = pcall(evaluate)
			if not ok then
				warn(`[LiveOps] Mud Storm check failed: {err}`)
			end
		end
	end)
end

return MudStorm
