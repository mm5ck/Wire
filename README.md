# Wire

A lightweight Roblox framework for building scalable games with a clean **Service Architecture**, a **typed Communication System**, and a small **Promise** implementation for startup sequencing.

Based on [mm5ck/Wire](https://github.com/mm5ck/Wire) v1.1.1. This version adds typed service `Client` tables, Signals/Properties, middleware, and dependency ordering — while staying **100% Roblox-native**: no Wally, no package manager, no third-party code. Just three `.luau` files.

## Installation

Copy `Packages/Wire.luau`, `Packages/Comm.luau`, and `Packages/Promise.luau` into `ReplicatedStorage/Packages/` (via Studio or a Rojo project — Rojo is optional, plain drag-and-drop into Studio works just as well since nothing here depends on it).

```
ReplicatedStorage
└── Packages
    ├── Wire.luau
    ├── Comm.luau
    └── Promise.luau
```

Services live in `ServerScriptService.Services`, controllers in `StarterPlayer.StarterPlayerScripts.Controllers` (or wherever you like — `Wire.Register` just points at a folder).

## Quick Start

```lua
-- ServerScriptService/Server.server.lua
local Wire = require(game:GetService("ReplicatedStorage").Packages.Wire)

Wire.Register(game:GetService("ServerScriptService").Services)
Wire.Start():catch(warn)
```

```lua
-- StarterPlayerScripts/Client.client.lua
local Wire = require(game:GetService("ReplicatedStorage").Packages.Wire)

Wire.Register(script.Parent.Controllers)
Wire.Start():catch(warn)
```

## A Service With a Typed Client

```lua
-- ServerScriptService/Services/MoneyService.luau
local Wire = require(game:GetService("ReplicatedStorage").Packages.Wire)

local MoneyService = Wire.CreateService({
    Name = "MoneyService",
    Client = {
        -- exposed to every client as a method
        GetMoney = function(self, player)
            return self.Server:GetMoney(player)
        end,

        -- push-only event, server -> client
        MoneyChanged = Wire.CreateSignal(),

        -- replicated value, auto-synced to all clients
        Jackpot = Wire.CreateProperty(0),
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

function MoneyService:WireInit()
    -- Client remotes are already bound at this point.
end

return MoneyService
```

```lua
-- StarterPlayerScripts/Controllers/MoneyController.luau
local Wire = require(game:GetService("ReplicatedStorage").Packages.Wire)
local Comm = Wire.Comm

local MoneyService = Comm.BuildClient("MoneyService")

MoneyService.MoneyChanged:Connect(function(newBalance)
    print("New balance:", newBalance)
end)

MoneyService.Jackpot:Observe(function(value)
    print("Jackpot is now", value)
end)

print("Current money:", MoneyService:GetMoney())
```

No string-matching between server and client — the shape of `Client` on the server *is* the API the client gets back from `Comm.BuildClient`.

## Dependencies Between Services

```lua
local Wire = require(game:GetService("ReplicatedStorage").Packages.Wire)

Wire.CreateService({
    Name = "InventoryService",
    Dependencies = { "DataService" }, -- DataService's WireInit always runs first
    WireInit = function(self)
        self.Data = Wire.GetService("DataService")
    end,
})
```

Circular or unknown dependencies are caught before any service runs, with a clear error identifying the cycle. This never silently races.

## Middleware

```lua
Wire.CreateService({
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
Wire.CreateService({
    Name = "DataService",
    Critical = true, -- a failed WireInit/WireStart here rejects Wire.Start()
})

Wire.Start():catch(function(err)
    warn("Startup failed:", err)
    -- e.g. kick all players, since data can't load
end)
```

By default a critical failure only rejects the start `Promise` — it does **not** crash the calling script. If you want the old hard-crash-on-critical-failure behaviour, opt in explicitly:

```lua
Wire.Configure({ HaltOnCriticalFailure = true })
```

## Configuration

```lua
Wire.Configure({
    Debug = true, -- verbose [Wire]/[Comm] logging, off by default
    HaltOnCriticalFailure = false,
})
```

## Low-Level Comm API (unchanged, still available)

For quick one-off networking that doesn't need a full service `Client` table:

```lua
-- server
Comm.On("PlayerJumped", function(player)
    print(player.Name, "jumped")
end)

-- client
Comm.FireServer("PlayerJumped")
```

`Comm.FireClient`, `Comm.FireAll`, `Comm.SetFunction`, `Comm.InvokeServer`, `Comm.InvokeClient`, `Comm.Event`, `Comm.Function` all work exactly as in the original Wire v1.1.1.

## Testing

There's a small, dependency-free test runner under `Tests/` (no TestEZ, no Wally):

1. Copy the `Wire/` and `Tests/` folders into your Rojo project (or Studio, as siblings) so `Tests/Wire.spec.luau` can reach `../Packages`.
2. In Studio, start a Play/Test session (so `RunService:IsServer()` is server-true) and paste into the Command Bar:
   ```lua
   require(game.ServerScriptService.Tests["Wire.spec"])
   ```
   (adjust the path to wherever you placed `Tests/`)
3. Read the Output window — `[PASS]` / `[FAIL]` per test, with a summary line at the end.

## API Reference

### Wire
| Function | Description |
|---|---|
| `Wire.CreateService(def)` | Registers a service. `def` may include `Client`, `Dependencies`, `Middleware`, `Critical`, `RateLimit`, `InvokeRateLimit`, `WireInit`, `WireStart`. |
| `Wire.GetService(name)` | Returns a registered service or errors. |
| `Wire.GetServices()` | Returns a copy of the full service registry. |
| `Wire.Unregister(name)` | Removes a service before `Start()`. |
| `Wire.Register(folder, recursive?)` | Requires every `ModuleScript` under `folder`; returns `{ Module, Success, Result, Error }[]`. |
| `Wire.Start()` | Binds Client remotes, runs `WireInit` then `WireStart` in dependency order. Returns the start `Promise`. |
| `Wire.OnStart()` | Returns the start `Promise` (resolves/rejects once, safe to call any time). |
| `Wire.Configure({ Debug, HaltOnCriticalFailure })` | Central configuration. |
| `Wire.CreateSignal()` / `Wire.CreateUnreliableSignal()` / `Wire.CreateProperty(v)` | Markers for use inside a service's `Client` table. |

### Comm
| Function | Description |
|---|---|
| `Comm.WrapService(name, clientTable, opts?)` | Server-only. Binds a `Client` table to real Remotes. Called automatically by `Wire.Start()` for services with a `Client` field. |
| `Comm.BuildClient(name, timeout?)` | Client-only. Returns a proxy for a wrapped service. |
| `Comm.Destroy(name)` | Removes every Remote created for a service. |
| `Comm.On/FireClient/FireAll/FireServer/SetFunction/InvokeServer/InvokeClient/Event/Function` | Low-level, string-keyed API (unchanged from v1.x). |
| `Comm.Configure({...})` | Bulk-set `Comm.Debug`, `Comm.DefaultRateLimit`, etc. |

See [CHANGELOG.md](CHANGELOG.md) for the full list of changes versus the original v1.1.1.
