--!strict
--[[
	Test suite for Thread / Channel / Promise.

	No external test framework (no TestEZ, no Wally) - built on TestRunner.luau,
	which is nothing but pcall + assert. Run this from a server-side context in
	Roblox Studio: either paste the two lines below into the Command Bar while
	a Play/Run session is active, or drop a throwaway Script under
	ServerScriptService that requires this module, then delete the script again.

		local Thread = game:GetService("ReplicatedStorage").Packages.Thread
		require(Thread.Parent.Parent.Tests["Thread.spec"])

	Adjust the path to wherever you actually placed the Thread/ and Tests/
	folders in your Rojo/Studio hierarchy.
]]

local Packages = script.Parent.Parent.Packages

local Promise = require(Packages.Promise)
local Channel = require(Packages.Channel)
local ThreadModuleScript = Packages.Thread :: ModuleScript

local Signal = require(Packages.Util.Signal)
local Trove = require(Packages.Util.Trove)
local TableUtil = require(Packages.Util.TableUtil)
local Option = require(Packages.Util.Option)
local EnumList = require(Packages.Util.EnumList)

local TestRunner = require(script.Parent.TestRunner)

-- Thread is a singleton module (keeps `_Started` state). To test dependency
-- ordering / start-failure behaviour in isolation, clone the ModuleScript so
-- each test gets its own fresh Thread instance. Channel/Promise are fine to share
-- since they don't carry a one-shot "already started" flag.
local function FreshThread()
	local clone = ThreadModuleScript:Clone()
	clone.Parent = ThreadModuleScript.Parent
	local thread = require(clone) :: any
	return thread, clone
end

--------------------------------------------------
-- Promise
--------------------------------------------------

TestRunner.Test("Promise resolves and awaits", function()
	local p = Promise.new(function(resolve)
		resolve(42)
	end)
	assert(p:await() == 42, "expected 42")
end)

TestRunner.Test("Promise rejects and catch recovers", function()
	local p = Promise.reject("boom"):catch(function(err)
		return "recovered:" .. err
	end)
	assert(p:await() == "recovered:boom", "catch did not recover")
end)

TestRunner.Test("Promise.all waits for every promise", function()
	local results = Promise.all({
		Promise.resolve(1),
		Promise.resolve(2),
		Promise.resolve(3),
	}):await()
	assert(#results == 3 and results[1] == 1 and results[3] == 3, "Promise.all result mismatch")
end)

TestRunner.Test("Promise.allSettled never rejects", function()
	local results = Promise.allSettled({
		Promise.resolve("ok"),
		Promise.reject("fail"),
	}):await()
	assert(results[1].Status == "Resolved" and results[1].Value == "ok", "first entry should resolve")
	assert(results[2].Status == "Rejected" and results[2].Error == "fail", "second entry should reject")
end)

--------------------------------------------------
-- Thread: basic registry behaviour
--------------------------------------------------

TestRunner.Test("Thread.CreateService rejects duplicate names", function()
	local thread = FreshThread()
	thread.CreateService({ Name = "Dup" })

	local ok = pcall(function()
		thread.CreateService({ Name = "Dup" })
	end)

	assert(not ok, "expected duplicate registration to error")
end)

TestRunner.Test("Thread.GetService throws for unknown service", function()
	local thread = FreshThread()
	local ok = pcall(function()
		thread.GetService("DoesNotExist")
	end)
	assert(not ok, "expected missing service lookup to error")
end)

TestRunner.Test("Thread.Unregister removes a pending service", function()
	local thread = FreshThread()
	thread.CreateService({ Name = "Temp" })
	assert(thread.Unregister("Temp") == true, "expected Unregister to succeed")
	assert(thread.Unregister("Temp") == false, "second Unregister should be a no-op returning false")
end)

--------------------------------------------------
-- Thread: dependency ordering
--------------------------------------------------

TestRunner.Test("Thread.Start initializes services in dependency order", function()
	local thread = FreshThread()
	local order = {}

	thread.CreateService({
		Name = "C",
		Dependencies = { "B" },
		ThreadInit = function()
			table.insert(order, "C")
		end,
	})

	thread.CreateService({
		Name = "A",
		ThreadInit = function()
			table.insert(order, "A")
		end,
	})

	thread.CreateService({
		Name = "B",
		Dependencies = { "A" },
		ThreadInit = function()
			table.insert(order, "B")
		end,
	})

	thread.Start():await()

	assert(table.concat(order, ",") == "A,B,C", "expected init order A,B,C, got " .. table.concat(order, ","))
end)

TestRunner.Test("Thread.Start rejects (without hard-erroring) on circular dependencies", function()
	local thread = FreshThread()

	thread.CreateService({ Name = "X", Dependencies = { "Y" } })
	thread.CreateService({ Name = "Y", Dependencies = { "X" } })

	-- HaltOnCriticalFailure defaults to false, so Start() itself must not throw.
	local startOk = pcall(function()
		thread.Start()
	end)
	assert(startOk, "Thread.Start() should not hard-error by default")

	local rejected = false
	thread.OnStart():catch(function()
		rejected = true
	end):await()

	assert(rejected, "expected the start Promise to reject on a circular dependency")
end)

--------------------------------------------------
-- Thread: Register()
--------------------------------------------------

TestRunner.Test("Thread.Register loads ModuleScripts and reports results", function()
	local thread = FreshThread()

	local folder = Instance.new("Folder")
	folder.Name = "TestServices"

	local good = Instance.new("ModuleScript")
	good.Name = "GoodModule"
	good.Source = "return 'ok'"
	good.Parent = folder

	local bad = Instance.new("ModuleScript")
	bad.Name = "BadModule"
	bad.Source = "error('boom')"
	bad.Parent = folder

	local results = thread.Register(folder)

	assert(#results == 2, "expected 2 results")

	local byName = {}
	for _, r in ipairs(results) do
		byName[r.Module.Name] = r
	end

	assert(byName.GoodModule.Success == true, "GoodModule should have loaded successfully")
	assert(byName.BadModule.Success == false, "BadModule should have failed to load")

	folder:Destroy()
end)

--------------------------------------------------
-- Channel: service-scoped Signals & Properties
--------------------------------------------------

TestRunner.Test("Channel.WrapService creates a Method RemoteFunction", function()
	local serviceName = "SpecService_Method"
	local client = {
		Ping = function(_self, _player)
			return "pong"
		end,
	}

	Channel.WrapService(serviceName, client)

	local remote = game:GetService("ReplicatedStorage").ThreadChannel.RemoteFunction:FindFirstChild(serviceName)
	assert(remote ~= nil, "expected namespace folder to exist")

	local pingRemote = remote:FindFirstChild("Ping")
	assert(pingRemote ~= nil, "expected Ping RemoteFunction to exist")
	assert(pingRemote:GetAttribute("ThreadKind") == "Method", "expected ThreadKind attribute to be Method")

	Channel.Destroy(serviceName)
end)

TestRunner.Test("Channel.WrapService turns a Property marker into a working Property", function()
	local serviceName = "SpecService_Property"
	local client = {
		Score = Channel.CreateProperty(0),
	}

	Channel.WrapService(serviceName, client)

	assert(client.Score:Get() == 0, "expected initial value 0")

	client.Score:Set(10)
	assert(client.Score:Get() == 10, "expected value 10 after Set")

	Channel.Destroy(serviceName)
end)

TestRunner.Test("Channel.WrapService applies Outbound middleware to Property:Set", function()
	local serviceName = "SpecService_PropertyMiddleware"
	local middlewareRan = false

	local client = {
		Score = Channel.CreateProperty(0),
	}

	Channel.WrapService(serviceName, client, {
		Middleware = {
			Outbound = {
				function(_player, args)
					middlewareRan = true
					args[1] = args[1] * 2 -- double the value on the way out
					return true
				end,
			},
		},
	})

	client.Score:Set(5)

	assert(middlewareRan, "expected Outbound middleware to run")
	assert(client.Score:Get() == 10, "expected middleware to have doubled the value to 10")

	Channel.Destroy(serviceName)
end)

TestRunner.Test("Channel.WrapService Outbound middleware can block a Signal:FireAll", function()
	local serviceName = "SpecService_SignalMiddleware"
	local blocked = false

	local client = {
		Alert = Channel.CreateSignal(),
	}

	Channel.WrapService(serviceName, client, {
		Middleware = {
			Outbound = {
				function(_player, _args)
					blocked = true
					return false -- drop every outgoing Alert
				end,
			},
		},
	})

	-- FireAll should run (and be blocked by) the middleware without erroring,
	-- even with zero players connected in this test session.
	client.Alert:FireAll("test")

	assert(blocked, "expected Outbound middleware to have run and blocked the fire")

	Channel.Destroy(serviceName)
end)

TestRunner.Test("Channel.Destroy removes a service's remotes", function()
	local serviceName = "SpecService_Destroy"
	Channel.WrapService(serviceName, {
		Foo = function() end,
	})

	local before = game:GetService("ReplicatedStorage").ThreadChannel.RemoteFunction:FindFirstChild(serviceName)
	assert(before ~= nil, "expected namespace folder to exist before Destroy")

	Channel.Destroy(serviceName)

	local after = game:GetService("ReplicatedStorage").ThreadChannel.RemoteFunction:FindFirstChild(serviceName)
	assert(after == nil, "expected namespace folder to be gone after Destroy")
end)

TestRunner.Test("Property per-player overrides (skipped without a live Player)", function()
	local players = game:GetService("Players"):GetPlayers()

	if #players == 0 then
		print("[SKIP] no live Players in this session - run during Play/Test mode to exercise this")
		return
	end

	local player = players[1]
	local serviceName = "SpecService_PropertyOverride"
	local client = { Score = Channel.CreateProperty(0) }

	Channel.WrapService(serviceName, client)

	client.Score:Set(5)
	assert(client.Score:GetFor(player) == 5, "expected default value when no override is set")

	client.Score:SetFor(player, 99)
	assert(client.Score:GetFor(player) == 99, "expected the per-player override")
	assert(client.Score:Get() == 5, "the shared default should be unaffected by a per-player override")

	client.Score:ClearFor(player)
	assert(client.Score:GetFor(player) == 5, "expected the override to be cleared back to the default")

	Channel.Destroy(serviceName)
end)

--------------------------------------------------
-- Promise: race / some / retry / timeout / fromEvent
--------------------------------------------------

TestRunner.Test("Promise.race settles with the first promise to finish", function()
	local fast = Promise.delay(0):andThen(function()
		return "fast"
	end)
	local slow = Promise.delay(1):andThen(function()
		return "slow"
	end)

	assert(Promise.race({ slow, fast }):await() == "fast", "expected the faster promise to win the race")
end)

TestRunner.Test("Promise.some resolves once enough promises resolve", function()
	local results = Promise.some({
		Promise.resolve(1),
		Promise.resolve(2),
		Promise.reject("nope"),
	}, 2):await()

	assert(#results == 2, "expected exactly 2 results")
end)

TestRunner.Test("Promise.retry retries until success", function()
	local attempts = 0

	local result = Promise.retry(function()
		attempts += 1
		if attempts < 3 then
			return Promise.reject("not yet")
		end
		return Promise.resolve("done")
	end, 5):await()

	assert(result == "done" and attempts == 3, "expected exactly 3 attempts before success")
end)

TestRunner.Test("Promise:timeout rejects a promise that settles too slowly", function()
	local slow = Promise.delay(2):andThen(function()
		return "too slow"
	end)

	local ok = pcall(function()
		slow:timeout(0.05):await()
	end)

	assert(not ok, "expected the timeout to reject before the slow promise resolves")
end)

TestRunner.Test("Promise.fromEvent resolves with the next fired value", function()
	local signal = Signal.new()
	local promise = Promise.fromEvent(signal)

	task.delay(0, function()
		signal:Fire("hello")
	end)

	assert(promise:await() == "hello", "expected fromEvent to resolve with the fired value")
	signal:Destroy()
end)

--------------------------------------------------
-- Util: Signal
--------------------------------------------------

TestRunner.Test("Signal fires connected handlers with the given arguments", function()
	local signal = Signal.new()
	local received = nil

	signal:Connect(function(a, b)
		received = a + b
	end)

	signal:Fire(2, 3)
	task.wait()

	assert(received == 5, "expected the handler to receive the fired arguments")
	signal:Destroy()
end)

TestRunner.Test("Signal:Once only fires a single time", function()
	local signal = Signal.new()
	local count = 0

	signal:Once(function()
		count += 1
	end)

	signal:Fire()
	signal:Fire()
	task.wait()

	assert(count == 1, "expected a Once handler to fire exactly once")
	signal:Destroy()
end)

TestRunner.Test("Signal:DisconnectAll stops future fires", function()
	local signal = Signal.new()
	local fired = false

	signal:Connect(function()
		fired = true
	end)
	signal:DisconnectAll()
	signal:Fire()
	task.wait()

	assert(fired == false, "expected no handlers to run after DisconnectAll")
end)

--------------------------------------------------
-- Util: Trove
--------------------------------------------------

TestRunner.Test("Trove cleans up added objects on Destroy", function()
	local trove = Trove.new()
	local cleaned = false

	trove:Add(function()
		cleaned = true
	end)
	trove:Destroy()

	assert(cleaned == true, "expected the tracked function to run on Destroy")
end)

TestRunner.Test("Trove:Remove excludes an object from cleanup", function()
	local trove = Trove.new()
	local cleaned = false
	local fn = function()
		cleaned = true
	end

	trove:Add(fn)
	trove:Remove(fn)
	trove:Clean()

	assert(cleaned == false, "expected a removed object to not be cleaned up")
end)

TestRunner.Test("Trove:Extend cleans up the sub-trove with its parent", function()
	local trove = Trove.new()
	local sub = trove:Extend()
	local cleaned = false

	sub:Add(function()
		cleaned = true
	end)
	trove:Destroy()

	assert(cleaned == true, "expected the sub-trove to be cleaned when the parent trove is destroyed")
end)

--------------------------------------------------
-- Util: TableUtil
--------------------------------------------------

TestRunner.Test("TableUtil.Map / Filter / Reduce work on arrays", function()
	local nums = { 1, 2, 3, 4, 5 }

	local doubled = TableUtil.Map(nums, function(n)
		return n * 2
	end)
	assert(doubled[1] == 2 and doubled[5] == 10, "Map result mismatch")

	local evens = TableUtil.Filter(nums, function(n)
		return n % 2 == 0
	end)
	assert(#evens == 2 and evens[1] == 2 and evens[2] == 4, "Filter result mismatch")

	local sum = TableUtil.Reduce(nums, function(acc, n)
		return acc + n
	end, 0)
	assert(sum == 15, "Reduce result mismatch")
end)

TestRunner.Test("TableUtil.Reconcile adds missing keys without dropping extras", function()
	local template = { kills = 0, deaths = 0 }
	local data = { kills = 10, extra = "keep me" }

	local result = TableUtil.Reconcile(data, template)

	assert(result.kills == 10 and result.deaths == 0 and result.extra == "keep me", "Reconcile result mismatch")
end)

TestRunner.Test("TableUtil.Copy(deep) does not alias nested tables", function()
	local original = { a = { b = 1 } }
	local copy = TableUtil.Copy(original, true)
	copy.a.b = 2

	assert(original.a.b == 1, "deep copy should not affect the original table")
end)

--------------------------------------------------
-- Util: Option
--------------------------------------------------

TestRunner.Test("Option.Wrap distinguishes Some and None", function()
	assert(Option.Wrap(nil):IsNone(), "expected None for a nil value")
	assert(Option.Wrap(5):IsSome(), "expected Some for a non-nil value")
	assert(Option.Wrap(5):Unwrap() == 5, "expected Unwrap to return the wrapped value")
end)

TestRunner.Test("Option:UnwrapOr and :Match behave correctly", function()
	assert(Option.None:UnwrapOr(42) == 42, "expected the default value from None")

	local matched = Option.Some(7):Match({
		Some = function(v)
			return v * 2
		end,
		None = function()
			return -1
		end,
	})

	assert(matched == 14, "expected the Some branch to run")
end)

--------------------------------------------------
-- Util: EnumList
--------------------------------------------------

TestRunner.Test("EnumList creates comparable, named items", function()
	local Direction = EnumList.new("Direction", { "North", "South" })

	assert(Direction.North.Name == "North", "expected the Name field to be set")
	assert(Direction.North.Value == 1, "expected the first item to have Value 1")
	assert(Direction:BelongsTo(Direction.North), "expected BelongsTo to recognize its own item")
	assert(Direction:FromName("South") == Direction.South, "expected FromName lookup to match")
	assert(Direction:FromValue(1) == Direction.North, "expected FromValue lookup to match")
end)

return TestRunner.RunAll()
