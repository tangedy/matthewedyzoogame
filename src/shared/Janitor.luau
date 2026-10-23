-- Small cleanup bucket for connections, instances, threads, and functions.
-- Add(task, method?, key?) remembers one thing. Cleanup (or Remove) runs its teardown.
-- A thread that is currently running is not cancelled, so a timer can Cleanup from inside itself.

local Janitor = {}
Janitor.__index = Janitor

export type Janitor = typeof(setmetatable(
	{} :: {
		_tasks: { [any]: any },
		_keys: { [string]: any },
	},
	Janitor
))

function Janitor.new(): Janitor
	return setmetatable({
		_tasks = {},
		_keys = {},
	}, Janitor)
end

local function cleanupOne(taskObj: any, method: any)
	if method == true and typeof(taskObj) == "thread" and taskObj == coroutine.running() then
		return
	end
	local ok, err = pcall(function()
		if method == true then
			local kind = typeof(taskObj)
			if kind == "RBXScriptConnection" then
				taskObj:Disconnect()
			elseif kind == "thread" then
				task.cancel(taskObj)
			elseif kind == "Instance" then
				taskObj:Destroy()
			elseif kind == "function" then
				taskObj()
			end
		elseif typeof(method) == "string" then
			taskObj[method](taskObj)
		elseif typeof(method) == "function" then
			method(taskObj)
		end
	end)
	if not ok then
		warn(`[Janitor] cleanup failed: {err}`)
	end
end

function Janitor.Add(self: Janitor, taskObj: any, method: any?, key: string?): any
	if key ~= nil then
		self:Remove(key)
		self._keys[key] = taskObj
	end
	self._tasks[taskObj] = if method == nil then true else method
	return taskObj
end

function Janitor.Remove(self: Janitor, key: string)
	local taskObj = self._keys[key]
	if taskObj == nil then
		return
	end
	self._keys[key] = nil
	local method = self._tasks[taskObj]
	self._tasks[taskObj] = nil
	if method ~= nil then
		cleanupOne(taskObj, method)
	end
end

function Janitor.Cleanup(self: Janitor)
	local tasks = self._tasks
	self._tasks = {}
	self._keys = {}
	for taskObj, method in tasks do
		cleanupOne(taskObj, method)
	end
end

return Janitor
