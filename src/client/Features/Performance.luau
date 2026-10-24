-- Low-detail mode for slow machines. Switches on when the player's Roblox graphics quality is
-- set low (levels 1-4), or when the frame rate stays under LOW_FPS for two checks in a row
-- after the join settles. It only changes this client: no shadows, no bloom, thinner haze,
-- fewer animated pen animals. It never switches back on its own within a session (flapping
-- between modes is worse than either).

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PenLife = require(script.Parent.PenLife)

local Performance = {}

local SETTLE_SECONDS = 15 -- loading and the opening cutscene are not a fair sample
local WINDOW_SECONDS = 5
local LOW_FPS = 40
local STRIKES = 2 -- slow windows in a row before switching
local CHECK_EVERY = 30 -- seconds between windows, so the check itself costs nothing

local low = false

local function lighten()
	Lighting.GlobalShadows = false
	for _, effect in Lighting:GetChildren() do
		if effect:IsA("BloomEffect") or effect:IsA("SunRaysEffect") or effect:IsA("DepthOfFieldEffect") then
			effect.Enabled = false
		elseif effect:IsA("Atmosphere") then
			effect.Haze = math.min(effect.Haze, 0.2)
		end
	end
end

function Performance.isLow(): boolean
	return low
end

function Performance.setLow()
	if low then
		return
	end
	low = true
	lighten()
	-- The server can set lighting again (e.g. after a Mud Storm); keep shadows off.
	Lighting:GetPropertyChangedSignal("GlobalShadows"):Connect(function()
		if Lighting.GlobalShadows then
			Lighting.GlobalShadows = false
		end
	end)
	Lighting.ChildAdded:Connect(function()
		task.defer(lighten)
	end)
	PenLife.setLowDetail(true)
end

local function lowQualitySetting(): boolean
	local ok, level = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel
	end)
	if not ok or typeof(level) ~= "EnumItem" then
		return false
	end
	-- Automatic is value 0; Level01..Level10 are 1..10.
	return level.Value >= 1 and level.Value <= 4
end

function Performance.init(_initial: any)
	if lowQualitySetting() then
		Performance.setLow()
		return
	end
	-- A window in the background renders slowly on purpose; don't count that.
	local focused = true
	UserInputService.WindowFocused:Connect(function()
		focused = true
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		focused = false
	end)
	task.spawn(function()
		task.wait(SETTLE_SECONDS)
		local strikes = 0
		while not low do
			if not focused then
				task.wait(1)
				continue
			end
			local frames = 0
			local started = os.clock()
			while os.clock() - started < WINDOW_SECONDS do
				RunService.RenderStepped:Wait()
				frames += 1
			end
			local fps = frames / (os.clock() - started)
			if not focused then
				continue
			end
			strikes = if fps < LOW_FPS then strikes + 1 else 0
			if strikes >= STRIKES then
				Performance.setLow()
			elseif strikes == 0 then
				task.wait(CHECK_EVERY)
			end
		end
	end)
end

return Performance
