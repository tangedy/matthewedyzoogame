-- Seven-day check-in chart (server: Features/LiveOps/CheckIn). A DAILY button on the left,
-- right above SHOP, opens a panel with all seven rewards: claimed days are ticked, today's
-- glows, and CLAIM sends the request (the server picks the reward). After a claim the button
-- stays, counting down to the next reward (LiveOpsConfig.CheckIn.CooldownHours). It only shows
-- once the player has upgraded their gear and placed an animal (the server's Unlocked). The panel never opens by itself. Rewards and their
-- labels come from LiveOpsConfig.CheckIn, so the chart always shows exactly what each day gives.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Modals = require(script.Parent.Parent.UI.Modals)
local UIPlatform = require(script.Parent.Parent.UI)

type State = {
	Count: number,
	CanClaim: boolean,
	NextDay: number,
	NextClaimIn: number,
	Claimed: string?,
	Unlocked: boolean?,
}
type Card = { Frame: Frame, Stroke: UIStroke, Status: TextLabel }

local player = Players.LocalPlayer
local Rewards = LiveOpsConfig.CheckIn.Rewards

local CheckIn = {}

local CLAIMED_COLOR = UIStyle.Colors.Cash
local TODAY_COLOR = Color3.fromRGB(255, 190, 40)
local LATER_COLOR = UIStyle.Colors.Muted
local BUTTON_COLOR = UIStyle.Colors.Cash
local WAIT_COLOR = UIStyle.Colors.Disabled

local panel: Frame
local panelScale: UIScale
local dim: TextButton
local claimButton: TextButton
local message: TextLabel
local dailyButton: TextButton
local dailyScale: UIScale
local badge: TextLabel
local cards: { Card } = {}
local state: State? = nil
local stateAt = 0 -- os.clock() when state arrived, for the countdown
local claimRemote: RemoteEvent

local function pop(scale: UIScale, from: number, seconds: number)
	scale.Scale = from
	TweenService:Create(scale, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
end

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60)
end

local function textLabel(parent: Instance, props: { [string]: any }, color: Color3?, thickness: number?): TextLabel
	local l = Instance.new("TextLabel")
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	UIStyle.text(l, color, nil, thickness)
	return l
end

-- The reward name in its own colour: green cash, rarity-coloured animals, a rainbow title.
local function styleReward(label: TextLabel, reward: LiveOpsConfig.CheckInReward)
	if reward.Kind == "Cash" then
		UIStyle.text(label, UIStyle.CashColor, nil, 2.5)
	elseif (reward.Kind == "Animal" and reward.Mutation == "Rainbow") or reward.Kind == "Title" then
		UIStyle.text(label, Color3.new(1, 1, 1), nil, 2.5)
		UIStyle.rainbow(label)
	elseif reward.Kind == "Animal" and reward.Rarity then
		local rarity = RarityConfig.ByKey[reward.Rarity]
		UIStyle.text(label, rarity and rarity.Color, rarity and rarity.StrokeColor, 2.5)
	elseif reward.Kind == "EarningsBuff" then
		UIStyle.text(label, Color3.fromRGB(200, 130, 255), nil, 2.5)
	else
		UIStyle.text(label, nil, nil, 2.5)
	end
end

local function render()
	local s = state
	if not s then
		return
	end
	for index, card in cards do
		local claimed = index <= s.Count
		local today = s.CanClaim and index == s.NextDay
		card.Frame.BackgroundColor3 = if claimed then CLAIMED_COLOR elseif today then TODAY_COLOR else LATER_COLOR
		card.Stroke.Color = if today then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
		card.Stroke.Thickness = if today then 4 else 3
		card.Status.Text = if claimed then "CLAIMED" elseif today then "TODAY!" else `DAY {index}`
	end
	local left = s.NextClaimIn - (os.clock() - stateAt)
	if s.CanClaim then
		claimButton.Text = `CLAIM DAY {s.NextDay}`
		claimButton.BackgroundColor3 = BUTTON_COLOR
		claimButton.Active = true
	else
		claimButton.Text = `TOMORROW · {clock(left)}`
		claimButton.BackgroundColor3 = WAIT_COLOR
		claimButton.Active = false
	end
	badge.Visible = s.CanClaim
	-- Touch shows the gift icon above a short caption: the countdown alone.
	local compact = UIPlatform.Layout.get().rail.compact
	dailyButton.Text = if s.CanClaim then "DAILY" elseif compact then clock(left) else `DAILY {clock(left)}`
	-- Hidden until unlocked; the rail closes the gap so SHOP moves up under INDEX.
	dailyButton.Visible = s.Unlocked == true
end

local function close()
	panel.Visible = false
	dim.Visible = false
end

local function open()
	Modals.claim("CheckIn")
	dim.Visible = true
	if not panel.Visible then
		panel.Visible = true
		pop(panelScale, 0.6, 0.4)
	end
	render()
end

local function makeCard(parent: Instance, index: number, reward: LiveOpsConfig.CheckInReward): Card
	local frame = Instance.new("Frame")
	frame.LayoutOrder = index
	frame.BackgroundColor3 = LATER_COLOR
	frame.Parent = parent
	UIStyle.border(frame, 3)
	local stroke = frame:FindFirstChildOfClass("UIStroke") :: UIStroke

	textLabel(frame, {
		Position = UDim2.fromOffset(6, 4),
		Size = UDim2.new(1, -12, 0, 22),
		Text = `DAY {index}`,
	}, Color3.fromRGB(255, 240, 160), 2)
	local name = textLabel(frame, {
		Position = UDim2.fromOffset(6, 30),
		Size = UDim2.new(1, -12, 0.42, -10),
		Text = reward.Label,
		TextWrapped = true,
	})
	styleReward(name, reward)
	textLabel(frame, {
		Position = UDim2.new(0, 6, 0.42, 22),
		Size = UDim2.new(1, -12, 0, 18),
		Text = reward.Detail,
	}, Color3.fromRGB(225, 225, 235), 1.5)
	local status = textLabel(frame, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 6, 1, -6),
		Size = UDim2.new(1, -12, 0, 20),
		Text = `DAY {index}`,
	}, nil, 2)
	return { Frame = frame, Stroke = stroke, Status = status }
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "CheckIn"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 32
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Second on the left rail, between INDEX and SHOP.
	dailyButton = Instance.new("TextButton")
	dailyButton.Name = "DailyButton"
	dailyButton.Visible = false
	dailyButton.BackgroundColor3 = UIStyle.Colors.Action
	dailyButton.ZIndex = 10
	dailyButton.Text = "DAILY"
	dailyButton.Parent = gui
	UIStyle.text(dailyButton, nil, nil, 2.5)
	UIStyle.border(dailyButton, 3)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = dailyButton
	dailyScale = Instance.new("UIScale")
	dailyScale.Parent = dailyButton
	UIPlatform.Layout.rail(dailyButton, 2, "Gift")
	UIPlatform.Feedback.button(dailyButton)
	badge = textLabel(dailyButton, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -4, 0, 2),
		Size = UDim2.fromOffset(26, 26),
		Text = "!",
		Visible = false,
		ZIndex = 11,
	})
	badge.BackgroundTransparency = 0 -- UIStyle.text clears label backgrounds
	badge.BackgroundColor3 = Color3.fromRGB(240, 60, 60)
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = badge
	dailyButton.Activated:Connect(function()
		if panel.Visible then
			close()
		else
			open()
		end
	end)

	panel = Instance.new("Frame")
	panel.Name = "CheckInPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.94, 0.86)
	panel.BackgroundColor3 = UIStyle.PanelColor
	panel.Visible = false
	panel.ZIndex = 5
	panel.Parent = gui
	dim = Modals.dim(gui, close)
	Modals.bind("CheckIn", close)
	UIStyle.border(panel, 4)
	UIPlatform.Layout.panel(panel, { scale = Vector2.new(0.94, 0.86), maxSize = Vector2.new(640, 430) })
	panelScale = Instance.new("UIScale")
	panelScale.Parent = panel

	local title = textLabel(panel, {
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -80, 0, 42),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "DAILY CHECK-IN",
	}, Color3.fromRGB(80, 200, 255), 3.5)
	title.ZIndex = 6

	local closeButton = Instance.new("TextButton")
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -10, 0, 8)
	closeButton.Size = UDim2.fromOffset(46, 46)
	closeButton.BackgroundColor3 = UIStyle.Colors.Close
	closeButton.Text = "X"
	closeButton.ZIndex = 6
	closeButton.Parent = panel
	UIStyle.text(closeButton)
	UIStyle.border(closeButton, 3)
	closeButton.Activated:Connect(close)
	UIPlatform.Feedback.button(closeButton)
	UIPlatform.Layout.closeTarget(closeButton, close)

	local grid = Instance.new("Frame")
	grid.Position = UDim2.fromOffset(12, 58)
	grid.Size = UDim2.new(1, -24, 1, -150)
	grid.BackgroundTransparency = 1
	grid.ZIndex = 6
	grid.Parent = panel
	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.CellSize = UDim2.new(0.25, -6, 0.5, -4) -- four across, two rows
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	for index, reward in Rewards do
		cards[index] = makeCard(grid, index, reward)
	end

	message = textLabel(panel, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -66),
		Size = UDim2.new(1, -24, 0, 24),
		Text = "Missing a day never resets.",
	}, Color3.fromRGB(220, 235, 255), 1.5)
	message.ZIndex = 6

	claimButton = Instance.new("TextButton")
	claimButton.AnchorPoint = Vector2.new(0.5, 1)
	claimButton.Position = UDim2.new(0.5, 0, 1, -12)
	claimButton.Size = UDim2.new(0.6, 0, 0, 48)
	claimButton.BackgroundColor3 = BUTTON_COLOR
	claimButton.Text = "CLAIM"
	claimButton.ZIndex = 6
	claimButton.Parent = panel
	UIStyle.text(claimButton, nil, nil, 3)
	UIStyle.border(claimButton, 4)
	local claimScale = Instance.new("UIScale")
	claimScale.Parent = claimButton
	claimButton.Activated:Connect(function()
		if state and state.CanClaim then
			pop(claimScale, 0.8, 0.3)
			state.CanClaim = false -- until the server answers
			claimRemote:FireServer()
			render()
		end
	end)
end

local function apply(value: any)
	if typeof(value) ~= "table" or typeof(value.Count) ~= "number" then
		return
	end
	state = value :: State
	stateAt = os.clock()
	if typeof(value.Claimed) == "string" then
		message.Text = value.Claimed
		pop(panelScale, 0.92, 0.3)
	end
	render()
end

function CheckIn.init(_initial: any)
	claimRemote = Remotes.event("CheckInClaim")
	buildGui()
	Remotes.event("CheckInState").OnClientEvent:Connect(apply)
	task.spawn(function()
		local ok, value = pcall(function()
			return Remotes.func("CheckInSync"):InvokeServer()
		end)
		if ok then
			apply(value)
		end
	end)
	task.spawn(function()
		while dailyButton.Parent do
			task.wait(1)
			if panel.Visible or (state and not state.CanClaim) then
				render() -- keeps the countdowns ticking
			elseif state and state.CanClaim then
				pop(dailyScale, 1.12, 0.5) -- a nudge while a reward is waiting
				task.wait(4)
			end
		end
	end)
end

return CheckIn
