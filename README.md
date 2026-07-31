# Thread

A lightweight Roblox framework for building scalable games with a clean **Service Architecture**, a **typed Communication System**, and a small **Promise** implementation for startup sequencing.

Based on the previous model "Wire v1.1.1. by me" This version adds typed service `Client` tables, Signals/Properties (with per-player overrides), middleware, dependency ordering, a richer Promise, and hand-written equivalents of the most-used [RbxUtil](https://github.com/Sleitnick/RbxUtil) modules (Signal, Trove, TableUtil, Option, EnumList) — while staying **100% Roblox-native**: no Wally, no package manager, no third-party code. Every file here is plain `.luau`.

## Installation

Copy the whole `Packages/` folder (including the `Util/` subfolder) into `ReplicatedStorage/Packages/` (via Studio or a Rojo project — Rojo is optional, plain drag-and-drop into Studio works just as well since nothing here depends on it).

```
ReplicatedStorage
└── Packages
    ├── Thread.luau
    ├── Channel.luau
    ├── Promise.luau
    └── Util
        ├── Signal.luau
        ├── Trove.luau
        ├── TableUtil.luau
        ├── Option.luau
        └── EnumList.luau
```

Services live in `ServerScriptService.Services`, controllers in `StarterPlayer.StarterPlayerScripts.Controllers` (or wherever you like — `Thread.Register` just points at a folder).

## Quick Start

```lua
-- ServerScriptService/Server.server.lua
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)

Thread.Register(game:GetService("ServerScriptService").Services)
Thread.Start():catch(warn)
```

```lua
-- StarterPlayerScripts/Client.client.lua
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)

Thread.Register(script.Parent.Controllers)
Thread.Start():catch(warn)
```

## A Service With a Typed Client

```lua
-- ServerScriptService/Services/MoneyService.luau
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)

local MoneyService = Thread.CreateService({
    Name = "MoneyService",
    Client = {
        -- exposed to every client as a method
        GetMoney = function(self, player)
            return self.Server:GetMoney(player)
        end,

        -- push-only event, server -> client
        MoneyChanged = Thread.CreateSignal(),

        -- replicated value, auto-synced to all clients
        Jackpot = Thread.CreateProperty(0),
    },
})

local balances = {}

function MoneyService:GetMoney(player)
    return balances[player] or 0
end

function MoneyService:GiveMoney(player, amount)
    balances[player] = self:GetMoney(player) + amount
    self.Client.MoneyChanged:Fire(player, balances[player])
end

function MoneyService:ThreadInit()
    -- Client remotes are already bound at this point.
end

return MoneyService
```

```lua
-- StarterPlayerScripts/Controllers/MoneyController.luau
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)
local Channel = Thread.Channel

local MoneyService = Channel.BuildClient("MoneyService")

MoneyService.MoneyChanged:Connect(function(newBalance)
    print("New balance:", newBalance)
end)

MoneyService.Jackpot:Observe(function(value)
    print("Jackpot is now", value)
end)

print("Current money:", MoneyService:GetMoney())
```

No string-matching between server and client — the shape of `Client` on the server *is* the API the client gets back from `Channel.BuildClient`.

### Per-Player Property Overrides

A `Property` normally replicates one value to every client, but you can override it for a single player (e.g. a personalized quest state) without disturbing everyone else's value:

```lua
function MoneyService:GiveVipBonus(player)
    self.Client.Jackpot:SetFor(player, 9999) -- only this player sees 9999
end

function MoneyService:ClearVipBonus(player)
    self.Client.Jackpot:ClearFor(player) -- reverts to the shared default
end
```

`Property:Set(value)` still broadcasts the shared default to everyone else, skipping any player with an active override.

## Dependencies Between Services

```lua
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)

Thread.CreateService({
    Name = "InventoryService",
    Dependencies = { "DataService" }, -- DataService's ThreadInit always runs first
    ThreadInit = function(self)
        self.Data = Thread.GetService("DataService")
    end,
})
```

Circular or unknown dependencies are caught before any service runs, with a clear error identifying the cycle. This never silently races.

## Middleware

```lua
Thread.CreateService({
    Name = "ShopService",
    Client = {
        Purchase = function(self, player, itemId) ... end,
    },
    Middleware = {
        Inbound = {
            function(player, args)
                if typeof(args[1]) ~= "string" then
                    return false -- drop the call
                end
                return true
            end,
        },
    },
})
```

## Critical Services & Startup Failure

```lua
Thread.CreateService({
    Name = "DataService",
    Critical = true, -- a failed ThreadInit/ThreadStart here rejects Thread.Start()
})

Thread.Start():catch(function(err)
    warn("Startup failed:", err)
    -- e.g. kick all players, since data can't load
end)
```

By default a critical failure only rejects the start `Promise` — it does **not** crash the calling script. If you want the old hard-crash-on-critical-failure behaviour, opt in explicitly:

```lua
Thread.Configure({ HaltOnCriticalFailure = true })
```

## Configuration

```lua
Thread.Configure({
    Debug = true, -- verbose [Thread]/[Channel] logging, off by default
    HaltOnCriticalFailure = false,
})
```

## Low-Level Channel API (unchanged, still available)

For quick one-off networking that doesn't need a full service `Client` table:

```lua
-- server
Channel.On("PlayerJumped", function(player)
    print(player.Name, "jumped")
end)

-- client
Channel.FireServer("PlayerJumped")
```

`Channel.FireClient`, `Channel.FireAll`, `Channel.SetFunction`, `Channel.InvokeServer`, `Channel.InvokeClient`, `Channel.Event`, `Channel.Function` all work exactly as in the original Wire v1.1.1.

## Promise Extras

Beyond `andThen`/`catch`/`finally`/`await`/`all`/`allSettled`:

```lua
local Promise = require(game.ReplicatedStorage.Packages.Promise)

-- First to settle wins:
Promise.race({ promiseA, promiseB }):andThen(print)

-- Resolve once N of many resolve:
Promise.some({ p1, p2, p3 }, 2):andThen(print)

-- Plain delay, useful in chains:
Promise.delay(1):andThen(function() print("1 second later") end)

-- Retry a flaky operation:
Promise.retry(function()
    return Promise.new(function(resolve, reject)
        local ok, result = pcall(dataStore.GetAsync, dataStore, "key")
        if ok then resolve(result) else reject(result) end
    end)
end, 5):andThen(print):catch(warn)

-- Reject if it takes too long:
someSlowPromise:timeout(5):catch(warn)

-- Wrap any signal-like object (RBXScriptSignal or Thread.Signal) into a Promise:
Promise.fromEvent(player.CharacterAdded):andThen(function(character)
    print(character.Name, "spawned")
end)
```

## Utilities (`Thread.Signal`, `Thread.Trove`, `Thread.TableUtil`, `Thread.Option`, `Thread.EnumList`)

Hand-written equivalents of the most commonly used [RbxUtil](https://github.com/Sleitnick/RbxUtil) modules — the same collection Knit itself depends on — each requirable standalone from `Packages/Util/`, or via `Thread.Signal` etc. after requiring `Thread`.

```lua
local Thread = require(game.ReplicatedStorage.Packages.Thread)

-- Signal: fast pub-sub, independent of BindableEvent
local mySignal = Thread.Signal.new()
mySignal:Connect(function(msg) print(msg) end)
mySignal:Fire("hello")

-- Trove: cleanup helper
local trove = Thread.Trove.new()
trove:Add(someInstance)
trove:Connect(player.CharacterAdded, onCharacterAdded)
trove:Destroy() -- destroys someInstance and disconnects the connection

-- TableUtil: table helpers
local doubled = Thread.TableUtil.Map({ 1, 2, 3 }, function(n) return n * 2 end)
local data = Thread.TableUtil.Reconcile(savedData, templateData)

-- Option: explicit nil-handling
local result = Thread.Option.Wrap(dataStore:GetAsync(key))
result:Match({
    Some = function(v) print("Got", v) end,
    None = function() print("Nothing stored") end,
})

-- EnumList: custom, comparable enums
local Direction = Thread.EnumList.new("Direction", { "North", "South", "East", "West" })
print(Direction.North.Name, Direction.North.Value)
```

## Testing

There's a small, dependency-free test runner under `Tests/` (no TestEZ, no Wally):

1. Copy the `Thread/` and `Tests/` folders into your Rojo project (or Studio, as siblings) so `Tests/Thread.spec.luau` can reach `../Packages`.
2. In Studio, start a Play/Test session (so `RunService:IsServer()` is server-true) and paste into the Command Bar:
   ```lua
   require(game.ServerScriptService.Tests["Thread.spec"])
   ```
   (adjust the path to wherever you placed `Tests/`)
3. Read the Output window — `[PASS]` / `[FAIL]` per test, with a summary line at the end.

## API Reference

### Thread
| Function | Description |
|---|---|
| `Thread.CreateService(def)` | Registers a service. `def` may include `Client`, `Dependencies`, `Middleware`, `Critical`, `RateLimit`, `InvokeRateLimit`, `ThreadInit`, `ThreadStart`. |
| `Thread.GetService(name)` | Returns a registered service or errors. |
| `Thread.GetServices()` | Returns a copy of the full service registry. |
| `Thread.Unregister(name)` | Removes a service before `Start()`. |
| `Thread.Register(folder, recursive?)` | Requires every `ModuleScript` under `folder`; returns `{ Module, Success, Result, Error }[]`. |
| `Thread.Start()` | Binds Client remotes, runs `ThreadInit` then `ThreadStart` in dependency order. Returns the start `Promise`. |
| `Thread.OnStart()` | Returns the start `Promise` (resolves/rejects once, safe to call any time). |
| `Thread.Configure({ Debug, HaltOnCriticalFailure })` | Central configuration. |
| `Thread.CreateSignal()` / `Thread.CreateUnreliableSignal()` / `Thread.CreateProperty(v)` | Markers for use inside a service's `Client` table. |

### Channel
| Function | Description |
|---|---|
| `Channel.WrapService(name, clientTable, opts?)` | Server-only. Binds a `Client` table to real Remotes. Called automatically by `Thread.Start()` for services with a `Client` field. |
| `Channel.BuildClient(name, timeout?)` | Client-only. Returns a proxy for a wrapped service. |
| `Channel.Destroy(name)` | Removes every Remote created for a service. |
| `Channel.On/FireClient/FireAll/FireServer/SetFunction/InvokeServer/InvokeClient/Event/Function` | Low-level, string-keyed API (unchanged from v1.x). |
| `Channel.Configure({...})` | Bulk-set `Channel.Debug`, `Channel.DefaultRateLimit`, etc. |

### Property (returned in place of a `Thread.CreateProperty()` marker)
| Method | Where | Description |
|---|---|---|
| `:Get()` | both | Client: last received value. Server: the shared default. |
| `:Set(value)` | server | Sets the default and broadcasts to every client without an override. |
| `:SetFor(player, value)` | server | Sets a value visible only to `player`. |
| `:GetFor(player)` | server | Reads `player`'s override, or the default if none. |
| `:ClearFor(player)` | server | Removes `player`'s override. |
| `:Observe(fn)` | client | Calls `fn` immediately and on every change; returns a `{Disconnect}` handle. |

### Promise
Standard `andThen` / `catch` / `finally` / `await` / `getState`, plus: `Promise.resolve`, `Promise.reject`, `Promise.all`, `Promise.allSettled`, `Promise.race`, `Promise.some(promises, count)`, `Promise.delay(seconds)`, `Promise.retry(fn, attempts)`, `Promise.fromEvent(signal, predicate?)`, and the instance method `Promise:timeout(seconds, err?)`.

### Util modules (`Packages/Util/`, also on `Thread.*`)
| Module | Highlights |
|---|---|
| `Signal` | `.new()`, `.Wrap(rbxSignal)`, `.Is(obj)`, `:Connect`, `:Once`, `:Fire`, `:Wait`, `:DisconnectAll`, `:GetConnections`, `:Destroy` |
| `Trove` | `.new()`, `:Add`, `:Remove`, `:Connect`, `:Clone`, `:Construct`, `:Clean`, `:Destroy`, `:Extend`, `:AttachToInstance` |
| `TableUtil` | `Copy`, `Sync`, `Reconcile`, `Lock`, `SwapRemove`, `SwapRemoveFirstValue`, `Reverse`, `Shuffle`, `Map`, `Filter`, `Reduce`, `Find`, `Every`, `Some`, `Keys`, `Values`, `IsEmpty`, `Length` |
| `Option` | `Some`, `Wrap`, `None`, `Is`, `:Match`, `:Unwrap`, `:Expect`, `:UnwrapOr`, `:UnwrapOrElse`, `:And`, `:AndThen`, `:Or`, `:OrElse`, `:Contains` |
| `EnumList` | `.new(name, {...})`, `:BelongsTo`, `:GetEnumItems`, `:GetName`, `:FromName`, `:FromValue` |

See [CHANGELOG.md](CHANGELOG.md) for the full list of changes versus the original v1.1.1.
