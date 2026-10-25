-- Button feel shared by every HUD button: grow on hover, sink on press, spring back
-- on release, with a soft tap sound. The motion runs on a UIScale on the button, so it
-- multiplies with ResponsiveScale instead of fighting it.
--
--   Feedback.button(button, options?)   wire one GuiButton
--   Feedback.popIn(scale)               a panel opening: pops from small with a Back ease
--
-- A button that already has a UIScale (one a controller pops on purchase, say) shares
-- it. The last tween wins, and every tween ends back at 1.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local Feedback = {}

export type Options = {
	hover: number?, -- scale while a mouse is over it
	press: number?, -- scale while held
	sound: boolean?, -- tap sound on click (default true)
}

local HOVER_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_INFO = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_FROM = 0.6

local hoverSound: Sound? = nil
local clickSound: Sound? = nil

local function sounds(): (Sound, Sound)
	if not clickSound then
		local click = Instance.new("Sound")
		click.Name = "UIClick"
		click.SoundId = GameConfig.Sounds.ShopClick
		click.Volume = 0.3
		click.Parent = SoundService
		clickSound = click
		local hover = click:Clone()
		hover.Name = "UIHover"
		hover.Volume = 0.08
		hover.PlaybackSpeed = 1.6
		hover.Parent = SoundService
		hoverSound = hover
	end
	return hoverSound :: Sound, clickSound :: Sound
end

function Feedback.play(kind: "hover" | "click")
	local hover, click = sounds()
	if kind == "hover" then
		hover:Play()
	else
		click:Play()
	end
end

function Feedback.popIn(scale: UIScale)
	scale.Scale = OPEN_FROM
	TweenService:Create(scale, OPEN_INFO, { Scale = 1 }):Play()
end

function Feedback.button(button: GuiButton, options: Options?)
	local opts: Options = options or {}
	local hoverTo = opts.hover or 1.06
	local pressTo = opts.press or 0.94
	button.AutoButtonColor = false

	local scale = button:FindFirstChildOfClass("UIScale")
	if not scale then
		local created = Instance.new("UIScale")
		created.Name = "FeedbackScale"
		created.Parent = button
		scale = created
	end
	local target = scale :: UIScale

	local hovered = false
	local pressed = false
	local tween: Tween? = nil
	local function go(to: number, info: TweenInfo)
		if tween then
			tween:Cancel()
		end
		tween = TweenService:Create(target, info, { Scale = to });
		(tween :: Tween):Play()
	end

	button.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseMovement then
			if not hovered then
				hovered = true
				if not pressed then
					go(hoverTo, HOVER_INFO)
				end
				Feedback.play("hover")
			end
		elseif kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			pressed = true
			go(pressTo, PRESS_INFO)
		end
	end)
	button.InputEnded:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseMovement then
			hovered = false
			if not pressed then
				go(1, HOVER_INFO)
			end
		elseif kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			pressed = false
			-- A touch has no hover, so it always springs back to 1.
			go(if hovered and kind ~= Enum.UserInputType.Touch then hoverTo else 1, RELEASE_INFO)
		end
	end)
	-- Hiding mid-press would leave it sunk the next time it shows.
	button:GetPropertyChangedSignal("Visible"):Connect(function()
		if not button.Visible then
			hovered, pressed = false, false
			if tween then
				tween:Cancel()
			end
			target.Scale = 1
		end
	end)
	if opts.sound ~= false then
		button.Activated:Connect(function()
			Feedback.play("click")
		end)
	end
end

return Feedback
