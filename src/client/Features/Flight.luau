-- Flight for the owners (the server sets StaffRole; FeatureConfig/StaffConfig). Double-tapping
-- Space, F, the Fly button on a phone or Y on a gamepad toggles it. The character flies where the camera
-- looks: the move keys or thumbstick steer, Space rises, Ctrl sinks (Q drops
-- a carried animal), Shift goes fast.
-- The client owns its character's physics, so the movers here replicate on their own.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local StaffConfig = require(ReplicatedStorage.Shared.FeatureConfig.StaffConfig)

local Flight = {}

local ACTION = "StaffFly"
local player = Players.LocalPlayer

local flying = false
local movers: { Instance } = {}
local stepConnection: RBXScriptConnection? = nil
local lastSpace = -math.huge

local function parts(): (Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
		return humanoid, root
	end
	return nil, nil
end

local function stop()
	flying = false
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end
	for _, mover in movers do
		mover:Destroy()
	end
	table.clear(movers)
	local humanoid = parts()
	if humanoid then
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall) -- lands normally instead of tipping over
	end
end

local function vertical(): number
	if UserInputService:GetFocusedTextBox() then
		return 0
	end
	local y = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		y += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		y -= 1
	end
	return y
end

local function start()
	local humanoid, root = parts()
	if not humanoid or not root then
		return
	end
	flying = true
	humanoid.PlatformStand = true

	local attachment = Instance.new("Attachment")
	attachment.Name = "FlyAttachment"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "FlyVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.MaxForce = math.huge
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "FlyAlign"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxTorque = math.huge
	align.Responsiveness = 30
	align.CFrame = root.CFrame.Rotation
	align.Parent = root
	movers = { attachment, velocity, align }

	local Fly = StaffConfig.Fly
	stepConnection = RunService.RenderStepped:Connect(function(dt)
		local liveHumanoid, liveRoot = parts()
		if not liveHumanoid or liveRoot ~= root or not velocity.Parent then
			stop()
			return
		end
		local camera = Workspace.CurrentCamera
		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis
		local right = flat:Cross(Vector3.yAxis)

		-- MoveDirection is the camera-relative walk input (keys or thumbstick). Splitting it
		-- back into forward and sideways lets forward follow the camera's pitch, so a phone
		-- can climb by looking up.
		local move = liveHumanoid.MoveDirection
		local direction = look * move:Dot(flat) + right * move:Dot(right) + Vector3.yAxis * vertical()
		if direction.Magnitude > 1 then
			direction = direction.Unit
		end
		local speed = if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then Fly.FastSpeed else Fly.Speed
		local alpha = math.clamp(dt * Fly.Responsiveness / 4, 0, 1)
		velocity.VectorVelocity = velocity.VectorVelocity:Lerp(direction * speed, alpha)
		align.CFrame = CFrame.lookAt(Vector3.zero, flat)
	end)
end

local function flip()
	if flying then
		stop()
	else
		start()
	end
end

local function toggle(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	flip()
	return Enum.ContextActionResult.Sink
end

-- The default controls bind Space with ContextActionService, so a jump press always arrives
-- as processed. Typing is the only press to skip. The first tap still jumps (or rises).
local function onInput(input: InputObject)
	if input.KeyCode ~= Enum.KeyCode.Space or UserInputService:GetFocusedTextBox() then
		return
	end
	if player:GetAttribute("StaffRole") == nil then
		return
	end
	local now = os.clock()
	if now - lastSpace <= StaffConfig.Fly.DoubleTapSeconds then
		lastSpace = -math.huge -- a third tap starts a new pair instead of flipping back
		flip()
	else
		lastSpace = now
	end
end

local function refresh()
	if player:GetAttribute("StaffRole") ~= nil then
		ContextActionService:BindAction(ACTION, toggle, true, Enum.KeyCode.F, Enum.KeyCode.ButtonY)
		ContextActionService:SetTitle(ACTION, "Fly")
		ContextActionService:SetPosition(ACTION, UDim2.new(1, -170, 1, -150))
	else
		ContextActionService:UnbindAction(ACTION)
		if flying then
			stop()
		end
	end
end

function Flight.init(_initial: any)
	player:GetAttributeChangedSignal("StaffRole"):Connect(refresh)
	UserInputService.InputBegan:Connect(onInput)
	player.CharacterAdded:Connect(function()
		if flying then
			stop()
		end
	end)
	refresh()
end

return Flight
