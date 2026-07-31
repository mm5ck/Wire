--!strict
--[[
	Minimal, dependency-free test runner for Roblox.

	No TestEZ, no Wally, nothing external - just plain Luau + assert/pcall.
	Meant to be required from a throwaway Script in Studio (e.g. pasted into
	the Command Bar, or a Script under ServerScriptService you delete again
	after running), never shipped with the game.

	Usage:
		local TestRunner = require(path.to.TestRunner)

		TestRunner.Test("adds numbers", function()
			assert(1 + 1 == 2, "math is broken")
		end)

		TestRunner.RunAll()
]]

local TestRunner = {}

export type TestCase = {
	Name: string,
	Fn: () -> (),
}

local tests: { TestCase } = {}

function TestRunner.Test(name: string, fn: () -> ())
	assert(type(name) == "string", "TestRunner.Test: name must be a string")
	assert(type(fn) == "function", "TestRunner.Test: fn must be a function")

	table.insert(tests, { Name = name, Fn = fn })
end

function TestRunner.RunAll(): (number, number)
	local passed, failed = 0, 0

	for _, test in ipairs(tests) do
		local ok, err = pcall(test.Fn)

		if ok then
			passed += 1
			print(("[PASS] %s"):format(test.Name))
		else
			failed += 1
			warn(("[FAIL] %s: %s"):format(test.Name, tostring(err)))
		end
	end

	print(("\n[TestRunner] Results: %d passed, %d failed (of %d)"):format(passed, failed, passed + failed))

	tests = {}

	return passed, failed
end

return TestRunner
