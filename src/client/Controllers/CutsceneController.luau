-- Unskippable spawn cutscene. The camera visits the showcase bay for Cutscene.Duration
-- seconds. There is no skip control. A single caption sits at the bottom. Janitor restores
-- the camera and the character when the shot ends.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local CutsceneController = {}

local function cameraPart(folder: Instance, name: string): BasePart?
	local found = folder:FindFirstChild(name)
	return if found and found:IsA("BasePart") then found else nil
end

local function freeze(humanoid: Humanoid)
	humanoid.WalkSpeed = 0
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = false
	local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
end

function CutsceneController.init(initial: Types.InitialState)
	if initial.PlayCutscene ~= true then
		return
	end
	local janitor = Janitor.new()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
		camera = Workspace.CurrentCamera
	end
	if camera == nil then
		Remotes.event("CutsceneFinished"):FireServer()
		return
	end
	local previousSubject = camera.CameraSubject
	camera.CameraType = Enum.CameraType.Scriptable

	local gui = Instance.new("ScreenGui")
	gui.Name = "SpawnCutscene"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = player:WaitForChild("PlayerGui")
	janitor:Add(gui)

	local caption = Instance.new("TextLabel")
	caption.BackgroundTransparency = 1
	caption.AnchorPoint = Vector2.new(0.5, 1)
	caption.Position = UDim2.new(0.5, 0, 1, -28)
	caption.Size = UDim2.new(0.6, 0, 0, 22)
	caption.Text = "This is the zoo you're building"
	caption.TextScaled = false
	caption.TextSize = 16
	caption.Parent = gui
	UIStyle.text(caption, Color3.fromRGB(240, 240, 240), Color3.fromRGB(20, 20, 20), 1.5)
	caption.TextScaled = false
	caption.TextSize = 16

	local function thaw(humanoid: Humanoid?)
		if not humanoid then
			return
		end
		humanoid.WalkSpeed = 16
		humanoid.JumpHeight = 7.2
		humanoid.AutoRotate = true
		local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			root.Anchored = false
		end
	end

	janitor:Add(player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid and humanoid:IsA("Humanoid") and gui.Parent then
			freeze(humanoid)
		end
	end))
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		freeze(humanoid)
	end

	janitor:Add(function()
		local current = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		thaw(current)
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = current or previousSubject
		Remotes.event("CutsceneFinished"):FireServer()
	end)

	task.spawn(function()
		local folder = Workspace:WaitForChild("CutsceneShowcase", 8)
		local shots = {}
		if folder then
			for _, name in { "CameraWide", "CameraClose", "CameraHero" } do
				local shot = cameraPart(folder, name)
				if shot then
					table.insert(shots, shot)
				end
			end
		end
		-- The server owns the lock, so a late-joining client still ends with everyone else
		-- and cannot skip by firing early.
		local waited = os.clock()
		while player:GetAttribute("InCutscene") ~= true and os.clock() - waited < 2 do
			task.wait()
		end
		local started = os.clock()
		local duration = GameConfig.Cutscene.Duration
		local shotIndex = 0
		while player:GetAttribute("InCutscene") == true and os.clock() - started < duration + 2 do
			if #shots > 0 then
				local index = math.clamp(math.floor((os.clock() - started) / duration * #shots) + 1, 1, #shots)
				if index ~= shotIndex then
					shotIndex = index
					local shot = shots[index]
					if index == 1 then
						camera.CFrame = shot.CFrame
					else
						TweenService:Create(
							camera,
							TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
							{ CFrame = shot.CFrame }
						):Play()
					end
				end
			end
			task.wait()
		end
		if gui.Parent then
			janitor:Cleanup()
		end
	end)

	-- Keep the scriptable camera if something else tries to take it during the shot.
	janitor:Add(RunService.RenderStepped:Connect(function()
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
	end))
end

return CutsceneController
