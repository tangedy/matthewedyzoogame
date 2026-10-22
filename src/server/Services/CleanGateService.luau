-- Rarities the hose cannot wash (Clean Now is the only way) start at 0%.
-- Each completed wash adds ChancePerWash to every one of those rarities, and that
-- chance is taken from Common. Seeing one of them resets the count to 0.
-- Hose upgrades no longer schedule a separate animal: the set is whatever this
-- hose, including Super Soap, still cannot wash.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimalConfig = require(ReplicatedStorage.Shared.AnimalConfig)
local CleanPower = require(ReplicatedStorage.Shared.CleanPower)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RarityConfig = require(ReplicatedStorage.Shared.RarityConfig)
local ToolConfig = require(ReplicatedStorage.Shared.ToolConfig)
local AnimalBuilder = require(script.Parent.AnimalBuilder)
local Hooks = require(script.Parent.Hooks)
local PlayerDataService = require(script.Parent.PlayerDataService)

local CleanGateService = {}

local rng = Random.new()

function CleanGateService.washPower(player: Player, tier: number): number
	local tool = ToolConfig[tier] or ToolConfig[1]
	local boosted = Hooks.apply("CleaningPower", tool.CleaningPower, player)
	if typeof(boosted) == "number" and boosted == boosted and boosted > 0 and boosted < math.huge then
		return boosted
	end
	return tool.CleaningPower
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

-- Folds the tiny unwashable chances into a washable weight table. Other rarities
-- keep their share. Each locked rarity's chance comes out of Common.
function CleanGateService.mix(player: Player, weights: { [string]: number }, power: number): { [string]: number }
	local data = PlayerDataService.get(player)
	local washes = if data then data.WashesSinceUnwashable else 0
	if washes <= 0 then
		return weights
	end
	local locked = lockedRarities(power)
	if #locked == 0 then
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
	local each = washes * GameConfig.CleanGate.ChancePerWash
	local taken = math.min(commonShare, each * #locked)
	local eachChance = taken / #locked
	local commonScale = 1 - taken / commonShare

	local mixed: { [string]: number } = {}
	for key, weight in weights do
		if AnimalConfig.Animals[key].Rarity == "Common" then
			mixed[key] = weight * commonScale
		else
			mixed[key] = weight
		end
	end
	local eachWeight = eachChance * total
	for _, rarityKey in locked do
		local species = speciesOfRarity(rarityKey)
		if species then
			mixed[species] = (mixed[species] or 0) + eachWeight
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
	local power = CleanGateService.washPower(player, data.ToolTier)
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
	local power = CleanGateService.washPower(player, data.ToolTier)
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
