-- Walk cycle and right-angle walk plans, shared by the server (AnimalService) and the client
-- (WalkReplay), so both compute exactly the same path.
--
-- A walk is sent as a plan (start pivot, corner points, seconds per leg, bob, server start
-- time) instead of moving every part on the server each frame: one attribute replicates, and
-- each client animates the walk locally. The server places the model at the end.

local HttpService = game:GetService("HttpService")

local AnimalConfig = require(script.Parent.AnimalConfig)

local AnimalGait = {}

AnimalGait.TAG = "Walking" -- CollectionService tag while a walk plan is playing
AnimalGait.ATTRIBUTE = "WalkPlan" -- JSON-encoded plan
AnimalGait.TURN_SECONDS = 0.28

-- Walk cycle. Each leg (and the hoof or foot under it) swings from the hip while the model
-- moves; diagonal pairs step together, and two-legged animals alternate. Poses are written
-- relative to the pivot every frame, so nothing drifts, and the rest pose comes back at the end.
export type LegPose = { Parts: { BasePart }, Rest: { CFrame }, Hip: Vector3, Phase: number }
export type Gait = { Legs: { LegPose }, Stride: number, Swing: number, Heavy: boolean, Scale: number }

local BIG_BODIES = { Giant = true, Gargantuan = true }
-- The rest pose is read once per model and size, so two overlapping walks can't record a
-- mid-swing leg as the rest pose.
local gaits: { [Model]: Gait } = setmetatable({}, { __mode = "k" }) :: any

function AnimalGait.gaitOf(model: Model): Gait?
	local cached = gaits[model]
	if cached and math.abs(cached.Scale - model:GetScale()) < 1e-4 then
		return cached
	end
	local pivot = model:GetPivot()
	local legs: { BasePart } = {}
	for _, child in model:GetChildren() do
		if child.Name == "Leg" and child:IsA("BasePart") then
			table.insert(legs, child)
		end
	end
	if #legs == 0 then
		return nil
	end
	-- Hooves, feet, paws, toes and socks: anything tagged LegPart, plus the older names.
	local feet: { BasePart } = {}
	for _, child in model:GetChildren() do
		if
			child:IsA("BasePart")
			and (child:GetAttribute("LegPart") == true or child.Name == "Hoof" or child.Name == "Foot")
		then
			table.insert(feet, child)
		end
	end
	local poses: { LegPose } = {}
	local legLength = 0
	for _, leg in legs do
		local rest = pivot:ToObjectSpace(leg.CFrame)
		local hip = (rest * CFrame.new(0, leg.Size.Y / 2, 0)).Position
		legLength = math.max(legLength, leg.Size.Y)
		local front = rest.Position.Z < 0
		local left = rest.Position.X < 0
		local phase = if #legs == 2 then (if left then 0 else math.pi) elseif front == left then 0 else math.pi
		local pose: LegPose = { Parts = { leg }, Rest = { rest }, Hip = hip, Phase = phase }
		table.insert(poses, pose)
	end
	-- Each foot part swings with the leg it is closest to.
	for _, foot in feet do
		local footRest = pivot:ToObjectSpace(foot.CFrame)
		local best: LegPose? = nil
		local bestDist = math.huge
		for _, pose in poses do
			local offset = footRest.Position - pose.Rest[1].Position
			local dist = Vector2.new(offset.X, offset.Z).Magnitude
			if dist < bestDist then
				best, bestDist = pose, dist
			end
		end
		if best and bestDist < math.max(best.Parts[1].Size.X, best.Parts[1].Size.Z) * 2.5 then
			table.insert(best.Parts, foot)
			table.insert(best.Rest, footRest)
		end
	end
	local key = model:GetAttribute("AnimalKey")
	local def = if typeof(key) == "string" then AnimalConfig.Animals[key] else nil
	local gait: Gait = {
		Legs = poses,
		Stride = math.max(legLength * 2.2, 1.2),
		Swing = math.rad(32),
		Heavy = def ~= nil and BIG_BODIES[def.BodyClass] == true,
		Scale = model:GetScale(),
	}
	gaits[model] = gait
	return gait
end

function AnimalGait.poseLegs(model: Model, gait: Gait, travelled: number)
	local pivot = model:GetPivot()
	local cycle = travelled / gait.Stride * math.pi * 2
	for _, leg in gait.Legs do
		local angle = math.sin(cycle + leg.Phase) * gait.Swing
		local swing = CFrame.new(leg.Hip) * CFrame.Angles(angle, 0, 0) * CFrame.new(-leg.Hip)
		for i, part in leg.Parts do
			part.CFrame = pivot * swing * leg.Rest[i]
		end
	end
end

function AnimalGait.restLegs(model: Model, gait: Gait)
	local pivot = model:GetPivot()
	for _, leg in gait.Legs do
		for i, part in leg.Parts do
			part.CFrame = pivot * leg.Rest[i]
		end
	end
end

-- Big animals bob slowly and heavily: a thud per step instead of a hop.
function AnimalGait.stepBob(gait: Gait?, travelled: number, amplitude: number): number
	if gait and gait.Heavy then
		return math.abs(math.sin(travelled / gait.Stride * math.pi * 2)) * amplitude * 2
	end
	return 0
end

export type Segment = {
	Start: number, -- seconds into the walk
	TurnFrom: CFrame,
	TurnTo: CFrame,
	From: Vector3,
	Goal: Vector3,
	Dir: Vector3,
	Span: number,
	Travel: number, -- distance walked before this leg
	Seconds: number, -- walking time for this leg, after the turn
}

export type Plan = {
	Start: CFrame,
	Points: { Vector3 },
	Each: number,
	Speed: number?, -- studs a second; when set, each leg takes span / Speed instead of Each
	Bob: number,
	At: number, -- Workspace:GetServerTimeNow() when the walk began
	Segments: { Segment },
	Duration: number,
}

-- Turn in place toward each corner, then walk straight to it at the starting height.
-- Corners closer than 0.4 studs (flat) are skipped, as before. With `speed`, legs are timed
-- by length (a run down the street), otherwise every leg takes `each` seconds.
function AnimalGait.plan(
	start: CFrame,
	points: { Vector3 },
	each: number,
	bob: number,
	at: number,
	speed: number?
): Plan
	local pace = if speed and speed > 0 then speed else nil
	local segments: { Segment } = {}
	local here = start
	local clock = 0
	local travel = 0
	for _, point in points do
		local pos = here.Position
		local flat = Vector3.new(point.X - pos.X, 0, point.Z - pos.Z)
		if flat.Magnitude < 0.4 then
			continue
		end
		local dir = flat.Unit
		local goal = Vector3.new(point.X, pos.Y, point.Z)
		local span = (goal - pos).Magnitude
		local seconds = if pace then math.max(span / pace, 0.15) else each
		table.insert(segments, {
			Start = clock,
			TurnFrom = here,
			TurnTo = CFrame.lookAt(pos, pos + dir),
			From = pos,
			Goal = goal,
			Dir = dir,
			Span = span,
			Travel = travel,
			Seconds = seconds,
		})
		clock += AnimalGait.TURN_SECONDS + seconds
		travel += span
		here = CFrame.lookAt(goal, goal + dir)
	end
	return {
		Start = start,
		Points = points,
		Each = each,
		Speed = pace,
		Bob = bob,
		At = at,
		Segments = segments,
		Duration = clock,
	}
end

-- Where the walk is t seconds in: the pivot and the distance walked (for the leg swing).
function AnimalGait.sample(plan: Plan, t: number, gait: Gait?): (CFrame, number, boolean)
	local segments = plan.Segments
	if #segments == 0 then
		return plan.Start, 0, false
	end
	for index = #segments, 1, -1 do
		local seg = segments[index]
		if t >= seg.Start or index == 1 then
			local localT = math.max(t - seg.Start, 0)
			if localT < AnimalGait.TURN_SECONDS then
				return seg.TurnFrom:Lerp(seg.TurnTo, localT / AnimalGait.TURN_SECONDS), seg.Travel, false
			end
			local elapsed = localT - AnimalGait.TURN_SECONDS
			if elapsed >= seg.Seconds then
				return CFrame.lookAt(seg.Goal, seg.Goal + seg.Dir), seg.Travel + seg.Span, false
			end
			local u = math.min(elapsed / seg.Seconds, 1)
			local travelled = seg.Travel + seg.Span * u
			local bob = if gait and gait.Heavy
				then AnimalGait.stepBob(gait, travelled, plan.Bob)
				else math.abs(math.sin(elapsed * 10)) * plan.Bob
			local pos = seg.From:Lerp(seg.Goal, u) + Vector3.new(0, bob, 0)
			return CFrame.lookAt(pos, pos + seg.Dir), travelled, true
		end
	end
	return plan.Start, 0, false
end

-- The walk's end pose.
function AnimalGait.finish(plan: Plan): CFrame
	local last = plan.Segments[#plan.Segments]
	if not last then
		return plan.Start
	end
	return CFrame.lookAt(last.Goal, last.Goal + last.Dir)
end

function AnimalGait.encode(plan: Plan): string
	local points = {}
	for _, p in plan.Points do
		table.insert(points, { p.X, p.Y, p.Z })
	end
	return HttpService:JSONEncode({
		s = { plan.Start:GetComponents() },
		p = points,
		e = plan.Each,
		v = plan.Speed,
		b = plan.Bob,
		t = plan.At,
	})
end

function AnimalGait.decode(text: any): Plan?
	if typeof(text) ~= "string" then
		return nil
	end
	local ok, raw = pcall(HttpService.JSONDecode, HttpService, text)
	if not ok or typeof(raw) ~= "table" or typeof(raw.s) ~= "table" or #raw.s ~= 12 or typeof(raw.p) ~= "table" then
		return nil
	end
	local points = {}
	for _, p in raw.p do
		table.insert(points, Vector3.new(p[1], p[2], p[3]))
	end
	return AnimalGait.plan(
		CFrame.new(table.unpack(raw.s)),
		points,
		tonumber(raw.e) or 1,
		tonumber(raw.b) or 0.25,
		tonumber(raw.t) or 0,
		tonumber(raw.v)
	)
end

return AnimalGait
