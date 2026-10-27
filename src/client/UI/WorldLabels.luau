-- Labels hung in the world (BillboardGuis) are sized in screen pixels, so on a phone a
-- nameplate, clean meter and callouts stack up to most of the screen. This shrinks every
-- billboard with the viewport height, the same way on every device: full size from
-- REFERENCE_HEIGHT up, down to MIN_SCALE on a landscape phone.
--
-- A UIScale straight under a BillboardGui does nothing, so a billboard is resized itself.
-- That only works when everything inside is sized in scale (TextScaled text, 1,1 frames),
-- so a billboard with pixel-sized contents is left alone, unless it names a pixel-sized
-- root frame in ROOT_ATTRIBUTE: that root gets a UIScale instead.
--
-- Stacked overhead rows stay lined up: UIStyle.overhead works from BASE_ATTRIBUTE, the
-- unscaled height, so its SizeOffset is the same fraction at any scale.
--
--   WorldLabels.start()   watches Workspace and PlayerGui; ClientBootstrap-time, once
--   WorldLabels.scale()   the current factor

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local UIStyle = require(ReplicatedStorage.Shared.UIStyle)

local WorldLabels = {}

WorldLabels.ROOT_ATTRIBUTE = "WorldScaleRoot"
WorldLabels.BASE_ATTRIBUTE = UIStyle.OverheadBaseHeight

local REFERENCE_HEIGHT = 600 -- viewport px at which labels draw at their authored size
local MIN_SCALE = 0.65
local ROOT_SCALE_NAME = "WorldScale"

type Record = { base: UDim2, applied: UDim2? }

local records: { [BillboardGui]: Record } = {}
local factor = 1

local function pixelOnly(size: UDim2): boolean
	return size.X.Scale == 0 and size.Y.Scale == 0
end

-- Everything inside follows the billboard's size: no pixel sizes or offsets, no fixed text.
local function followsSize(billboard: BillboardGui): boolean
	for _, item in billboard:GetDescendants() do
		if item:IsA("GuiObject") then
			local size, position = item.Size, item.Position
			if size.X.Offset ~= 0 or size.Y.Offset ~= 0 or position.X.Offset ~= 0 or position.Y.Offset ~= 0 then
				return false
			end
			if (item:IsA("TextLabel") or item:IsA("TextButton")) and not item.TextScaled then
				return false
			end
		end
	end
	return true
end

local function rootOf(billboard: BillboardGui): GuiObject?
	local name = billboard:GetAttribute(WorldLabels.ROOT_ATTRIBUTE)
	local root = if typeof(name) == "string" then billboard:FindFirstChild(name) else nil
	return if root and root:IsA("GuiObject") then root else nil
end

local function apply(billboard: BillboardGui)
	local record = records[billboard]
	if not record then
		return
	end
	local base = record.base
	local root = rootOf(billboard)
	local scale = if root or followsSize(billboard) then factor else 1
	local size = UDim2.fromOffset(math.floor(base.X.Offset * scale + 0.5), math.floor(base.Y.Offset * scale + 0.5))
	if root then
		local rootScale = root:FindFirstChild(ROOT_SCALE_NAME)
		if not rootScale then
			local created = Instance.new("UIScale")
			created.Name = ROOT_SCALE_NAME
			created.Parent = root
			rootScale = created
		end
		(rootScale :: UIScale).Scale = scale
	end
	record.applied = size
	if billboard.Size ~= size then
		billboard.Size = size
	end
end

local function track(billboard: BillboardGui)
	if records[billboard] or not pixelOnly(billboard.Size) then
		return
	end
	records[billboard] = { base = billboard.Size }
	billboard:SetAttribute(WorldLabels.BASE_ATTRIBUTE, billboard.Size.Y.Offset)
	-- A size we did not write is the owner's new authored size.
	billboard:GetPropertyChangedSignal("Size"):Connect(function()
		local record = records[billboard]
		if not record or billboard.Size == record.applied then
			return
		end
		if not pixelOnly(billboard.Size) then
			records[billboard] = nil
			billboard:SetAttribute(WorldLabels.BASE_ATTRIBUTE, nil)
			return
		end
		record.base = billboard.Size
		billboard:SetAttribute(WorldLabels.BASE_ATTRIBUTE, billboard.Size.Y.Offset)
		apply(billboard)
	end)
	-- Contents often arrive after the billboard (built after parenting, or replicated
	-- in pieces), so whether it can follow its size is checked again as they do.
	billboard.DescendantAdded:Connect(function()
		task.defer(apply, billboard)
	end)
	billboard.Destroying:Connect(function()
		records[billboard] = nil
	end)
	task.defer(apply, billboard)
end

local function consider(instance: Instance)
	if instance:IsA("BillboardGui") then
		track(instance)
	end
end

local function refresh()
	local camera = Workspace.CurrentCamera
	local height = if camera then camera.ViewportSize.Y else REFERENCE_HEIGHT
	local nextFactor = math.clamp(height / REFERENCE_HEIGHT, MIN_SCALE, 1)
	if math.abs(nextFactor - factor) < 0.01 then
		return
	end
	factor = nextFactor
	for billboard in records do
		apply(billboard)
	end
end

function WorldLabels.scale(): number
	return factor
end

function WorldLabels.start(playerGui: PlayerGui)
	refresh()
	Workspace.DescendantAdded:Connect(consider)
	for _, instance in Workspace:GetDescendants() do
		consider(instance)
	end
	-- Client-made billboards sit straight under PlayerGui (one inside a ScreenGui is never drawn).
	playerGui.ChildAdded:Connect(consider)
	for _, child in playerGui:GetChildren() do
		consider(child)
	end
	local cameraConn: RBXScriptConnection? = nil
	local function bindCamera()
		if cameraConn then
			cameraConn:Disconnect()
		end
		local camera = Workspace.CurrentCamera
		cameraConn = if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh) else nil
		refresh()
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)
	bindCamera()
end

return WorldLabels
