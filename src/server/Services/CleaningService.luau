-- Server-authoritative cleaning: spray validation, dirt state, progress, completion signal.
--
-- The client only sends (jobId, aimDirection). The server picks the origin (the player's
-- nozzle), raycasts with line of sight and tool range, decides which patch is hit, and
-- credits dirt removal from its own capped clock, so extra requests never clean faster.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local DirtRenderer = require(script.Parent.DirtRenderer)
local Hooks = require(script.Parent.Hooks)
local HoseBuilder = require(script.Parent.HoseBuilder)
local AnimalBuilder = require(script.Parent.AnimalBuilder)

type Patch = Types.DirtPatchState & { Part: BasePart }

type Job = {
	Id: string,
	Owner: Player,
	Model: Model,
	Rarity: string,
	Patches: { [string]: Patch },
	PatchList: { Patch },
	TotalWeighted: number,
	Active: boolean,
	OnComplete: () -> (),
}

export type JobParams = {
	JobId: string,
	Owner: Player,
	Model: Model,
	Patches: { AnimalBuilder.PatchInfo },
	WashTimeMultiplier: number,
	Rarity: string,
	OnComplete: () -> (),
}

local CleaningService = {}

local jobs: { [string]: Job } = {}
local jobByOwner: { [Player]: Job } = {}
local lastRequestAt: { [Player]: number } = {}
local cleanNowQueued: { [Player]: boolean } = {} -- paid Clean Now, waiting for an animal they can't wash

local progressChanged = Remotes.event("CleaningProgressChanged")

local getTool: (Player) -> ToolConfig.ToolTier? = function(_player)
	return nil
end

local function isFiniteNumber(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function isValidDirection(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	if not (isFiniteNumber(v.X) and isFiniteNumber(v.Y) and isFiniteNumber(v.Z)) then
		return false
	end
	local m = v.Magnitude
	return m > 0.9 and m < 1.1
end

local function progressOf(job: Job): number
	local remaining = 0
	for _, patch in job.PatchList do
		remaining += (patch.RemainingDirt / patch.InitialDirt) * patch.Weight
	end
	return 1 - remaining / job.TotalWeighted
end

local function isComplete(job: Job): boolean
	for _, patch in job.PatchList do
		if patch.RemainingDirt > 0 then
			return false
		end
	end
	return true
end

-- Direct patch hit wins; otherwise the nearest dirty patch within SprayRadius of the body hit.
-- Every dirty patch within the tool's spray radius of the hit point that faces the nozzle.
-- The facing test keeps cleaning spatial: spraying one side never cleans the far side, even
-- on small animals that fit inside the radius.
local function patchesInSpray(job: Job, hit: BasePart, position: Vector3, direction: Vector3, radius: number): { Patch }
	local found: { Patch } = {}
	local direct = hit:GetAttribute("PatchId")
	for _, patch in job.PatchList do
		if patch.RemainingDirt <= 0 then
			continue
		end
		local isDirect = typeof(direct) == "string" and patch.Id == direct
		local near = (patch.Part.Position - position).Magnitude <= radius
		local facing = patch.Part.CFrame.RightVector:Dot(-direction) > 0.15 -- RightVector is the surface normal
		if isDirect or (near and facing) then
			table.insert(found, patch)
		end
	end
	return found
end

local function onCleaningIntent(player: Player, jobId: any, aimDirection: any)
	-- Rate cap first: cheap, and the accepted step below is measured from this clock.
	local now = os.clock()
	local last = lastRequestAt[player]
	if last and now - last < GameConfig.MinRequestInterval then
		return
	end
	lastRequestAt[player] = now
	local step = math.min(if last then now - last else 1 / GameConfig.RequestRateHz, GameConfig.MaxAcceptedStep)

	if typeof(jobId) ~= "string" or not isValidDirection(aimDirection) then
		return
	end
	-- Job must exist, belong to this player, and be in the washing state.
	local job = jobs[jobId]
	if not job or job.Owner ~= player or not job.Active or jobByOwner[player] ~= job then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not humanoid or humanoid.Health <= 0 or not root then
		return
	end
	if not character:FindFirstChild("Hose") then
		return
	end
	local tool = getTool(player)
	if not tool then
		return
	end

	-- Line of sight from the server-derived nozzle; characters don't block the spray.
	local origin = root.Position + GameConfig.NozzleOffset
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	params.FilterDescendantsInstances = ignore
	local result = Workspace:Raycast(origin, (aimDirection :: Vector3).Unit * tool.Range, params)
	if not result or not result.Instance:IsDescendantOf(job.Model) then
		return
	end

	local direction = (aimDirection :: Vector3).Unit
	local hitPatches = patchesInSpray(job, result.Instance :: BasePart, result.Position, direction, tool.SprayRadius)
	if #hitPatches == 0 then
		return
	end

	local power = Hooks.apply("CleaningPower", tool.CleaningPower, player)
	-- A rarity above this hose (even with Super Soap) doesn't take dirt. Clean Now or a
	-- better hose is the way through; letting it go is handled by BayService.
	if not CleanPower.canClean(power, job.Rarity) then
		return
	end
	for _, patch in hitPatches do
		patch.RemainingDirt = math.max(0, patch.RemainingDirt - power * step)
		local fraction = patch.RemainingDirt / patch.InitialDirt
		if fraction <= GameConfig.PatchCleanThreshold then
			patch.RemainingDirt = 0
			DirtRenderer.clear(patch.Part, progressOf(job)) -- the pop gets higher-pitched as the wash nears 100%
		else
			DirtRenderer.setAmount(patch.Part, fraction)
		end
	end

	local progress = progressOf(job)
	DirtRenderer.setGrime(job.Model, progress)
	if isComplete(job) then
		job.Active = false -- lock before anything else so no further cleaning is accepted
		progressChanged:FireClient(player, job.Id, 1, false)
		task.spawn(job.OnComplete)
	else
		progressChanged:FireClient(player, job.Id, progress, progress >= GameConfig.HintProgress)
		Hooks.fire("WashProgress", player, job.Id, progress)
	end
end

function CleaningService.init(deps: { getTool: (Player) -> ToolConfig.ToolTier? })
	getTool = deps.getTool
	Remotes.event("CleaningIntent").OnServerEvent:Connect(onCleaningIntent)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		cleanNowQueued[player] = nil
	end)
end

local function effectivePower(player: Player): number
	local tool = getTool(player)
	local base = if tool then tool.CleaningPower else 0
	return Hooks.apply("CleaningPower", base, player)
end

-- True while the owner's current wash is a rarity their hose cannot clean.
function CleaningService.isBlocked(player: Player): boolean
	local job = jobByOwner[player]
	if not job or not job.Active then
		return false
	end
	return not CleanPower.canClean(effectivePower(player), job.Rarity)
end

local function finish(job: Job)
	job.Active = false
	for _, patch in job.PatchList do
		if patch.RemainingDirt > 0 then
			patch.RemainingDirt = 0
			DirtRenderer.clear(patch.Part, 1)
		end
	end
	DirtRenderer.setGrime(job.Model, 1)
	progressChanged:FireClient(job.Owner, job.Id, 1, false)
end

-- Starts accepting cleaning for a job. Total dirt is set from config so wash time doesn't
-- depend on how many patches a model happens to have.
function CleaningService.beginJob(params: JobParams)
	assert(not jobs[params.JobId], "Job already exists")
	local patchCount = #params.Patches
	local totalDirt = GameConfig.BaseWashSeconds * ToolConfig[1].CleaningPower * params.WashTimeMultiplier
	local perPatch = totalDirt / math.max(patchCount, 1)

	local job: Job = {
		Id = params.JobId,
		Owner = params.Owner,
		Model = params.Model,
		Rarity = params.Rarity,
		Patches = {},
		PatchList = {},
		TotalWeighted = 0,
		Active = true,
		OnComplete = params.OnComplete,
	}
	for _, info in params.Patches do
		local patch: Patch = {
			Id = info.Id,
			Part = info.Part,
			RemainingDirt = perPatch,
			InitialDirt = perPatch,
			Weight = 1,
		}
		job.Patches[info.Id] = patch
		table.insert(job.PatchList, patch)
		job.TotalWeighted += patch.Weight
		DirtRenderer.setAmount(info.Part, 1)
	end

	jobs[job.Id] = job
	jobByOwner[job.Owner] = job
end

-- Developer shortcut: finish the owner's active wash through the normal completion path.
function CleaningService.forceComplete(player: Player): boolean
	local job = jobByOwner[player]
	if not job or not job.Active then
		return false
	end
	finish(job)
	task.spawn(job.OnComplete)
	return true
end

-- Finishes the dirt without resuming the bay thread. BayService uses this when Clean Now
-- was paid before the wash started, so it can fall straight into the payout.
function CleaningService.completeWithoutResume(player: Player): boolean
	local job = jobByOwner[player]
	if not job or not job.Active then
		return false
	end
	finish(job)
	return true
end

-- Pays off a blocked wash now, or remembers the purchase until the next one they can't clean.
-- Returns true when an animal was cleaned immediately.
function CleaningService.grantCleanNow(player: Player): boolean
	if CleaningService.isBlocked(player) and CleaningService.forceComplete(player) then
		cleanNowQueued[player] = nil
		return true
	end
	cleanNowQueued[player] = true
	return false
end

-- True once, when a queued Clean Now matches the wash that just became active.
function CleaningService.pullQueuedClean(player: Player): boolean
	if not cleanNowQueued[player] or not CleaningService.isBlocked(player) then
		return false
	end
	cleanNowQueued[player] = nil
	return true
end

function CleaningService.endJob(jobId: string)
	local job = jobs[jobId]
	if not job then
		return
	end
	job.Active = false
	jobs[jobId] = nil
	if jobByOwner[job.Owner] == job then
		jobByOwner[job.Owner] = nil
	end
end

-- For features: the owner's active job, if they're washing right now.
function CleaningService.getActiveJob(player: Player): { Id: string, Model: Model, Progress: number }?
	local job = jobByOwner[player]
	if not job or not job.Active then
		return nil
	end
	return { Id = job.Id, Model = job.Model, Progress = progressOf(job) }
end

-- For features (e.g. an animal shaking mud back on): makes `fraction` of the already-clean
-- area dirty again, picking random clean patches. Returns how many patches came back.
function CleaningService.redirty(jobId: string, fraction: number): number
	local job = jobs[jobId]
	if not job or not job.Active then
		return 0
	end
	local clean = {}
	for _, patch in job.PatchList do
		if patch.RemainingDirt <= 0 and patch.Part.Parent then
			table.insert(clean, patch)
		end
	end
	local count = math.floor(#clean * math.clamp(fraction, 0, 1) + 0.5)
	for i = 1, count do
		local index = math.random(i, #clean)
		clean[i], clean[index] = clean[index], clean[i]
		local patch = clean[i]
		patch.RemainingDirt = patch.InitialDirt
		DirtRenderer.restore(patch.Part)
	end
	if count > 0 then
		local progress = progressOf(job)
		DirtRenderer.setGrime(job.Model, progress)
		progressChanged:FireClient(job.Owner, job.Id, progress, progress >= GameConfig.HintProgress)
	end
	return count
end

function CleaningService.getProgress(jobId: string): number?
	local job = jobs[jobId]
	return job and progressOf(job)
end

-- The hose in the player's hand matches their tool tier (HoseBuilder). Its presence is the
-- "tool equipped" check. Rebuilt on respawn and after an upgrade.
function CleaningService.refreshHose(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local tool = getTool(player)
	HoseBuilder.equip(character, if tool then tool.Tier else 1)
end

return CleaningService
