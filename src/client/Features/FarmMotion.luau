-- Farm scenery motion (server FarmDecor): windmill blades turn and the hot-air balloon bobs.
-- Client only, so nothing replicates. Each frame nudges a model from where it is now rather
-- than from a saved pose, so it still follows when the server lifts a new set out of the
-- ground or the cutscene moves its farm. Models far from the camera wait.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FarmMotion = {}

local SPIN_TAG = "FarmSpin" -- FarmDecor.SpinTag
local BOB_TAG = "FarmBob" -- FarmDecor.BobTag
local ACTIVE_DISTANCE = 400
local BOB_HEIGHT = 2.5
local BOB_SPEED = 0.6 -- radians per second of the bob's sine
local BOB_YAW = 0.04 -- radians per second of slow turning

local function bobHeight(t: number): number
	return math.sin(t * BOB_SPEED) * BOB_HEIGHT
end

local function near(model: Model, camera: Vector3): boolean
	return (model:GetPivot().Position - camera).Magnitude < ACTIVE_DISTANCE
end

function FarmMotion.init(_initial: any)
	local spinning: { [Model]: boolean } = {}
	local bobbing: { [Model]: number } = {} -- the bob time it was last posed at
	local function track(tag: string, set: { [Model]: any }, value: () -> any)
		local function add(inst: Instance)
			if inst:IsA("Model") then
				set[inst] = value()
			end
		end
		for _, inst in CollectionService:GetTagged(tag) do
			add(inst)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(add)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(inst)
			set[inst :: Model] = nil
		end)
	end
	track(SPIN_TAG, spinning, function()
		return true
	end)
	track(BOB_TAG, bobbing, os.clock)

	RunService.RenderStepped:Connect(function(dt)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local eye = camera.CFrame.Position
		for blades in spinning do
			if blades.Parent and near(blades, eye) then
				local speed = blades:GetAttribute("SpinSpeed")
				local rate = if typeof(speed) == "number" then speed else 0.8
				blades:PivotTo(blades:GetPivot() * CFrame.Angles(0, 0, rate * dt))
			end
		end
		local now = os.clock()
		for balloon, last in bobbing do
			if balloon.Parent and near(balloon, eye) then
				local from = balloon:GetPivot()
				local lift = bobHeight(now) - bobHeight(last)
				balloon:PivotTo((from + Vector3.new(0, lift, 0)) * CFrame.Angles(0, BOB_YAW * dt, 0))
				bobbing[balloon] = now
			end
		end
	end)
end

return FarmMotion
