-- Plays animal walks locally. The server publishes each walk as a plan (Shared.AnimalGait) on
-- the model and only places it at the end, so nothing replicates while an animal walks. Here
-- every tagged model is posed from that plan each frame (legs swinging, the same bob the
-- server used to send) and moved with one BulkMoveTo. Walks far from the camera are posed
-- less often, and when the tag goes the server's final placement takes over.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AnimalGait = require(ReplicatedStorage.Shared.AnimalGait)
local PenLife = require(script.Parent.PenLife)

local WalkReplay = {}

local FAR_DISTANCE = 120 -- studs from the camera; past this, posed every FAR_EVERY frames
local FAR_EVERY = 4
local CULL_DISTANCE = 400 -- past this, not posed at all (it pops to the end when the walk ends)

type Rig = {
	Parts: { BasePart },
	Rest: { CFrame }, -- relative to the pivot
	LegOf: { [number]: number }, -- part index -> gait leg index
	Gait: AnimalGait.Gait?,
}

type Replay = {
	Model: Model,
	Plan: AnimalGait.Plan,
	Rig: Rig,
	Done: boolean,
	Stagger: number,
}

local replays: { [Model]: Replay } = {}
local parts: { BasePart } = {}
local frames: { CFrame } = {}

local function buildRig(model: Model): Rig?
	local pivot = model:GetPivot()
	local rig: Rig = { Parts = {}, Rest = {}, LegOf = {}, Gait = AnimalGait.gaitOf(model) }
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			table.insert(rig.Parts, item)
			table.insert(rig.Rest, pivot:ToObjectSpace(item.CFrame))
		end
	end
	if #rig.Parts == 0 then
		return nil
	end
	local gait = rig.Gait
	if gait then
		local index: { [BasePart]: number } = {}
		for i, part in rig.Parts do
			index[part] = i
		end
		for legIndex, leg in gait.Legs do
			for j, part in leg.Parts do
				local i = index[part]
				if i then
					rig.LegOf[i] = legIndex
					rig.Rest[i] = leg.Rest[j]
				end
			end
		end
	end
	return rig
end

local function start(model: Model)
	if not model:IsA("Model") or not CollectionService:HasTag(model, AnimalGait.TAG) then
		return
	end
	local plan = AnimalGait.decode(model:GetAttribute(AnimalGait.ATTRIBUTE))
	if not plan then
		return
	end
	local existing = replays[model]
	if existing then
		-- A new walk took over: same parts, same rest pose, new path.
		existing.Plan = plan
		existing.Done = false
		return
	end
	-- Pen animals are posed by PenLife; stand it back at rest before reading the rest pose.
	PenLife.release(model)
	local rig = buildRig(model)
	if not rig then
		return
	end
	replays[model] = {
		Model = model,
		Plan = plan,
		Rig = rig,
		Done = false,
		Stagger = math.random(0, FAR_EVERY - 1),
	}
end

local function stop(model: Instance)
	replays[model :: Model] = nil
end

local function pose(replay: Replay, now: number)
	local plan = replay.Plan
	local t = now - plan.At
	local rig = replay.Rig
	local gait = rig.Gait
	local pivot, travelled, moving = AnimalGait.sample(plan, t, gait)
	if t >= plan.Duration then
		replay.Done = true -- hold the end pose until the server's placement arrives
	end
	local swings: { CFrame } = {}
	if gait and moving then
		local cycle = travelled / gait.Stride * math.pi * 2
		for legIndex, leg in gait.Legs do
			local angle = math.sin(cycle + leg.Phase) * gait.Swing
			swings[legIndex] = CFrame.new(leg.Hip) * CFrame.Angles(angle, 0, 0) * CFrame.new(-leg.Hip)
		end
	end
	for i, part in rig.Parts do
		if part.Parent then
			local swing = swings[rig.LegOf[i] or 0]
			table.insert(parts, part)
			table.insert(frames, if swing then pivot * swing * rig.Rest[i] else pivot * rig.Rest[i])
		end
	end
end

function WalkReplay.init(_initial: any)
	-- A new plan on a model that is already walking keeps the tag, so watch the attribute too.
	local watched: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local function onTagged(model: Instance)
		if not watched[model] then
			watched[model] = true
			model:GetAttributeChangedSignal(AnimalGait.ATTRIBUTE):Connect(function()
				start(model :: Model)
			end)
		end
		start(model :: Model)
	end
	CollectionService:GetInstanceAddedSignal(AnimalGait.TAG):Connect(onTagged)
	CollectionService:GetInstanceRemovedSignal(AnimalGait.TAG):Connect(stop)
	for _, model in CollectionService:GetTagged(AnimalGait.TAG) do
		onTagged(model)
	end

	local frame = 0
	RunService.Heartbeat:Connect(function()
		frame += 1
		local camera = Workspace.CurrentCamera
		local eye = if camera then camera.CFrame.Position else Vector3.zero
		local now = Workspace:GetServerTimeNow()
		table.clear(parts)
		table.clear(frames)
		for model, replay in replays do
			if not model.Parent then
				replays[model] = nil
				continue
			end
			if replay.Done then
				continue
			end
			local distance = (replay.Plan.Start.Position - eye).Magnitude
			if distance > CULL_DISTANCE then
				continue
			end
			if distance > FAR_DISTANCE and (frame + replay.Stagger) % FAR_EVERY ~= 0 then
				continue
			end
			pose(replay, now)
		end
		if #parts > 0 then
			Workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end)
end

return WalkReplay
