-- Income multiplier for a mutation. Gold and Rainbow come from DevParams.json so a
-- designer can retune them without shipping a code change. Anything the JSON doesn't
-- name keeps MutationConfig.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MutationConfig = require(ReplicatedStorage.Shared.MutationConfig)
local DevParams = require(script.Parent.Parent.DevParams)

local MutationPayout = {}

MutationPayout.params = DevParams

function MutationPayout.multiplier(mutationKey: string): number
	local mutations = DevParams.mutations
	local entry = if typeof(mutations) == "table" then mutations[mutationKey] else nil
	local custom = if typeof(entry) == "table" then entry.incomeMultiplier else nil
	if typeof(custom) == "number" and custom > 0 and custom == custom and custom < math.huge then
		return custom
	end
	local mutation = MutationConfig.ByKey[mutationKey] or MutationConfig.ByKey.Normal
	return mutation.IncomeMultiplier
end

return MutationPayout
