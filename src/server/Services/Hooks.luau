-- Extension points the core game exposes to feature modules (src/server/Features), so new
-- systems plug in without editing core services.
--
-- Events (Hooks.on / Hooks.fire), fired by the core:
--   "PlayerLoaded"   (player, data)                    profile loaded, before the bay is given
--   "BayAssigned"    (player, bayModel)
--   "PlayerLeaving"  (player)                          before the profile is saved and released
--   "WashStarted"    (player, info: WashInfo)          animal is at the wash spot, cleaning enabled
--   "WashProgress"   (player, jobId, progress)         after each accepted spray
--   "WashCompleted"  (player, info: WashInfo, reward)  paid; info.Model still exists
--   "WashAbandoned"  (player, info: WashInfo)          the animal wandered off unpaid (Tension)
--   "AnimalPlaced"   (player, animal: OwnedAnimal)     carried animal put in a pen
--   "AnimalSold"     (player, species, mutation, value)
--   "IncomeTick"     (player, amount)                  cash added to pads this tick
--   "ToolPurchased"  (player, tier, name)              the next hose was bought (cash or Robux)
--   "ZooExpanded"    (player, pens, price, barn)       a barn expansion was bought
--
-- Modifiers (Hooks.modify / Hooks.apply): each registered function receives the current value
-- plus context and returns the new value. Applied in registration order.
--   "CleaningPower"      (power, player)                    -> number
--   "SoapActive"         (false, player)                    -> boolean  Super Soap is running (soap-only animals)
--   "WashTimeMultiplier" (mult, player, species, mutation)  -> number (more mud = higher)
--   "SpawnWeight"        (weight, player, species)          -> number
--   "MutationWeight"     (weight, player, mutation)         -> number
--   "MutationPick"       (mutation, player, isFirst)        -> string  final mutation key for a walk-in
--   "VariantOneIn"       (oneIn, player, mutation)          -> number  1-in-N chance for a variant (lower is likelier)
--   "NextAnimal"         (nil, player, isFirst)             -> { Species: string, Mutation: string? }?  override a walk-in
--   "WashReward"         (reward, player, species, mutation) -> number
--   "IncomeMultiplier"   (mult, player)                     -> number
--   "OfflineSeconds"     (seconds, player)                  -> number

export type WashInfo = {
	JobId: string,
	Species: string,
	Mutation: string,
	Model: Model,
	Bay: Model,
}

local Hooks = {}

local listeners: { [string]: { (...any) -> () } } = {}
local modifiers: { [string]: { (any, ...any) -> any } } = {}

function Hooks.on(name: string, fn: (...any) -> ())
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end

-- Listeners run in their own threads so a slow or broken feature can't stall the core.
function Hooks.fire(name: string, ...: any)
	local list = listeners[name]
	if not list then
		return
	end
	for _, fn in list do
		task.spawn(function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				warn(`[Hooks] {name} listener failed: {err}`)
			end
		end, ...)
	end
end

function Hooks.modify(name: string, fn: (any, ...any) -> any)
	modifiers[name] = modifiers[name] or {}
	table.insert(modifiers[name], fn)
end

-- Runs synchronously; a modifier that errors (or returns nil for a number) is skipped.
function Hooks.apply(name: string, value: any, ...: any): any
	local list = modifiers[name]
	if not list then
		return value
	end
	for _, fn in list do
		local ok, result = pcall(fn, value, ...)
		if ok and (result ~= nil or name == "NextAnimal") then
			value = result
		elseif not ok then
			warn(`[Hooks] {name} modifier failed: {result}`)
		end
	end
	return value
end

return Hooks
