--!strict
--[[
	Test suite for Wire / Comm / Promise.

	No external test framework (no TestEZ, no Wally) - built on TestRunner.luau,
	which is nothing but pcall + assert. Run this from a server-side context in
	Roblox Studio: either paste the two lines below into the Command Bar while
	a Play/Run session is active, or drop a throwaway Script under
	ServerScriptService that requires this module, then delete the script again.

		local Wire = game:GetService("ReplicatedStorage").Packages.Wire
		require(Wire.Parent.Parent.Tests["Wire.spec"])

	Adjust the path to wherever you actually placed the Wire/ and Tests/
	folders in your Rojo/Studio hierarchy.
]]

local Packages = script.Parent.Parent.Packages

local Promise = require(Packages.Promise)
local Comm = require(Packages.Comm)
local WireModuleScript = Packages.Wire :: ModuleScript

local TestRunner = require(script.Parent.TestRunner)

-- Wire is a singleton module (keeps `_Started` state). To test dependency
-- ordering / start-failure behaviour in isolation, clone the ModuleScript so
-- each test gets its own fresh Wire instance. Comm/Promise are fine to share
-- since they don't carry a one-shot "already started" flag.
local function FreshWire()
	local clone = WireModuleScript:Clone()
	clone.Parent = WireModuleScript.Parent
	local wire = require(clone) :: any
	return wire, clone
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
-- Wire: basic registry behaviour
--------------------------------------------------

TestRunner.Test("Wire.CreateService rejects duplicate names", function()
	local wire = FreshWire()
	wire.CreateService({ Name = "Dup" })

	local ok = pcall(function()
		wire.CreateService({ Name = "Dup" })
	end)

	assert(not ok, "expected duplicate registration to error")
end)

TestRunner.Test("Wire.GetService throws for unknown service", function()
	local wire = FreshWire()
	local ok = pcall(function()
		wire.GetService("DoesNotExist")
	end)
	assert(not ok, "expected missing service lookup to error")
end)

TestRunner.Test("Wire.Unregister removes a pending service", function()
	local wire = FreshWire()
	wire.CreateService({ Name = "Temp" })
	assert(wire.Unregister("Temp") == true, "expected Unregister to succeed")
	assert(wire.Unregister("Temp") == false, "second Unregister should be a no-op returning false")
end)

--------------------------------------------------
-- Wire: dependency ordering
--------------------------------------------------

TestRunner.Test("Wire.Start initializes services in dependency order", function()
	local wire = FreshWire()
	local order = {}

	wire.CreateService({
		Name = "C",
		Dependencies = { "B" },
		WireInit = function()
			table.insert(order, "C")
		end,
	})

	wire.CreateService({
		Name = "A",
		WireInit = function()
			table.insert(order, "A")
		end,
	})

	wire.CreateService({
		Name = "B",
		Dependencies = { "A" },
		WireInit = function()
			table.insert(order, "B")
		end,
	})

	wire.Start():await()

	assert(table.concat(order, ",") == "A,B,C", "expected init order A,B,C, got " .. table.concat(order, ","))
end)

TestRunner.Test("Wire.Start rejects (without hard-erroring) on circular dependencies", function()
	local wire = FreshWire()

	wire.CreateService({ Name = "X", Dependencies = { "Y" } })
	wire.CreateService({ Name = "Y", Dependencies = { "X" } })

	-- HaltOnCriticalFailure defaults to false, so Start() itself must not throw.
	local startOk = pcall(function()
		wire.Start()
	end)
	assert(startOk, "Wire.Start() should not hard-error by default")

	local rejected = false
	wire.OnStart():catch(function()
		rejected = true
	end):await()

	assert(rejected, "expected the start Promise to reject on a circular dependency")
end)

--------------------------------------------------
-- Wire: Register()
--------------------------------------------------

TestRunner.Test("Wire.Register loads ModuleScripts and reports results", function()
	local wire = FreshWire()

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

	local results = wire.Register(folder)

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
-- Comm: service-scoped Signals & Properties
--------------------------------------------------

TestRunner.Test("Comm.WrapService creates a Method RemoteFunction", function()
	local serviceName = "SpecService_Method"
	local client = {
		Ping = function(_self, _player)
			return "pong"
		end,
	}

	Comm.WrapService(serviceName, client)

	local remote = game:GetService("ReplicatedStorage").WireComm.RemoteFunction:FindFirstChild(serviceName)
	assert(remote ~= nil, "expected namespace folder to exist")

	local pingRemote = remote:FindFirstChild("Ping")
	assert(pingRemote ~= nil, "expected Ping RemoteFunction to exist")
	assert(pingRemote:GetAttribute("WireKind") == "Method", "expected WireKind attribute to be Method")

	Comm.Destroy(serviceName)
end)

TestRunner.Test("Comm.WrapService turns a Property marker into a working Property", function()
	local serviceName = "SpecService_Property"
	local client = {
		Score = Comm.CreateProperty(0),
	}

	Comm.WrapService(serviceName, client)

	assert(client.Score:Get() == 0, "expected initial value 0")

	client.Score:Set(10)
	assert(client.Score:Get() == 10, "expected value 10 after Set")

	Comm.Destroy(serviceName)
end)

TestRunner.Test("Comm.Destroy removes a service's remotes", function()
	local serviceName = "SpecService_Destroy"
	Comm.WrapService(serviceName, {
		Foo = function() end,
	})

	local before = game:GetService("ReplicatedStorage").WireComm.RemoteFunction:FindFirstChild(serviceName)
	assert(before ~= nil, "expected namespace folder to exist before Destroy")

	Comm.Destroy(serviceName)

	local after = game:GetService("ReplicatedStorage").WireComm.RemoteFunction:FindFirstChild(serviceName)
	assert(after == nil, "expected namespace folder to be gone after Destroy")
end)

return TestRunner.RunAll()
