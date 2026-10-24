-- Pets (server/Features/Social) trail their owner. The server parks each pet once and tags
-- it with PetOwner, PetIndex and PetCount; every client walks every pet locally, the same
-- way PenLife moves pen animals, so a pet costs no replication while it follows.
--
-- Each pet's parts are read once relative to its pivot and moved together with one
-- BulkMoveTo per frame. Pets far from the camera freeze where they are.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PetFollow = {}

local ACTIVE_DISTANCE = 300 -- studs from the camera
local FOLLOW_RATE = 6 -- how quickly a pet closes on its spot behind the owner

type Pet = {
	Model: Model,
	Parts: { BasePart },
	Rest: { CFrame }, -- pivot space
	Size: Vector3,
	Scale: number,
	Pivot: CFrame,
}

local pets: { [Model]: Pet } = {}
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

local function measure(model: Model): Pet
	local pivot = model:GetPivot()
	local parts: { BasePart } = {}
	local rest: { CFrame } = {}
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			table.insert(parts, inst)
			table.insert(rest, pivot:ToObjectSpace(inst.CFrame))
		end
	end
	local _, size = model:GetBoundingBox()
	return { Model = model, Parts = parts, Rest = rest, Size = size, Scale = model:GetScale(), Pivot = pivot }
end

local function track(model: Instance)
	if model:IsA("Model") and not pets[model] then
		pets[model] = measure(model)
	end
end

local partList: { BasePart } = {}
local frameList: { CFrame } = {}

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	dt = math.min(dt, 0.1)
	table.clear(partList)
	table.clear(frameList)
	for model, pet in pets do
		if not model.Parent then
			pets[model] = nil
			continue
		end
		local owner = Players:GetPlayerByUserId(model:GetAttribute("PetOwner") or 0)
		local character = owner and owner.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") or (root.Position - eye).Magnitude > ACTIVE_DISTANCE then
			continue
		end
		if model:GetScale() ~= pet.Scale then
			pet = measure(model)
			pets[model] = pet
		end
		local index = (model:GetAttribute("PetIndex") or 1) :: number
		local count = (model:GetAttribute("PetCount") or 1) :: number
		local size = pet.Size
		local lateral = (index - (count + 1) / 2) * math.max(4.5, size.X * 0.55)
		local back = math.max(6, size.Z * 0.5 + 3)
		local goal = (root.CFrame * CFrame.new(lateral, 0, back)).Position
		params.FilterDescendantsInstances = { character :: Model }
		local hit = Workspace:Raycast(Vector3.new(goal.X, root.Position.Y + 6, goal.Z), Vector3.new(0, -40, 0), params)
		local y = if hit then hit.Position.Y else root.Position.Y - 3
		local desired = Vector3.new(goal.X, y, goal.Z)
		local nextPos = pet.Pivot.Position:Lerp(desired, math.clamp(dt * FOLLOW_RATE, 0, 1))
		local look = Vector3.new(root.Position.X - nextPos.X, 0, root.Position.Z - nextPos.Z)
		if look.Magnitude < 0.2 then
			local flat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
			look = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zAxis
		end
		local pivot = CFrame.lookAt(nextPos, nextPos + look)
		pet.Pivot = pivot
		for i, part in pet.Parts do
			table.insert(partList, part)
			table.insert(frameList, pivot * pet.Rest[i])
		end
	end
	if #partList > 0 then
		Workspace:BulkMoveTo(partList, frameList, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function PetFollow.init(_initial: any)
	task.spawn(function()
		local folder = Workspace:WaitForChild("Pets")
		for _, child in folder:GetChildren() do
			track(child)
		end
		-- Parts stream in after the model itself; measure once the whole pet is here.
		folder.ChildAdded:Connect(function(child)
			task.defer(track, child)
		end)
		folder.ChildRemoved:Connect(function(child)
			pets[child :: Model] = nil
		end)
		RunService.Heartbeat:Connect(step)
	end)
end

return PetFollow
