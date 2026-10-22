-- Code-side placement of UIAspectRatioConstraint and UISizeConstraint.
-- ScreenGui is not a GuiObject, so both constraints always go on a Frame,
-- ImageLabel, or button inside it. See docs/ui-platform.md for the Studio steps.

local Constraints = {}

export type Spec = {
	aspectRatio: number?,
	aspectType: Enum.AspectType?,
	dominantAxis: Enum.DominantAxis?,
	minSize: Vector2?,
	maxSize: Vector2?,
}

local ASPECT_NAME = "UIPlatformAspect"
local SIZE_NAME = "UIPlatformSize"

local function aspectOf(object: GuiObject): UIAspectRatioConstraint
	local existing = object:FindFirstChild(ASPECT_NAME)
	if existing and existing:IsA("UIAspectRatioConstraint") then
		return existing
	end
	local created = Instance.new("UIAspectRatioConstraint")
	created.Name = ASPECT_NAME
	created.Parent = object
	return created
end

local function sizeOf(object: GuiObject): UISizeConstraint
	local existing = object:FindFirstChild(SIZE_NAME)
	if existing and existing:IsA("UISizeConstraint") then
		return existing
	end
	local created = Instance.new("UISizeConstraint")
	created.Name = SIZE_NAME
	created.Parent = object
	return created
end

-- FitWithinMaxSize keeps the ratio inside the box UISizeConstraint already clamped.
-- DominantAxis Height is the right default for square icon buttons in a row.
function Constraints.apply(object: GuiObject, spec: Spec)
	if spec.aspectRatio then
		local aspect = aspectOf(object)
		aspect.AspectRatio = spec.aspectRatio
		aspect.AspectType = spec.aspectType or Enum.AspectType.FitWithinMaxSize
		aspect.DominantAxis = spec.dominantAxis or Enum.DominantAxis.Height
	end
	if spec.minSize or spec.maxSize then
		local size = sizeOf(object)
		if spec.minSize then
			size.MinSize = spec.minSize
		end
		if spec.maxSize then
			size.MaxSize = spec.maxSize
		end
	end
end

return Constraints
