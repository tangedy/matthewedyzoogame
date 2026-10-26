-- Animal nameplates (UIStyle.nameplate) only show for the one animal you are looking at:
-- the one whose head is nearest the middle of the screen, inside FOCUS_RADIUS. A full pen
-- used to stack a dozen name / rarity / $/s plates over each other (worst on a phone);
-- now the farm reads clean, and turning the camera to an animal brings its plate up.
--
-- Always shown: a Pinned plate (UIStyle.liftNameplate, the animal you are washing).
-- Never shown: the animal in your own hands (the carry banner already names it).
-- Only the local Enabled changes, so every player sees their own focus.
-- ZooController uses the same focus for each pen's Pick up / Sell / Set pet card.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local player = Players.LocalPlayer

local AnimalFocus = {}

local PLATE_NAME = "Nameplate"
local FOCUS_RADIUS = 0.16 -- of the screen's short side, around the middle
local KEEP_RADIUS = 0.24 -- the focused plate holds until it drifts this far (no flicker)
local KEEP_BONUS = 0.04 -- and wins close calls against a new one
local DEPTH_WEIGHT = 0.002 -- per stud: of two animals equally central, the nearer wins
local CHECK_SECONDS = 0.08

local plates: { [BillboardGui]: boolean } = {} -- value: what we last set Enabled to
local focus: BillboardGui? = nil
local listeners: { () -> () } = {}

local function setShown(plate: BillboardGui, on: boolean)
	if plates[plate] ~= on then
		plates[plate] = on
		plate.Enabled = on
	end
end

local function consider(instance: Instance)
	if not instance:IsA("BillboardGui") or instance.Name ~= PLATE_NAME or plates[instance] ~= nil then
		return
	end
	plates[instance] = true
	-- Hidden from the start; the next check shows it if it is the one in view.
	setShown(instance, false)
end

local function headOf(plate: BillboardGui): BasePart?
	local head = plate.Adornee or plate.Parent
	return if head and head:IsA("BasePart") then head else nil
end

local function pickFocus(camera: Camera): BillboardGui?
	local viewport = camera.ViewportSize
	local center = viewport / 2
	local short = math.max(1, math.min(viewport.X, viewport.Y))
	local character = player.Character
	local best: BillboardGui? = nil
	local bestScore = math.huge
	for plate in plates do
		local head = headOf(plate)
		if not head or (character and head:IsDescendantOf(character)) then
			continue
		end
		local point, onScreen = camera:WorldToViewportPoint(head.Position)
		local reach = if plate.MaxDistance > 0 then plate.MaxDistance else math.huge
		if not onScreen or point.Z > reach then
			continue
		end
		local off = (Vector2.new(point.X, point.Y) - center).Magnitude / short
		local held = plate == focus
		if off > (if held then KEEP_RADIUS else FOCUS_RADIUS) then
			continue
		end
		local score = off + point.Z * DEPTH_WEIGHT - (if held then KEEP_BONUS else 0)
		if score < bestScore then
			best = plate
			bestScore = score
		end
	end
	return best
end

local function check()
	for plate in plates do
		if not plate.Parent then
			plates[plate] = nil
		end
	end
	if focus and plates[focus] == nil then
		focus = nil
	end
	local camera = Workspace.CurrentCamera
	local was = focus
	focus = if camera then pickFocus(camera) else nil
	for plate in plates do
		setShown(plate, plate == focus or plate:GetAttribute(UIStyle.PinnedAttribute) == true)
	end
	if focus ~= was then
		for _, listener in listeners do
			task.spawn(listener)
		end
	end
end

-- The head of the animal you are looking at, if any (pen action cards follow it too).
function AnimalFocus.focusedHead(): BasePart?
	return if focus then headOf(focus) else nil
end

function AnimalFocus.onChanged(listener: () -> ())
	table.insert(listeners, listener)
end

function AnimalFocus.init(_initial: any)
	for _, instance in Workspace:GetDescendants() do
		consider(instance)
	end
	Workspace.DescendantAdded:Connect(consider)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= CHECK_SECONDS then
			elapsed = 0
			check()
		end
	end)
end

return AnimalFocus
