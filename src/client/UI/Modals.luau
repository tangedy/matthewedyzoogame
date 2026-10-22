-- One full-screen panel at a time. Opening Index, the Robux shop, or the hose shop
-- closes the others. A dimmer behind the panel keeps the wash card from drawing over it.

local Modals = {}

local closers: { [string]: () -> () } = {}

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
	return dim
end

return Modals
