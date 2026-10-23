-- Bay assignment, ownership, and the per-bay animal lifecycle:
--   Empty -> Arriving -> Washing -> Completing -> Departing -> Empty
-- Bays are built when a player is given a random free plot and destroyed when they leave.
-- Three animals stand on the U. Only the front one is washed. When its wash finishes it
-- celebrates and walks into the cache on its own while the line steps forward, and a new
-- animal joins at the back.
--
-- BayService owns job state. Each owned bay runs one thread that walks the state machine;
-- releasing the bay cancels that thread and disposes of whatever the job left behind.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local AnimalBuilder = require(script.Parent.AnimalBuilder)
local AnimalService = require(script.Parent.AnimalService)
local PlotLayout = require(ReplicatedStorage.Shared.PlotLayout)
local CleanGateService = require(script.Parent.CleanGateService)
local CleaningService = require(script.Parent.CleaningService)
local EconomyService = require(script.Parent.EconomyService)
local GuideService = require(script.Parent.GuideService)
local Hooks = require(script.Parent.Hooks)
local WorldBuilder = require(script.Parent.WorldBuilder)
local ZooService = require(script.Parent.ZooService)

type Job = {
	Id: string,
	AnimalKey: string,
	Mutation: string,
	Reward: number,
	Model: Model?, -- nil once handed over to the cache
	Paid: boolean,
	WaitingThread: thread?,
	Abandoned: boolean?, -- set by abandonWash: the animal walks off unpaid
	NeedsPurchase: boolean?, -- rarity this hose cannot wash; Clean Now or let it go
	Scripted: boolean?, -- opening baby elephant: the starter hose can wash it
}

-- An animal standing on the U. Token bumps whenever a new walk starts, so an older walk stops.
type Arrival = {
	Id: string,
	AnimalKey: string,
	Mutation: string,
	Model: Model,
	Patches: { AnimalBuilder.PatchInfo },
	Token: number,
	Scripted: boolean,
}

type Bay = {
	Name: string,
	Index: number,
	Model: Model,
	Entrance: BasePart,
	WashPosition: BasePart,
	Exit: BasePart,
	Spawn: SpawnLocation,
	Label: TextLabel?,
	Right: Vector3,
	QueueMarks: { BasePart },
	Approach: BasePart,
	TurnIn: BasePart,
	RoadReturn: BasePart,
	Line: { Arrival },
	Owner: Player?,
	State: Types.BayState,
	Job: Job?,
	Thread: thread?,
	FirstAnimalGiven: boolean,
}

local BayService = {}

local bayBySlot: { [number]: Bay } = {}
local bayByOwner: { [Player]: Bay } = {}
local waiting: { Player } = {} -- players who joined while every slot was taken, oldest first
local spawnBound: { [Player]: RBXScriptConnection } = {}

local bayStateChanged = Remotes.event("BayStateChanged")
local washCompleted = Remotes.event("WashCompleted")
local washCelebrated = Remotes.event("WashCelebrated")
local announcement = Remotes.event("Announcement")

local function snapshot(bay: Bay): Types.BaySnapshot
	local job = bay.Job
	local def = job and AnimalConfig.Animals[job.AnimalKey]
	local scripted = job ~= nil and job.Scripted == true
	return {
		BayName = bay.Name,
		State = bay.State,
		JobId = job and job.Id,
		AnimalName = if scripted then GameConfig.Intro.DisplayName else def and def.DisplayName,
		Rarity = if scripted then "Common" else def and def.Rarity,
		Mutation = job and job.Mutation,
		Reward = job and job.Reward,
		Progress = job and CleaningService.getProgress(job.Id),
	}
end

local function setState(bay: Bay, state: Types.BayState)
	bay.State = state
	if bay.Owner then
		bayStateChanged:FireClient(bay.Owner, snapshot(bay))
	end
end

local function disposeJob(bay: Bay)
	local job = bay.Job
	if job then
		CleaningService.endJob(job.Id)
		AnimalService.destroy(job.Model)
		bay.Job = nil
	end
end

local function clearLine(bay: Bay)
	local jobModel = bay.Job and bay.Job.Model
	for _, arrival in bay.Line do
		arrival.Token += 1 -- stop a walk that is still lerping this model
		if arrival.Model ~= jobModel then
			AnimalService.destroy(arrival.Model)
		end
	end
	table.clear(bay.Line)
	disposeJob(bay)
end

local function waitAll(moves: { () -> () }, bay: Bay, owner: Player)
	local left = #moves
	for _, fn in moves do
		task.spawn(function()
			fn()
			left -= 1
		end)
	end
	while left > 0 and bay.Owner == owner do
		task.wait()
	end
end

local function lineCap(owner: Player): number
	if ZooService.introRemaining(owner) > 0 then
		return 1
	end
	return GameConfig.WashQueue
end

local function rollArrival(bay: Bay, owner: Player): Arrival
	local intro = ZooService.introRemaining(owner) > 0
	local profile = EconomyService.getProfile(owner)
	local tier = if profile then profile.ToolTier else 1
	-- The deterministic first animal is reserved for after the baby-elephant intro,
	-- so the opening minute is an elephant and the next real walk-in is still FirstAnimal.
	local isFirst = not intro and not bay.FirstAnimalGiven
	if not intro then
		bay.FirstAnimalGiven = true
	end
	local animalKey: string
	local mutationKey: string
	local look: AnimalService.SpawnLook? = nil
	if intro then
		animalKey = GameConfig.Intro.Species
		mutationKey = MutationConfig.Default
		look = {
			Scale = GameConfig.Intro.BabyScale,
			Name = GameConfig.Intro.DisplayName,
			Income = GameConfig.Intro.PayoutIncome,
			Rarity = "Common",
		}
	else
		animalKey = AnimalService.pickNext(isFirst, tier, owner)
		mutationKey = AnimalService.pickMutation(isFirst, owner)
		local override = Hooks.apply("NextAnimal", nil, owner, isFirst)
		if typeof(override) == "table" and AnimalConfig.Animals[override.Species] then
			animalKey = override.Species
			if typeof(override.Mutation) == "string" and MutationConfig.ByKey[override.Mutation] then
				mutationKey = override.Mutation
			end
		end
	end
	local id = HttpService:GenerateGUID(false)
	local slot = #bay.Line + 1
	local at = bay.Approach.CFrame + bay.Right * (-(slot - 1) * 14)
	local model, patches = AnimalService.spawn(animalKey, mutationKey, id, at, bay.Model, look)
	model.Name = "QueuedAnimal"
	if intro then
		model:SetAttribute("ScriptedIntro", true)
	end
	return {
		Id = id,
		AnimalKey = animalKey,
		Mutation = mutationKey,
		Model = model,
		Patches = patches,
		Token = 0,
		Scripted = intro,
	}
end

-- First join fills the U and waits until all three are standing. Later, only gaps are filled.
local function ensureLine(bay: Bay, owner: Player)
	if #bay.Line >= lineCap(owner) or bay.Owner ~= owner then
		return
	end
	setState(bay, "Arriving")
	local moves = {}
	while #bay.Line < lineCap(owner) and bay.Owner == owner do
		local arrival = rollArrival(bay, owner)
		local slot = #bay.Line + 1
		table.insert(bay.Line, arrival)
		local target = bay.QueueMarks[slot].CFrame
		local turn = bay.TurnIn.CFrame
		local delay = (slot - 1) * 1.1
		table.insert(moves, function()
			if delay > 0 then
				task.wait(delay)
			end
			if arrival.Model.Parent and bay.Owner == owner then
				-- Along the road, one turn, then in to this queue spot.
				AnimalService.walkCorners(arrival.Model, { turn, target }, GameConfig.ArriveDuration * 0.7)
			end
		end)
	end
	waitAll(moves, bay, owner)
end

-- The front animal has left. Everyone steps up, then a new animal walks in from the road
-- without holding up the next wash.
local function stepLine(bay: Bay, owner: Player)
	if bay.Owner ~= owner then
		return
	end
	setState(bay, "Arriving")
	local moves = {}
	for index, arrival in bay.Line do
		local target = bay.QueueMarks[index].CFrame
		table.insert(moves, function()
			AnimalService.walkCorners(arrival.Model, { target }, 1.2)
		end)
	end
	waitAll(moves, bay, owner)
	if bay.Owner ~= owner or #bay.Line >= lineCap(owner) then
		return
	end
	local arrival = rollArrival(bay, owner)
	table.insert(bay.Line, arrival)
	local target = bay.QueueMarks[#bay.Line].CFrame
	task.spawn(function()
		if arrival.Model.Parent then
			AnimalService.walkCorners(arrival.Model, { bay.TurnIn.CFrame, target }, GameConfig.ArriveDuration * 0.7)
		end
	end)
end

-- Called by CleaningService exactly when the last patch is cleaned.
local function onJobComplete(bay: Bay, job: Job)
	if bay.Job ~= job or job.Paid then
		return
	end
	local thread = job.WaitingThread
	job.WaitingThread = nil
	if thread and coroutine.status(thread) == "suspended" then
		task.spawn(thread)
	end
end

local function announce(owner: Player, animalKey: string, mutationKey: string)
	local def = AnimalConfig.Animals[animalKey]
	local rarity = RarityConfig.ByKey[def.Rarity]
	local mutation = MutationConfig.ByKey[mutationKey]
	if not (rarity.Announce or mutation.Announce) then
		return
	end
	local name = if mutationKey == MutationConfig.Default
		then def.DisplayName
		else `{mutation.DisplayName} {def.DisplayName}`
	announcement:FireAllClients(`{owner.DisplayName} found a {rarity.DisplayName} {name}!`, def.Rarity)
end

-- Celebrate, then hand the animal to the zoo: intro animals auto-sell, a free cache slot
-- takes the next one, and a full cache keeps the animal as an overflow instead of deleting it.
local function departToCache(bay: Bay, owner: Player, model: Model, animalKey: string, mutationKey: string)
	AnimalService.celebrate(model)
	if bay.Owner ~= owner or not model.Parent then
		AnimalService.destroy(model)
		return
	end
	ZooService.receiveWashed(owner, model, animalKey, mutationKey)
end

local function runOneJob(bay: Bay, owner: Player)
	ensureLine(bay, owner)
	local front = bay.Line[1]
	if bay.Owner ~= owner or not front or not front.Model.Parent then
		return
	end
	-- The client finds the animal being washed by this name. The two behind stay queued.
	front.Model.Name = "Animal"
	local animalKey = front.AnimalKey
	local mutationKey = front.Mutation
	local needsPurchase = if front.Scripted then false else CleanGateService.observe(owner, animalKey)
	local def = AnimalConfig.Animals[animalKey]
	local model = front.Model
	local baseReward = if front.Scripted
		then ZooService.introWashReward()
		else ZooService.washReward(animalKey, mutationKey)
	local job: Job = {
		Id = front.Id,
		AnimalKey = animalKey,
		Mutation = mutationKey,
		Reward = math.max(0, math.floor(Hooks.apply("WashReward", baseReward, owner, animalKey, mutationKey))),
		Model = model,
		Paid = false,
		NeedsPurchase = needsPurchase,
		Scripted = front.Scripted,
	}
	bay.Job = job
	if not front.Scripted then
		announce(owner, animalKey, mutationKey)
	end

	-- Register the waiting thread before cleaning can begin, so completion can't be missed.
	job.WaitingThread = coroutine.running()
	CleaningService.beginJob({
		JobId = front.Id,
		Owner = owner,
		Model = model,
		Patches = front.Patches,
		WashTimeMultiplier = math.max(
			0.05,
			Hooks.apply(
				"WashTimeMultiplier",
				if front.Scripted then GameConfig.Intro.WashTimeMultiplier else def.WashTimeMultiplier,
				owner,
				animalKey,
				mutationKey
			)
		),
		Rarity = if front.Scripted then "Common" else def.Rarity,
		BodyClass = def.BodyClass,
		OnComplete = function()
			onJobComplete(bay, job)
		end,
	})
	setState(bay, "Washing")
	local info: Hooks.WashInfo =
		{ JobId = front.Id, Species = animalKey, Mutation = mutationKey, Model = model, Bay = bay.Model }
	Hooks.fire("WashStarted", owner, info)
	-- Clean Now bought ahead of this animal: it's already paid for, so skip the wait.
	-- The bay thread hasn't yielded, so the finish must not try to resume it.
	if CleaningService.pullQueuedClean(owner) then
		CleaningService.completeWithoutResume(owner)
	else
		coroutine.yield() -- resumed by onJobComplete (or abandonWash)
	end

	if job.Abandoned then
		Hooks.fire("WashAbandoned", owner, info) -- (player, info: WashInfo); never paid
		setState(bay, "Departing")
		front.Token += 1
		local back = bay.RoadReturn.CFrame
		AnimalService.walkCorners(model, { bay.Model.Cache.Slot1.CFrame, back }, GameConfig.DepartDuration)
		if bay.Line[1] == front then
			table.remove(bay.Line, 1)
		end
		disposeJob(bay)
		stepLine(bay, owner)
		task.wait(GameConfig.NextAnimalDelay)
		return
	end

	-- Completing: pay once, guarded by the job's Paid flag.
	CleaningService.endJob(front.Id)
	setState(bay, "Completing")
	if not job.Paid then
		job.Paid = true
		-- First wash of this species + mutation is an index discovery with a bonus on top.
		local bonus = 0
		if not front.Scripted and ZooService.discover(owner, animalKey, mutationKey) then
			bonus = math.floor(job.Reward * GameConfig.DiscoveryBonusMultiplier)
		end
		if EconomyService.awardWash(owner, job.Reward + bonus) then
			local updated = EconomyService.getProfile(owner)
			washCompleted:FireClient(owner, front.Id, job.Reward + bonus, if updated then updated.Coins else 0, bonus)
		end
		Hooks.fire("WashCompleted", owner, info, job.Reward + bonus)
		-- Everyone sees the chat bubble. The coin payout above stays on the owner's client.
		washCelebrated:FireAllClients(front.Id)
		if front.Scripted then
			ZooService.noteIntroWash(owner)
		end
		GuideService.onWashCompleted(owner)
		if not job.NeedsPurchase and not front.Scripted then
			CleanGateService.onWashed(owner)
		end
	end
	-- Hand the washed animal off: it celebrates and walks into the cache on its own while the
	-- line steps forward, so the next wash starts right away.
	setState(bay, "Departing")
	front.Token += 1 -- stop any walk still moving it
	job.Model = nil
	model.Name = "DepartingAnimal" -- clients look up the bay's current animal by "Animal"
	if bay.Line[1] == front then
		table.remove(bay.Line, 1)
	end
	task.spawn(departToCache, bay, owner, model, animalKey, mutationKey)
	-- Give the hop a head start so the next animal doesn't step into it.
	task.wait(GameConfig.CelebrationDuration * 0.6)
	disposeJob(bay)
	stepLine(bay, owner)
	task.wait(GameConfig.NextAnimalDelay)
end

local function runBay(bay: Bay, owner: Player)
	while bay.Owner == owner do
		local ok, err = pcall(runOneJob, bay, owner)
		if not ok then
			-- Never leave a broken bay stuck: clean up and try the next animal.
			warn(`[BayService] {bay.Name} job failed: {err}`)
			clearLine(bay)
			task.wait(GameConfig.NextAnimalDelay)
		end
	end
end

-- Feet on the pad, facing the wash. Used for the first spawn and every respawn.
local function placeOnSpawn(player: Player)
	local bay = bayByOwner[player]
	local character = player.Character
	if not bay or not character or not bay.Spawn.Parent then
		return
	end
	character:PivotTo(bay.Spawn.CFrame + Vector3.new(0, 3, 0))
end

local function bindSpawn(player: Player)
	local existing = spawnBound[player]
	if existing then
		existing:Disconnect()
	end
	-- After Roblox places the character, so a leftover pad cannot win.
	spawnBound[player] = player.CharacterAdded:Connect(function()
		task.defer(placeOnSpawn, player)
	end)
end

local function makeBay(index: number): Bay
	local model = WorldBuilder.buildBay(index)
	local post = model:FindFirstChild("SignPost")
	local sign = post and post:FindFirstChild("Sign")
	local wash = model:FindFirstChild("WashPosition") :: BasePart
	local queue2 = model:FindFirstChild("Queue2") :: BasePart
	local queue3 = model:FindFirstChild("Queue3") :: BasePart
	return {
		Name = model.Name,
		Index = index,
		Model = model,
		Entrance = model:FindFirstChild("Entrance") :: BasePart,
		WashPosition = wash,
		Exit = model:FindFirstChild("Exit") :: BasePart,
		Spawn = model:FindFirstChild("Spawn") :: SpawnLocation,
		Label = sign and sign:FindFirstChild("BayLabel") :: TextLabel?,
		Right = PlotLayout.frame(index).Right,
		QueueMarks = { wash, queue2, queue3 },
		Approach = model:FindFirstChild("Approach") :: BasePart,
		TurnIn = model:FindFirstChild("TurnIn") :: BasePart,
		RoadReturn = model:FindFirstChild("RoadReturn") :: BasePart,
		Line = {},
		Owner = nil,
		State = "Empty",
		Job = nil,
		Thread = nil,
		FirstAnimalGiven = false,
	}
end

-- Builds a bay on a random free plot. Returns false when every plot is taken (the player
-- is queued and gets the next plot that frees up).
function BayService.assign(player: Player): boolean
	if bayByOwner[player] then
		return true
	end
	local free: { number } = {}
	for i = 1, GameConfig.BayCount do
		if not bayBySlot[i] then
			table.insert(free, i)
		end
	end
	if #free == 0 then
		if not table.find(waiting, player) then
			table.insert(waiting, player)
			warn(`[BayService] No free bay for {player.Name}; queued ({#waiting} waiting)`)
		end
		return false
	end

	local index = free[math.random(1, #free)]

	local bay = makeBay(index)
	bayBySlot[index] = bay
	bay.Owner = player
	bayByOwner[player] = bay
	if bay.Label then
		bay.Label.Text = player.DisplayName .. "'s Zoo"
	end
	player.RespawnLocation = bay.Spawn
	bindSpawn(player)
	placeOnSpawn(player)
	ZooService.attach(player, bay.Model)
	Hooks.fire("BayAssigned", player, bay.Model)
	bay.Thread = task.spawn(runBay, bay, player)
	return true
end

function BayService.release(player: Player)
	local queued = table.find(waiting, player)
	if queued then
		table.remove(waiting, queued)
	end
	local bay = bayByOwner[player]
	if not bay then
		return
	end
	bayByOwner[player] = nil
	bay.Owner = nil
	player.RespawnLocation = nil
	local bound = spawnBound[player]
	if bound then
		bound:Disconnect()
		spawnBound[player] = nil
	end
	local thread = bay.Thread
	bay.Thread = nil
	if thread and coroutine.status(thread) ~= "dead" then
		task.cancel(thread)
	end
	clearLine(bay) -- unfinished washes are never paid, and the queue is cleared
	ZooService.detach(player)
	bayBySlot[bay.Index] = nil
	bay.Model:Destroy()

	-- Hand the freed slot to the longest-waiting player still in the server.
	while #waiting > 0 do
		local nextPlayer = table.remove(waiting, 1) :: Player
		if nextPlayer.Parent then
			BayService.assign(nextPlayer)
			break
		end
	end
end

-- For features: the animal being washed gives up and walks off down the lane. The wash is
-- lost and never paid. Returns false when the player isn't mid-wash.
function BayService.abandonWash(player: Player): boolean
	local bay = bayByOwner[player]
	local job = bay and bay.Job
	if not bay or not job or bay.State ~= "Washing" or job.Paid then
		return false
	end
	local thread = job.WaitingThread
	if not thread or coroutine.status(thread) ~= "suspended" then
		return false
	end
	job.WaitingThread = nil
	job.Abandoned = true
	CleaningService.endJob(job.Id)
	task.spawn(thread)
	return true
end

function BayService.getSnapshot(player: Player): Types.BaySnapshot?
	local bay = bayByOwner[player]
	return bay and snapshot(bay)
end

local lastLetGoAt: { [Player]: number } = {}
Remotes.event("LetAnimalGo").OnServerEvent:Connect(function(player)
	local now = os.clock()
	if lastLetGoAt[player] and now - lastLetGoAt[player] < 0.4 then
		return
	end
	lastLetGoAt[player] = now
	-- Only an animal their hose can't wash. A normal wash isn't something they can skip.
	if CleaningService.isBlocked(player) then
		BayService.abandonWash(player)
	end
end)

Remotes.event("GuideAdvance").OnServerEvent:Connect(function(player)
	local bay = bayByOwner[player]
	local station = bay and bay.Model:FindFirstChild("UpgradeStation")
	local counter = station and station:FindFirstChild("Counter")
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not counter or not counter:IsA("BasePart") or not root then
		return
	end
	if (root.Position - counter.Position).Magnitude > 10 then
		return
	end
	GuideService.onReachedUpgrade(player)
end)

Players.PlayerRemoving:Connect(function(player)
	lastLetGoAt[player] = nil
end)

return BayService
