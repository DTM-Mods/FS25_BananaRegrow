"""Offline test of brMenu (production menu buttons and hook chain) on Lua 5.1.

Builds a fake InGameMenuProductionFrame with a chain of Utils.appendedFunction / overwrittenFunction hooks, a production
page instance with a few buttons and a selected washing station, runs the console command and checks the log lines.

Usage: python tools/test/run_menu_stub.py
"""
import sys
from pathlib import Path

from lupa import lua51

MOD_DIR = Path(__file__).resolve().parent.parent.parent

SCENARIO = r"""
PRINTED = {}
print = function(s) PRINTED[#PRINTED + 1] = s end
LISTENER = nil
function addModEventListener(l) LISTENER = l end
CONSOLE = {}
function addConsoleCommand(name, desc, fn, target) CONSOLE[name] = function() return target[fn](target) end end
function removeConsoleCommand(name) CONSOLE[name] = nil end
Utils = {}
function Utils.appendedFunction(old, new) return function(...) old(...); new(...) end end
function Utils.overwrittenFunction(old, new) return function(self, ...) return new(self, old, ...) end end
InputAction = {MENU_EXTRA_1 = 101, MENU_ACTIVATE = 102}

InGameMenuProductionFrame = {POINTS_OWNED = 1}
function InGameMenuProductionFrame:updateMenuButtons() self.menuButtonInfo = {self.visitButtonInfo} end
function InGameMenuProductionFrame:onButtonToggleOutputMode() end
function InGameMenuProductionFrame:getSelectedProduction() return self.selectedProduction, self.selectedPoint end
local function dlcHook(frame) table.insert(frame.menuButtonInfo, frame.manageWorkersButtonInfo) end
InGameMenuProductionFrame.updateMenuButtons = Utils.appendedFunction(InGameMenuProductionFrame.updateMenuButtons, dlcHook)
InGameMenuProductionFrame.updateMenuButtons = Utils.appendedFunction(InGameMenuProductionFrame.updateMenuButtons, function() end)
InGameMenuProductionFrame.onButtonToggleOutputMode = Utils.overwrittenFunction(InGameMenuProductionFrame.onButtonToggleOutputMode, function(self, superFunc) end)

local washing = {typeName = "pdlc_beansAndAlpacasPack.bananaWashingStation", configFileNameClean = "bananaWashingStation",
                 ownerFarmId = 5, spec_productionPoint = {}, ["spec_pdlc_beansAndAlpacasPack.bananaWashingStation"] = {numWorkers = 0}}
function washing:getIsBananaWashingStation() return true end
local page = setmetatable({
    visitButtonInfo = {inputAction = InputAction.MENU_ACTIVATE, text = "Visit", callback = function() end},
    manageWorkersButtonInfo = {inputAction = InputAction.MENU_EXTRA_1, text = "Manage workers", callback = function() end},
    selectedProduction = {id = "bananaWashing"},
    selectedPoint = {owningPlaceable = washing, palletSpawner = {}},
    pointsSelector = {getState = function() return 1 end},
}, {__index = InGameMenuProductionFrame})
page:updateMenuButtons()
g_inGameMenu = {pageProduction = page}
g_currentMission = {missionInfo = {mapId = "FS25_NFMarsch4fach_oG.SampleModMap"}, placeableSystem = {placeables = {}}, vineSystem = {nodes = {}}}
"""

CHECKS = r"""
local result = CONSOLE.brMenu()
assert(string.find(result, "written", 1, true), "unexpected result " .. tostring(result))
local text = table.concat(PRINTED, "\n")
local function has(s) assert(string.find(text, s, 1, true), "missing in log: " .. s .. "\n" .. text) end
has("InGameMenuProductionFrame.updateMenuButtons")
has("upvalue old")            -- the hook chain is walked through the Utils closures
has("upvalue new")
has("button manageWorkersButtonInfo: text=\"Manage workers\" inputAction=MENU_EXTRA_1")
has("bottom bar now (2 buttons):")
has("2. [manageWorkersButtonInfo]")
has("points selector state: 1 (owned = 1)")
has("placeable pdlc_beansAndAlpacasPack.bananaWashingStation (bananaWashingStation) farm 5")
has("getIsBananaWashingStation")
has("spec_pdlc_beansAndAlpacasPack.bananaWashingStation fields: numWorkers=0")
has("menu probe end")

-- no production page: a clear message instead of an error
g_inGameMenu = {}
PRINTED = {}
result = CONSOLE.brMenu()
assert(string.find(result, "not found", 1, true), "expected 'not found', got " .. tostring(result))
return #PRINTED
"""


def main():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SCENARIO)
    source = (MOD_DIR / "scripts" / "BananaRegrowProbe.lua").read_text(encoding="utf-8")
    lua.execute(source)
    lua.execute("BananaRegrowProbe:loadMap()")
    n = lua.execute(CHECKS)
    lua.execute("BananaRegrowProbe:deleteMap()")
    assert lua.eval("CONSOLE.brMenu") is None, "brMenu not removed on deleteMap"
    print(f"menu probe OK ({n} lines in the no-page case)")
    print("\n".join(lua.eval("PRINTED").values()))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"FAILED: {e}")
