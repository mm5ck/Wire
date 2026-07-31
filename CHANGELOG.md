# Changelog

## 2.0.0

Rewrite on top of the original [mm5ck/Wire](https://github.com/mm5ck/Wire) v1.1.1, addressing the gaps identified when comparing it against Knit. Everything stays pure Luau for Roblox — **no Wally, no third-party packages, nothing outside the engine's own APIs** (Attributes, RemoteEvent/RemoteFunction/UnreliableRemoteEvent, Instance).

### Added
- **Typed `Client` tables** on services (`Wire.CreateService({ Client = { ... } })`). Methods, `Wire.CreateSignal()`, `Wire.CreateUnreliableSignal()`, and `Wire.CreateProperty(initial)` are auto-bound to real Remotes by `Comm.WrapService` — no more manually matching string names between `Comm.On` calls on the server and `Comm.FireServer` calls on the client.
- **`Comm.BuildClient(serviceName)`** — client-side counterpart that discovers a service's Remotes (via a `WireKind` Attribute set on each Remote) and returns a ready-to-use proxy: `proxy:Method(...)`, `proxy.SomeSignal:Connect(fn)`, `proxy.SomeProperty:Get()`.
- **Dependency ordering**: `Wire.CreateService({ Dependencies = { "OtherService" } })`. Services are initialized in topological order; circular or unknown dependencies are detected up front with a clear error instead of silently racing.
- **Middleware**: per-service `Middleware = { Inbound = {...}, Outbound = {...} }`, run for every wrapped Client method/Signal call. A middleware fn can mutate the args table and return `false` to drop the call.
- **`Wire.Configure({ Debug = bool, HaltOnCriticalFailure = bool })`** — central place to toggle logging and startup behaviour instead of poking module fields directly.
- **`Wire.GetServices()`**, **`Wire.Unregister(name)`**, and `Wire.Register()` now returns a `{ Module, Success, Result, Error }[]` report instead of nothing.
- **`Comm.Destroy(serviceName)`** — tears down every Remote created for a service (useful for hot-reload/testing).
- **`Promise.allSettled`** for "run everything, tell me what failed" flows.
- Exported Luau types (`ServiceDef`, `Service`, `Middleware`, `RegisterResult`, ...) for editor autocomplete and type-checking.
- A small, dependency-free test runner (`Tests/TestRunner.luau`) plus a real test suite (`Tests/Wire.spec.luau`) covering Promise, dependency ordering, circular-dependency detection, `Wire.Register`, and the new Comm signal/property wrapping — no TestEZ, no Wally.
- `LICENSE` (MIT) instead of a one-line README disclaimer.

### Changed
- **`Wire.Debug` / `Comm.Debug` now default to `false`** (was `true`) — no console spam in production by default.
- **Critical service failures no longer hard-crash the calling script.** `Wire.Start()` always returns the start Promise; on a critical failure it now *rejects* that Promise (so `Wire.Start():catch(warn)` works like in Knit) instead of unconditionally calling `error()`. The old hard-crash behaviour is still available via `Wire.Configure({ HaltOnCriticalFailure = true })`.
- Service init/start order is now deterministic (topological, falling back to registration order) instead of relying on Lua's unspecified `pairs()` iteration order.
- `Wire.Version` bumped to `2.0.0` and is now the single source of truth (no more README/code version mismatch).
- Internal `Comm` container/cache logic reworked to support per-service namespacing without breaking the existing low-level API.

### Unchanged (fully backwards compatible)
- `Comm.On` / `FireClient` / `FireAll` / `FireServer` / `SetFunction` / `InvokeServer` / `InvokeClient` / `Event` / `Function` — the original string-keyed low-level API still works exactly as before, for cases where a full service `Client` table is overkill.
- Per-player rate limiting, `InvokeClient` timeout, handler error isolation.
- Two-phase service lifecycle (`WireInit` / `WireStart`).

### Known limitations (intentionally out of scope)
- `Property` replicates one value to *all* clients; there's no per-player property override (Knit's `RemoteProperty:SetFor(player, value)`). Adding it is straightforward if needed, but it wasn't in the original Wire and was left out to keep the diff focused.
- No package-manager distribution (by request — this stays a manual drop-in, Rojo-project-optional, copy-paste module).
