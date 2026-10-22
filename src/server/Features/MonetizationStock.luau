-- Global stock for limited products, shared by every server through one DataStore record per
-- product: { Sold = number, Claims = { [PurchaseId] = true } }. Claims make a claim idempotent,
-- so a receipt that is retried (player left mid-grant, server crashed) never takes a second
-- unit. Stock is never restocked. Part of the Monetization feature (no init of its own).

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage.Shared.FeatureConfig.MonetizationConfig)

export type ClaimResult = "Claimed" | "SoldOut" | "Error"

type Record = { Sold: number, Claims: { [string]: boolean } }

local MonetizationStock = {}

local store: DataStore? = nil
local remaining: { [string]: number } = {} -- last known stock per product key
local studioFallback: { [string]: Record } = {} -- Studio without DataStore access
local testClaims: { [string]: Record } = {} -- simulated purchases on a live server
local lastRefresh: { [string]: number } = {}
local listeners: { (key: string, left: number) -> () } = {}

local function getStore(): DataStore?
	if store then
		return store
	end
	local name = if RunService:IsStudio()
		then MonetizationConfig.StudioStockStoreName
		else MonetizationConfig.StockStoreName
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if ok then
		store = result
		return result
	end
	return nil
end

local function totalStock(key: string): number
	local product = MonetizationConfig.ProductsByKey[key]
	return if product and product.Stock then product.Stock else 0
end

local function sanitize(raw: any): Record
	local record: Record = { Sold = 0, Claims = {} }
	if typeof(raw) ~= "table" then
		return record
	end
	if typeof(raw.Sold) == "number" and raw.Sold == raw.Sold and raw.Sold >= 0 and raw.Sold < math.huge then
		record.Sold = math.floor(raw.Sold)
	end
	if typeof(raw.Claims) == "table" then
		for purchaseId, claimed in raw.Claims do
			if typeof(purchaseId) == "string" and claimed == true then
				record.Claims[purchaseId] = true
			end
		end
	end
	return record
end

local function setRemaining(key: string, left: number)
	left = math.max(0, left)
	if remaining[key] == left then
		return
	end
	remaining[key] = left
	for _, fn in listeners do
		task.spawn(fn, key, left)
	end
end

-- Last known stock, or nil if it hasn't been read yet. Doesn't yield.
function MonetizationStock.remaining(key: string): number?
	return remaining[key]
end

function MonetizationStock.onChanged(fn: (key: string, left: number) -> ())
	table.insert(listeners, fn)
end

-- Yields. Reads the live stock; returns nil if the DataStore can't be reached. With
-- minInterval, a read that happened less than that many seconds ago is reused instead, so
-- player requests can't drain the server's GetAsync budget.
function MonetizationStock.refresh(key: string, minInterval: number?): number?
	local now = os.clock()
	local last = lastRefresh[key]
	if minInterval and last and now - last < minInterval then
		return remaining[key]
	end
	lastRefresh[key] = now
	local ds = getStore()
	if ds then
		local ok, raw = pcall(function()
			return ds:GetAsync(key)
		end)
		if ok then
			setRemaining(key, totalStock(key) - sanitize(raw).Sold)
			return remaining[key]
		end
	end
	if RunService:IsStudio() then
		local record = studioFallback[key] or { Sold = 0, Claims = {} }
		setRemaining(key, totalStock(key) - record.Sold)
		return remaining[key]
	end
	return nil
end

-- Yields. Takes one unit for this purchase. A purchase that already holds a unit counts as
-- Claimed again. "Error" means try again later (the receipt stays unprocessed).
function MonetizationStock.claim(key: string, purchaseId: string): ClaimResult
	local total = totalStock(key)
	local ds = getStore()
	if ds then
		local result: ClaimResult = "Error"
		local sold = 0
		local ok, err = pcall(function()
			ds:UpdateAsync(key, function(raw)
				local record = sanitize(raw)
				sold = record.Sold
				if record.Claims[purchaseId] then
					result = "Claimed"
					return nil -- already ours; nothing to write
				end
				if record.Sold >= total then
					result = "SoldOut"
					return nil
				end
				record.Sold += 1
				record.Claims[purchaseId] = true
				sold = record.Sold
				result = "Claimed"
				return record
			end)
		end)
		if ok then
			setRemaining(key, total - sold)
			return result
		end
		warn(`[Monetization] Stock claim for {key} failed: {err}`)
	end
	if RunService:IsStudio() then
		local record = studioFallback[key] or { Sold = 0, Claims = {} }
		studioFallback[key] = record
		if record.Claims[purchaseId] then
			return "Claimed"
		end
		if record.Sold >= total then
			return "SoldOut"
		end
		record.Sold += 1
		record.Claims[purchaseId] = true
		setRemaining(key, total - record.Sold)
		return "Claimed"
	end
	return "Error"
end

-- A simulated purchase on a live server (the place owner testing an id-0 item) takes a unit
-- from a per-server test counter, never from the real global stock. Doesn't yield.
function MonetizationStock.claimTest(key: string, purchaseId: string): ClaimResult
	local record = testClaims[key] or { Sold = 0, Claims = {} }
	testClaims[key] = record
	if record.Claims[purchaseId] then
		return "Claimed"
	end
	if record.Sold >= totalStock(key) then
		return "SoldOut"
	end
	record.Sold += 1
	record.Claims[purchaseId] = true
	return "Claimed"
end

return MonetizationStock
