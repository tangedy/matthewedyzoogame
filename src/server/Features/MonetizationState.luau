-- Monetization's saved data (data.Extra.Monetization), per-session state, and what the client
-- is told about its shop. Saved data is validated the first time it's read each session.
-- Part of the Monetization feature (no init of its own).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)
local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local Services = script.Parent.Parent.Services
local PlayerDataService = require(Services.PlayerDataService)
local ZooService = require(Services.ZooService)
local MonetizationStock = require(script.Parent.MonetizationStock)

export type PendingAnimal = { Species: string, Mutation: string }

export type Saved = {
	Receipts: { string }, -- most recent PurchaseIds, oldest first
	SuperSoapLeft: number, -- seconds; only counts down while the player is online
	AutoCollectLeft: number, -- seconds; only counts down while the player is online
	LuckyLeft: number, -- walk-ins
	-- Absolute os.time() expiries. 0 means the buff is off. They keep counting while offline.
	SpeedEndsAt: number, -- 2x walk speed
	LuckEndsAt: number, -- Incredible Luck (rare-animal drop weights)
	Passes: { [string]: boolean }, -- passes granted by this server (purchase, or a Studio simulation)
	Once: { [string]: boolean }, -- once-only products bought
	PendingAnimals: { PendingAnimal }, -- bought animals waiting for a cache slot
	PastureUnlocked: boolean, -- any Robux spend; both medium road cages stay open
	SidePastureUnlocked: boolean, -- the Axolotl; the first large road cage stays open
	CashPastureUnlocked: boolean, -- the old single cash cage (the right large); still honoured
	CashCages: { [string]: boolean }, -- road cages bought with cash, keyed by RoadCages index
}

export type Session = {
	JoinedAt: number, -- os.clock()
	SoapEndsAt: number, -- Workspace:GetServerTimeNow(); 0 when inactive
	AutoCollectEndsAt: number, -- same clock; 0 when the timed auto-collect is off
	LuckyRolled: boolean, -- a walk-in was rolled while Lucky Soap was active
	PendingOnce: { [string]: boolean }, -- once-only products with a prompt open or a receipt due
	PendingOffline: boolean, -- a 2x offline prompt is open or its receipt is still due
	OwnedPasses: { [string]: boolean }, -- UserOwnsGamePassAsync results and grants
	LastRequest: { [string]: number },
	LastOffer: { [string]: number },
	OffersShown: number,
	Connections: { RBXScriptConnection },
}

local MonetizationState = {}

-- Weak keys as a backstop; release() clears both when the player leaves.
local savedCache: { [Player]: Saved } = setmetatable({}, { __mode = "k" }) :: any
local sessions: { [Player]: Session } = setmetatable({}, { __mode = "k" }) :: any

local stateRemote = Remotes.event("MonetizationState")
local noticeRemote = Remotes.event("MonetizationNotice")

local function count(value: any, max: number): number
	if typeof(value) ~= "number" or value ~= value or value <= 0 then
		return 0
	end
	return math.min(value, max)
end

-- A stored expiry. Expired or nonsense values become 0. Future values are capped so a
-- corrupt save cannot keep a buff up longer than its stacking limit.
local function unixEnd(value: any, maxAhead: number): number
	if typeof(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		return 0
	end
	local now = os.time()
	if value <= now then
		return 0
	end
	return math.min(value, now + maxAhead)
end

local function flags(value: any, valid: { [string]: any }): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if typeof(value) == "table" then
		for key, on in value do
			if typeof(key) == "string" and on == true and valid[key] then
				out[key] = true
			end
		end
	end
	return out
end

local function sanitize(raw: any): Saved
	local saved: Saved = {
		Receipts = {},
		SuperSoapLeft = 0,
		AutoCollectLeft = 0,
		LuckyLeft = 0,
		SpeedEndsAt = 0,
		LuckEndsAt = 0,
		Passes = {},
		Once = {},
		PendingAnimals = {},
		PastureUnlocked = false,
		SidePastureUnlocked = false,
		CashPastureUnlocked = false,
		CashCages = {},
	}
	if typeof(raw) ~= "table" then
		return saved
	end
	if typeof(raw.Receipts) == "table" then
		for _, id in raw.Receipts do
			if typeof(id) == "string" and #id <= 100 then
				table.insert(saved.Receipts, id)
			end
		end
		while #saved.Receipts > MonetizationConfig.ReceiptsKept do
			table.remove(saved.Receipts, 1)
		end
	end
	saved.SuperSoapLeft = count(raw.SuperSoapLeft, MonetizationConfig.SuperSoap.MaxSeconds)
	saved.AutoCollectLeft = count(raw.AutoCollectLeft, MonetizationConfig.AutoCollect.MaxSeconds)
	saved.LuckyLeft = math.floor(count(raw.LuckyLeft, MonetizationConfig.LuckySoap.MaxWalkIns))
	saved.SpeedEndsAt = unixEnd(raw.SpeedEndsAt, MonetizationConfig.Speed.MaxSeconds)
	saved.LuckEndsAt = unixEnd(raw.LuckEndsAt, MonetizationConfig.IncredibleLuck.MaxSeconds)
	saved.Passes = flags(raw.Passes, MonetizationConfig.PassesByKey)
	saved.Once = flags(raw.Once, MonetizationConfig.ProductsByKey)
	if typeof(raw.PendingAnimals) == "table" then
		for _, entry in raw.PendingAnimals do
			-- Species is kept even if it's missing from AnimalConfig right now: it was paid for,
			-- and delivery waits until the species exists again.
			if
				typeof(entry) == "table"
				and typeof(entry.Species) == "string"
				and typeof(entry.Mutation) == "string"
				and MutationConfig.ByKey[entry.Mutation]
			then
				table.insert(saved.PendingAnimals, { Species = entry.Species, Mutation = entry.Mutation })
			end
		end
	end
	local function anyFlag(map: { [string]: boolean }): boolean
		for _ in map do
			return true
		end
		return false
	end
	-- Any earlier Robux spend counts: a receipt, a pass, a once-only product, a queued
	-- animal, or boost time still on the clock. The flag then sticks even after those expire.
	saved.PastureUnlocked = raw.PastureUnlocked == true
		or #saved.Receipts > 0
		or #saved.PendingAnimals > 0
		or anyFlag(saved.Passes)
		or anyFlag(saved.Once)
		or saved.SuperSoapLeft > 0
		or saved.AutoCollectLeft > 0
		or saved.LuckyLeft > 0
		or saved.SpeedEndsAt > 0
		or saved.LuckEndsAt > 0
	local pendingAxolotl = false
	for _, entry in saved.PendingAnimals do
		if entry.Species == "Axolotl" then
			pendingAxolotl = true
			break
		end
	end
	saved.SidePastureUnlocked = raw.SidePastureUnlocked == true or saved.Once.SidePasture == true or pendingAxolotl
	saved.CashPastureUnlocked = raw.CashPastureUnlocked == true
	if typeof(raw.CashCages) == "table" then
		for key, bought in raw.CashCages do
			local index = tonumber(key)
			if bought == true and index and GameConfig.Zoo.RoadCages[index] then
				saved.CashCages[tostring(index)] = true
			end
		end
	end
	return saved
end

local function profileHasAxolotl(data: PlayerDataService.SavedData): boolean
	for _, animal in data.Animals do
		if animal.Species == "Axolotl" then
			return true
		end
	end
	for _, animal in data.Cache do
		if animal.Species == "Axolotl" then
			return true
		end
	end
	for key, discovered in data.Index do
		if discovered == true and string.match(key, "^Axolotl:") then
			return true
		end
	end
	return false
end

-- The player's validated monetization data, or nil while their profile isn't loaded.
function MonetizationState.saved(player: Player): Saved?
	local data = PlayerDataService.get(player)
	if not data then
		return nil
	end
	local cached = savedCache[player]
	if cached and data.Extra.Monetization == cached then
		return cached
	end
	local raw = data.Extra.Monetization
	local already = typeof(raw) == "table" and raw.PastureUnlocked == true
	local alreadySide = typeof(raw) == "table" and raw.SidePastureUnlocked == true
	local saved = sanitize(data.Extra.Monetization)
	-- The Axolotl is one per player; someone who bought it before that rule counts as bought.
	local alreadyAxolotl = saved.Once.LimitedAxolotl == true
	if profileHasAxolotl(data) then
		saved.SidePastureUnlocked = true
		saved.Once.LimitedAxolotl = true
	end
	for _, entry in saved.PendingAnimals do
		if entry.Species == "Axolotl" then
			saved.Once.LimitedAxolotl = true
		end
	end
	data.Extra.Monetization = saved
	savedCache[player] = saved
	if
		(saved.PastureUnlocked and not already)
		or (saved.SidePastureUnlocked and not alreadySide)
		or (saved.Once.LimitedAxolotl and not alreadyAxolotl)
	then
		PlayerDataService.markDirty(player)
	end
	return saved
end

-- The player's session, if it has started (it starts when they join).
function MonetizationState.peek(player: Player): Session?
	return sessions[player]
end

-- Starts (or returns) the player's session.
function MonetizationState.session(player: Player): Session
	local session = sessions[player]
	if not session then
		session = {
			JoinedAt = os.clock(),
			SoapEndsAt = 0,
			AutoCollectEndsAt = 0,
			LuckyRolled = false,
			PendingOnce = {},
			PendingOffline = false,
			OwnedPasses = {},
			LastRequest = {},
			LastOffer = {},
			OffersShown = 0,
			Connections = {},
		}
		sessions[player] = session
	end
	return session
end

function MonetizationState.release(player: Player)
	local session = sessions[player]
	if session then
		for _, connection in session.Connections do
			connection:Disconnect()
		end
	end
	sessions[player] = nil
	savedCache[player] = nil
end

-- Simple per-player, per-action rate limit. Returns true when the request may go ahead.
function MonetizationState.allow(player: Player, action: string, cooldown: number): boolean
	local session = sessions[player]
	if not session then
		return false
	end
	local now = os.clock()
	local last = session.LastRequest[action]
	if last and now - last < cooldown then
		return false
	end
	session.LastRequest[action] = now
	return true
end

function MonetizationState.isDeveloper(player: Player): boolean
	return RunService:IsStudio() or (game.CreatorId ~= 0 and player.UserId == game.CreatorId)
end

-- Studio always simulates; a live server only for unconfigured (id 0) items, and then only for
-- the place owner unless SimulateUnconfiguredLive is on. Real ids in a live game never simulate.
function MonetizationState.shouldSimulate(player: Player, id: number): boolean
	if RunService:IsStudio() then
		return true
	end
	if id ~= 0 then
		return false
	end
	return MonetizationConfig.SimulateUnconfiguredLive or (game.CreatorId ~= 0 and player.UserId == game.CreatorId)
end

function MonetizationState.ownsPass(player: Player, key: string): boolean
	local session = sessions[player]
	if session and session.OwnedPasses[key] then
		return true
	end
	local saved = MonetizationState.saved(player)
	return saved ~= nil and saved.Passes[key] == true
end

-- Both medium road cages stay open once any Robux has been spent.
-- Returns true only the first time, so the caller can announce it.
function MonetizationState.unlockPasture(player: Player): boolean
	local saved = MonetizationState.saved(player)
	if not saved or saved.PastureUnlocked then
		return false
	end
	saved.PastureUnlocked = true
	PlayerDataService.markDirty(player)
	ZooService.refresh(player)
	return true
end

-- The first large road cage. Buying the Axolotl, or an older right-pasture receipt.
function MonetizationState.unlockSidePasture(player: Player): boolean
	local saved = MonetizationState.saved(player)
	if not saved or saved.SidePastureUnlocked then
		return false
	end
	saved.SidePastureUnlocked = true
	PlayerDataService.markDirty(player)
	ZooService.refresh(player)
	return true
end

function MonetizationState.sidePastureOpen(player: Player): boolean
	local saved = MonetizationState.saved(player)
	return saved ~= nil and saved.SidePastureUnlocked == true
end

function MonetizationState.soapActive(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.SoapEndsAt > Workspace:GetServerTimeNow()
end

function MonetizationState.autoCollectActive(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.AutoCollectEndsAt > Workspace:GetServerTimeNow()
end

-- os.time() expiry converted into the synced server clock the client counts down with.
local function toServerClock(unixEnds: number): number
	local left = unixEnds - os.time()
	if left <= 0 then
		return 0
	end
	return Workspace:GetServerTimeNow() + left
end

-- Price of the hose the player would buy next (the top hose's price once fully upgraded).
local function nextHosePrice(player: Player): number
	local data = PlayerDataService.get(player)
	local tier = if data then data.ToolTier else 1
	local nextTool = ToolConfig[tier + 1] or ToolConfig[#ToolConfig]
	return nextTool.Price
end

-- Cash for a pack: N minutes of current income, at least the floor, never more than a fraction
-- of the next hose (so a pack can't skip a tool tier).
function MonetizationState.cashAmount(
	player: Player,
	spec: { Minutes: number?, Floor: number?, CapFraction: number? }
): number
	local minutes = spec.Minutes or 0
	local floor = spec.Floor or 0
	local cap = math.max(1, math.floor(nextHosePrice(player) * (spec.CapFraction or 0)))
	local fromIncome = math.floor(ZooService.totalIncome(player) * 60 * minutes)
	return math.max(1, math.min(math.max(floor, fromIncome), cap))
end

function MonetizationState.payload(player: Player): MonetizationConfig.ShopState
	local saved = MonetizationState.saved(player)
	local session = sessions[player]
	local state: MonetizationConfig.ShopState = {
		SoapEndsAt = if session and session.SoapEndsAt > Workspace:GetServerTimeNow() then session.SoapEndsAt else 0,
		AutoCollectEndsAt = if session and session.AutoCollectEndsAt > Workspace:GetServerTimeNow()
			then session.AutoCollectEndsAt
			else 0,
		SpeedEndsAt = if saved then toServerClock(saved.SpeedEndsAt) else 0,
		LuckEndsAt = if saved then toServerClock(saved.LuckEndsAt) else 0,
		LuckyLeft = if saved then saved.LuckyLeft else 0,
		Passes = {},
		Once = if saved then table.clone(saved.Once) else {},
		Stock = {},
		Cash = {},
		Unavailable = {},
		TestMode = MonetizationState.shouldSimulate(player, 0),
		PendingAnimals = if saved then #saved.PendingAnimals else 0,
	}
	for _, pass in MonetizationConfig.Passes do
		if MonetizationState.ownsPass(player, pass.Key) then
			state.Passes[pass.Key] = true
		end
	end
	for _, product in MonetizationConfig.Products do
		if product.Kind == "Cash" then
			state.Cash[product.Key] = MonetizationState.cashAmount(player, product)
		elseif product.Kind == "Limited" then
			local left = MonetizationStock.remaining(product.Key)
			if left then
				state.Stock[product.Key] = left
			end
			if not (product.Species and AnimalConfig.Animals[product.Species]) then
				state.Unavailable[product.Key] = true
			end
		end
	end
	return state
end

function MonetizationState.push(player: Player)
	if player.Parent then
		stateRemote:FireClient(player, MonetizationState.payload(player))
	end
end

function MonetizationState.notify(player: Player, text: string, ok: boolean)
	if player.Parent then
		noticeRemote:FireClient(player, text, ok)
	end
end

function MonetizationState.players(): { Player }
	local list = {}
	for player in sessions do
		if player.Parent == Players then
			table.insert(list, player)
		end
	end
	return list
end

return MonetizationState
