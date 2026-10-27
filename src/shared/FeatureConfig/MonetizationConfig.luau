-- Monetization tuning: developer products, game passes, boost strengths and the guardrails
-- that keep paid items from skipping the game (concept doc: nothing pay-to-win, no shop
-- prompt in the first 90 seconds, mostly repeatable consumables plus limiteds and whale items).
--
-- Permanent skips are gone: no Forever auto-collect, no Fire-Hose game pass, no forever
-- speed. Speed and Incredible Luck are consumables with absolute expiry timestamps.
-- The one permanent boost is 2x Cash Forever, priced as an impulse buy (3 Robux).
--
-- Ids live in MonetizationIds (0 until the product exists). Robux prices here are for display only: Roblox charges whatever
-- the product is set to on the website, so keep the two in sync when the real ids go in.
-- In Studio, or while an id is 0, buying simulates a successful purchase through the real
-- grant path (live servers only simulate for the place owner, see SimulateUnconfiguredLive).

export type Product = {
	Key: string,
	Id: number,
	Robux: number,
	DisplayName: string,
	Description: string,
	Tab: string,
	Order: number,
	Kind: string, -- "CalmTreat" | "Cash" | "Limited" | "AutoCollect" | "CleanNow" | "Truck" | "SpeedBoost" | "OfflineDouble" | "HoseTier"
	ToolTier: number?, -- HoseTier: the single next hose this product grants. Never a skip.
	Hidden: boolean?, -- offered in the moment (not a shop card)
	CleanSteps: number?, -- Clean Now: rarity steps above the cheapest animal this hose cannot wash
	Seconds: number?, -- AutoCollect: play-time added per purchase
	Color: Color3,
	OncePerPlayer: boolean?, -- can only be bought once (an intro price)
	IntroKey: string?, -- the shop shows this cheaper once-only product instead, until it's used
	-- Cash packs: max(Floor, total income per second * 60 * Minutes), capped at CapFraction
	-- of the next hose price so one pack can never skip a whole tool tier.
	Minutes: number?,
	Floor: number?,
	CapFraction: number?,
	-- Limited animals: a global stock shared by every server, never restocked.
	Species: string?,
	Mutation: string?,
	Stock: number?,
}

export type Pass = {
	Key: string,
	Id: number,
	Robux: number,
	DisplayName: string,
	Description: string,
	Order: number,
	Color: Color3,
}

-- What the server tells a client about its shop (MonetizationState remote).
export type ShopState = {
	SoapEndsAt: number, -- Workspace:GetServerTimeNow() when Super Soap runs out; 0 when inactive
	AutoCollectEndsAt: number, -- same clock; 0 when the timed auto-collect is off
	SpeedEndsAt: number, -- same clock; 0 when the 2x speed buff is off
	Passes: { [string]: boolean }, -- owned game passes
	Once: { [string]: boolean }, -- once-only products already bought
	Stock: { [string]: number }, -- remaining stock per limited (missing while unknown)
	Cash: { [string]: number }, -- what each cash pack gives this player right now
	Unavailable: { [string]: boolean }, -- products that can't be sold (e.g. animal not in the game)
	TestMode: boolean, -- purchases are simulated for this player
	PendingAnimals: number, -- bought animals waiting for a free cache slot
}

local ToolConfig = require(script.Parent.Parent.ToolConfig)
local Ids = require(script.Parent.MonetizationIds)

local PINK = Color3.fromRGB(255, 90, 200)
local BLUE = Color3.fromRGB(80, 190, 255)
local GREEN = Color3.fromRGB(90, 220, 110)
local GOLD = Color3.fromRGB(255, 200, 40)
local PURPLE = Color3.fromRGB(170, 90, 255)
local RED = Color3.fromRGB(255, 80, 80)
local ORANGE = Color3.fromRGB(255, 140, 40)

local products: { Product } = {
	-- Boosts
	{
		Key = "CalmTreat",
		Id = 0,
		Robux = 15,
		DisplayName = "Calm Treat",
		Description = "Freeze patience for 60s.",
		Tab = "Boosts",
		Order = 3,
		Kind = "CalmTreat",
		Color = GREEN,
	},
	{
		Key = "AutoCollect2h",
		Id = 0,
		Robux = 49,
		DisplayName = "Auto-Collect",
		Description = "Pens pay you for 30 min. Stacks.",
		Tab = "Boosts",
		Order = 5,
		Kind = "AutoCollect",
		Color = GREEN,
		Seconds = 30 * 60,
	},
	{
		Key = "SpeedBoost",
		Id = 0,
		Robux = 16,
		DisplayName = "2x Speed",
		Description = "Run 2x faster for 10 min. Stacks.",
		Tab = "Boosts",
		Order = 6,
		Kind = "SpeedBoost",
		Color = ORANGE,
	},
	-- Cash
	{
		Key = "CashSmall",
		Id = 0,
		Robux = 7, -- the cheapest buy in the game; one minute keeps bigger packs the better value
		DisplayName = "Pile of Cash",
		Description = "1 min of farm income.",
		Tab = "Cash",
		Order = 1,
		Kind = "Cash",
		Color = GREEN,
		Minutes = 1,
		Floor = 30,
		CapFraction = 0.03,
	},
	{
		Key = "CashMedium",
		Id = 0,
		Robux = 75,
		DisplayName = "Bag of Cash",
		Description = "20 min of farm income.",
		Tab = "Cash",
		Order = 2,
		Kind = "Cash",
		Color = GREEN,
		Minutes = 20,
		Floor = 250,
		CapFraction = 0.35,
	},
	{
		Key = "CashLarge",
		Id = 0,
		Robux = 149,
		DisplayName = "Vault of Cash",
		Description = "60 min of farm income.",
		Tab = "Cash",
		Order = 3,
		Kind = "Cash",
		Color = GREEN,
		Minutes = 60,
		Floor = 500,
		CapFraction = 0.75,
	},
	-- Offered on an animal the hose can't wash. Not a shop card.
	{
		Key = "CleanNow",
		Id = 0,
		Robux = 39,
		DisplayName = "Clean Now",
		Description = "Wash a too-dirty animal now.",
		Tab = "Boosts",
		Order = 99,
		Kind = "CleanNow",
		Color = GOLD,
		Hidden = true,
		CleanSteps = 0, -- the next rarity this hose cannot wash
	},
	{
		Key = "TruckAnimal",
		Id = 0,
		Robux = 199,
		DisplayName = "Delivery Truck Animal",
		Description = "The animal on your truck.",
		Tab = "Boosts",
		Order = 98,
		Kind = "Truck",
		Color = GOLD,
		Hidden = true, -- sold from the truck's prompt (DeliveryTruck feature), not a shop card
	},
	{
		Key = "LimitedAxolotl",
		Id = 0,
		Robux = 1000,
		DisplayName = "Axolotl",
		Description = "Limited Mythic. Only 1,000 ever.",
		Tab = "Limited",
		Order = 1,
		Kind = "Limited",
		Color = RED,
		Species = "Axolotl",
		Mutation = "Normal",
		Stock = 1000,
		OncePerPlayer = true,
	},
	-- Welcome-back only. Doubles the offline payout that is already on the pads.
	{
		Key = "OfflineDouble",
		Id = 0,
		Robux = 25,
		DisplayName = "2x Offline",
		Description = "Double your away earnings.",
		Tab = "Boosts",
		Order = 97,
		Kind = "OfflineDouble",
		Color = GREEN,
		Hidden = true,
	},
}

-- Forever auto-collect, the Fire-Hose skip, and forever speed were removed so a purchase
-- cannot jump the hose ladder. 2x Cash doubles income and wash pay, never clean power.
local passes: { Pass } = {
	{
		Key = "DoubleCash",
		Id = 0,
		Robux = 3,
		DisplayName = "2x Cash Forever",
		Description = "Double all cash you earn. Forever!",
		Order = 1,
		Color = GREEN,
	},
	{
		Key = "VIPKeeper",
		Id = 0,
		Robux = 399,
		DisplayName = "VIP Keeper",
		Description = "+25% income forever and a VIP title.",
		Order = 2,
		Color = GOLD,
	},
}

-- One hidden product per step above the cheapest unwashable rarity. Roblox charges a
-- fixed catalog price, so each step is its own developer product. Ids stay 0 until published.
-- Epic through Secret is at most 4 steps above the next animal a hose cannot wash.
local CLEAN_NOW_ROBUX = { 79, 149, 249, 399 } -- steps 1..4; step 0 is the CleanNow product above
for steps, robux in CLEAN_NOW_ROBUX do
	table.insert(products, {
		Key = `CleanNow{steps}`,
		Id = 0,
		Robux = robux,
		DisplayName = "Clean Now",
		Description = "Wash a too-dirty animal now.",
		Tab = "Boosts",
		Order = 99,
		Kind = "CleanNow",
		Color = GOLD,
		Hidden = true,
		CleanSteps = steps,
	})
end

-- One hidden product per hose the player can buy next, except the Fire-Hose Rig.
-- Each receipt grants exactly that tier, and only when it is the next one, so Robux
-- cannot skip the ladder. The Fire-Hose Rig stays a $1,000,000 cash upgrade.
local HOSE_ROBUX: { [number]: number } = {
	[2] = 19,
	[3] = 29,
	[4] = 99,
	[5] = 249, -- above Vault of Cash (149, at most 75% of a hose), so the packs still pay
}
for tier, robux in HOSE_ROBUX do
	local tool = ToolConfig[tier]
	table.insert(products, {
		Key = `HoseTier{tier}`,
		Id = 0,
		Robux = robux,
		DisplayName = tool.Name,
		Description = "Your next hose.",
		Tab = "Boosts",
		Order = 90 + tier,
		Kind = "HoseTier",
		Color = BLUE,
		Hidden = true,
		ToolTier = tier,
	})
end

local productsByKey: { [string]: Product } = {}
for _, product in products do
	local id = Ids.Products[product.Key]
	if typeof(id) == "number" and id > 0 then
		product.Id = id
	end
	productsByKey[product.Key] = product
end

local function productForHoseTier(tier: number): Product?
	for _, product in products do
		if product.Kind == "HoseTier" and product.ToolTier == tier then
			return product
		end
	end
	return nil
end

local function productForCleanSteps(steps: number): Product?
	for _, product in products do
		if product.Kind == "CleanNow" and (product.CleanSteps or 0) == steps then
			return product
		end
	end
	return nil
end

local passesByKey: { [string]: Pass } = {}
for _, pass in passes do
	local id = Ids.Passes[pass.Key]
	if typeof(id) == "number" and id > 0 then
		pass.Id = id
	end
	passesByKey[pass.Key] = pass
end

return {
	Products = products,
	ProductsByKey = productsByKey,
	productForCleanSteps = productForCleanSteps,
	productForHoseTier = productForHoseTier,
	Passes = passes,
	PassesByKey = passesByKey,
	Tabs = { "Boosts", "Cash", "Passes", "Limited" },
	ShopColor = PINK,
	-- One-tap buttons down the right side of the screen (MonetizationQuickBuy), top first.
	-- Two at most, so the column fits above WASH on a phone; everything else is in the shop.
	-- A pass hides once owned and the next key in QuickBuyBackup takes its place.
	QuickBuy = { "DoubleCash", "SpeedBoost" },
	QuickBuyBackup = { "CashSmall" },

	SuperSoap = {
		PowerMultiplier = 2, -- applied through Hooks "CleaningPower"
		Seconds = 600, -- per purchase; purchases stack
		MaxSeconds = 4 * 3600, -- stacking cap
	},
	CalmTreatSeconds = 60, -- sent with Hooks "CalmTreat"; the Tension feature freezes patience
	DoubleCash = {
		Multiplier = 2, -- pen income and wash pay, through Hooks "IncomeMultiplier" and "WashReward"
	},
	VIP = {
		IncomeMultiplier = 1.25, -- applied through Hooks "IncomeMultiplier"
		TagText = "VIP",
	},
	Speed = {
		Multiplier = 2, -- WalkSpeed while the consumable is active
		Seconds = 600, -- per purchase; purchases stack
		MaxSeconds = 4 * 3600,
	},
	AutoCollect = {
		MaxSeconds = 2 * 3600, -- stacked 30-minute purchases stop here
	},
	-- Sold out between the stock check and the receipt: cash instead (the Robux can't be refunded).
	-- max(Floor, min(120 min of income, the full next hose)): never less than Floor at any tier.
	SoldOutCompensation = { Minutes = 120, Floor = 5000, CapFraction = 1 },

	Offers = {
		-- The side pop-up (Calm Treat before a mud shake) is off.
		-- The products stay in the shop and on the "too dirty" prompt.
		Enabled = false,
		QuietSeconds = 90, -- no offer this early in a session
		CooldownSeconds = 240, -- per offer kind
		MaxPerSession = 6,
		AutoHideSeconds = 12,
	},

	ReceiptsKept = 100, -- PurchaseIds remembered per player so a receipt is never granted twice
	PendingDeliverySeconds = 3, -- how often queued animals retry for a free cache slot
	StockStoreName = "LimitedStock_v1",
	StudioStockStoreName = "LimitedStock_Studio_v1",
	StockRefreshSeconds = 30,
	StockRecheckSeconds = 10, -- a shop request re-reads an unknown stock at most this often
	BuyCooldown = 0.75, -- seconds between shop requests per player
	StateCooldown = 1,
	-- Live servers simulate unconfigured (id 0) purchases for the place owner only. Turning this
	-- on gives every player free items, so never ship with it on.
	SimulateUnconfiguredLive = false,
}
