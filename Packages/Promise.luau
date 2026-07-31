--!strict
--[[
	Minimal Promise implementation (A+-ish, Roblox-flavoured).
	No external dependencies - self-contained on purpose.
]]

local Promise = {}
Promise.__index = Promise

export type Promise<T = any> = typeof(setmetatable(
	{} :: {
		_state: "Pending" | "Resolved" | "Rejected",
		_value: T,
		_resolveQueue: { (T) -> () },
		_rejectQueue: { (any) -> () },
	},
	Promise
))

local function isPromise(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Promise
end

Promise.is = isPromise

function Promise.new(executor: (resolve: (any) -> (), reject: (any) -> ()) -> ()): Promise
	local self = setmetatable({
		_state = "Pending",
		_value = nil,
		_resolveQueue = {},
		_rejectQueue = {},
	}, Promise)

	local function resolve(value: any)
		if self._state ~= "Pending" then
			return
		end

		if isPromise(value) then
			value:andThen(resolve, function(err)
				if self._state ~= "Pending" then
					return
				end
				self._state = "Rejected"
				self._value = err
				for _, callback in ipairs(self._rejectQueue) do
					task.spawn(callback, err)
				end
			end)
			return
		end

		self._state = "Resolved"
		self._value = value
		for _, callback in ipairs(self._resolveQueue) do
			task.spawn(callback, value)
		end
	end

	local function reject(err: any)
		if self._state ~= "Pending" then
			return
		end
		self._state = "Rejected"
		self._value = err
		for _, callback in ipairs(self._rejectQueue) do
			task.spawn(callback, err)
		end
	end

	task.spawn(function()
		local success, err = pcall(executor, resolve, reject)
		if not success then
			reject(err)
		end
	end)

	return self
end

function Promise.resolve(value: any): Promise
	return Promise.new(function(resolve)
		resolve(value)
	end)
end

function Promise.reject(err: any): Promise
	return Promise.new(function(_, reject)
		reject(err)
	end)
end

function Promise.all(promises: { Promise }): Promise
	return Promise.new(function(resolve, reject)
		local results = {}
		local remaining = #promises

		if remaining == 0 then
			resolve(results)
			return
		end

		for i, promise in ipairs(promises) do
			promise:andThen(function(value)
				results[i] = value
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end, reject)
		end
	end)
end

--[[
	Like Promise.all, but never rejects - resolves once every promise has
	settled (either resolved or rejected), with a per-entry status report.
	Useful for "start everything, tell me what failed" flows.
]]
function Promise.allSettled(promises: { Promise }): Promise
	return Promise.new(function(resolve)
		local results = {}
		local remaining = #promises

		if remaining == 0 then
			resolve(results)
			return
		end

		for i, promise in ipairs(promises) do
			promise:andThen(function(value)
				results[i] = { Status = "Resolved", Value = value }
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end, function(err)
				results[i] = { Status = "Rejected", Error = err }
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end)
		end
	end)
end

function Promise:andThen(onResolve: ((any) -> any)?, onReject: ((any) -> any)?): Promise
	return Promise.new(function(resolve, reject)
		local function handleResolve(value: any)
			if type(onResolve) ~= "function" then
				resolve(value)
				return
			end
			local success, result = pcall(onResolve, value)
			if success then
				resolve(result)
			else
				reject(result)
			end
		end

		local function handleReject(err: any)
			if type(onReject) ~= "function" then
				reject(err)
				return
			end
			local success, result = pcall(onReject, err)
			if success then
				resolve(result)
			else
				reject(result)
			end
		end

		if self._state == "Resolved" then
			task.spawn(handleResolve, self._value)
		elseif self._state == "Rejected" then
			task.spawn(handleReject, self._value)
		else
			table.insert(self._resolveQueue, handleResolve)
			table.insert(self._rejectQueue, handleReject)
		end
	end)
end

function Promise:catch(onReject: (any) -> any): Promise
	return self:andThen(nil, onReject)
end

function Promise:finally(callback: () -> ()): Promise
	return self:andThen(function(value)
		callback()
		return value
	end, function(err)
		callback()
		error(err, 0)
	end)
end

function Promise:await(): any
	if self._state == "Resolved" then
		return self._value
	end
	if self._state == "Rejected" then
		error(self._value, 0)
	end

	local thread = coroutine.running()
	table.insert(self._resolveQueue, function(value)
		task.spawn(thread, true, value)
	end)
	table.insert(self._rejectQueue, function(err)
		task.spawn(thread, false, err)
	end)

	local success, result = coroutine.yield()
	if not success then
		error(result, 0)
	end
	return result
end

function Promise:getState(): string
	return self._state
end

return Promise
