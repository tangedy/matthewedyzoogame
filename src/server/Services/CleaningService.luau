-- Server-authoritative cleaning: spray validation, dirt state, progress, completion signal.
--
-- The client only sends (jobId, aimDirection). The server picks the origin (the player's
-- nozzle), raycasts with line of sight and tool range, decides which patch is hit, and
-- credits dirt removal from its own capped clock, so extra requests never clean faster.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local DirtRenderer = require(script.Parent.DirtRenderer)
local AnimalBuilder = require(script.Parent.AnimalBuilder)

type Patch = Types.DirtPatchState & { Part: BasePart }

type Job = {
	Id: string,
	Owner: Player,
	Model: Model,
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
	OnComplete: () -> (),
}

local CleaningService = {}

local jobs: { [string]: Job } = {}
local jobByOwner: { [Player]: Job } = {}
local lastRequestAt: { [Player]: number } = {}

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
local function findPatch(job: Job, hit: BasePart, position: Vector3): Patch?
	local id = hit:GetAttribute("PatchId")
	if typeof(id) == "string" then
		local patch = job.Patches[id]
		if patch and patch.RemainingDirt > 0 then
			return patch
		end
	end
	local best: Patch?, bestDist = nil, GameConfig.SprayRadius
	for _, patch in job.PatchList do
		if patch.RemainingDirt > 0 then
			local d = (patch.Part.Position - position).Magnitude
			if d <= bestDist then
				best, bestDist = patch, d
			end
		end
	end
	return best
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

	local patch = findPatch(job, result.Instance :: BasePart, result.Position)
	if not patch then
		return
	end

	patch.RemainingDirt = math.max(0, patch.RemainingDirt - tool.CleaningPower * step)
	local fraction = patch.RemainingDirt / patch.InitialDirt
	if fraction <= GameConfig.PatchCleanThreshold then
		patch.RemainingDirt = 0
		DirtRenderer.clear(patch.Part)
	else
		DirtRenderer.setAmount(patch.Part, fraction)
	end

	local progress = progressOf(job)
	if isComplete(job) then
		job.Active = false -- lock before anything else so no further cleaning is accepted
		progressChanged:FireClient(player, job.Id, 1, false)
		task.spawn(job.OnComplete)
	else
		progressChanged:FireClient(player, job.Id, progress, progress >= GameConfig.HintProgress)
	end
end

function CleaningService.init(deps: { getTool: (Player) -> ToolConfig.ToolTier? })
	getTool = deps.getTool
	Remotes.event("CleaningIntent").OnServerEvent:Connect(onCleaningIntent)
	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
	end)
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
	job.Active = false
	for _, patch in job.PatchList do
		if patch.RemainingDirt > 0 then
			patch.RemainingDirt = 0
			DirtRenderer.clear(patch.Part)
		end
	end
	progressChanged:FireClient(player, job.Id, 1, false)
	task.spawn(job.OnComplete)
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

function CleaningService.getProgress(jobId: string): number?
	local job = jobs[jobId]
	return job and progressOf(job)
end

-- Visual hose welded to the character's right hand. Its presence is the "tool equipped" check.
function CleaningService.giveHose(character: Model)
	local hand = character:WaitForChild("RightHand", 5) or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") or character:FindFirstChild("Hose") then
		return
	end
	local hose = Instance.new("Part")
	hose.Name = "Hose"
	hose.Size = Vector3.new(0.35, 0.35, 1.6)
	hose.Color = Color3.fromRGB(60, 160, 80)
	hose.Material = Enum.Material.SmoothPlastic
	hose.CanCollide = false
	hose.CanQuery = false
	hose.CanTouch = false
	hose.Massless = true
	hose.CFrame = hand.CFrame * CFrame.new(0, -0.2, -0.6)

	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, 0, -0.85)
	nozzle.Parent = hose

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = hose
	weld.Parent = hose
	hose.Parent = character
end

return CleaningService
