-- Monetization tuning: developer products, game passes, boost strengths and the guardrails
-- that keep paid items from skipping the game (concept doc: nothing pay-to-win, no shop
-- prompt in the first 90 seconds, mostly repeatable consumables plus limiteds and whale items).
--
-- Permanent skips are gone: no Forever auto-collect, no Fire-Hose game pass, no forever
-- speed. Speed and Incredible Luck are consumables with absolute expiry timestamps.
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
	Kind: string, -- "SuperSoap" | "CalmTreat" | "LuckySoap" | "Cash" | "Limited" | "AutoCollect" | "CleanNow" | "Truck" | "SidePasture" | "SpeedBoost" | "IncredibleLuck" | "OfflineDouble" | "HoseTier"
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
	LuckEndsAt: number, -- same clock; 0 when Incredible Luck is off
	LuckyLeft: number, -- walk-ins left on Lucky Soap
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
		Key = "SuperSoapStarter",
		Id = 0,
		Robux = 5,
		DisplayName = "Super Soap",
		Description = "2x clean power for 10 min.",
		Tab = "Boosts",
		Order = 1,
		Kind = "SuperSoap",
		Color = BLUE,
		OncePerPlayer = true,
	},
	{
		Key = "SuperSoap",
		Id = 0,
		Robux = 9,
		DisplayName = "Super Soap",
		Description = "2x clean power for 10 min. Stacks.",
		Tab = "Boosts",
		Order = 1,
		Kind = "SuperSoap",
		Color = BLUE,
		IntroKey = "SuperSoapStarter",
	},
	{
		Key = "CalmTreat",
		Id = 0,
		Robux = 15,
		DisplayName = "Calm Treat",
		Description = "Freeze patience for 60s.",
		Tab = "Boosts",
		Order = 2,
		Kind = "CalmTreat",
		Color = GREEN,
	},
	{
		Key = "LuckySoap",
		Id = 0,
		Robux = 49,
		DisplayName = "Lucky Soap",
		Description = "Next 5 walk-ins: rarer, more mutations.",
		Tab = "Boosts",
		Order = 3,
		Kind = "LuckySoap",
		Color = GOLD,
	},
	{
		Key = "AutoCollect2h",
		Id = 0,
		Robux = 49,
		DisplayName = "Auto-Collect",
		Description = "Pens pay you for 10 min. Stacks.",
		Tab = "Boosts",
		Order = 4,
		Kind = "AutoCollect",
		Color = GREEN,
		Seconds = 10 * 60,
	},
	{
		Key = "SpeedBoost",
		Id = 0,
		Robux = 39,
		DisplayName = "2x Speed",
		Description = "Run 2x faster for 10 min. Stacks.",
		Tab = "Boosts",
		Order = 5,
		Kind = "SpeedBoost",
		Color = ORANGE,
	},
	{
		Key = "IncredibleLuck",
		Id = 0,
		Robux = 49,
		DisplayName = "Incredible Luck",
		Description = "Rare+ walk-ins far likelier for 10 min.",
		Tab = "Boosts",
		Order = 6,
		Kind = "IncredibleLuck",
		Color = PURPLE,
	},
	-- Cash
	{
		Key = "CashSmall",
		Id = 0,
		Robux = 25,
		DisplayName = "Pile of Cash",
		Description = "5 min of farm income.",
		Tab = "Cash",
		Order = 1,
		Kind = "Cash",
		Color = GREEN,
		Minutes = 5,
		Floor = 100,
		CapFraction = 0.15,
	},
	{
		Key = "CashMedium",
		Id = 0,
		Robux = 75,
		DisplayName = "Bag of Cash",
		Description = "15 min of farm income.",
		Tab = "Cash",
		Order = 2,
		Kind = "Cash",
		Color = GREEN,
		Minutes = 15,
		Floor = 250,
		CapFraction = 0.3,
	},
	{
		Key = "CashLarge",
		Id = 0,
		Robux = 199,
		DisplayName = "Vault of Cash",
		Description = "45 min of farm income.",
		Tab = "Cash",
		Order = 3,
		Kind = "Cash",
		Color = GREEN,
		Minutes = 45,
		Floor = 500,
		CapFraction = 0.5,
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
		Robux = 200,
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
	-- Kept so a receipt for the old right pasture is still honoured: it opens the road cages.
	-- Nothing in the world prompts this any more.
	{
		Key = "SidePasture",
		Id = 0,
		Robux = 99,
		DisplayName = "Large Cage",
		Description = "Opens the road cages.",
		Tab = "Boosts",
		Order = 50,
		Kind = "SidePasture",
		Color = GOLD,
		Hidden = true,
		OncePerPlayer = true,
	},
	-- Welcome-back only. Doubles the offline payout that is already on the pads.
	{
		Key = "OfflineDouble",
		Id = 0,
		Robux = 19,
		DisplayName = "2x Offline",
		Description = "Double your away earnings.",
		Tab = "Boosts",
		Order = 97,
		Kind = "OfflineDouble",
		Color = GREEN,
		Hidden = true,
	},
}

-- VIP is the only game pass. Forever auto-collect, the Fire-Hose skip, and forever speed
-- were removed so a purchase cannot jump the hose ladder.
local passes: { Pass } = {
	{
		Key = "VIPKeeper",
		Id = 0,
		Robux = 399,
		DisplayName = "VIP Keeper",
		Description = "+25% income forever and a VIP title.",
		Order = 1,
		Color = GOLD,
	},
}

-- One hidden product per step above the cheapest unwashable rarity. Roblox charges a
-- fixed catalog price, so each step is its own developer product. Ids stay 0 until published.
-- Epic through Secret is at most 4 steps above the next animal a hose cannot wash.
local cleanNowBase = 39
for _, product in products do
	if product.Key == "CleanNow" then
		cleanNowBase = product.Robux
		break
	end
end
for steps = 1, 4 do
	table.insert(products, {
		Key = `CleanNow{steps}`,
		Id = 0,
		Robux = cleanNowBase + 100 * steps,
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
	[2] = 15,
	[3] = 35,
	[4] = 75,
	[5] = 149,
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

	SuperSoap = {
		PowerMultiplier = 2, -- applied through Hooks "CleaningPower"
		Seconds = 600, -- per purchase; purchases stack
		MaxSeconds = 4 * 3600, -- stacking cap
	},
	CalmTreatSeconds = 60, -- sent with Hooks "CalmTreat"; the Tension feature freezes patience
	LuckySoap = {
		WalkIns = 5, -- per purchase; purchases stack
		MaxWalkIns = 50,
		MinRarityOrder = 4, -- RarityConfig order: Legendary and above
		SpawnWeightMultiplier = 4,
		MutationWeightMultiplier = 3, -- every mutation except Normal
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
	IncredibleLuck = {
		Seconds = 600,
		MaxSeconds = 4 * 3600,
		MinRarityOrder = 2, -- Rare and above
		SpawnWeightMultiplier = 5,
	},
	AutoCollect = {
		MaxSeconds = 40 * 60, -- stacked 10-minute purchases stop here
	},
	-- Sold out between the stock check and the receipt: cash instead (the Robux can't be refunded).
	-- max(Floor, min(120 min of income, the full next hose)): never less than Floor at any tier.
	SoldOutCompensation = { Minutes = 120, Floor = 5000, CapFraction = 1 },

	Offers = {
		-- The side pop-ups (Super Soap on a big wash, Calm Treat before a mud shake) are off.
		-- The products stay in the shop and on the "too dirty" prompt.
		Enabled = false,
		QuietSeconds = 90, -- no offer or auto-opened shop this early in a session
		CooldownSeconds = 240, -- per offer kind
		MaxPerSession = 6,
		AutoHideSeconds = 12,
		BigAnimalWashTime = 2, -- Super Soap offer: AnimalConfig WashTimeMultiplier at least this
		SuperSoapCheckDelay = 8, -- seconds into the wash
		SuperSoapMaxProgress = 0.5, -- still less clean than this
		CashAutoOpenEvery = 3, -- failed cash purchases (hose or barn) per auto-open
		CashAutoOpenMax = 3, -- auto-opens per session
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
