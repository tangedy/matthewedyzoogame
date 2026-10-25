-- Small box on the right: "Invite Friends for 2x LUCK!" opens the Roblox invite prompt.
-- While a friend is in the server (the FriendLuck attribute the server sets), it turns
-- green and says the boost is on. Desktop keeps it at right middle, under the contextual
-- offer; touch moves it to the top right, clear of the jump and WASH buttons.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.FeatureConfig.FriendLuckConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local UIPlatform = require(script.Parent.Parent.UI)

local FriendLuck = {}

local IDLE_TOP = Color3.fromRGB(120, 200, 255)
local IDLE_BOTTOM = Color3.fromRGB(60, 110, 230)
local ACTIVE_TOP = Color3.fromRGB(130, 255, 140)
local ACTIVE_BOTTOM = Color3.fromRGB(30, 170, 70)

local player = Players.LocalPlayer
local inviting = false

local function invite()
	if inviting then
		return
	end
	inviting = true
	task.spawn(function()
		local okCan, canInvite = pcall(SocialService.CanSendGameInviteAsync, SocialService, player)
		if okCan and canInvite then
			local options = Instance.new("ExperienceInviteOptions")
			options.PromptMessage = Config.InviteMessage
			pcall(SocialService.PromptGameInvite, SocialService, player, options)
		end
		inviting = false
	end)
end

function FriendLuck.init(_initial: any)
	local gui = Instance.new("ScreenGui")
	gui.Name = "FriendLuck"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local box = Instance.new("TextButton")
	box.Name = "InviteBox"
	box.AutoButtonColor = true
	box.Text = ""
	box.BackgroundColor3 = Color3.new(1, 1, 1)
	box.Size = UDim2.fromOffset(200, 62)
	-- Right middle on desktop; top right on touch, clear of jump and WASH.
	UIPlatform.Layout.watch(function(spec)
		box.AnchorPoint = spec.invite.anchor
		box.Position = spec.invite.position
	end)
	box.Parent = gui
	UIStyle.border(box, 3)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = box
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Parent = box
	local scale = Instance.new("UIScale")
	scale.Parent = box

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(8, 5)
	title.Size = UDim2.new(1, -16, 0, 32)
	title.TextWrapped = true
	title.Parent = box
	UIStyle.text(title, Color3.fromRGB(255, 240, 120), nil, 2.5)
	local sub = Instance.new("TextLabel")
	sub.Position = UDim2.new(0, 8, 1, -24)
	sub.Size = UDim2.new(1, -16, 0, 18)
	sub.Parent = box
	UIStyle.text(sub, nil, nil, 1.5)

	local function render()
		local count = player:GetAttribute("FriendLuck")
		local here = if typeof(count) == "number" then count else 0
		local active = here > 0
		local top = if active then ACTIVE_TOP else IDLE_TOP
		local bottom = if active then ACTIVE_BOTTOM else IDLE_BOTTOM
		gradient.Color = ColorSequence.new(top, bottom)
		title.Text = if active then Config.ActiveText else Config.PromptText
		if active then
			sub.Text = `{here} friend{if here == 1 then "" else "s"} here! Invite more`
		else
			sub.Text = if UIPlatform.get().inputMode == "Touch" then "Tap to invite" else "Click to invite"
		end
	end
	render()
	player:GetAttributeChangedSignal("FriendLuck"):Connect(function()
		render()
		scale.Scale = 1.15
		TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	end)

	box.Activated:Connect(function()
		scale.Scale = 0.9
		TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
		invite()
	end)
end

return FriendLuck
