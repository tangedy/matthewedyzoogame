-- The next rarity the hose cannot wash starts at 0% and gains ChancePerWash per
-- completed wash, taken from Common. Every rarity above that is FlatChance on every
-- walk-in and does not grow. Seeing any unwashable resets the growing count to 0.
-- Hose upgrades no longer schedule a separate animal: the set is whatever this
-- hose (and its sub-tier) still cannot wash.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local GearLadder = require(ReplicatedStorage.Shared.GearLadder)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local AnimalBuilder = require(script.Parent.AnimalBuilder)
local Hooks = require(script.Parent.Hooks)
local PlayerDataService = require(script.Parent.PlayerDataService)

local CleanGateService = {}

local rng = Random.new()

-- The player's hose power at their current sub-tier (the Fire Hose's last one unlocks Secret).
function CleanGateService.washPower(player: Player): number
	local data = PlayerDataService.get(player)
	local base = if data then GearLadder.power(data.ToolTier, data.ToolUpgrade) else GearLadder.power(1)
	local boosted = Hooks.apply("CleaningPower", base, player)
	if typeof(boosted) == "number" and boosted == boosted and boosted > 0 and boosted < math.huge then
		return boosted
	end
	return base
end

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

-- Rarities this power cannot wash that still have a walk-in model, cheapest first.
local function lockedRarities(power: number): { string }
	local list = {}
	for _, rarity in RarityConfig.List do
		if not CleanPower.canClean(power, rarity.Key) then
			local found = false
			for _, def in AnimalConfig.Animals do
				if def.Rarity == rarity.Key and not def.Limited and AnimalBuilder.has(def.TemplateName) then
					found = true
					break
				end
			end
			if found then
				table.insert(list, rarity.Key)
			end
		end
	end
	return list
end

-- Folds unwashable chances into a washable weight table. Rare and above that the
-- hose can already wash keep their share. The extra chance comes out of Common.
function CleanGateService.mix(player: Player, weights: { [string]: number }, power: number): { [string]: number }
	local locked = lockedRarities(power)
	if #locked == 0 then
		return weights
	end
	local data = PlayerDataService.get(player)
	local washes = if data then data.WashesSinceUnwashable else 0
	local cfg = GameConfig.CleanGate
	local nextChance = math.max(0, washes) * cfg.ChancePerWash
	local flat = cfg.FlatChance
	local wanted = nextChance + flat * (#locked - 1)
	if wanted <= 0 then
		return weights
	end

	local total = 0
	local common = 0
	for key, weight in weights do
		total += weight
		if AnimalConfig.Animals[key].Rarity == "Common" then
			common += weight
		end
	end
	if total <= 0 or common <= 0 then
		return weights
	end

	local commonShare = common / total
	local taken = math.min(commonShare, wanted)
	local fit = taken / wanted
	local commonScale = 1 - taken / commonShare

	local mixed: { [string]: number } = {}
	for key, weight in weights do
		if AnimalConfig.Animals[key].Rarity == "Common" then
			mixed[key] = weight * commonScale
		else
			mixed[key] = weight
		end
	end
	for index, rarityKey in locked do
		local species = speciesOfRarity(rarityKey)
		local chance = if index == 1 then nextChance else flat
		if species and chance > 0 then
			mixed[species] = (mixed[species] or 0) + chance * fit * total
		end
	end
	return mixed
end

-- The animal that just walked in. An unwashable one clears the bonus.
function CleanGateService.observe(player: Player, species: string): boolean
	local data = PlayerDataService.get(player)
	local def = AnimalConfig.Animals[species]
	if not data or not def then
		return false
	end
	local power = CleanGateService.washPower(player)
	if CleanPower.canClean(power, def.Rarity) then
		return false
	end
	data.WashesSinceUnwashable = 0
	PlayerDataService.markDirty(player)
	PlayerDataService.saveNow(player)
	return true
end

-- A finished wash of an animal the hose could clean. Unwashable arrivals do not count.
function CleanGateService.onWashed(player: Player)
	local data = PlayerDataService.get(player)
	if not data then
		return
	end
	local power = CleanGateService.washPower(player)
	if #lockedRarities(power) == 0 then
		return
	end
	data.WashesSinceUnwashable += 1
	PlayerDataService.markDirty(player)
end

-- Kept so a hose purchase still has a place to call. The mix above already follows
-- the hose the player has now, so an upgrade does not schedule a second animal.
function CleanGateService.onTiersGained(_player: Player, _oldTier: number, _newTier: number) end

return CleanGateService
