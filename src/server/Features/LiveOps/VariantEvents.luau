-- Rotating live events on top of the Mud Storm and the Daily Dirty Animal.
-- DevParams.json is the whole tuning surface: 10 minutes on, 5 minutes quiet, then the
-- next event, plus the hidden gold/rainbow odds. Nothing in here tells the player the
-- rates or how close they are to a guaranteed variant.
--
-- Every server uses the same os.time() cycle, so they change events together.
-- The banner end time is published in GetServerTimeNow() space (Common.synced), same as
-- the Mud Storm. State on ReplicatedStorage.LiveOpsState (display only, no odds):
--   VariantEventTitle, VariantEventBlurb, VariantEventEndsAt, VariantEventColor
--   VariantEventNextTitle, VariantEventNextAt — the following event and when it starts

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local MutationPayout = require(script.Parent.Parent.Parent.Services.MutationPayout)
local PlayerDataService = require(script.Parent.Parent.Parent.Services.PlayerDataService)
local Hooks = require(script.Parent.Parent.Parent.Services.Hooks)
local Common = require(script.Parent.Common)

type Boost = { mutation: string, oneIn: number }
type EventDef = {
	id: string,
	title: string,
	blurb: string,
	announceRarity: string,
	color: Color3,
	boosts: { Boost },
}

local VariantEvents = {}

local rng = Random.new()
local events: { EventDef } = {}
local activeSeconds = 600
local downtimeSeconds = 300
local priority: { string } = { "Rainbow", "Gold" }
local activeId = ""
local activeEnds = 0 -- os.time() instant; the attribute is the synced copy
local activeEvent: EventDef? = nil

local function positiveInt(value: any, fallback: number): number
	if typeof(value) == "number" and value >= 1 and value == value and value < 1e7 then
		return math.floor(value)
	end
	return fallback
end

local function colorOf(raw: any, fallback: Color3): Color3
	if typeof(raw) == "table" and #raw >= 3 then
		local r, g, b = raw[1], raw[2], raw[3]
		if typeof(r) == "number" and typeof(g) == "number" and typeof(b) == "number" then
			return Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
		end
	end
	return fallback
end

local function load()
	local params = MutationPayout.params
	local schedule = if typeof(params.schedule) == "table" then params.schedule else {}
	activeSeconds = positiveInt(schedule.activeSeconds, 600)
	downtimeSeconds = positiveInt(schedule.downtimeSeconds, 300)
	priority = {}
	if typeof(params.priority) == "table" then
		for _, key in params.priority do
			if typeof(key) == "string" and MutationConfig.ByKey[key] then
				table.insert(priority, key)
			end
		end
	end
	if #priority == 0 then
		priority = { "Rainbow", "Gold" }
	end
	events = {}
	if typeof(params.events) ~= "table" then
		return
	end
	for _, raw in params.events do
		if typeof(raw) == "table" and typeof(raw.id) == "string" and typeof(raw.title) == "string" then
			local boosts: { Boost } = {}
			if typeof(raw.boosts) == "table" then
				for _, boost in raw.boosts do
					if
						typeof(boost) == "table"
						and typeof(boost.mutation) == "string"
						and MutationConfig.ByKey[boost.mutation]
					then
						table.insert(boosts, { mutation = boost.mutation, oneIn = positiveInt(boost.oneIn, 10) })
					end
				end
			end
			local rarity = if typeof(raw.announceRarity) == "string" and RarityConfig.ByKey[raw.announceRarity]
				then raw.announceRarity
				else "Rare"
			table.insert(events, {
				id = raw.id,
				title = raw.title,
				blurb = if typeof(raw.blurb) == "string" then raw.blurb else "",
				announceRarity = rarity,
				color = colorOf(raw.color, Color3.fromRGB(255, 220, 80)),
				boosts = boosts,
			})
		end
	end
end

-- Current event (nil during the quiet gap), when it ends, the following event, and when
-- that one starts. The follow-on start includes the quiet gap.
local function phase(now: number): (EventDef?, number, EventDef?, number)
	if #events == 0 then
		return nil, 0, nil, 0
	end
	local cycle = activeSeconds + downtimeSeconds
	local index = math.floor(now / cycle) % #events
	local into = now % cycle
	local cycleStart = now - into
	local upcoming = events[((index + 1) % #events) + 1]
	local nextStart = cycleStart + cycle
	if into < activeSeconds then
		return events[index + 1], cycleStart + activeSeconds, upcoming, nextStart
	end
	return nil, 0, upcoming, nextStart
end

local function publish(event: EventDef?, endsAt: number, upcoming: EventDef?, nextStart: number)
	local folder = Common.stateFolder()
	folder:SetAttribute("VariantEventTitle", if event then event.title else "")
	folder:SetAttribute("VariantEventBlurb", if event then event.blurb else "")
	folder:SetAttribute("VariantEventEndsAt", Common.synced(endsAt))
	folder:SetAttribute("VariantEventColor", if event then event.color else Color3.new(1, 1, 1))
	folder:SetAttribute("VariantEventNextTitle", if upcoming then upcoming.title else "")
	folder:SetAttribute("VariantEventNextAt", Common.synced(nextStart))
end

local function evaluate()
	local event, endsAt, upcoming, nextStart = phase(Common.now())
	local id = if event then event.id else ""
	-- Keep the countdown attributes on the synced clock even while the same event is up.
	if id == activeId and endsAt == activeEnds then
		local folder = Common.stateFolder()
		if event then
			folder:SetAttribute("VariantEventEndsAt", Common.synced(endsAt))
		end
		folder:SetAttribute("VariantEventNextAt", Common.synced(nextStart))
		return
	end
	local previous = activeEvent
	activeId = id
	activeEnds = endsAt
	activeEvent = event
	publish(event, endsAt, upcoming, nextStart)
	if event then
		Common.announce(`{event.title}! {event.blurb}`, event.announceRarity)
	elseif previous then
		Common.announce(`{previous.title} is over.`, previous.announceRarity)
	end
end

local function baseEntry(mutation: string): { [string]: any }?
	local mutations = MutationPayout.params.mutations
	local entry = if typeof(mutations) == "table" then mutations[mutation] else nil
	return if typeof(entry) == "table" then entry else nil
end

local function eventOneIn(mutation: string): number?
	local event = activeEvent
	if not event then
		return nil
	end
	local best: number? = nil
	for _, boost in event.boosts do
		if boost.mutation == mutation and (best == nil or boost.oneIn < best) then
			best = boost.oneIn
		end
	end
	return best
end

-- 1-in-N after Mud Storm / Lucky Soap have had a say about the everyday rate.
-- An event boost is a flat rate from the JSON, not stacked on top of that.
local function chance(player: Player, mutation: string): number?
	local entry = baseEntry(mutation)
	local base = if entry then entry.oneIn else nil
	if typeof(base) == "number" and base >= 1 then
		local adjusted = Hooks.apply("VariantOneIn", base, player, mutation)
		if typeof(adjusted) == "number" and adjusted >= 1 and adjusted == adjusted then
			base = adjusted
		end
	else
		base = nil
	end
	local boosted = eventOneIn(mutation)
	if boosted and (base == nil or boosted < base) then
		return boosted
	end
	return base
end

local function hits(player: Player, mutation: string, arrival: number): boolean
	local entry = baseEntry(mutation)
	local every = if entry then entry.guaranteedEvery else nil
	if typeof(every) == "number" and every >= 1 and arrival % math.floor(every) == 0 then
		return true
	end
	local oneIn = chance(player, mutation)
	if not oneIn or oneIn < 1 then
		return false
	end
	return rng:NextInteger(1, math.max(1, math.floor(oneIn))) == 1
end

local function listed(mutation: string): boolean
	for _, key in priority do
		if key == mutation then
			return true
		end
	end
	return baseEntry(mutation) ~= nil
end

function VariantEvents.init()
	load()
	Hooks.modify("MutationPick", function(current: any, player: Player, isFirst: boolean): any
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return current
		end
		local state = Common.state(player)
		local data = PlayerDataService.get(player)
		if not state or not data then
			return current
		end
		state.WashesRolled = (state.WashesRolled or 0) + 1
		PlayerDataService.markDirty(player)
		local arrival = state.WashesRolled
		-- The very first animal stays Normal so the opening wash is predictable.
		if isFirst and data.LifetimeAnimalsWashed == 0 and arrival == 1 then
			return MutationConfig.Default
		end
		for _, mutation in priority do
			if hits(player, mutation, arrival) then
				return mutation
			end
		end
		local event = activeEvent
		if event then
			for _, boost in event.boosts do
				if not listed(boost.mutation) and hits(player, boost.mutation, arrival) then
					return boost.mutation
				end
			end
		end
		return if typeof(current) == "string" then current else MutationConfig.Default
	end)

	local folder = Common.stateFolder()
	folder:SetAttribute("VariantEventTitle", "")
	folder:SetAttribute("VariantEventBlurb", "")
	folder:SetAttribute("VariantEventEndsAt", 0)
	folder:SetAttribute("VariantEventColor", Color3.new(1, 1, 1))
	folder:SetAttribute("VariantEventNextTitle", "")
	folder:SetAttribute("VariantEventNextAt", 0)
	evaluate()
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(evaluate)
			if not ok then
				warn(`[LiveOps] Variant event check failed: {err}`)
			end
		end
	end)
end

return VariantEvents
