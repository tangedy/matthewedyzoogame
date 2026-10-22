-- Schedules animals the player is not strong enough to wash:
--   * Walk-in number FirstTeaseAt (the 10th) is always Legendary.
--   * Each hose upgrade arms another one, TeaseEvery walk-ins later. The first upgrade's
--     tease is Legendary; every upgrade after that steps the rarity up by one (Mythic,
--     Zoo God, then Secret). A tier jump (the Fire-Hose Rig pass) steps once per tier gained.
-- The species is returned to BayService, which spawns it in place of the normal roll.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local AnimalBuilder = require(script.Parent.AnimalBuilder)
local PlayerDataService = require(script.Parent.PlayerDataService)

local CleanGateService = {}

local rng = Random.new()
local maxOrder = RarityConfig.List[#RarityConfig.List].Order

local function speciesOfRarity(rarityKey: string): string?
	local pool = {}
	for key, def in AnimalConfig.Animals do
		if def.Rarity == rarityKey and not def.Limited and AnimalBuilder.has(def.TemplateName) then
			table.insert(pool, key)
		end
	end
	table.sort(pool)
	if #pool == 0 then
		return nil
	end
	return pool[rng:NextInteger(1, #pool)]
end

local function rarityKeyForOrder(order: number): string?
	for _, rarity in RarityConfig.List do
		if rarity.Order == order then
			return rarity.Key
		end
	end
	return nil
end

-- Counts this walk-in and maybe returns a species that skips the normal power gate.
function CleanGateService.roll(player: Player): string?
	local data = PlayerDataService.get(player)
	if not data then
		return nil
	end
	local cfg = GameConfig.CleanGate
	data.AnimalsSeen += 1

	local rarityKey: string? = nil
	local tenth = data.AnimalsSeen == cfg.FirstTeaseAt and not data.TenthLegendaryGiven
	if tenth then
		data.TenthLegendaryGiven = true
		rarityKey = cfg.FirstTeaseRarity
	end
	if data.AnimalsUntilTease > 0 then
		data.AnimalsUntilTease -= 1
		if data.AnimalsUntilTease == 0 then
			if tenth then
				-- One locked animal at a time. The upgrade tease waits another full set.
				data.AnimalsUntilTease = cfg.TeaseEvery
			else
				rarityKey = rarityKeyForOrder(data.TeaseOrder)
			end
		end
	end
	PlayerDataService.markDirty(player)

	local species = if rarityKey then speciesOfRarity(rarityKey) else nil
	if species then
		PlayerDataService.saveNow(player)
	end
	return species
end

-- oldTier -> newTier. One step per tier gained, then the 10-animal wait starts over.
function CleanGateService.onTiersGained(player: Player, oldTier: number, newTier: number)
	local data = PlayerDataService.get(player)
	if not data then
		return
	end
	local gained = newTier - oldTier
	if gained < 1 then
		return
	end
	local cfg = GameConfig.CleanGate
	for _ = 1, gained do
		data.CleanUpgradeCount += 1
		if data.CleanUpgradeCount == 1 then
			data.TeaseOrder = cfg.TeaseStartOrder
		else
			data.TeaseOrder = math.min(maxOrder, data.TeaseOrder + 1)
		end
	end
	data.AnimalsUntilTease = cfg.TeaseEvery
	PlayerDataService.markDirty(player)
end

return CleanGateService
