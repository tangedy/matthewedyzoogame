-- Monetization tuning: developer products, game passes, boost strengths and the guardrails
-- that keep paid items from skipping the game (concept doc: nothing pay-to-win, no shop
-- prompt in the first 90 seconds, mostly repeatable consumables plus limiteds and whale items).
--
-- Ids are placeholders (0). Robux prices here are for display only: Roblox charges whatever
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
	Kind: string, -- "SuperSoap" | "CalmTreat" | "LuckySoap" | "Cash" | "Limited" | "AutoCollect" | "CleanNow" | "Truck"
	Hidden: boolean?, -- offered in the moment (not a shop card)
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
	LuckyLeft: number, -- walk-ins left on Lucky Soap
	Passes: { [string]: boolean }, -- owned game passes
	Once: { [string]: boolean }, -- once-only products already bought
	Stock: { [string]: number }, -- remaining stock per limited (missing while unknown)
	Cash: { [string]: number }, -- what each cash pack gives this player right now
	Unavailable: { [string]: boolean }, -- products that can't be sold (e.g. animal not in the game)
	TestMode: boolean, -- purchases are simulated for this player
	PendingAnimals: number, -- bought animals waiting for a free cache slot
}

local PINK = Color3.fromRGB(255, 90, 200)
local BLUE = Color3.fromRGB(80, 190, 255)
local GREEN = Color3.fromRGB(90, 220, 110)
local GOLD = Color3.fromRGB(255, 200, 40)
local PURPLE = Color3.fromRGB(170, 90, 255)
local RED = Color3.fromRGB(255, 80, 80)

local products: { Product } = {
	-- Boosts
	{
		Key = "SuperSoapStarter",
		Id = 0,
		Robux = 5,
		DisplayName = "Super Soap",
		Description = "2x cleaning power for 10 minutes. Your first one is cheap!",
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
		Description = "2x cleaning power for 10 minutes. Buy more to stack the time.",
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
		Description = "Freezes the animal's patience for 60 seconds. No more mud shakes!",
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
		Description = "Next 5 walk-ins: mutations 3x as likely, and Legendary+ animals your hose can wash 4x as likely.",
		Tab = "Boosts",
		Order = 3,
		Kind = "LuckySoap",
		Color = GOLD,
	},
	{
		Key = "AutoCollect2h",
		Id = 0,
		Robux = 49,
		DisplayName = "Auto-Collect: 2 Hours",
		Description = "Pens pay themselves for 2 hours while you play. Buying again adds another 2 hours, up to 8.",
		Tab = "Boosts",
		Order = 4,
		Kind = "AutoCollect",
		Color = GREEN,
		Seconds = 2 * 3600,
	},
	-- Cash
	{
		Key = "CashSmall",
		Id = 0,
		Robux = 25,
		DisplayName = "Pile of Cash",
		Description = "5 minutes of your zoo's income, right now.",
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
		Description = "15 minutes of your zoo's income, right now.",
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
		Description = "45 minutes of your zoo's income, right now.",
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
		Description = "Instantly clean one animal your hose isn't strong enough for.",
		Tab = "Boosts",
		Order = 99,
		Kind = "CleanNow",
		Color = GOLD,
		Hidden = true,
	},
	{
		Key = "TruckAnimal",
		Id = 0,
		Robux = 200,
		DisplayName = "Delivery Truck Animal",
		Description = "The high-rarity animal on the delivery truck parked at your zoo.",
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
		Description = "Limited Mythic! Only 1,000 will ever exist. Never restocked.",
		Tab = "Limited",
		Order = 1,
		Kind = "Limited",
		Color = RED,
		Species = "Axolotl",
		Mutation = "Normal",
		Stock = 1000,
	},
}

local passes: { Pass } = {
	{
		Key = "VIPKeeper",
		Id = 0,
		Robux = 399,
		DisplayName = "VIP Keeper",
		Description = "+25% zoo income forever and a gold VIP tag over your head.",
		Order = 1,
		Color = GOLD,
	},
	{
		Key = "FireHoseRig",
		Id = 0,
		Robux = 1499,
		DisplayName = "Fire-Hose Rig",
		Description = "Unlock the best hose right now, forever. Blast mud like a pro.",
		Order = 2,
		Color = PURPLE,
	},
	{
		Key = "AutoCollectForever",
		Id = 0,
		Robux = 399,
		DisplayName = "Auto-Collect: Forever",
		Description = "Pens pay themselves forever. You never have to walk the collect pads again.",
		Order = 3,
		Color = GREEN,
	},
}

local productsByKey: { [string]: Product } = {}
for _, product in products do
	productsByKey[product.Key] = product
end
local passesByKey: { [string]: Pass } = {}
for _, pass in passes do
	passesByKey[pass.Key] = pass
end

return {
	Products = products,
	ProductsByKey = productsByKey,
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
		TagColor = GOLD,
	},
	AutoCollect = {
		MaxSeconds = 8 * 3600, -- stacked 2-hour purchases stop here
		PassKey = "AutoCollectForever",
	},
	-- Sold out between the stock check and the receipt: cash instead (the Robux can't be refunded).
	-- max(Floor, min(120 min of income, the full next hose)): never less than Floor at any tier.
	SoldOutCompensation = { Minutes = 120, Floor = 5000, CapFraction = 1 },

	Offers = {
		QuietSeconds = 90, -- no offer or auto-opened shop this early in a session
		CooldownSeconds = 240, -- per offer kind
		MaxPerSession = 6,
		AutoHideSeconds = 12,
		BigAnimalWashTime = 2, -- Super Soap offer: AnimalConfig WashTimeMultiplier at least this
		SuperSoapCheckDelay = 8, -- seconds into the wash
		SuperSoapMaxProgress = 0.5, -- still less clean than this
		CashAutoOpenEvery = 3, -- failed hose purchases ("Not enough cash") per auto-open
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
