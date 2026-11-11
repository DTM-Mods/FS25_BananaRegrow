"""Offline test of the research tools (brProbe / brTrace) on Lua 5.1 with a fake DLC environment.

Checks that brProbe finds the DLC classes in the real global table, and that brTrace logs calls with arguments and
return values, respects the per-function limit and restores every function afterwards.

Usage: python tools/test/run_probe_stub.py
"""
import sys
from pathlib import Path

from lupa import lua51

MOD_DIR = Path(__file__).resolve().parent.parent.parent

SCENARIO = r"""
PRINTED = {}
print = function(s) PRINTED[#PRINTED + 1] = s end
function Class(members, baseClass)
    if baseClass ~= nil then setmetatable(members, {__index = baseClass}) end
    return {__index = members}
end
LISTENER = nil
function addModEventListener(l) LISTENER = l end
CONSOLE = {}
function addConsoleCommand(name, desc, fn, target) CONSOLE[name] = function() return target[fn](target) end end
function removeConsoleCommand(name) CONSOLE[name] = nil end

-- fake DLC environment in the global table
BananaRailSystemFake = {}
local mt = Class(BananaRailSystemFake)
function BananaRailSystemFake:addBunch(farmId, x, y, z, liters) self.bunches[#self.bunches + 1] = {farmId, liters}; return #self.bunches end
function BananaRailSystemFake:getNumBunches() return #self.bunches end
pdlc_beansAndAlpacasPack = {BananaRailSystem = BananaRailSystemFake, HandToolBananaKnife = {harvest = function(self, a) return a * 2 end},
                            BananaBunchSpawnEvent = {readStream = function() end, writeStream = function() end, new = function() end}}
rail = setmetatable({bunches = {}, workerManager = {maxNumWorkers = 20}}, mt)
g_currentMission = {bananaRailSystem = rail, placeableSystem = {placeables = {}}, vineSystem = {nodes = {}}}
g_localPlayer = nil
"""

CHECKS = r"""
local function check(c, m) if not c then error("CHECK FAILED: " .. m, 2) end end
LISTENER:loadMap()
check(CONSOLE.brProbe ~= nil and CONSOLE.brTrace ~= nil, "console commands registered")
CONSOLE.brProbe()
local text = table.concat(PRINTED, "\n")
check(string.find(text, "class BananaRailSystem %(2 functions%): addBunch, getNumBunches"), "probe lists the rail class functions")
check(string.find(text, "BananaBunchSpawnEvent %[EVENT%]"), "probe marks events")
check(string.find(text, "bananaRailSystem functions: addBunch, getNumBunches"), "probe lists the live rail object's functions")

PRINTED = {}
local original = BananaRailSystemFake.addBunch
CONSOLE.brTrace()
check(BananaRailSystemFake.addBunch ~= original, "trace wraps class functions")
for i = 1, 6 do rail:addBunch(5, 1.5, 2, 3, 37.5) end
check(pdlc_beansAndAlpacasPack.HandToolBananaKnife.harvest(nil, 21) == 42, "wrapped function still returns its result")
CONSOLE.brTrace()
check(BananaRailSystemFake.addBunch == original, "trace off restores the functions")
check(rail:getNumBunches() == 6, "calls went through to the originals")
local calls, results = 0, 0
for _, l in ipairs(PRINTED) do
    if string.find(l, "-> BananaRailSystem.addBunch(", 1, true) then calls = calls + 1 end
    if string.find(l, "<- BananaRailSystem.addBunch = ", 1, true) then results = results + 1 end
end
check(calls == 4 and results == 4, "4 calls logged (limit), got " .. calls .. "/" .. results)
check(string.find(table.concat(PRINTED, "\n"), "5, 1.500, 2, 3, 37.500", 1, true), "arguments logged")
check(string.find(table.concat(PRINTED, "\n"), "BananaRailSystem.addBunch x6", 1, true), "summary counts all calls")
io.write("ALL PROBE CHECKS PASSED\n")
"""


def main():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SCENARIO)
    lua.execute((MOD_DIR / "scripts" / "BananaRegrowProbe.lua").read_text(encoding="utf-8"))
    lua.execute(CHECKS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
