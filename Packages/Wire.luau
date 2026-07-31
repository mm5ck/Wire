--!strict

local Wire = {}

--------------------------------------------------
-- Types
--------------------------------------------------

local Comm = require(script.Parent.Comm)

export type Middleware = Comm.Middleware

export type ServiceDef = {
	Name: string,
	Client: { [any]: any }?,
	Dependencies: { string }?,
	Middleware: Middleware?,
	Critical: boolean?,
	RateLimit: number?,
	InvokeRateLimit: number?,
	WireInit: ((self: any) -> ())?,
	WireStart: ((self: any) -> ())?,
	[any]: any,
}

export type Service = ServiceDef

export type RegisterResult = {
	Module: ModuleScript,
	Success: boolean,
	Result: any,
	Error: any,
}

--------------------------------------------------
-- State
--------------------------------------------------

Wire.Version = "2.0.0"
Wire.Debug = false
Wire.HaltOnCriticalFailure = false -- if true, a critical service failure hard-errors instead of just rejecting the start Promise

Wire._Register = {} :: { [string]: Service }
Wire._Started = false
Wire._StartResolved = false

--------------------------------------------------
-- Promise
--------------------------------------------------

local Promise = require(script.Parent.Promise)

local StartPromise = Promise.new(function(resolve, reject)
	Wire._ResolveStart = resolve
	Wire._RejectStart = reject
end)

--------------------------------------------------
-- Debug
--------------------------------------------------

local function Log(...)
	if Wire.Debug then
		print("[Wire]", ...)
	end
end

local function Warn(...)
	warn("[Wire]", ...)
end

--------------------------------------------------
-- Configuration
--------------------------------------------------

function Wire.Configure(config: { Debug: boolean?, HaltOnCriticalFailure: boolean? })
	assert(type(config) == "table", "Wire.Configure expects a table")

	if config.Debug ~= nil then
		Wire.Debug = config.Debug
		Wire.Comm.Debug = config.Debug
	end

	if config.HaltOnCriticalFailure ~= nil then
		Wire.HaltOnCriticalFailure = config.HaltOnCriticalFailure
	end
end

--------------------------------------------------
-- Comm
--------------------------------------------------

Wire.Comm = Comm

Wire.CreateSignal = Comm.CreateSignal
Wire.CreateUnreliableSignal = Comm.CreateUnreliableSignal
Wire.CreateProperty = Comm.CreateProperty

Log("Comm loaded")

--------------------------------------------------
-- Service Creation
--------------------------------------------------

function Wire.CreateService(service: ServiceDef): Service
	assert(type(service) == "table", "Wire.CreateService expects a table")
	assert(type(service.Name) == "string", "Service requires a Name")
	assert(#service.Name > 0, "Service.Name must be a non-empty string")

	if service.Client ~= nil then
		assert(type(service.Client) == "table", "Service.Client must be a table")
	end

	if service.Dependencies ~= nil then
		assert(type(service.Dependencies) == "table", "Service.Dependencies must be a table of service names")
	end

	if Wire._Register[service.Name] then
		error(("[Wire] Duplicate service name: '%s' is already registered"):format(service.Name), 0)
	end

	Wire._Register[service.Name] = service

	Log("Registered service:", service.Name)

	return service
end

--------------------------------------------------
-- Service Access
--------------------------------------------------

function Wire.GetService(name: string): Service
	assert(type(name) == "string", "Wire.GetService expects a string")

	local service = Wire._Register[name]

	assert(service ~= nil, ("[Wire] No service named '%s' is registered"):format(name))

	return service
end

-- Returns a shallow copy of every registered service, keyed by name.
function Wire.GetServices(): { [string]: Service }
	local copy = {}
	for name, service in pairs(Wire._Register) do
		copy[name] = service
	end
	return copy
end

-- Removes a registered service. Only valid before Wire.Start().
function Wire.Unregister(name: string): boolean
	assert(type(name) == "string", "Wire.Unregister expects a string")
	assert(not Wire._Started, "Cannot unregister after Wire.Start()")

	if Wire._Register[name] then
		Wire._Register[name] = nil
		Log("Unregistered service:", name)
		return true
	end

	return false
end

--------------------------------------------------
-- Register Modules
--------------------------------------------------

function Wire.Register(folder: Instance, recursive: boolean?): { RegisterResult }
	assert(typeof(folder) == "Instance", "Wire.Register expects an Instance (folder)")
	assert(not Wire._Started, "Cannot register after Wire.Start()")

	Log("Registering folder:", folder:GetFullName())

	local results: { RegisterResult } = {}

	local function registerFolder(target: Instance)
		for _, module in ipairs(target:GetChildren()) do
			if module:IsA("ModuleScript") then
				Log("Requiring module:", module.Name)

				local success, result = pcall(require, module)

				table.insert(results, {
					Module = module,
					Success = success,
					Result = success and result or nil,
					Error = (not success) and result or nil,
				})

				if success then
					Log("Loaded:", module.Name)
				else
					Warn("Failed loading:", module.Name, result)
				end
			elseif recursive and module:IsA("Folder") then
				registerFolder(module)
			end
		end
	end

	registerFolder(folder)

	Log("Folder loaded:", #results, "modules")

	return results
end

--------------------------------------------------
-- Dependency ordering
--------------------------------------------------

-- Kahn/DFS topological sort over Dependencies. Returns (order, nil) on
-- success, or (nil, errorMessage) if a cycle or unknown dependency exists.
local function TopoSort(register: { [string]: Service }): ({ string }?, string?)
	local order: { string } = {}
	local state: { [string]: "Visiting" | "Done" } = {}
	local errorMsg: string? = nil

	local function visit(name: string, stack: { string })
		if errorMsg then
			return
		end

		if state[name] == "Done" then
			return
		end

		if state[name] == "Visiting" then
			errorMsg = ("Circular dependency detected: %s -> %s"):format(table.concat(stack, " -> "), name)
			return
		end

		local service = register[name]

		if not service then
			errorMsg = ("Service '%s' declares a dependency on unknown service '%s'"):format(
				stack[#stack] or "?",
				name
			)
			return
		end

		state[name] = "Visiting"
		table.insert(stack, name)

		if type(service.Dependencies) == "table" then
			for _, dep in ipairs(service.Dependencies) do
				visit(dep, stack)
				if errorMsg then
					return
				end
			end
		end

		table.remove(stack)
		state[name] = "Done"
		table.insert(order, name)
	end

	for name in pairs(register) do
		visit(name, {})
		if errorMsg then
			return nil, errorMsg
		end
	end

	return order, nil
end

--------------------------------------------------
-- Start Framework
--------------------------------------------------

local function Fail(message: string)
	if not Wire._StartResolved then
		Wire._StartResolved = true
		Wire._RejectStart(message)
	end

	if Wire.HaltOnCriticalFailure then
		error("[Wire] " .. message, 0)
	else
		Warn(message)
	end

	return Wire.OnStart()
end

function Wire.Start()
	if Wire._Started then
		Warn("Start called twice")
		return Wire.OnStart()
	end

	Wire._Started = true

	local amount = 0
	for _ in pairs(Wire._Register) do
		amount += 1
	end

	if amount == 0 then
		Warn("No services registered")

		Wire._ResolveStart(Wire)
		Wire._StartResolved = true

		return Wire.OnStart()
	end

	local order, depErr = TopoSort(Wire._Register)

	if not order then
		return Fail("Dependency resolution failed: " .. (depErr :: string))
	end

	Log("Starting", amount, "services in dependency order:", table.concat(order, ", "))

	--------------------------------------------------
	-- Bind Client remotes (before Init, so services can
	-- use their own Signals/Properties inside WireInit)
	--------------------------------------------------

	for _, name in ipairs(order) do
		local service = Wire._Register[name]

		if type(service.Client) == "table" then
			local ok, err = pcall(Comm.WrapService, name, service.Client, {
				Middleware = service.Middleware,
				RateLimit = service.RateLimit,
				InvokeRateLimit = service.InvokeRateLimit,
			})

			if not ok then
				Warn("Failed to bind Client remotes for", name, ":", err)
			end
		end
	end

	local criticalFailure: string? = nil

	--------------------------------------------------
	-- Init
	--------------------------------------------------

	local initialized = 0

	for _, name in ipairs(order) do
		local service = Wire._Register[name]

		if type(service.WireInit) == "function" then
			Log("Initializing:", name)

			local success, err = xpcall(function()
				service:WireInit()
			end, debug.traceback)

			if success then
				initialized += 1
				Log("Initialized:", name)
			else
				Warn("Init failed:", name, err)

				if service.Critical and not criticalFailure then
					criticalFailure = ("Critical service '%s' failed WireInit: %s"):format(name, tostring(err))
				end
			end
		end
	end

	Log("Initialized", initialized, "/", amount)

	if criticalFailure then
		return Fail(criticalFailure)
	end

	--------------------------------------------------
	-- Start Services
	--------------------------------------------------

	local started = 0

	for _, name in ipairs(order) do
		local service = Wire._Register[name]

		if type(service.WireStart) == "function" then
			Log("Starting:", name)

			local success, err = xpcall(function()
				service:WireStart()
			end, debug.traceback)

			if success then
				started += 1
				Log("Started:", name)
			else
				Warn("Start failed:", name, err)

				if service.Critical and not criticalFailure then
					criticalFailure = ("Critical service '%s' failed WireStart: %s"):format(name, tostring(err))
				end
			end
		end
	end

	Log("Started", started, "/", amount)

	if criticalFailure then
		return Fail(criticalFailure)
	end

	Log("Wire startup complete ✓")

	if not Wire._StartResolved then
		Wire._StartResolved = true
		Wire._ResolveStart(Wire)
	end

	return Wire.OnStart()
end

--------------------------------------------------
-- Await Startup
--------------------------------------------------

function Wire.OnStart()
	return StartPromise
end

return Wire
