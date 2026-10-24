-- How walk-in chance spreads across rarity tiers (GameConfig.SpawnCurve). Tiers sit on the
-- x axis by RarityConfig Order; a tier's share of walk-ins is the curve's height there.
-- The curve is a lopsided bell. Its peak sits at Common for a new player and slides right
-- as the hose washes higher tiers. Both sides widen as it goes, so the peak drops, Common
-- thins out, and the right tail stretches toward the best tier the hose can wash.
-- Tiers left of the peak never fall below Floor, so a top hose still sees some commons.
-- Shared so the shop or index could show the same odds the server rolls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local SpawnCurve = {}

-- Curve height at tier order x, for a player whose best washable tier has order top.
function SpawnCurve.height(x: number, top: number): number
	local cfg = GameConfig.SpawnCurve
	local steps = math.max(0, top - cfg.StartTop)
	local peak = math.max(1, 1 + cfg.PeakOffset + cfg.PeakPerTier * steps)
	local width = if x < peak
		then cfg.LeftWidth + cfg.LeftWidthPerTier * steps
		else cfg.RightWidth + cfg.RightWidthPerTier * steps
	local height = math.exp(-((x - peak) ^ 2) / (2 * width * width))
	if x <= peak then
		height = math.max(height, cfg.Floor)
	end
	return height
end

-- Normalised shares for the given tier orders (the tiers that can actually walk in).
function SpawnCurve.shares(orders: { number }): { [number]: number }
	local top = 0
	for _, order in orders do
		top = math.max(top, order)
	end
	local heights: { [number]: number } = {}
	local total = 0
	for _, order in orders do
		heights[order] = SpawnCurve.height(order, top)
		total += heights[order]
	end
	if total > 0 then
		for order, height in heights do
			heights[order] = height / total
		end
	end
	return heights
end

return SpawnCurve
