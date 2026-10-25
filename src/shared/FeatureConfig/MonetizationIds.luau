-- Real Roblox ids for every developer product and game pass, by MonetizationConfig key.
-- The one place to paste ids: MonetizationConfig reads them from here. A 0 means "not on
-- sale yet" (simulated in Studio and for the place owner, see MonetizationConfig).
--
-- tools/create-products.ps1 creates the developer products through Open Cloud and rewrites
-- the Products table. Game passes are made by hand on the Creator Dashboard (Monetization >
-- Passes); paste the pass id below.

return {
	Products = {
		SuperSoapStarter = 3722053138,
		SuperSoap = 3722053141,
		SuperSoapLarge = 3722053147,
		CalmTreat = 3722053150,
		AutoCollect2h = 3722053159,
		SpeedBoost = 3722053168,
		CashSmall = 3722053177,
		CashMedium = 3722053181,
		CashLarge = 3722053186,
		CleanNow = 3722053190,
		TruckAnimal = 3722053213,
		LimitedAxolotl = 3722053219,
		OfflineDouble = 3722053224,
		CleanNow1 = 3722053192,
		CleanNow2 = 3722053198,
		CleanNow3 = 3722053206,
		CleanNow4 = 3722053210,
		HoseTier2 = 3722053229,
		HoseTier3 = 3722053232,
		HoseTier4 = 3722053239,
		HoseTier5 = 3722053246,
	},
	Passes = {
		VIPKeeper = 0,
	},
}
