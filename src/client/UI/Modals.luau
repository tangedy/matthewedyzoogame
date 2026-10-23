-- One full-screen panel at a time. Opening Index, the Robux shop, or the hose shop
-- closes the others. A dimmer behind the panel keeps the wash card from drawing over it.
--
-- Zooming the camera in on desktop (and shift lock) pins the cursor to the middle of
-- the screen, so menu buttons cannot be clicked. The default camera script locks the
-- mouse again every frame, which overrides GuiButton.Modal. While a menu is open we
-- step the camera just outside first person and, after the camera update, force the
-- cursor free. Closing the last menu gives that lock back.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Modals = {}

local RENDER_STEP = "MenuCursorUnlock"
-- First person starts below 1 stud. Holding the minimum here makes the camera
-- script drop the lock itself instead of fighting us every frame.
local FIRST_PERSON_ZOOM = 1

local closers: { [string]: () -> () } = {}
-- true while that gui is showing. A hidden gui must stay in the table so a second
-- holdCursor call does not connect Visible twice.
local watching: { [GuiObject]: boolean } = {}
local unlockButton: TextButton? = nil
local stepBound = false
local savedMinZoom: number? = nil

local function menuOpen(): boolean
	for gui, open in watching do
		if open and gui.Parent ~= nil then
			return true
		end
	end
	return false
end

local function showCursor()
	-- Runs after the camera script, which locks the cursor again every frame
	-- while zoomed in or shift-locked.
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function pushZoom()
	local player = Players.LocalPlayer
	if savedMinZoom == nil then
		savedMinZoom = player.CameraMinZoomDistance
	end
	if player.CameraMinZoomDistance < FIRST_PERSON_ZOOM then
		player.CameraMinZoomDistance = FIRST_PERSON_ZOOM
	end
end

local function popZoom()
	if savedMinZoom == nil then
		return
	end
	Players.LocalPlayer.CameraMinZoomDistance = savedMinZoom
	savedMinZoom = nil
end

local function refreshCursor()
	local open = menuOpen()
	if unlockButton then
		unlockButton.Visible = open
	end
	if open then
		pushZoom()
		if not stepBound then
			stepBound = true
			RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + 1, showCursor)
		end
		showCursor()
	else
		if stepBound then
			stepBound = false
			RunService:UnbindFromRenderStep(RENDER_STEP)
		end
		popZoom()
	end
end

local function ensureUnlock()
	if unlockButton and unlockButton.Parent then
		return
	end
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "MenuCursor"
	gui.ResetOnSpawn = false
	-- IgnoreGuiInset alone. Also setting ScreenInsets shifts this button off the
	-- top of the screen by the top-bar height, and an off-screen Modal button
	-- does not count.
	gui.IgnoreGuiInset = true
	gui.ClipToDeviceSafeArea = false
	-- Behind every menu. Active is false too, so a click always lands on the panel.
	gui.DisplayOrder = 0
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui:SetAttribute("UIPlatformExclude", true)

	local button = Instance.new("TextButton")
	button.Name = "Unlock"
	button.AnchorPoint = Vector2.new(0, 0)
	button.Position = UDim2.fromScale(0, 0)
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Text = ""
	button.TextTransparency = 1
	button.AutoButtonColor = false
	button.Modal = true
	button.Active = false -- clicks fall through to the menu under this gui
	button.Selectable = false
	button.Visible = false
	button.Parent = gui
	gui.Parent = playerGui
	unlockButton = button
end

-- While guiObject is visible, the cursor can move and click. Closing it gives
-- the camera its lock back (first person and shift lock apply on the next frame).
function Modals.holdCursor(guiObject: GuiObject)
	if watching[guiObject] ~= nil then
		watching[guiObject] = guiObject.Visible
		refreshCursor()
		return
	end
	ensureUnlock()
	watching[guiObject] = guiObject.Visible
	guiObject:GetPropertyChangedSignal("Visible"):Connect(function()
		watching[guiObject] = guiObject.Visible
		refreshCursor()
	end)
	guiObject.Destroying:Connect(function()
		watching[guiObject] = nil
		refreshCursor()
	end)
	refreshCursor()
end

function Modals.bind(name: string, close: () -> ())
	closers[name] = close
end

-- Hide every panel except the one that is about to open. Close functions only hide;
-- they must not call claim, or two panels would loop.
function Modals.claim(name: string)
	for other, close in closers do
		if other ~= name then
			close()
		end
	end
end

-- ResponsiveScale multiplies a scale-sized frame, so a 1,1 dim would only cover
-- part of the viewport. Grow it by the inverse so the wash card stays behind it.
local function fitDim(dim: TextButton, gui: ScreenGui)
	local scale = gui:FindFirstChild("ResponsiveScale")
	local factor = if scale and scale:IsA("UIScale") and scale.Scale > 0.05 then scale.Scale else 1
	dim.Size = UDim2.fromScale(1 / factor, 1 / factor)
end

-- Full-screen dimmer. Clicking it closes the panel. Keep the open-button's ZIndex
-- above this so the button still toggles while the panel is up.
function Modals.dim(parent: ScreenGui, onClose: () -> ()): TextButton
	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.25
	dim.BorderSizePixel = 0
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.Modal = true
	dim.Selectable = false
	dim.Visible = false
	dim.ZIndex = 2
	dim.Parent = parent
	fitDim(dim, parent)
	local function watch(scale: Instance)
		if scale:IsA("UIScale") and scale.Name == "ResponsiveScale" then
			fitDim(dim, parent)
			scale:GetPropertyChangedSignal("Scale"):Connect(function()
				fitDim(dim, parent)
			end)
		end
	end
	local existing = parent:FindFirstChild("ResponsiveScale")
	if existing then
		watch(existing)
	end
	parent.ChildAdded:Connect(watch)
	dim.Activated:Connect(onClose)
	Modals.holdCursor(dim)
	return dim
end

return Modals
