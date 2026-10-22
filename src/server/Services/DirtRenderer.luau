-- Visual representation of dirt. Everything that changes how dirt LOOKS lives here, so a
-- decal or texture-mask approach can replace it without touching cleaning or reward logic.
-- Runs on the server; property changes replicate to every client.

local TweenService = game:GetService("TweenService")

local DirtRenderer = {}

local MIN_SCALE = 0.45 -- a nearly clean patch shrinks to this fraction of its size
local MAX_FADE = 0.55 -- and becomes this transparent

-- fraction: remaining dirt in [0, 1]
function DirtRenderer.setAmount(patch: BasePart, fraction: number)
	local base = (patch:GetAttribute("BaseDiameter") or patch.Size.Y) :: number
	local d = base * (MIN_SCALE + (1 - MIN_SCALE) * fraction)
	patch.Size = Vector3.new(patch.Size.X, d, d)
	patch.Transparency = (1 - fraction) * MAX_FADE
	patch:SetAttribute("Dirt", fraction)
end

-- Fully cleaned: fade out, then remove so it no longer blocks spray or shows in hints.
function DirtRenderer.clear(patch: BasePart)
	patch:SetAttribute("Dirt", 0)
	patch.CanQuery = false
	local tween = TweenService:Create(patch, TweenInfo.new(0.2), { Transparency = 1 })
	tween.Completed:Once(function()
		patch:Destroy()
	end)
	tween:Play()
end

return DirtRenderer
