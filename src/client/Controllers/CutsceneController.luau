-- Spawn cutscene, in the real world. A tight shot of you sponging a muddy piglet at your own
-- starter bay; the ground shakes; the camera whip-pans across the road to a fully upgraded
-- farm and pulls back over your little base to show a top player on a crane rig fire-hosing a
-- Kaiju at that farm's wash.
--
-- The server sends this player their own copy of the maxed farm (PlayerGui.CutsceneSet). It
-- is dropped on the plot across the road on this client only; whoever's farm stands there is
-- hidden here for the length of the shot and comes back after. Animals at your own wash are
-- hidden the same way, so only the piglet is there.
-- After SkipAfter seconds, E ends it. Janitor restores the camera, the world and the character.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local HoseBuilder = require(ReplicatedStorage.Shared.HoseBuilder)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local PlotLayout = require(ReplicatedStorage.Shared.PlotLayout)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Settings = require(ReplicatedStorage.Shared.CutsceneSettings)
local Types = require(ReplicatedStorage.Shared.Types)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local CutsceneController = {}

local RENDER_STEP = "SpawnCutscene"
local PEN_FOV = 50
local YARD_FOV = 60
local SET_WAIT = 20 -- seconds to wait for your bay, then for the set, before giving the camera back

local function freeze(humanoid: Humanoid)
	humanoid.WalkSpeed = 0
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = false
	local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
end

local function smooth(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

-- Slow in, very fast middle, slow out: the whip.
local function whip(u: number): number
	u = math.clamp(u, 0, 1)
	return if u < 0.5 then 8 * u ^ 4 else 1 - (-2 * u + 2) ^ 4 / 2
end

-- Camera shake of strength `amount` (studs), built from smooth noise so it rolls, not jitters.
local function shake(t: number, amount: number): CFrame
	if amount <= 0 then
		return CFrame.identity
	end
	local x = math.noise(t * 22, 1.7) * amount
	local y = math.noise(t * 22, 5.3) * amount
	local roll = math.noise(t * 18, 9.1) * amount * 0.06
	return CFrame.new(x, y, 0) * CFrame.Angles(0, 0, roll)
end

local function handheld(t: number): CFrame
	return CFrame.Angles(math.noise(t * 0.6, 2.2) * 0.008, math.noise(t * 0.6, 4.4) * 0.008, 0)
end

-- A plot's own frame: at its road-edge anchor, -Z toward the road.
local function plotFrame(index: number): CFrame
	local plot = PlotLayout.frame(index)
	return CFrame.lookAt(plot.Anchor, plot.Anchor + plot.Look)
end

-- Pivots a model to cframe, then lifts or drops it so its lowest point sits at floorY.
local function standOn(model: Model, cframe: CFrame, floorY: number)
	model:PivotTo(cframe)
	local box, size = model:GetBoundingBox()
	model:PivotTo(cframe + Vector3.new(0, floorY - (box.Position.Y - size.Y / 2), 0))
end

local function myBay(): Model?
	local bays = Workspace:FindFirstChild("WashBays")
	if not bays then
		return nil
	end
	for _, bay in bays:GetChildren() do
		if bay:GetAttribute("OwnerUserId") == player.UserId and bay:IsA("Model") then
			return bay
		end
	end
	return nil
end

local function shoulderOf(actor: Model): (Motor6D?, CFrame?, boolean)
	local r15 = actor:FindFirstChild("RightUpperArm")
	local motor = r15 and r15:FindFirstChild("RightShoulder")
	if motor and motor:IsA("Motor6D") then
		return motor, motor.C0, true
	end
	local torso = actor:FindFirstChild("Torso")
	motor = torso and torso:FindFirstChild("Right Shoulder")
	if motor and motor:IsA("Motor6D") then
		return motor, motor.C0, false
	end
	return nil, nil, false
end

local function placeActor(actor: Model, feet: CFrame)
	local humanoid = actor:FindFirstChildOfClass("Humanoid")
	local root = actor:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	root.Anchored = true
	local lift = root.Size.Y / 2 + (if humanoid then humanoid.HipHeight else 2)
	root.CFrame = feet + Vector3.new(0, lift, 0)
end

-- A posable copy of your own character, holding a sponge.
local function copyOfYou(): Model?
	local character = player.Character
	if not character or not character:FindFirstChildOfClass("Humanoid") then
		return nil
	end
	local archivable = character.Archivable
	character.Archivable = true
	local ok, copy = pcall(function()
		return character:Clone()
	end)
	character.Archivable = archivable
	if not ok or not copy then
		return nil
	end
	for _, item in copy:GetDescendants() do
		if item:IsA("Tool") or item:IsA("BaseScript") or item:IsA("ForceField") or item:IsA("BillboardGui") then
			item:Destroy()
		end
	end
	local humanoid = copy:FindFirstChildOfClass("Humanoid")
	local root = copy:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		copy:Destroy()
		return nil
	end
	for _, item in copy:GetDescendants() do
		if item:IsA("BasePart") then
			item.CanCollide = false
			item.CanQuery = false
			item.LocalTransparencyModifier = 0
		end
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	copy.Name = "You"
	return copy
end

local function suds(parent: Instance, rate: number, drip: boolean): ParticleEmitter
	local fx = Instance.new("ParticleEmitter")
	fx.Name = "Suds"
	fx.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	fx.Rate = rate
	fx.Lifetime = if drip then NumberRange.new(0.8, 1.4) else NumberRange.new(0.5, 1)
	fx.Speed = if drip then NumberRange.new(0.2, 0.6) else NumberRange.new(1, 2.5)
	fx.SpreadAngle = Vector2.new(70, 70)
	fx.Acceleration = Vector3.new(0, if drip then -9 else -3, 0)
	fx.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(1, 0.08) })
	fx.Transparency = NumberSequence.new(0.1, 0.5)
	fx.Color = ColorSequence.new(Color3.fromRGB(245, 250, 255), Color3.fromRGB(200, 230, 255))
	fx.Parent = parent
	return fx
end

-- The keeper's jet, from the Fire Hose (top tier, as in the shop) to the Kaiju.
local function jetBeams(hose: Instance, target: Attachment): { Beam }
	local nozzle = hose:FindFirstChild("Nozzle", true)
	if not nozzle or not nozzle:IsA("Attachment") then
		return {}
	end
	local beams = {}
	for _, spec in { { "JetCore", 0.05 }, { "JetMist", 0.7 } } do
		local b = Instance.new("Beam")
		b.Name = spec[1]
		b.Attachment0 = nozzle
		b.Attachment1 = target
		b.FaceCamera = true
		b.LightEmission = 0.6
		b.Segments = 1
		b.Transparency = NumberSequence.new(spec[2], spec[2] + 0.2)
		b.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 215, 255))
		b.Parent = hose
		table.insert(beams, b)
	end
	return beams
end

local function sound(janitor: any, id: string?, speed: number, volume: number, looped: boolean): Sound?
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.PlaybackSpeed = speed
	s.Volume = volume
	s.Looped = looped
	s.Parent = SoundService
	janitor:Add(s)
	return s
end

-- Takes an instance out of this client's world until the janitor cleans up, then puts it
-- back (unless the server removed it meanwhile).
local function stash(janitor: any, item: Instance)
	local home = item.Parent
	if not home then
		return
	end
	item.Parent = nil
	janitor:Add(function()
		if home.Parent then
			pcall(function()
				item.Parent = home
			end)
		end
	end)
end

function CutsceneController.init(initial: Types.InitialState)
	if initial.PlayCutscene ~= true then
		return
	end
	local cfg = Settings
	local beats = cfg.Beats
	local janitor = Janitor.new()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
		camera = Workspace.CurrentCamera
	end
	if camera == nil then
		Remotes.event("CutsceneFinished"):FireServer(false)
		return
	end
	local previousSubject = camera.CameraSubject
	local previousFov = camera.FieldOfView
	camera.CameraType = Enum.CameraType.Scriptable

	local gui = Instance.new("ScreenGui")
	gui.Name = "SpawnCutscene"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = player:WaitForChild("PlayerGui")
	janitor:Add(gui)

	-- Black until the set is in place, so the spawn never flashes before the first shot.
	local fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BorderSizePixel = 0
	fade.Size = UDim2.fromScale(1, 1)
	fade.ZIndex = 5
	fade.Parent = gui

	-- Letterbox bars slide in for the film look.
	local bars = {}
	for _, top in { true, false } do
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0, if top then 0 else 1)
		bar.Position = UDim2.fromScale(0, if top then 0 else 1)
		bar.Size = UDim2.fromScale(1, 0.1)
		bar.Parent = gui
		table.insert(bars, bar)
	end

	local skip = Instance.new("TextLabel")
	skip.Name = "Skip"
	skip.BackgroundTransparency = 1
	skip.AnchorPoint = Vector2.new(0.5, 1)
	skip.Position = UDim2.new(0.5, 0, 1, -24)
	skip.Size = UDim2.new(0.4, 0, 0, 20)
	skip.Text = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
		then "Tap to skip"
		else "Press E to skip"
	skip.Visible = false
	skip.ZIndex = 6
	skip.Parent = gui
	UIStyle.text(skip, Color3.fromRGB(255, 220, 120), Color3.fromRGB(20, 20, 20), 1.5)
	skip.TextScaled = false
	skip.TextSize = 16

	local blur = Instance.new("BlurEffect")
	blur.Name = "CutsceneWhipBlur"
	blur.Size = 0
	blur.Parent = Lighting
	janitor:Add(blur)

	local function thaw(humanoid: Humanoid?)
		if not humanoid then
			return
		end
		humanoid.WalkSpeed = GameConfig.WalkSpeed
		humanoid.JumpHeight = 7.2
		humanoid.AutoRotate = true
		local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			root.Anchored = false
		end
	end

	-- Your real character waits frozen (and unseen, since the copy plays you) at the spawn.
	local function cloak(character: Model?, amount: number)
		if not character then
			return
		end
		for _, item in character:GetDescendants() do
			if item:IsA("BasePart") or item:IsA("Decal") then
				item.LocalTransparencyModifier = amount
			end
		end
	end
	janitor:Add(player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid and humanoid:IsA("Humanoid") and gui.Parent then
			freeze(humanoid)
			cloak(character, 1)
		end
	end))
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		freeze(humanoid)
	end

	local started: number? = nil -- when the first shot begins, once the set is in place
	local function release()
		RunService:UnbindFromRenderStep(RENDER_STEP)
		cloak(player.Character, 0)
		local current = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		thaw(current)
		camera.FieldOfView = previousFov
		if camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
			camera.CameraSubject = current or previousSubject
		end
		-- Watched only if the shot actually ran; otherwise the server just unlocks the hose.
		Remotes.event("CutsceneFinished"):FireServer(started ~= nil)
	end
	janitor:Add(release)

	-- The film owns the screen: every other ScreenGui (HUD, welcome popups and so on) is
	-- hidden, including any that open mid-shot, and comes back when control returns.
	local hidden: { [ScreenGui]: boolean } = {}
	local restoring = false
	local playerGui = gui.Parent :: Instance
	local function hush(other: Instance)
		if other == gui or not other:IsA("ScreenGui") then
			return
		end
		local screen = other :: ScreenGui
		local function apply()
			if screen.Enabled and not restoring then
				hidden[screen] = true
				screen.Enabled = false
			end
		end
		apply()
		janitor:Add(screen:GetPropertyChangedSignal("Enabled"):Connect(apply))
	end
	for _, other in playerGui:GetChildren() do
		hush(other)
	end
	janitor:Add(playerGui.ChildAdded:Connect(hush))
	janitor:Add(function()
		restoring = true
		for screen in hidden do
			if screen.Parent then
				screen.Enabled = true
			end
		end
	end)

	local opened = os.clock()
	local duration = cfg.Duration
	local skipAfter = cfg.SkipAfter
	local ended = false
	local function finish()
		if ended or not gui.Parent then
			return
		end
		ended = true
		janitor:Cleanup()
	end
	-- E (or a tap or click, for touch and mouse) is live for the whole shot. Presses before
	-- SkipAfter do nothing.
	janitor:Add(UserInputService.InputBegan:Connect(function(input: InputObject, _processed: boolean)
		local pressed = input.KeyCode == Enum.KeyCode.E
			or input.KeyCode == Enum.KeyCode.ButtonA
			or input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		if not pressed or not started then
			return
		end
		if os.clock() - started < skipAfter then
			return
		end
		finish()
	end))

	-- Everything below is filled in once your bay and the set have arrived.
	local shots: { [string]: CFrame } = {}
	local pigBase: CFrame? = nil
	local piglet: Model? = nil
	local actorMotor: Motor6D? = nil
	local actorC0: CFrame? = nil
	local actorR15 = true
	local spongeSuds: ParticleEmitter? = nil
	local pigSuds: ParticleEmitter? = nil
	local jets: { Beam } = {}
	local cannon: Sound? = nil

	local function stage(): boolean
		local deadline = os.clock() + SET_WAIT
		local bay = myBay()
		while not bay and os.clock() < deadline and not ended do
			task.wait(0.2)
			bay = myBay()
		end
		if ended or not bay then
			return false
		end
		-- The server starts the shot's clock and sends the set only now, so a slow join
		-- can't outlast it.
		Remotes.event("CutsceneReady"):FireServer()
		deadline = os.clock() + SET_WAIT -- a fresh wait for the set itself
		local mySlot = bay:GetAttribute("BayIndex")
		if typeof(mySlot) == "number" then
			-- With streaming on, both farms may not be loaded yet (no character to focus on).
			local across = if mySlot <= 4 then mySlot + 4 else mySlot - 4
			for _, slot in { mySlot, across } do
				pcall(player.RequestStreamAroundAsync, player, PlotLayout.frame(slot).Anchor, 5)
			end
		end
		local set = playerGui:WaitForChild("CutsceneSet", math.max(deadline - os.clock(), 0.1))
		if ended or not set or not set:IsA("Model") then
			return false
		end
		local farm = set:WaitForChild("MaxFarm", math.max(deadline - os.clock(), 0.1))
		local washMarker = bay:WaitForChild("WashPosition", math.max(deadline - os.clock(), 0.1))
		local templateSlot = set:GetAttribute("TemplateSlot")
		if
			not farm
			or not farm:IsA("Model")
			or not washMarker
			or not washMarker:IsA("BasePart")
			or typeof(mySlot) ~= "number"
			or typeof(templateSlot) ~= "number"
		then
			return false
		end

		-- The maxed farm goes on the plot straight across the road. Whoever owns that plot
		-- is hidden on this screen until the cutscene ends.
		local across = if mySlot <= 4 then mySlot + 4 else mySlot - 4
		local bays = Workspace:FindFirstChild("WashBays") :: Instance
		local function hideNeighbour(other: Instance)
			if other ~= bay and other:GetAttribute("BayIndex") == across then
				stash(janitor, other)
			end
		end
		for _, other in bays:GetChildren() do
			hideNeighbour(other)
		end
		janitor:Add(bays.ChildAdded:Connect(hideNeighbour))
		janitor:Add(set)
		set.Parent = Workspace
		farm:PivotTo(plotFrame(across) * plotFrame(templateSlot):Inverse() * farm:GetPivot())

		-- Your wash gets the piglet; the animal that is really walking in waits off screen.
		local function hideArrival(item: Instance)
			if item:IsA("Model") and item:GetAttribute("AnimalKey") ~= nil then
				stash(janitor, item)
			end
		end
		for _, item in bay:GetChildren() do
			hideArrival(item)
		end
		janitor:Add(bay.ChildAdded:Connect(function(item)
			task.defer(hideArrival, item)
		end))

		local plot = PlotLayout.frame(mySlot)
		local wash = washMarker.Position
		local right = plot.Right
		local up = Vector3.yAxis
		local floorY = wash.Y - 0.1
		local found = set:FindFirstChild("Piglet")
		if found and found:IsA("Model") then
			piglet = found
			standOn(found, CFrame.lookAt(wash, wash + plot.Back), floorY)
			pigBase = found:GetPivot()
			local body = found:FindFirstChild("Body")
			if body and body:IsA("BasePart") then
				pigSuds = suds(body, 14, true)
			end
		end

		-- You, behind the pig and facing the camera. The default-avatar Rookie stands in if
		-- your character can't be copied.
		local spot = wash - right * 2.9
		local feet = CFrame.lookAt(Vector3.new(spot.X, floorY, spot.Z), Vector3.new(spot.X, floorY, spot.Z) + right)
		local actor = copyOfYou()
		local rookie = set:FindFirstChild("Rookie")
		if actor then
			janitor:Add(actor)
			actor.Parent = Workspace
			if rookie then
				rookie:Destroy()
			end
			placeActor(actor, feet)
			HoseBuilder.equip(actor, 1)
		elseif rookie and rookie:IsA("Model") then
			actor = rookie
			placeActor(rookie, feet)
			HoseBuilder.equip(rookie, 1)
		end
		cloak(player.Character, 1)
		if actor then
			actorMotor, actorC0, actorR15 = shoulderOf(actor)
			local sponge = actor:FindFirstChild("Hose")
			if sponge and sponge:IsA("BasePart") then
				spongeSuds = suds(sponge, 30, false)
			end
		end

		-- Shots, all from the real positions of the two washes.
		local kaiju = farm:FindFirstChild("WashAnimal")
		local basket = farm:FindFirstChild("Basket")
		local blast = farm:FindFirstChild("BlastPoint")
		if
			not kaiju
			or not kaiju:IsA("Model")
			or not basket
			or not basket:IsA("BasePart")
			or not blast
			or not blast:IsA("BasePart")
		then
			return false
		end
		local box, size = kaiju:GetBoundingBox()
		local monster = box.Position
		shots.Pen = CFrame.lookAt(wash + right * 10.5 + up * 4.4, wash - right * 1.6 + up * 2.2)
		shots.Whip = CFrame.lookAt(shots.Pen.Position + up * 0.8, monster + up * size.Y * 0.1)
		shots.Reveal = CFrame.lookAt(PlotLayout.point(plot, 58, -6, 36), monster + up * 2)
		local toYou = Vector3.new(wash.X - basket.Position.X, 0, wash.Z - basket.Position.Z).Unit
		local side = toYou:Cross(up)
		local heroFrom = basket.Position + toYou * 20 + side * 8 + up * 5
		shots.Hero = CFrame.lookAt(heroFrom, basket.Position:Lerp(blast.Position, 0.45) + up * 1.5)

		-- Tools go on here: a hand weld made on the server, outside Workspace, doesn't hold.
		local keeper = farm:FindFirstChild("TopKeeper")
		local target = blast:FindFirstChild("SprayTarget")
		if keeper and keeper:IsA("Model") and target and target:IsA("Attachment") then
			HoseBuilder.equip(keeper, 6)
			local hose = keeper:FindFirstChild("Hose")
			if hose then
				jets = jetBeams(hose, target)
			end
		end
		return true
	end

	task.spawn(function()
		local ok, ready = pcall(stage)
		if not ok then
			warn("[CutsceneController] Could not stage the cutscene:", ready)
		end
		if ended then
			return
		end
		if not ok or not ready then
			finish()
			return
		end
		started = os.clock()
		TweenService:Create(fade, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
	end)

	local rumbled, whooshed, barsOut = false, false, false
	local sawLock = player:GetAttribute("InCutscene") == true

	local function cameraAt(t: number): (CFrame?, number)
		local pen, whipTo, reveal, hero = shots.Pen, shots.Whip, shots.Reveal, shots.Hero
		if not pen or not whipTo or not reveal or not hero then
			return nil, YARD_FOV
		end
		local pushed = pen * CFrame.new(0, 0, -0.6 * smooth(t / beats.Whip))
		if t < beats.Whip then
			local tremor = if t >= beats.Shake then 0.06 + 0.22 * smooth((t - beats.Shake) / 0.5) else 0
			return pushed * shake(t, tremor) * handheld(t), PEN_FOV
		elseif t < beats.Reveal then
			local u = (t - beats.Whip) / (beats.Reveal - beats.Whip)
			local e = whip(u)
			return pushed:Lerp(whipTo, e) * shake(t, 0.25 * (1 - u)), PEN_FOV + (YARD_FOV - PEN_FOV) * e
		elseif t < beats.Hero then
			local u = (t - beats.Reveal) / (beats.Hero - beats.Reveal)
			return whipTo:Lerp(reveal, smooth(u)) * shake(t, 0.05), YARD_FOV
		end
		local u = (t - beats.Hero) / math.max(duration - beats.Hero, 0.01)
		return reveal:Lerp(hero, smooth(u)) * handheld(t), YARD_FOV
	end

	RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + 1, function()
		if ended then
			return
		end
		local locked = player:GetAttribute("InCutscene") == true
		-- A false attribute before the lock replicates used to end the shot on the first frame.
		if locked then
			sawLock = true
		elseif sawLock then
			finish()
			return
		end
		-- Keep the scriptable camera if something else tries to take it during the shot.
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		if not started then
			if os.clock() - opened > SET_WAIT * 2 + 5 then
				finish()
			end
			return
		end
		local t = os.clock() - started
		if t >= duration then
			finish()
			return
		end
		if not skip.Visible and t >= skipAfter then
			skip.Visible = true
		end

		local frame, fov = cameraAt(t)
		if frame then
			camera.CFrame = frame
			camera.FieldOfView = fov
		end

		-- The wash: happy scrubbing until the ground shakes.
		local calm = t < beats.Shake
		if piglet and pigBase then
			local wiggle = if calm
				then CFrame.new(0, math.abs(math.sin(t * 6)) * 0.08, 0) * CFrame.Angles(0, 0, math.sin(t * 6) * 0.05)
				else CFrame.new(math.noise(t * 30, 3) * 0.1, 0, 0) * CFrame.Angles(
					0,
					math.noise(t * 4, 8) * 0.3,
					0
				)
			piglet:PivotTo(pigBase * wiggle)
		end
		if actorMotor and actorC0 then
			local lift = if calm then math.rad(72) + math.sin(t * 11) * 0.12 else math.rad(35)
			local sweep = if calm then math.sin(t * 11) * 0.4 else 0
			actorMotor.C0 = if actorR15
				then actorC0 * CFrame.Angles(0, sweep, 0) * CFrame.Angles(lift, 0, 0)
				else actorC0 * CFrame.Angles(sweep, 0, lift)
		end
		if spongeSuds then
			spongeSuds.Enabled = calm
		end
		if pigSuds then
			pigSuds.Enabled = t < beats.Whip
		end

		-- Sound and blur cues.
		if not rumbled and t >= beats.Shake then
			rumbled = true
			local rumble = sound(janitor, cfg.Sounds.Rumble, 0.45, 1, false)
			if rumble then
				rumble:Play()
			end
		end
		if not whooshed and t >= beats.Whip then
			whooshed = true
			local whoosh = sound(janitor, cfg.Sounds.Whoosh, 1.6, 0.8, false)
			if whoosh then
				whoosh:Play()
			end
			cannon = sound(janitor, cfg.Sounds.Cannon, 0.55, 0, true)
			if cannon then
				cannon:Play()
			end
		end
		if t >= beats.Whip and t < beats.Reveal then
			blur.Size = math.sin(math.pi * (t - beats.Whip) / (beats.Reveal - beats.Whip)) * 28
		elseif blur.Size ~= 0 then
			blur.Size = 0
		end
		if cannon then
			-- The roar swells in as the farm comes into view.
			cannon.Volume = 0.9 * smooth((t - beats.Whip) / 1.5)
		end

		-- The jet throbs with pressure.
		local pulse = 1 + math.sin(t * 20) * 0.12 + math.noise(t * 9, 1) * 0.1
		for _, beam in jets do
			local wide = beam.Name == "JetMist"
			beam.Width0 = (if wide then 1.8 else 0.8) * pulse
			beam.Width1 = (if wide then 6 else 2.4) * pulse
		end

		-- Letterbox bars leave just before the camera hands back.
		if t >= duration - 0.6 and not barsOut then
			barsOut = true
			for _, bar in bars do
				TweenService:Create(bar, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(1, 0) })
					:Play()
			end
		end
	end)
end

return CutsceneController
