-- Real Roblox ids for every developer product and game pass, by MonetizationConfig key.
-- The one place to paste ids: MonetizationConfig reads them from here. A 0 means "not on
-- sale yet" (simulated in Studio and for the place owner, see MonetizationConfig).
--
-- tools/create-products.ps1 creates the developer products through Open Cloud and rewrites
-- the Products table. Game passes are made by hand on the Creator Dashboard (Monetization >
-- Passes); paste the pass id below.

return {
	Products = {
		SuperSoapStarter = 0,
		SuperSoap = 0,
		SuperSoapLarge = 0,
		CalmTreat = 0,
		LuckySoap = 0,
		AutoCollect2h = 0,
		SpeedBoost = 0,
		IncredibleLuck = 0,
		CashSmall = 0,
		CashMedium = 0,
		CashLarge = 0,
		CleanNow = 0,
		TruckAnimal = 0,
		LimitedAxolotl = 0,
		SidePasture = 0,
		OfflineDouble = 0,
		CleanNow1 = 0,
		CleanNow2 = 0,
		CleanNow3 = 0,
		CleanNow4 = 0,
		HoseTier2 = 0,
		HoseTier3 = 0,
		HoseTier4 = 0,
		HoseTier5 = 0,
	},
	Passes = {
		VIPKeeper = 0,
	},
}
