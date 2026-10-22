-- Bay assignment, ownership, and the per-bay animal lifecycle:
--   Empty -> Arriving -> Washing -> Completing -> Departing -> Empty
--
-- BayService owns job state. Each owned bay runs one thread that walks the state machine;
-- releasing the bay cancels that thread and disposes of whatever the job left behind.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local AnimalService = require(script.Parent.AnimalService)
local CleaningService = require(script.Parent.CleaningService)
local EconomyService = require(script.Parent.EconomyService)

type Job = {
	Id: string,
	AnimalKey: string,
	Reward: number,
	Model: Model,
	Paid: boolean,
	WaitingThread: thread?,
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

local bays: { Bay } = {}
local bayByOwner: { [Player]: Bay } = {}

local bayStateChanged = Remotes.event("BayStateChanged")
local washCompleted = Remotes.event("WashCompleted")

local function snapshot(bay: Bay): Types.BaySnapshot
	local job = bay.Job
	local def = job and AnimalConfig.Animals[job.AnimalKey]
	return {
		BayName = bay.Name,
		State = bay.State,
		JobId = job and job.Id,
		AnimalName = def and def.DisplayName,
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

local function setLabel(bay: Bay)
	if bay.Label then
		bay.Label.Text = if bay.Owner then bay.Owner.DisplayName .. "'s Wash Bay" else "Wash Bay " .. bay.Index
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

local function runOneJob(bay: Bay, owner: Player)
	setState(bay, "Empty")
	local profile = EconomyService.getProfile(owner)
	local tier = if profile then profile.ToolTier else 1
	local animalKey = AnimalService.pickNext(not bay.FirstAnimalGiven, tier)
	bay.FirstAnimalGiven = true
	local def = AnimalConfig.Animals[animalKey]

	local jobId = HttpService:GenerateGUID(false)
	local model, patches = AnimalService.spawn(animalKey, jobId, bay.Entrance.CFrame, bay.Model)
	local job: Job = {
		Id = jobId,
		AnimalKey = animalKey,
		Reward = math.max(0, def.BaseReward),
		Model = model,
		Paid = false,
	}
	bay.Job = job

	setState(bay, "Arriving")
	AnimalService.moveTo(model, bay.WashPosition.CFrame, GameConfig.ArriveDuration)

	-- Register the waiting thread before cleaning can begin, so completion can't be missed.
	job.WaitingThread = coroutine.running()
	CleaningService.beginJob({
		JobId = jobId,
		Owner = owner,
		Model = model,
		Patches = patches,
		WashTimeMultiplier = def.WashTimeMultiplier,
		OnComplete = function()
			onJobComplete(bay, job)
		end,
	})
	setState(bay, "Washing")
	coroutine.yield() -- resumed by onJobComplete

	-- Completing: pay once, guarded by the job's Paid flag.
	CleaningService.endJob(jobId)
	setState(bay, "Completing")
	if not job.Paid then
		job.Paid = true
		if EconomyService.awardWash(owner, job.Reward) then
			local updated = EconomyService.getProfile(owner)
			washCompleted:FireClient(owner, jobId, job.Reward, if updated then updated.Coins else 0)
		end
	end
	AnimalService.celebrate(model)

	setState(bay, "Departing")
	AnimalService.moveTo(model, bay.Exit.CFrame, GameConfig.DepartDuration)
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

function BayService.init(bayModels: { Model })
	for _, model in bayModels do
		local post = model:FindFirstChild("SignPost")
		local sign = post and post:FindFirstChild("Sign")
		table.insert(bays, {
			Name = model.Name,
			Index = (model:GetAttribute("BayIndex") or #bays + 1) :: number,
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
		})
	end
end

-- Returns false when every bay is taken; the player can still walk around and watch.
function BayService.assign(player: Player): boolean
	if bayByOwner[player] then
		return true
	end
	local free: Bay?
	for _, bay in bays do
		if not bay.Owner then
			free = bay
			break
		end
	end
	if not free then
		warn(`[BayService] No free bay for {player.Name}; raise BayCount or lower Max Players`)
		return false
	end
	local bay = free :: Bay

	bay.Owner = player
	bay.FirstAnimalGiven = false
	bayByOwner[player] = bay
	setLabel(bay)
	player.RespawnLocation = bay.Spawn
	local character = player.Character
	if character then
		character:PivotTo(bay.Spawn.CFrame + Vector3.new(0, 3, 0))
	end
	bay.Thread = task.spawn(runBay, bay, player)
	return true
end

function BayService.release(player: Player)
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
	bay.State = "Empty"
	setLabel(bay)
end

function BayService.getSnapshot(player: Player): Types.BaySnapshot?
	local bay = bayByOwner[player]
	return bay and snapshot(bay)
end

return BayService
