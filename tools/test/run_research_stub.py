"""Offline test of the multiplayer side of the research tools (brRipen, brProbe/brTrace relayed from the server).

Reuses the engine stubs of run_stub.py. Checks: brRipen in single player makes only the own farm's plants within the
radius ripe and refreshes them; in multiplayer it runs on the server for admins only; the server's trace and probe
lines come back to the client as "[server]" lines; long lines are split and nothing is lost.

Usage: python tools/test/run_research_stub.py
"""
import sys
from pathlib import Path

from lupa import lua51

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_stub  # noqa: E402

MOD_DIR = run_stub.MOD_DIR

SETUP = r"""
LISTENERS = {}
function addModEventListener(l) LISTENERS[#LISTENERS + 1] = l end
function addConsoleCommand(name, desc, fn, target) CONSOLE[name] = function(...) return target[fn](target, ...) end end
PRINTED = {}
print = function(s) PRINTED[#PRINTED + 1] = tostring(s) end
STRINGS = true
function streamWriteString(id, v) table.insert(STREAMS[id], v) end
function streamReadString(id) return table.remove(STREAMS[id], 1) end
"""

CHECKS = r"""
local function check(c, m) if not c then error("CHECK FAILED: " .. m, 2) end io.write("ok  " .. m .. "\n") end
local function printed(pattern)
    for _, l in ipairs(PRINTED) do if string.find(l, pattern, 1, true) then return l end end
end
for _, l in ipairs(LISTENERS) do if l.loadMap then l:loadMap("map") end end
check(CONSOLE.brRipen ~= nil, "brRipen registered")

-- R (farm 1): 4 plants at z=800, x = 0, 3, 6, 9; Q (farm 2) next to it at z=802
local R = newDlcOrchard("R.xml", 1, 0, 800, 4, {S.cutDownFully, S.regrowSmall, S.harvested, S.cutDownFully}, true)
local Q = newDlcOrchard("Q.xml", 2, 0, 802, 1, {S.cutDownFully}, true)
for k in pairs(g_currentMission.vineSystem.dirtyNodes) do g_currentMission.vineSystem.dirtyNodes[k] = nil end

-- single player: runs locally
g_server = {}; g_client = nil
movePlayer(2, 800)
CONSOLE.brRipen("3")
check(dlcPlantStates(R, 1)[1] == S.harvestReady and dlcPlantStates(R, 2)[1] == S.harvestReady, "SP: the 2 own plants within 3 m are ripe")
check(dlcPlantStates(R, 3)[1] == S.harvested and dlcPlantStates(R, 4)[1] == S.cutDownFully, "SP: plants further away untouched")
check(dlcPlantStates(Q, 1)[1] == S.cutDownFully, "SP: the other farm's plant untouched")
check(g_currentMission.vineSystem.dirtyNodes[R.nodes[1]] and g_currentMission.vineSystem.dirtyNodes[R.nodes[2]], "SP: ripened plants refreshed")
check(printed("ripen: 2 of 3 banana plants within 3.0 m"), "SP: result logged")

-- multiplayer: client -> server events, server -> client log lines
local USERS = {[7] = {admin = false}}
g_currentMission.userManager = {getUserByUserId = function(_, id)
    local u = USERS[id]
    return u and {getIsMasterUser = function() return u.admin end} or nil
end}
g_currentMission.playerSystem = {getPlayerByConnection = function(_, conn) return {farmId = conn.farmId, userId = conn.userId} end}
local serverSide = {farmId = 1, userId = 7}   -- the client's connection as the server sees it
local clientSide = {}                          -- the server's connection as the client sees it
local function deliver(event, toConnection)
    STREAMS[91] = {}
    event:writeStream(91, toConnection)
    local copy = getmetatable(event).__index.emptyNew()
    copy:readStream(91, toConnection)
end
function clientSide:sendEvent(event) g_server = {}; g_client = nil; deliver(event, serverSide); g_server = nil; g_client = CLIENT end
function serverSide:sendEvent(event) local s = g_server; g_server = nil; deliver(event, clientSide); g_server = s end
CLIENT = {getServerConnection = function() return clientSide end}
g_server = nil; g_client = CLIENT
local function frames(n)
    for _ = 1, n do
        g_server = {}; g_client = nil
        for _, l in ipairs(LISTENERS) do if l == BananaRegrowProbe then l:update(16) end end
        g_server = nil; g_client = CLIENT
    end
end

-- not an admin: refused
PRINTED = {}
movePlayer(8, 800)
CONSOLE.brRipen("2")
frames(2)
check(dlcPlantStates(R, 3)[1] == S.harvested, "MP: non-admin ripen refused")
check(printed("[server] [BananaRegrow:probe] server: brRipen refused"), "MP: refusal reaches the client log")

-- admin
USERS[7].admin = true
PRINTED = {}
CONSOLE.brRipen("3")
frames(2)
check(dlcPlantStates(R, 3)[1] == S.harvestReady and dlcPlantStates(R, 4)[1] == S.harvestReady, "MP admin: plants made ripe by the server")
check(printed("[server] [BananaRegrow:probe] ripen: 2 of 2"), "MP admin: server answer in the client log")

-- trace on both sides, server lines relayed
pdlc_beansAndAlpacasPack = {HandToolBananaKnife = {harvest = function(self, n) return n + 1 end}}
-- (client and server share one Lua state here, so the console command's own local trace is checked by spying on the
-- event it sends, and the server trace is driven through the event alone)
local sent = {}
local realSend = clientSide.sendEvent
clientSide.sendEvent = function(self, event) sent[#sent + 1] = event end
print(CONSOLE.brTrace())
print(CONSOLE.brTrace())
clientSide.sendEvent = realSend
check(#sent == 2 and sent[1].action == BananaRegrowResearchEvent.ACTION_TRACE and sent[1].data.on == true
    and sent[2].data.on == false, "MP: brTrace on a client also switches the server's trace on and off")
PRINTED = {}
clientSide:sendEvent(BananaRegrowResearchEvent.new(BananaRegrowResearchEvent.ACTION_TRACE, {on = true}))
check(BananaRegrowProbe.traceConnection == serverSide and BananaRegrowProbe.tracing, "MP: server traces for the requesting client")
g_server = {}; g_client = nil
check(pdlc_beansAndAlpacasPack.HandToolBananaKnife.harvest(nil, 41) == 42, "traced function works")
g_server = nil; g_client = CLIENT
clientSide:sendEvent(BananaRegrowResearchEvent.new(BananaRegrowResearchEvent.ACTION_TRACE, {on = false}))
frames(5)
check(BananaRegrowProbe.traceConnection == nil and #BananaRegrowProbe.wrapped == 0, "MP: trace off on both sides")
check(printed("[server] [BananaRegrow:trace] -> HandToolBananaKnife.harvest("), "MP: server trace call relayed")
check(printed("[server] [BananaRegrow:trace] trace OFF"), "MP: server trace summary relayed")

-- probe: long lines are split, everything arrives
PRINTED = {}
local many = {}
for i = 1, 300 do many["fn" .. i] = function() end end
pdlc_beansAndAlpacasPack.BananaBigClass = many
print(CONSOLE.brProbe())
local queued = #BananaRegrowProbe.relayQueue
frames(200)
check(#BananaRegrowProbe.relayQueue == 0, "MP: relay queue drained (" .. queued .. " pieces)")
local serverLines, longest = 0, 0
for _, l in ipairs(PRINTED) do
    if string.sub(l, 1, 9) == "[server] " then serverLines = serverLines + 1; longest = math.max(longest, #l) end
end
check(serverLines > 5 and printed("[server] [BananaRegrow:probe] ===== probe end"), "MP: server probe relayed (" .. serverLines .. " lines)")
check(longest <= 9 + BananaRegrowProbe.RELAY_CHUNK, "MP: relayed pieces at most one chunk long")

-- brHarvest like in the game: the machete harvest creates a BananaBunch (fillLevel) that hangs in the HANDS; the mod
-- deletes it and puts its liters into the washing station's storage, all ripe plants in one go
g_server = {}; g_client = nil
-- plant 5 is "ripe" only at its edge (3 of 20 pixels): not counted
local T = newDlcOrchard("T.xml", 1, 0, 900, 5, {S.harvestReady, S.harvestReadySick, S.noFruits, S.harvestReady2,
    {S.harvested, S.harvested, S.harvested}}, true)
PIXELS[sectionKey(T.sectionsByPlant[5][1])] = {[S.harvested] = 17, [S.harvestReady] = 3}
local CALLS, BUNCHES, DELETED = {}, {}, 0
local knife = {typeName = "pdlc_beansAndAlpacasPack.bananaKnife", isHeld = true}
local hands = {typeName = "hands", isHeld = false, spec_hands = {}}
local flashlight = {typeName = "flashlight"}
function flashlight:getCarryingPlayer() return g_localPlayer end
local function hold(tool) knife.isHeld = tool == knife; hands.isHeld = tool == hands end
function knife:getCarryingPlayer() return g_localPlayer end
function knife:getIsHeld() return self.isHeld end
function hands:getCarryingPlayer() return g_localPlayer end
function hands:getIsHeld() return self.isHeld end
function knife:executeHarvest(x, y, z, noEventSend)
    assert(self.isHeld, "executeHarvest with the machete not in the hand")
    CALLS[#CALLS + 1] = {x, y, z, noEventSend}
    for _, sections in ipairs(T.sectionsByPlant) do
        local s = sections[1]
        if x >= s[1] and x <= s[1] + 3 then
            for _, sec in ipairs(sections) do PIXELS[sectionKey(sec)] = {[S.harvested] = 20} end
        end
    end
    local node = newNode(x, z)
    BUNCHES[node] = {fillLevel = 26.625, fillType = 222, delete = function(b) DELETED = DELETED + 1; b.deleted = true end}
    hands.spec_hands.heldItemNode = node
    hold(hands)
end
function hands:dropHeldItem(noEventSend) self.dropped = (self.dropped or 0) + 1; self.spec_hands.heldItemNode = nil end
g_currentMission.getNodeObject = function(_, node) return BUNCHES[node] end
g_localPlayer.setCurrentHandTool = function(self, tool, noEventSend) hold(tool) end
g_currentMission.handToolSystem = {handTools = {knife, hands, flashlight}}
local function newStorage(capacity)
    local st = {fillLevels = {[222] = 0, [245] = 0}, capacity = capacity}
    function st:getFillLevel(ft) return self.fillLevels[ft] or 0 end
    function st:getFreeCapacity(ft) return self.capacity - self.fillLevels[ft] end
    function st:setFillLevel(level, ft) self.fillLevels[ft] = math.min(level, self.capacity) end
    return st
end
local function newStation(name, farmId, x, z, capacity)
    local st = {typeName = "pdlc_beansAndAlpacasPack.bananaWashingStation", ownerFarmId = farmId, rootNode = newNode(x, z)}
    st["spec_pdlc_beansAndAlpacasPack.bananaWashingStation"] = {storage = newStorage(capacity or 10000), bananaFillTypeIndex = 222}
    function st:getIsBananaWashingStation() return true end
    function st:getName() return name end
    function st:getOwnerFarmId() return self.ownerFarmId end
    return st
end
local near = newStation("near", 1, 20, 900)
g_currentMission.placeableSystem = {placeables = {newStation("far", 1, 500, 900), near, newStation("other farm", 2, 5, 900)}}
movePlayer(4, 900)
local H = BananaRegrowHarvest
local function frames(n) for _ = 1, n do H:update(16) end end
PRINTED = {}; NOTES = {}
check(string.find(CONSOLE.brHarvest("20"), "3 ripe"), "3 ripe plants found (growing and edge-only plants are not)")
frames(1)
check(#CALLS == 3 and H.queue == nil, "all ripe plants harvested in one frame (" .. #CALLS .. ")")
check(CALLS[1][4] == false and math.abs(CALLS[1][2] - (100 + H.BUNCH_HEIGHT)) < 0.01, "called like the machete: bunch height, noEventSend false")
check(dlcPlantStates(T, 1)[1] == S.harvested and dlcPlantStates(T, 2)[1] == S.harvested and dlcPlantStates(T, 4)[1] == S.harvested, "ripe plants harvested")
check(dlcPlantStates(T, 3)[1] == S.noFruits, "growing plant untouched")
local nearStorage = near["spec_pdlc_beansAndAlpacasPack.bananaWashingStation"].storage
check(math.abs(nearStorage.fillLevels[222] - 3 * 26.625) < 0.001, "the farm's nearest station got all the liters")
check(DELETED == 3 and hands.dropped == 3 and hands.spec_hands.heldItemNode == nil, "no bunch left over: released and deleted")
check(knife.isHeld, "machete back in the hand")
check(printed("done: 3 plants harvested, 79.9 l bananas (80 l to near)"), "summary logged")
check(NOTES[#NOTES] ~= nil and string.find(NOTES[#NOTES], "3 plants harvested"), "player told: " .. tostring(NOTES[#NOTES]))

-- machete only carried, not in the hand: the mod takes it into the hand
for i = 1, 4 do for _, sec in ipairs(T.sectionsByPlant[i]) do PIXELS[sectionKey(sec)] = {[S.harvestReady] = 20} end end
hold(nil)
check(string.find(CONSOLE.brHarvest("20"), "4 ripe"), "machete in the backpack is enough")
frames(2)
check(#CALLS == 7 and knife.isHeld, "machete taken into the hand, 4 more harvested")

-- no room in the farm's stations: stops, says so
for i = 1, 2 do for _, sec in ipairs(T.sectionsByPlant[i]) do PIXELS[sectionKey(sec)] = {[S.harvestReady] = 20} end end
g_currentMission.placeableSystem = {placeables = {newStation("full", 1, 20, 900, 10), newStation("other farm", 2, 5, 900)}}
PRINTED = {}; NOTES = {}
CONSOLE.brHarvest("20")
frames(1)
check(printed("no washing station of your farm has room"), "full station: stops and says so")
check(H.queue == nil and string.find(NOTES[#NOTES], "stopped"), "player told why it stopped")

-- Shift-P tool: an area with ripe and harvested plants; one click harvests the ripe ones into the station, then cuts all
g_currentMission.placeableSystem = {placeables = {near}}
local W = newDlcOrchard("W.xml", 1, 0, 1000, 5, {S.harvestReady, S.harvested, S.harvestReady2, S.noFruits, S.withered}, true)
knife.executeHarvest = function(self, x, y, z, noEventSend)
    CALLS[#CALLS + 1] = {x, y, z, noEventSend}
    for _, sections in ipairs(W.sectionsByPlant) do
        local s = sections[1]
        if x >= s[1] and x <= s[1] + 3 then
            for _, sec in ipairs(sections) do PIXELS[sectionKey(sec)] = {[S.harvested] = 20} end
        end
    end
    local node = newNode(x, z)
    BUNCHES[node] = {fillLevel = 26.625, fillType = 222, delete = function() DELETED = DELETED + 1 end}
    hands.spec_hands.heldItemNode = node
    hold(hands)
end
hold(knife)
local stationBefore = nearStorage.fillLevels[222]
local brush = ConstructionBrushBananaRegrow.new(nil, CURSOR)
brush:activate()
moveCursor(-1, 998); brush:update(300); brush:onButtonPrimary()
moveCursor(15, 1002); brush:update(300); brush:onButtonPrimary()
check(BananaRegrow.preview.numRipe == 2 and BananaRegrow.preview.numNeedCut == 2, "area: 2 ripe, 2 to cut back")
brush:update(300)
check(brush:getButtonPrimaryText() == string.format(TEXTS.bananaRegrow_brush_harvestCut, 2, 4), "left click text: " .. tostring(brush:getButtonPrimaryText()))
local calls0 = #CALLS
NOTES = {}
g_time = g_time + 100
brush:onButtonPrimary()
frames(2)
check(#CALLS == calls0 + 2, "the 2 ripe plants harvested with the machete")
check(math.abs(nearStorage.fillLevels[222] - stationBefore - 2 * 26.625) < 0.001, "their bananas went into the station")
for _, i in ipairs({1, 2, 3, 5}) do check(dlcPlantStates(W, i)[1] == S.cutDownFully, "W plant " .. i .. " cut back after the harvest") end
check(dlcPlantStates(W, 4)[1] == S.noFruits, "growing plant untouched")
local last = NOTES[#NOTES]
check(last ~= nil and string.find(last, "2 plants harvested", 1, true) and string.find(last, "4 plants cut back", 1, true), "one message for both: " .. tostring(last))
brush:deactivate()

-- no machete: only the cut, with a hint
knife.typeName = "somethingElse"
local V = newDlcOrchard("V.xml", 1, 0, 1100, 2, {S.harvestReady, S.harvested}, true)
NOTES = {}
movePlayer(3, 1100)
BananaRegrow.clearSelection(true); BananaRegrow.requestCut()
check(dlcPlantStates(V, 1)[1] == S.harvestReady and dlcPlantStates(V, 2)[1] == S.cutDownFully, "without the machete: ripe plant stays, harvested one cut")
local hinted = false
for _, n in ipairs(NOTES) do if n == string.format(TEXTS.bananaRegrow_harvest_needMachete, 1) then hinted = true end end
check(hinted, "player told to carry the machete")
knife.typeName = "pdlc_beansAndAlpacasPack.bananaKnife"

-- multiplayer: the client asks, the SERVER harvests with the requesting player's machete. Worst case for the lookup:
-- the server never shows the machete as held and the bunch is not in the hands, only in the rail system's list.
local remotePlayer = {farmId = 1}
local remoteKnife = {typeName = "pdlc_beansAndAlpacasPack.bananaKnife"}
function remoteKnife:getCarryingPlayer() return remotePlayer end
function remoteKnife:getIsHeld() return false end
local U = newDlcOrchard("U.xml", 1, 0, 1200, 3, {S.harvestReady, S.harvestReady, S.harvested}, true)
-- like the real dedicated server (2026-11-07): the bunch is neither in the hands nor in the rail list; it only shows up
-- through g_currentMission:addNodeObject, and gets its liters after that
local railList = {}
g_currentMission.bananaRailSystem = {activeBunches = railList}
g_currentMission.nodeToObject = {}
local MissionClass = {addNodeObject = function(self, node, object) self.nodeToObject[node] = object end}
setmetatable(g_currentMission, {__index = MissionClass})
local serverCalls = 0
local function newBunch(x, z, liters)
    local node = newNode(x, z)
    local b = {className = "pdlc_beansAndAlpacasPack.BananaBunch", hook = 99}
    function b:delete() g_currentMission.nodeToObject[node] = nil; self.deleted = true end
    g_currentMission:addNodeObject(node, b)
    b.fillLevel, b.fillType = liters, 222
    return b
end
function remoteKnife:executeHarvest(x, y, z, noEventSend)
    serverCalls = serverCalls + 1
    for _, sections in ipairs(U.sectionsByPlant) do
        local s = sections[1]
        if x >= s[1] and x <= s[1] + 3 then
            for _, sec in ipairs(sections) do PIXELS[sectionKey(sec)] = {[S.harvested] = 20} end
        end
    end
    newBunch(x, z, 30)
end
g_currentMission.handToolSystem = {handTools = {remoteKnife}}
remotePlayer.setCurrentHandTool = function() end
local mpServer = {farmId = 1, userId = 7}
local mpClient = {}
local function mpDeliver(event, toConnection)
    STREAMS[93] = {}
    event:writeStream(93, toConnection)
    local copy = getmetatable(event).__index.emptyNew()
    copy:readStream(93, toConnection)
end
function mpClient:sendEvent(event) g_server = {}; g_client = nil; mpDeliver(event, mpServer); g_server = nil; g_client = MPCLIENT end
function mpServer:sendEvent(event) local s = g_server; g_server = nil; g_client = MPCLIENT; mpDeliver(event, mpClient); g_server = s end
MPCLIENT = {getServerConnection = function() return mpClient end}
g_currentMission.playerSystem = {getPlayerByConnection = function(_, conn) if conn == mpServer then return remotePlayer end end}
local before = nearStorage.fillLevels[222]
g_server = nil; g_client = MPCLIENT
NOTES = {}; PRINTED = {}
movePlayer(3, 1200)
BananaRegrow.clearSelection(true)
BananaRegrow.requestCut()
for _ = 1, 8 do
    g_server = {}; g_client = nil
    for _, l in ipairs(LISTENERS) do if l.update then l:update(16) end end
    g_server = nil; g_client = MPCLIENT
end
check(serverCalls == 2, "MP: the server harvested the 2 ripe plants with the player's machete (" .. serverCalls .. ")")
check(math.abs(nearStorage.fillLevels[222] - before - 60) < 0.001, "MP: 60 l into the washing station")
check(next(g_currentMission.nodeToObject) == nil, "MP: the bunches are gone (deleted on the server)")
check(rawget(g_currentMission, "addNodeObject") == nil, "MP: addNodeObject restored after the harvest")
for i = 1, 3 do check(dlcPlantStates(U, i)[1] == S.cutDownFully, "MP: U plant " .. i .. " cut back after the harvest") end
local mpMessage = nil
for _, n in ipairs(NOTES) do if string.find(n, "2 plants harvested", 1, true) then mpMessage = n end end
check(mpMessage ~= nil and string.find(mpMessage, "60 l", 1, true) and string.find(mpMessage, "3 plants cut back", 1, true), "MP: the client is told: " .. tostring(mpMessage))
check(printed("[server] [BananaRegrow:harvest] first plant: machete held false, bunch true (found in the new objects, 30 l)"), "MP: server harvest log reaches the client")

-- brCollect: bunches already lying on the ground go into the station; one moving on a rail and one far away stay
USERS[7].admin = true
g_currentMission.playerSystem = {getPlayerByConnection = function(_, conn) if conn == mpServer then return remotePlayer end end}
g_currentMission.userManager = {getUserByUserId = function() return {getIsMasterUser = function() return true end} end}
remotePlayer.userId = 7
local loose1, loose2 = newBunch(5, 1205, 26), newBunch(8, 1210, 20)
local onRail = newBunch(6, 1206, 25); onRail.currentSegmentIndex = 3
local far = newBunch(300, 1200, 22)
before = nearStorage.fillLevels[222]
PRINTED = {}
g_server = nil; g_client = MPCLIENT
movePlayer(4, 1204)
CONSOLE.brCollect("20")
for _ = 1, 4 do
    g_server = {}; g_client = nil
    for _, l in ipairs(LISTENERS) do if l.update then l:update(16) end end
    g_server = nil; g_client = MPCLIENT
end
check(loose1.deleted and loose2.deleted and not onRail.deleted and not far.deleted, "collect: the 2 loose bunches near you, not the rail one or the far one")
check(math.abs(nearStorage.fillLevels[222] - before - 46) < 0.001, "collect: 46 l into the station")
check(printed("[server] [BananaRegrow:harvest] collect: 2 loose bunches within 20 m put into the washing station (46.0 l), 1 left"), "collect: answer in the client log")
g_server = {}; g_client = nil
check(INGAME_NOTIFICATIONS == nil, "messages never in the game's notification list")
io.write("ALL RESEARCH CHECKS PASSED\n")
"""


def main():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().TEXTS = lua.table_from(run_stub.load_texts())
    lua.globals().g_currentModDirectory = str(MOD_DIR).replace('\\', '/') + '/'
    lua.execute(run_stub.PRELUDE)
    lua.execute(SETUP)
    for rel in ("scripts/events/BananaRegrowCutEvent.lua", "scripts/events/BananaRegrowResultEvent.lua",
                "scripts/events/BananaRegrowResearchEvent.lua", "scripts/BananaRegrow.lua", "scripts/BananaRegrowProbe.lua",
                "scripts/BananaRegrowHarvest.lua"):
        lua.execute((MOD_DIR / rel).read_text(encoding="utf-8"))
    lua.execute(run_stub.NOTIFY_SPY)
    lua.execute(CHECKS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
