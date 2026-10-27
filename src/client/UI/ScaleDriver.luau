-- One UIScale named ResponsiveScale on each game ScreenGui. A single Heartbeat
-- drives every scale toward the profile target, so a resize does not allocate
-- a tween per gui.
--
-- Only named game guis (or a gui with UIPlatformInclude) are scaled. Engine and
-- plugin guis parented to PlayerGui — TouchGui, ContextActionGui, Freecam —
-- must stay at scale 1 or the thumbstick, jump button, and virtual action
-- buttons shrink and slide off their anchors.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ScaleDriver = {}

ScaleDriver.SCALE_NAME = "ResponsiveScale"
ScaleDriver.EXCLUDE_ATTRIBUTE = "UIPlatformExclude"
ScaleDriver.INCLUDE_ATTRIBUTE = "UIPlatformInclude"

-- Never scale these, even if something sets UIPlatformInclude on them.
local ENGINE_GUIS: { [string]: boolean } = {
	TouchGui = true,
	ContextActionGui = true,
	Freecam = true,
	BubbleChat = true,
	Chat = true,
	Backpack = true,
}

-- Game ScreenGuis whose children are normal HUD layout. Viewport-pixel guis
-- (SprayControls, TensionSplat, LiveOpsTop) are intentionally absent.
local GAME_GUIS: { [string]: boolean } = {
	HUD = true,
	Shop = true,
	Onboarding = true,
	Zoo = true,
	Index = true,
	Monetization = true,
	QuickBuy = true,
	Tension = true,
	LiveOps = true,
	LiveOpsPopups = true,
	FriendLuck = true,
	CheckIn = true,
	GuideInstruction = true,
	OverflowPrompt = true,
	PaidConfirm = true,
}

type Record = {
	scale: UIScale,
	owned: boolean,
}

local tracked: { [ScreenGui]: Record } = {}
local watched: { [ScreenGui]: boolean } = {}

local shown = 1
local target = 1
local pump: RBXScriptConnection? = nil

local function shouldScale(gui: ScreenGui): boolean
	if ENGINE_GUIS[gui.Name] then
		return false
	end
	if gui:GetAttribute(ScaleDriver.EXCLUDE_ATTRIBUTE) == true then
		return false
	end
	if gui:GetAttribute(ScaleDriver.INCLUDE_ATTRIBUTE) == true then
		return true
	end
	return GAME_GUIS[gui.Name] == true
end

local function findScale(gui: ScreenGui): UIScale?
	for _, child in gui:GetChildren() do
		if child.Name == ScaleDriver.SCALE_NAME and child:IsA("UIScale") then
			return child
		end
	end
	return nil
end

local function stamp()
	for gui, record in tracked do
		if gui.Parent == nil then
			tracked[gui] = nil
		else
			record.scale.Scale = shown
		end
	end
end

local function stopPump()
	if pump then
		pump:Disconnect()
		pump = nil
	end
end

local function step(dt: number)
	local delta = target - shown
	if math.abs(delta) < 0.004 then
		shown = target
		stamp()
		stopPump()
		return
	end
	-- ~180ms to cover most of a profile-boundary step, frame-rate independent.
	shown += delta * math.min(1, dt * 12)
	stamp()
end

local function ensurePump()
	if pump then
		return
	end
	pump = RunService.Heartbeat:Connect(step)
end

local function detach(gui: ScreenGui)
	local record = tracked[gui]
	if not record then
		return
	end
	tracked[gui] = nil
	if record.owned then
		record.scale:Destroy()
	else
		record.scale.Scale = 1
	end
end

local function attach(gui: ScreenGui)
	if tracked[gui] then
		return
	end
	local scale = findScale(gui)
	local owned = false
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = ScaleDriver.SCALE_NAME
		scale.Scale = shown
		scale.Parent = gui
		owned = true
	else
		scale.Scale = shown
	end
	tracked[gui] = { scale = scale, owned = owned }
end

local function sync(gui: ScreenGui)
	if shouldScale(gui) then
		attach(gui)
	else
		detach(gui)
	end
end

local function watch(gui: ScreenGui)
	if watched[gui] then
		return
	end
	watched[gui] = true
	gui:GetAttributeChangedSignal(ScaleDriver.EXCLUDE_ATTRIBUTE):Connect(function()
		sync(gui)
	end)
	gui:GetAttributeChangedSignal(ScaleDriver.INCLUDE_ATTRIBUTE):Connect(function()
		sync(gui)
	end)
	gui.Destroying:Connect(function()
		watched[gui] = nil
		detach(gui)
	end)
	sync(gui)
end

local function onChild(child: Instance)
	if child:IsA("ScreenGui") then
		watch(child)
	end
end

function ScaleDriver.setTarget(scale: number, immediate: boolean)
	if immediate then
		target = scale
		shown = scale
		stamp()
		stopPump()
		return
	end
	if math.abs(target - scale) < 0.0005 and math.abs(shown - scale) < 0.0005 then
		return
	end
	target = scale
	ensurePump()
end

function ScaleDriver.start(): PlayerGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	-- Connect first so a gui created during the scan is not missed.
	playerGui.ChildAdded:Connect(onChild)
	for _, child in playerGui:GetChildren() do
		onChild(child)
	end
	return playerGui
end

return ScaleDriver
