-- Bay assignment, ownership, and the per-bay animal lifecycle:
--   [CacheFull ->] Empty -> Arriving -> Washing -> Completing -> Departing -> Empty
-- Bays are built when a player is given a slot and destroyed when they leave. After a wash
-- the animal walks into the bay's cache (Departing). While the cache is full, no new animal
-- walks in (CacheFull) until the owner places or sells one.
--
-- BayService owns job state. Each owned bay runs one thread that walks the state machine;
-- releasing the bay cancels that thread and disposes of whatever the job left behind.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local AnimalService = require(script.Parent.AnimalService)
local CleaningService = require(script.Parent.CleaningService)
local EconomyService = require(script.Parent.EconomyService)
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

local bayStateChanged = Remotes.event("BayStateChanged")
local washCompleted = Remotes.event("WashCompleted")
local announcement = Remotes.event("Announcement")

local function snapshot(bay: Bay): Types.BaySnapshot
	local job = bay.Job
	local def = job and AnimalConfig.Animals[job.AnimalKey]
	return {
		BayName = bay.Name,
		State = bay.State,
		JobId = job and job.Id,
		AnimalName = def and def.DisplayName,
		Rarity = def and def.Rarity,
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

local function runOneJob(bay: Bay, owner: Player)
	-- Hold the line while the cache is full; the owner has to place or sell first.
	if not ZooService.cacheHasRoom(owner) then
		setState(bay, "CacheFull")
		while not ZooService.cacheHasRoom(owner) do
			task.wait(0.5)
		end
	end

	setState(bay, "Empty")
	local profile = EconomyService.getProfile(owner)
	local tier = if profile then profile.ToolTier else 1
	local isFirst = not bay.FirstAnimalGiven
	local animalKey = AnimalService.pickNext(isFirst, tier, owner)
	local mutationKey = AnimalService.pickMutation(isFirst, owner)
	-- Features can override a walk-in (e.g. the Daily Dirty Animal).
	local override = if isFirst then nil else Hooks.apply("NextAnimal", nil, owner, isFirst)
	if typeof(override) == "table" and AnimalConfig.Animals[override.Species] then
		animalKey = override.Species
		if typeof(override.Mutation) == "string" and MutationConfig.ByKey[override.Mutation] then
			mutationKey = override.Mutation
		end
	end
	bay.FirstAnimalGiven = true
	local def = AnimalConfig.Animals[animalKey]

	local jobId = HttpService:GenerateGUID(false)
	local model, patches = AnimalService.spawn(animalKey, mutationKey, jobId, bay.Entrance.CFrame, bay.Model)
	local job: Job = {
		Id = jobId,
		AnimalKey = animalKey,
		Mutation = mutationKey,
		Reward = math.max(
			0,
			math.floor(
				Hooks.apply("WashReward", ZooService.washReward(animalKey, mutationKey), owner, animalKey, mutationKey)
			)
		),
		Model = model,
		Paid = false,
	}
	bay.Job = job
	announce(owner, animalKey, mutationKey)

	setState(bay, "Arriving")
	AnimalService.moveTo(model, bay.WashPosition.CFrame, GameConfig.ArriveDuration)

	-- Register the waiting thread before cleaning can begin, so completion can't be missed.
	job.WaitingThread = coroutine.running()
	CleaningService.beginJob({
		JobId = jobId,
		Owner = owner,
		Model = model,
		Patches = patches,
		WashTimeMultiplier = math.max(
			0.05,
			Hooks.apply("WashTimeMultiplier", def.WashTimeMultiplier, owner, animalKey, mutationKey)
		),
		OnComplete = function()
			onJobComplete(bay, job)
		end,
	})
	setState(bay, "Washing")
	local info: Hooks.WashInfo =
		{ JobId = jobId, Species = animalKey, Mutation = mutationKey, Model = model, Bay = bay.Model }
	Hooks.fire("WashStarted", owner, info)
	coroutine.yield() -- resumed by onJobComplete (or abandonWash)

	if job.Abandoned then
		Hooks.fire("WashAbandoned", owner, info) -- (player, info: WashInfo); never paid
		setState(bay, "Departing")
		AnimalService.moveTo(model, bay.Exit.CFrame, GameConfig.DepartDuration)
		disposeJob(bay)
		setState(bay, "Empty")
		task.wait(GameConfig.NextAnimalDelay)
		return
	end

	-- Completing: pay once, guarded by the job's Paid flag.
	CleaningService.endJob(jobId)
	setState(bay, "Completing")
	if not job.Paid then
		job.Paid = true
		-- First wash of this species + mutation is an index discovery with a bonus on top.
		local bonus = 0
		if ZooService.discover(owner, animalKey, mutationKey) then
			bonus = math.floor(job.Reward * GameConfig.DiscoveryBonusMultiplier)
		end
		if EconomyService.awardWash(owner, job.Reward + bonus) then
			local updated = EconomyService.getProfile(owner)
			washCompleted:FireClient(owner, jobId, job.Reward + bonus, if updated then updated.Coins else 0)
		end
		Hooks.fire("WashCompleted", owner, info, job.Reward + bonus)
	end
	AnimalService.celebrate(model)

	-- Walk into the cache. Room was checked before this animal walked in, and only this
	-- thread adds to the cache, so it still fits.
	setState(bay, "Departing")
	local record, slot = ZooService.addToCache(owner, animalKey, mutationKey)
	if record and slot then
		local pos = model:GetPivot().Position
		local facing = (slot.Position - pos) * Vector3.new(1, 0, 1)
		if facing.Magnitude > 0.1 then
			AnimalService.moveTo(model, CFrame.lookAt(slot.Position, slot.Position + facing), GameConfig.DepartDuration)
		end
		AnimalService.moveTo(model, slot, 0.5) -- turn to face out of the cache
		job.Model = nil
		ZooService.adoptIntoCache(owner, record, model)
	else
		AnimalService.moveTo(model, bay.Exit.CFrame, GameConfig.DepartDuration)
	end
	disposeJob(bay)
	setState(bay, "Empty")
	task.wait(GameConfig.NextAnimalDelay)
end

local function runBay(bay: Bay, owner: Player)
	while bay.Owner == owner do
		local ok, err = pcall(runOneJob, bay, owner)
		if not ok then
			-- Never leave a broken bay stuck: clean up and try the next animal.
			warn(`[BayService] {bay.Name} job failed: {err}`)
			disposeJob(bay)
			task.wait(GameConfig.NextAnimalDelay)
		end
	end
end

local function makeBay(index: number): Bay
	local model = WorldBuilder.buildBay(index)
	local post = model:FindFirstChild("SignPost")
	local sign = post and post:FindFirstChild("Sign")
	return {
		Name = model.Name,
		Index = index,
		Model = model,
		Entrance = model:FindFirstChild("Entrance") :: BasePart,
		WashPosition = model:FindFirstChild("WashPosition") :: BasePart,
		Exit = model:FindFirstChild("Exit") :: BasePart,
		Spawn = model:FindFirstChild("Spawn") :: SpawnLocation,
		Label = sign and sign:FindFirstChild("BayLabel") :: TextLabel?,
		Owner = nil,
		State = "Empty",
		Job = nil,
		Thread = nil,
		FirstAnimalGiven = false,
	}
end

-- Builds a bay in the lowest free slot. Returns false when every slot is taken (the player
-- is queued and gets the next bay that frees up).
function BayService.assign(player: Player): boolean
	if bayByOwner[player] then
		return true
	end
	local index: number? = nil
	for i = 1, GameConfig.BayCount do
		if not bayBySlot[i] then
			index = i
			break
		end
	end
	if not index then
		if not table.find(waiting, player) then
			table.insert(waiting, player)
			warn(`[BayService] No free bay for {player.Name}; queued ({#waiting} waiting)`)
		end
		return false
	end

	local bay = makeBay(index)
	bayBySlot[index] = bay
	bay.Owner = player
	bayByOwner[player] = bay
	if bay.Label then
		bay.Label.Text = player.DisplayName .. "'s Zoo"
	end
	player.RespawnLocation = bay.Spawn
	local character = player.Character
	if character then
		character:PivotTo(bay.Spawn.CFrame + Vector3.new(0, 3, 0))
	end
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
	local thread = bay.Thread
	bay.Thread = nil
	if thread and coroutine.status(thread) ~= "dead" then
		task.cancel(thread)
	end
	disposeJob(bay) -- unfinished washes are never paid
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

return BayService
