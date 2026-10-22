-- Native leaderstats (Cash, Income, Stars) for the player list, and a physical "TOP ZOOS"
-- board behind the welcome plaza fountain ranking everyone in the server by income per
-- second. LiveOps owns each player's leaderstats folder.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LiveOpsConfig = require(ReplicatedStorage.Shared.FeatureConfig.LiveOpsConfig)
local UIStyle = require(ReplicatedStorage.Shared.UIStyle)
local Stars = require(script.Parent.Stars)
local Services = script.Parent.Parent.Parent.Services
local Hooks = require(Services.Hooks)
local PlayerDataService = require(Services.PlayerDataService)
local ZooService = require(Services.ZooService)

local Config = LiveOpsConfig.Board

type Row = { Rank: TextLabel, Name: TextLabel, Income: TextLabel, Stars: TextLabel, Frame: Frame }

local Leaderboard = {}

local rows: { Row } = {}

-- Income per second as the pens actually pay it (base income x income modifiers).
local function incomeOf(player: Player): number
	local multiplier = Hooks.apply("IncomeMultiplier", 1, player)
	if typeof(multiplier) ~= "number" or multiplier ~= multiplier or multiplier < 0 or multiplier == math.huge then
		multiplier = 1
	end
	return ZooService.totalIncome(player) * multiplier
end

local function value(folder: Instance, className: string, name: string): ValueBase
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing :: ValueBase
	end
	local new = Instance.new(className) :: ValueBase
	new.Name = name
	new.Parent = folder
	return new
end

local function setupLeaderstats(player: Player)
	local folder: Instance? = player:FindFirstChild("leaderstats")
	if not folder then
		local created = Instance.new("Folder")
		created.Name = "leaderstats"
		created.Parent = player
		folder = created
	end
	local parent = folder :: Instance
	-- The player list sorts by the first stat; Stars is numeric, so it goes first (the
	-- formatted Cash string would sort as text, putting "$9.5K" above "$120K").
	local stars = value(parent, "IntValue", "Stars") :: IntValue
	local cash = value(parent, "StringValue", "Cash") :: StringValue
	local income = value(parent, "StringValue", "Income") :: StringValue
	if cash.Value == "" then
		cash.Value = "$0"
		income.Value = "$0/s"
		stars.Value = 1
	end
end

local function updateLeaderstats(player: Player)
	local folder = player:FindFirstChild("leaderstats")
	local data = PlayerDataService.get(player)
	if not folder or not data then
		return
	end
	local cash = folder:FindFirstChild("Cash")
	local income = folder:FindFirstChild("Income")
	local stars = folder:FindFirstChild("Stars")
	if cash and cash:IsA("StringValue") then
		cash.Value = UIStyle.formatMoney(data.Coins)
	end
	if income and income:IsA("StringValue") then
		income.Value = UIStyle.formatMoney(incomeOf(player)) .. "/s"
	end
	if stars and stars:IsA("IntValue") then
		stars.Value = Stars.get(player)
	end
end

local function part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanQuery = false -- never blocks the hose
	for key, v in props do
		(p :: any)[key] = v
	end
	p.Parent = parent
	return p
end

local function label(parent: Instance, props: { [string]: any }, color: Color3?, stroke: number?): TextLabel
	local l = Instance.new("TextLabel")
	for key, v in props do
		(l :: any)[key] = v
	end
	l.Parent = parent
	UIStyle.text(l, color, nil, stroke)
	return l
end

-- The board stands on two posts and faces -X, toward the plaza and the welcome sign.
local function buildBoard()
	local existing = Workspace:FindFirstChild("LiveOpsLeaderboard")
	if existing then
		existing:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "LiveOpsLeaderboard"
	local base = Config.Position
	local size = Config.Size
	local wood = Color3.fromRGB(130, 90, 55)
	local board = part({
		Name = "Board",
		Size = size,
		Position = base + Vector3.new(0, Config.Height + size.Y / 2, 0),
		Color = Color3.fromRGB(40, 70, 130),
		Material = Enum.Material.SmoothPlastic,
	}, model)
	part({
		Name = "Frame",
		Size = size + Vector3.new(0.2, 0.8, 0.8),
		Position = board.Position + Vector3.new(0.2, 0, 0),
		Color = wood,
		Material = Enum.Material.Wood,
	}, model)
	for _, dz in { -size.Z / 2 + 1, size.Z / 2 - 1 } do
		part({
			Name = "Post",
			Size = Vector3.new(0.8, Config.Height + 1, 0.8),
			Position = base + Vector3.new(0.2, (Config.Height + 1) / 2, dz),
			Color = wood,
			Material = Enum.Material.Wood,
		}, model)
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Leaderboard"
	gui.Face = Enum.NormalId.Left
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.MaxDistance = 150
	gui.Parent = board
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Color3.new(1, 1, 1)
	root.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(Color3.fromRGB(120, 190, 255), Color3.fromRGB(60, 90, 200))
	gradient.Parent = root

	local title = label(root, {
		Position = UDim2.fromScale(0.04, 0.02),
		Size = UDim2.fromScale(0.92, 0.14),
		Text = "TOP ZOOS",
	}, Color3.fromRGB(255, 230, 120), 6)
	local shine = Instance.new("UIGradient")
	shine.Rotation = 90
	shine.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(255, 200, 60))
	shine.Parent = title
	label(root, {
		Position = UDim2.fromScale(0.04, 0.155),
		Size = UDim2.fromScale(0.92, 0.06),
		Text = "by cash per second",
	}, nil, 3)

	local top = 0.235
	local rowHeight = (0.97 - top) / Config.Rows
	for i = 1, Config.Rows do
		local frame = Instance.new("Frame")
		frame.Position = UDim2.fromScale(0.03, top + (i - 1) * rowHeight)
		frame.Size = UDim2.new(0.94, 0, rowHeight, -6)
		frame.BackgroundColor3 = if i % 2 == 1 then Color3.fromRGB(25, 35, 70) else Color3.fromRGB(35, 50, 95)
		frame.BackgroundTransparency = 0.25
		frame.Parent = root
		UIStyle.border(frame, 4)
		local rankColor = if i == 1
			then Color3.fromRGB(255, 205, 40)
			elseif i == 2 then Color3.fromRGB(220, 225, 235)
			elseif i == 3 then Color3.fromRGB(230, 150, 80)
			else Color3.new(1, 1, 1)
		table.insert(rows, {
			Frame = frame,
			Rank = label(frame, {
				Position = UDim2.fromScale(0.01, 0.1),
				Size = UDim2.fromScale(0.09, 0.8),
				Text = `#{i}`,
			}, rankColor, 4),
			Name = label(frame, {
				Position = UDim2.fromScale(0.11, 0.12),
				Size = UDim2.fromScale(0.44, 0.76),
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = "",
			}, nil, 4),
			Income = label(frame, {
				Position = UDim2.fromScale(0.56, 0.12),
				Size = UDim2.fromScale(0.25, 0.76),
				TextXAlignment = Enum.TextXAlignment.Right,
				Text = "",
			}, UIStyle.CashColor, 4),
			Stars = label(frame, {
				Position = UDim2.fromScale(0.82, 0.18),
				Size = UDim2.fromScale(0.17, 0.64),
				RichText = true,
				Text = "",
			}, nil, 3),
		})
	end
	model.Parent = Workspace
end

local function updateBoard()
	local entries: { { Player: Player, Income: number } } = {}
	for _, player in Players:GetPlayers() do
		if PlayerDataService.get(player) then
			table.insert(entries, { Player = player, Income = incomeOf(player) })
		end
	end
	table.sort(entries, function(a, b)
		if a.Income ~= b.Income then
			return a.Income > b.Income
		end
		return a.Player.UserId < b.Player.UserId
	end)
	for i, row in rows do
		local entry = entries[i]
		row.Frame.Visible = entry ~= nil
		if entry then
			row.Name.Text = entry.Player.DisplayName
			row.Income.Text = UIStyle.formatMoney(entry.Income) .. "/s"
			row.Stars.Text = Stars.richText(Stars.get(entry.Player))
		end
	end
end

local function loop(interval: number, fn: () -> ())
	task.spawn(function()
		while true do
			task.wait(interval)
			local ok, err = pcall(fn)
			if not ok then
				warn(`[LiveOps] Leaderboard update failed: {err}`)
			end
		end
	end)
end

function Leaderboard.init()
	Players.PlayerAdded:Connect(setupLeaderstats)
	for _, player in Players:GetPlayers() do
		setupLeaderstats(player)
	end
	buildBoard()
	updateBoard()
	loop(LiveOpsConfig.Leaderstats.UpdateInterval, function()
		for _, player in Players:GetPlayers() do
			updateLeaderstats(player)
		end
	end)
	loop(Config.UpdateInterval, updateBoard)
end

return Leaderboard
