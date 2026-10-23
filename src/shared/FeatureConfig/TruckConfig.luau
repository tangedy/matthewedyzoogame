-- Delivery truck: every few minutes a truck drives down the road to each player's zoo and
-- parks for a short while carrying one high-rarity animal, sold for Robux (MonetizationConfig
-- product "TruckAnimal"). The animal goes to the cache as a paid animal (never pushed out).

return {
	FirstArrivalSeconds = 90, -- after the player gets their zoo
	IntervalSeconds = 300, -- between arrivals (counted from when the last truck left)
	ParkSeconds = 30,
	DriveSeconds = 7, -- along the road, each way
	ProductKey = "TruckAnimal",

	MinRarity = "Legendary", -- rarity order at or above this can ride the truck
	-- Chance of each mutation on the truck animal (anything left over is Normal).
	MutationChances = { Gold = 0.15, Diamond = 0.08, Rainbow = 0.02 },

	ParkOffset = Vector3.new(0, 0, 10), -- from the bay's road entrance; clear of the walk-in lane
	StartDistance = 90, -- studs up the road the truck appears from; stays on the eight-plot road
	MaxAnimalLength = 7, -- the animal on the bed is scaled down to fit if longer

	Colors = {
		Cab = Color3.fromRGB(230, 70, 60),
		Bed = Color3.fromRGB(245, 245, 245),
		Trim = Color3.fromRGB(255, 205, 40),
	},
}
