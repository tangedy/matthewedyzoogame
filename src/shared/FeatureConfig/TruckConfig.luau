-- Delivery truck: every few minutes a truck drives down the road to each player's zoo and
-- parks for a short while carrying one high-rarity animal, sold for Robux (MonetizationConfig
-- product "TruckAnimal"). The animal goes to the cache as a paid animal (never pushed out).
-- Trucks start after the second hose upgrade. Each one carries an animal one rarity above the
-- rarest the player's hose can wash; once that would be Farm God or better, the truck rolls
-- HighTierChances instead and anything left over is HighTierFallback.

return {
	UnlockToolTier = 3, -- the Garden Hose: two upgrades past the starting sponge
	FirstAfterUnlockSeconds = 15, -- the first truck after the upgrade that unlocks them
	FirstArrivalSeconds = 90, -- after the player gets their zoo, when trucks were already unlocked
	IntervalSeconds = 300, -- between arrivals (counted from when the last truck left)
	ParkSeconds = 30,
	DriveSeconds = 7, -- along the road, each way
	ProductKey = "TruckAnimal",

	HighTierFrom = "ZooGod", -- one-above rarity at which the high-tier odds take over
	HighTierChances = { ZooGod = 1 / 5, Secret = 1 / 10 },
	HighTierFallback = "Mythic", -- the third rarest tier
	-- Chance of each mutation on the truck animal (anything left over is Normal).
	MutationChances = { Gold = 0.15, Diamond = 0.08, Rainbow = 0.02 },

	ParkOffset = Vector3.new(0, 0, 10), -- from the bay's road entrance; clear of the walk-in lane
	StartDistance = 90, -- studs up the road the truck appears from; stays on the eight-plot road
	MaxAnimalLength = 6.2, -- the animal rides sideways on the bed, scaled down to fit between the rails

	Colors = {
		Cab = Color3.fromRGB(230, 70, 60),
		Bed = Color3.fromRGB(245, 245, 245),
		Trim = Color3.fromRGB(255, 205, 40),
		Beacon = Color3.fromRGB(255, 160, 30), -- roof light, flashes while parked
	},
}
