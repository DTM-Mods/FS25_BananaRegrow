"""Offline test of the Banana Regrow Lua on real Lua 5.1 (python lupa's lua51), with stubs for the game engine.

Builds three fake plantations whose plants live in a fake density map, marks an area, cuts, and checks that only the
right plants (own farm, inside the area, in the states the machete would cut) changed state, in single-player and in a
client/server round trip through the two network events.

Usage: python tools/test/run_stub.py
"""
import re
import sys
from pathlib import Path

from lupa import lua51

MOD_DIR = Path(__file__).resolve().parent.parent.parent

PRELUDE = r"""
-- ---------------------------------------------------------------- engine / game stubs
g_currentModName = "FS25_BananaRegrow"
LOG = {}
Logging = {
    info = function(fmt, ...) LOG[#LOG+1] = "I " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)) end,
    warning = function(fmt, ...) LOG[#LOG+1] = "W " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)) end,
}
function Class(members, baseClass)
    if baseClass ~= nil then setmetatable(members, {__index = baseClass}) end
    members.superClass = function() return baseClass end
    return {__index = members}
end
Event = {}
function Event.new(mt) return setmetatable({}, mt) end
EVENT_CLASSES = {}
function InitEventClass(cls, name) EVENT_CLASSES[name] = cls; cls.className = name end

-- streams: one queue per id
STREAMS = {}
local function q(id) STREAMS[id] = STREAMS[id] or {}; return STREAMS[id] end
function streamWriteUIntN(id, v, bits) table.insert(q(id), v) end
function streamReadUIntN(id, bits) return table.remove(q(id), 1) end
function streamWriteBool(id, v) table.insert(q(id), v) end
function streamReadBool(id) return table.remove(q(id), 1) end
function streamWriteFloat32(id, v) table.insert(q(id), v) end
function streamReadFloat32(id) return table.remove(q(id), 1) end
OBJECT_IDS, OBJECTS = {}, {}
NetworkUtil = {
    writeNodeObject = function(id, obj) table.insert(q(id), OBJECT_IDS[obj]) end,
    readNodeObject = function(id) return OBJECTS[table.remove(q(id), 1)] end,
}
function registerObject(obj) local id = #OBJECTS + 1; OBJECTS[id] = obj; OBJECT_IDS[obj] = id end
FarmManager = {FARM_ID_SEND_NUM_BITS = 4}

TEXTS = TEXTS or {}
g_i18n = {getText = function(_, key) return TEXTS[key] or ("<" .. key .. ">") end}

-- fruit type
local STATE_NAMES = {"regrowSmall", "regrowMiddle", "regrowMiddle2", "noFruits", "greenSmall", "greenBig", "greenBigSick",
    "harvestReady", "harvestReady2", "harvestReadySick", "harvestReadySick2", "withered", "harvested", "cutDownHalf", "cutDownFully"}
S = {}
for i, n in ipairs(STATE_NAMES) do S[n] = i end
BANANA = {name = "banana", index = 7, terrainDataPlaneId = 42, startStateChannel = 0, numStateChannels = 4,
          growthStateToName = STATE_NAMES, nameToGrowthState = {}, numFoliageStates = #STATE_NAMES}
for i, n in ipairs(STATE_NAMES) do BANANA.nameToGrowthState[string.upper(n)] = i end
function BANANA:getGrowthStateByName(name) return self.nameToGrowthState[string.upper(name)] end
g_fruitTypeManager = {getFruitTypeByName = function(_, name) if name == "BANANA" then return BANANA end end}

-- density map: PIXELS[sectionKey] = {[state] = count}
PIXELS = {}
DensityCoordType = {POINT_POINT_POINT = 0, POINT_VECTOR_VECTOR = 1}
DensityValueCompareType = {ALWAYS = 0, EQUAL = 1, GREATER = 2, BETWEEN = 3, NOTEQUAL = 4, NOTBETWEEN = 5}
function sectionKey(s) return string.format("%.2f|%.2f|%.2f|%.2f|%.2f|%.2f", s[1], s[2], s[3], s[4], s[5], s[6]) end
DensityMapModifier = {}
DensityMapModifier.__index = DensityMapModifier
function DensityMapModifier.new(mapId, first, num, terrain)
    assert(mapId == 42 and first == 0 and num == 4 and terrain == 1, "modifier args")
    return setmetatable({}, DensityMapModifier)
end
function DensityMapModifier:setParallelogramWorldCoords(a, b, c, d, e, f, coordType)
    assert(coordType == 0); self.key = sectionKey({a, b, c, d, e, f})
end
local function matches(filter, state)
    if filter.mode == 1 then return state == filter.a
    elseif filter.mode == 3 then return state >= filter.a and state <= filter.b
    elseif filter.mode == 2 then return state > filter.a
    elseif filter.mode == 0 then return true end
    error("filter mode " .. tostring(filter.mode))
end
function DensityMapModifier:executeGet(filter)
    local px = PIXELS[self.key] or {}
    local n, total = 0, 0
    for state, count in pairs(px) do total = total + count; if matches(filter, state) then n = n + count end end
    return 0, n, total
end
function DensityMapModifier:executeSet(value, filter)
    local px = PIXELS[self.key] or {}
    local n, total, moved = 0, 0, {}
    for state, count in pairs(px) do
        total = total + count
        if matches(filter, state) and state ~= value then moved[state] = count; n = n + count end
    end
    for state, count in pairs(moved) do px[state] = nil; px[value] = (px[value] or 0) + count end
    -- the game's executeSet does not return a pixel count (the cut counted 0 in game while it did change the
    -- plants); return nothing so the mod cannot rely on it
    return nil
end
DensityMapFilter = {}
DensityMapFilter.__index = DensityMapFilter
function DensityMapFilter.new(modifier) return setmetatable({}, DensityMapFilter) end
function DensityMapFilter:setValueCompareParams(mode, a, b) self.mode, self.a, self.b = mode, a, b end

-- scene nodes
NODES = {}
g_terrainNode = 1
function getTerrainHeightAtWorldPos(t, x, y, z) return 100 end
function getWorldTranslation(node) local n = NODES[node]; return n.x, n.y, n.z end
function localDirectionToWorld(node, x, y, z) return 1, 0, 0 end  -- rows run along world x
function entityExists(node) return NODES[node] ~= nil end
NEXT_NODE = 10
function newNode(x, z) NEXT_NODE = NEXT_NODE + 1; NODES[NEXT_NODE] = {x = x, y = 100, z = z}; return NEXT_NODE end

-- plantations (PlaceableVine layout)
UPDATED = {}
function newOrchard(name, farmId, startX, z, numPlants, statesPerPlant)
    local p = {typeName = "vineOrchard", configFileName = name, ownerFarmId = farmId}
    p.spec_vine = {fruitType = BANANA, width = 2, length = 3, numSections = 3, nodes = {}, vineSegments = {}}
    function p:getVineFruitTypeIndex() return self.spec_vine.fruitType.index end
    function p:getOwnerFarmId() return self.ownerFarmId end
    function p:updateVineNode(node, isGrowing) UPDATED[node] = (UPDATED[node] or 0) + 1 end
    p.nodes = {}
    for i = 1, numPlants do
        local x = startX + (i - 1) * 3
        local node = newNode(x, z)
        local sections = {}
        for s = 1, 3 do
            local sx = x + (s - 1)
            sections[s] = {sx, z - 1, sx, z + 1, sx + 1, z - 1}
            local st = statesPerPlant[i]
            if type(st) == "table" then st = st[s] end
            PIXELS[sectionKey(sections[s])] = {[st] = 20}
        end
        p.spec_vine.nodes[node] = {node = node, sections = sections}
        p.nodes[i] = node
        g_currentMission.vineSystem.nodes[node] = p
    end
    registerObject(p)
    return p
end
function plantStates(p, i)
    local out = {}
    for s, section in ipairs(p.spec_vine.nodes[p.nodes[i]].sections) do
        local px = PIXELS[sectionKey(section)]
        local st
        for state, count in pairs(px) do st = state end
        out[s] = st
    end
    return out
end


-- Beans & Alpacas style plantation: type orchard, specs placement + newFence + orchard; plants in segment.vineNodes
function newDlcOrchard(name, farmId, startX, z, numPlants, statesPerPlant, withSections)
    local p = {typeName = "pdlc_beansAndAlpacasPack.orchard", configFileName = name, ownerFarmId = farmId}
    p["spec_pdlc_beansAndAlpacasPack.orchard"] = {fruitType = BANANA, rowWidth = 2}
    local fence = {segments = {{x1 = startX, z1 = z, x2 = startX + numPlants * 3, z2 = z, vineNodes = {}}}}
    p.spec_newFence = fence
    function p:getFence() return fence end
    function p:getVineFruitTypeIndex() return BANANA.index end
    function p:getOwnerFarmId() return self.ownerFarmId end
    p.nodes = {}
    p.sectionsByPlant = {}
    for i = 1, numPlants do
        local x = startX + (i - 1) * 3
        local node = newNode(x, z)
        local sections
        if withSections then
            sections = {}
            for s = 1, 3 do
                local sx = x + (s - 1)
                sections[s] = {sx, z - 1, sx, z + 1, sx + 1, z - 1}
            end
        else
            -- what BananaRegrow.computeNodeArea derives from the node: width 2 (rowWidth), length 3 (default)
            sections = {{x, z - 1, x, z + 1, x + 3, z - 1}}
        end
        for s, section in ipairs(sections) do
            local st = statesPerPlant[i]
            if type(st) == "table" then st = st[s] end
            PIXELS[sectionKey(section)] = {[st] = 20}
        end
        local data = {growthValues = {}}
        if withSections then data.sections = sections end
        fence.segments[1].vineNodes[node] = data
        p.nodes[i] = node
        p.sectionsByPlant[i] = sections
        g_currentMission.vineSystem.nodes[node] = p
    end
    registerObject(p)
    return p
end
function dlcPlantStates(p, i)
    local out = {}
    for s, section in ipairs(p.sectionsByPlant[i]) do
        for state in pairs(PIXELS[sectionKey(section)]) do out[s] = state end
    end
    return out
end


-- construction screen: brush base class, top-down cursor, brush type manager
g_time = 1000
Farm = {PERMISSION = {LANDSCAPING = 3}}
ConstructionBrush = {}
function ConstructionBrush.new(mt, cursor) local self = setmetatable({}, mt); self.cursor = cursor; self.textDirty = 0; return self end
function ConstructionBrush:activate() self.isActive = true end
function ConstructionBrush:deactivate() self.isActive = false end
function ConstructionBrush:setInputTextDirty() self.textDirty = self.textDirty + 1 end
GuiTopDownCursor = {SHAPES = {CIRCLE = 1, SQUARE = 2}, SHAPES_COLORS = {SUCCESS = 1, SELECT = 2, ERROR = 3}}
CURSOR = {x = 0, y = 100, z = 0, message = nil, isError = false}
function CURSOR:setRotationEnabled(v) end
function CURSOR:setShape(v) end
function CURSOR:setShapeSize(v) end
function CURSOR:setColorMode(v) self.color = v end
function CURSOR:setTerrainOnly(v) self.terrainOnly = v end
function CURSOR:getPosition() return self.x, self.y, self.z end
function CURSOR:setMessage(t) self.message, self.isError = t, false end
function CURSOR:setErrorMessage(t) self.message, self.isError = t, true end
function moveCursor(x, z) CURSOR.x, CURSOR.z = x, z end
BRUSH_TYPES = {}
g_constructionBrushTypeManager = {addBrushType = function(self, name, className, filename)
    BRUSH_TYPES[name] = {className = className, filename = filename}
    dofile(filename)
end}

NOTES = {}
g_currentMission = {
    vineSystem = {nodes = {}, dirtyNodes = {}},
    terrainRootNode = 1,
    accessHandler = {canFarmAccess = function(self, farmId, obj) return obj:getOwnerFarmId() == farmId end},
    playerSystem = {getPlayerByConnection = function(self, conn) return {farmId = conn.farmId} end},
    addIngameNotification = function(self, kind, msg) INGAME_NOTIFICATIONS = (INGAME_NOTIFICATIONS or 0) + 1 end,
    getFarmId = function() return 1 end,
}
FSBaseMission = {INGAME_NOTIFICATION_INFO = "info", INGAME_NOTIFICATION_CRITICAL = "critical"}
PLAYER_NODE = newNode(0, 0)
g_localPlayer = {farmId = 1, rootNode = PLAYER_NODE, getCurrentVehicle = function() return nil end}
function movePlayer(x, z) NODES[PLAYER_NODE].x = x; NODES[PLAYER_NODE].z = z end

-- input
REGISTERED = {}
InputAction = {BANANAREGROW_MARK = "BANANAREGROW_MARK", BANANAREGROW_CUT = "BANANAREGROW_CUT", BANANAREGROW_CLEAR = "BANANAREGROW_CLEAR"}
GS_PRIO_LOW, GS_PRIO_NORMAL, GS_PRIO_HIGH = 1, 2, 3
g_inputBinding = {
    registerActionEvent = function(self, action, target, callback, up, down, always, active)
        local id = #REGISTERED + 1
        REGISTERED[id] = {action = action, target = target, callback = callback, text = nil, visible = true}
        return true, id
    end,
    setActionEventTextPriority = function(self, id, prio) REGISTERED[id].prio = prio end,
    setActionEventText = function(self, id, t) REGISTERED[id].text = t end,
    setActionEventTextVisibility = function(self, id, v) REGISTERED[id].visible = v end,
    beginActionEventsModification = function() end,
    endActionEventsModification = function() end,
}
function press(actionName)
    for _, e in ipairs(REGISTERED) do if e.action == actionName then e.callback(e.target, actionName, 1) return end end
    error("action not registered: " .. actionName)
end
PlayerInputComponent = {INPUT_CONTEXT_NAME = "PLAYER", registerGlobalPlayerActionEvents = function(self) end}
Utils = {appendedFunction = function(oldFunc, newFunc) return function(...) local r = oldFunc(...); newFunc(...); return r end end}
LISTENER = nil
function addModEventListener(l) LISTENER = l end
CONSOLE = {}
function addConsoleCommand(name, desc, fn, target) CONSOLE[name] = function() return target[fn](target) end end
function removeConsoleCommand(name) CONSOLE[name] = nil end
DRAWN = 0
function drawDebugLine() DRAWN = DRAWN + 1 end
RENDERED = {}
function renderText(x, y, size, t) RENDERED[#RENDERED+1] = t end
function setTextAlignment() end
function setTextBold() end
function setTextColor() end
function getCorrectTextSize(s) return s end
RenderText = {ALIGN_LEFT = 0, ALIGN_CENTER = 1}
g_gui = {getIsGuiVisible = function() return false end}
g_server = {}
g_client = nil
g_dedicatedServer = nil
"""

# messages the mod shows (on the player's own screen only)
NOTIFY_SPY = r"""
local realNotify = BananaRegrow.notify
BananaRegrow.notify = function(message, isWarning) NOTES[#NOTES + 1] = message; return realNotify(message, isWarning) end
"""

SCENARIO = r"""
local function check(cond, msg) if not cond then error("CHECK FAILED: " .. msg, 2) end print("ok  " .. msg) end
local function eq(a, b, msg) if a ~= b then error(string.format("CHECK FAILED: %s: got %s, want %s", msg, tostring(a), tostring(b)), 2) end print("ok  " .. msg .. " = " .. tostring(a)) end

-- plantations: A (farm 1) 10 plants at z=0, B (farm 2) 3 plants at z=10, C (farm 1) 4 plants at z=200
local A = newOrchard("A.xml", 1, 0, 0, 10, {S.harvested, S.harvested, S.harvested, S.harvested, S.cutDownHalf, S.withered,
    S.harvestReady, S.noFruits, S.regrowSmall, {S.harvested, S.harvestReady, S.cutDownFully}})
local B = newOrchard("B.xml", 2, 0, 10, 3, {S.harvested, S.harvested, S.harvested})
local C = newOrchard("C.xml", 1, 0, 200, 4, {S.harvested, S.harvested, S.withered, S.cutDownHalf})

LISTENER:loadMap("map")
PlayerInputComponent.registerGlobalPlayerActionEvents({}, "PLAYER")
eq(#REGISTERED, 3, "three keys registered in the player context")
check(REGISTERED[1].text == TEXTS.input_BANANAREGROW_MARK, "key text comes from l10n")
check(REGISTERED[3].visible == false, "clear key hidden while nothing is marked")

-- mark a rectangle around A and B
movePlayer(-1, -2); press("BANANAREGROW_MARK")
eq(#BananaRegrow.corners, 1, "one corner")
LISTENER:draw()
check(RENDERED[#RENDERED] == TEXTS.bananaRegrow_hud_oneCorner, "HUD asks for the second corner")
movePlayer(40, 12); press("BANANAREGROW_MARK")
check(BananaRegrow.rect ~= nil, "rectangle set")
local p = BananaRegrow.preview
eq(p.numPlants, 13, "13 plants in the area (A 10 + B 3)")
eq(p.numNeedCut, 10, "10 need cutting (A: 1-6 and 10, B: 3)")
LISTENER:update(16)
check(REGISTERED[3].visible == true, "clear key shown while an area is marked")
DRAWN = 0; LISTENER:draw()
check(DRAWN > 10, "area and plants drawn (" .. DRAWN .. " lines)")
check(string.find(RENDERED[#RENDERED], "13") and string.find(RENDERED[#RENDERED], "10"), "HUD shows counts: " .. RENDERED[#RENDERED])

-- cut (single player: g_server set, runs locally)
NOTES = {}
press("BANANAREGROW_CUT")
check(string.find(NOTES[1], "7 "), "notification reports 7 cut: " .. tostring(NOTES[1]))
check(NOTES[2] ~= nil and string.find(NOTES[2], "3 "), "notification reports 3 skipped on other land: " .. tostring(NOTES[2]))
for i = 1, 6 do local st = plantStates(A, i); check(st[1] == S.cutDownFully and st[2] == S.cutDownFully and st[3] == S.cutDownFully, "A plant " .. i .. " fully cut down") end
local st7 = plantStates(A, 7); eq(st7[1], S.harvestReady, "A plant 7 (ripe) untouched")
eq(plantStates(A, 8)[1], S.noFruits, "A plant 8 (growing) untouched")
eq(plantStates(A, 9)[1], S.regrowSmall, "A plant 9 (regrowing) untouched")
local st10 = plantStates(A, 10)
check(st10[1] == S.cutDownFully and st10[2] == S.harvestReady and st10[3] == S.cutDownFully, "A plant 10: only the harvested section changed")
for i = 1, 3 do eq(plantStates(B, i)[1], S.harvested, "B plant " .. i .. " (other farm) untouched") end
for i = 1, 4 do check(plantStates(C, i)[1] ~= S.cutDownFully, "C plant " .. i .. " (outside) untouched") end
local updated = 0 for _ in pairs(UPDATED) do updated = updated + 1 end
eq(updated, 7, "updateVineNode called once per changed plant")

-- recount after the sync delay
LISTENER:update(2000)
eq(BananaRegrow.preview.numNeedCut, 3, "after cutting only B's 3 plants still need it")

-- cut-all mode takes ripe and growing plants too, never the regrowing ones
print(CONSOLE.brCutAll())
eq(BananaRegrow.preview.numNeedCut, 6, "cut-all preview: A 7, 8, 10 + B 3")
NOTES = {}
press("BANANAREGROW_CUT")
check(string.find(NOTES[1], "3 "), "cut-all cut 3 plants: " .. tostring(NOTES[1]))
eq(plantStates(A, 7)[1], S.cutDownFully, "A plant 7 (ripe) now cut down")
eq(plantStates(A, 8)[1], S.cutDownFully, "A plant 8 (growing) now cut down")
eq(plantStates(A, 9)[1], S.regrowSmall, "A plant 9 (regrowing) still untouched")
eq(plantStates(A, 10)[2], S.cutDownFully, "A plant 10 ripe section now cut down")
print(CONSOLE.brCutAll())

-- whole-plantation mode: no area marked, player next to C
press("BANANAREGROW_CLEAR")
check(BananaRegrow.rect == nil and #BananaRegrow.corners == 0, "area cleared")
movePlayer(5, 203)
NOTES = {}
press("BANANAREGROW_CUT")
check(string.find(NOTES[1], "4 "), "whole plantation: 4 plants announced: " .. tostring(NOTES[1]))
check(string.find(NOTES[2], "4 "), "whole plantation: 4 plants cut: " .. tostring(NOTES[2]))
for i = 1, 4 do eq(plantStates(C, i)[1], S.cutDownFully, "C plant " .. i .. " cut down") end
eq(plantStates(B, 1)[1], S.harvested, "B untouched by the whole-plantation cut")

-- no plantation nearby
movePlayer(500, 500)
NOTES = {}
press("BANANAREGROW_CUT")
eq(NOTES[1], TEXTS.bananaRegrow_noOrchard, "no plantation nearby message")

-- client / server round trip through the events
for i = 1, 3 do for _, section in ipairs(B.spec_vine.nodes[B.nodes[i]].sections) do PIXELS[sectionKey(section)] = {[S.harvested] = 20} end end
B.ownerFarmId = 1
g_server = nil
local serverConnection = {farmId = 1}
local clientConnection = {}
local function deliver(event, toConnection)
    local streamId = 77
    STREAMS[streamId] = {}
    event:writeStream(streamId, toConnection)
    local cls = getmetatable(event).__index
    local copy = cls.emptyNew()
    copy:readStream(streamId, toConnection)
end
-- client -> server: the server side runs in this same Lua state, with g_server set while it handles the event
function clientConnection:sendEvent(event) g_server = {}; deliver(event, serverConnection); g_server = nil end
-- server -> client: the client runs the answer
function serverConnection:sendEvent(event) local s = g_server; g_server = nil; deliver(event, clientConnection); g_server = s end
g_client = {getServerConnection = function() return clientConnection end}
movePlayer(5, 12)
NOTES = {}
press("BANANAREGROW_CUT")
check(string.find(NOTES[1], "3 "), "MP: whole plantation of 3 announced: " .. tostring(NOTES[1]))
check(string.find(NOTES[2], "3 "), "MP: result event reports 3 cut: " .. tostring(NOTES[2]))
for i = 1, 3 do eq(plantStates(B, i)[1], S.cutDownFully, "MP: B plant " .. i .. " cut by the server") end


-- Beans & Alpacas layout: plants under fence segments, stored sections (D) and without stored sections (E)
g_server = {}
g_client = nil
local D = newDlcOrchard("D.xml", 1, 0, 300, 5, {S.harvested, S.harvested, S.withered, S.harvestReady, S.cutDownHalf}, true)
local E = newDlcOrchard("E.xml", 1, 0, 400, 3, {S.harvested, S.noFruits, S.harvested}, false)
movePlayer(6, 301)
NOTES = {}
press("BANANAREGROW_CUT")
check(string.find(NOTES[1], "5 "), "DLC layout D: 5 plants announced: " .. tostring(NOTES[1]))
check(string.find(NOTES[2], "4 "), "DLC layout D: 4 plants cut: " .. tostring(NOTES[2]))
for i = 1, 3 do eq(dlcPlantStates(D, i)[1], S.cutDownFully, "D plant " .. i .. " cut down") end
eq(dlcPlantStates(D, 4)[1], S.harvestReady, "D plant 4 (ripe) untouched")
eq(dlcPlantStates(D, 5)[1], S.cutDownFully, "D plant 5 (half cut) cut down")
local dirty = 0 for _ in pairs(g_currentMission.vineSystem.dirtyNodes) do dirty = dirty + 1 end
eq(dirty, 4, "no update function on the orchard: changed nodes marked dirty in the vine system")
movePlayer(3, 401)
NOTES = {}
press("BANANAREGROW_CUT")
check(string.find(NOTES[2], "2 "), "DLC layout E (computed areas): 2 plants cut: " .. tostring(NOTES[2]))
eq(dlcPlantStates(E, 1)[1], S.cutDownFully, "E plant 1 cut down via computed area")
eq(dlcPlantStates(E, 2)[1], S.noFruits, "E plant 2 (growing) untouched")
eq(dlcPlantStates(E, 3)[1], S.cutDownFully, "E plant 3 cut down via computed area")

-- a plantation whose plants have no banana pixels at all: the automatic diagnostic runs once
local F = newDlcOrchard("F.xml", 1, 0, 500, 2, {S.regrowSmall, S.regrowSmall}, true)
movePlayer(3, 501)
LOG = {}
press("BANANAREGROW_CUT")
local diagnosed = false
for _, l in ipairs(LOG) do if string.find(l, "plantation type=pdlc_beansAndAlpacasPack.orchard") then diagnosed = true end end
check(diagnosed, "automatic plantation dump written when nothing could be cut")
check(BananaRegrow.diagnosed == true, "diagnostic runs only once")


-- construction screen tool (Shift-P)
check(BRUSH_TYPES.bananaRegrow ~= nil and BRUSH_TYPES.bananaRegrow.className == "ConstructionBrushBananaRegrow", "brush type registered")
check(ConstructionBrushBananaRegrow ~= nil, "brush class loaded from the registered file")
g_server = {}
g_client = nil
local G = newDlcOrchard("G.xml", 1, 0, 600, 5, {S.harvested, S.harvested, S.harvestReady, S.withered, S.harvested}, true)
local H = newDlcOrchard("H.xml", 1, 0, 700, 3, {S.harvested, S.cutDownHalf, S.noFruits}, true)
local brush = ConstructionBrushBananaRegrow.new(nil, CURSOR)
eq(brush.requiredPermission, Farm.PERMISSION.LANDSCAPING, "tool needs the landscaping permission")
brush:activate()
check(CURSOR.terrainOnly == true, "cursor on terrain")
eq(#BananaRegrow.corners, 0, "activating starts with nothing marked")

moveCursor(-1, 598)
brush:update(300)
eq(brush.hoverCount, 5, "plantation under the cursor found (5 plants)")
eq(brush:getButtonPrimaryText(), TEXTS.bananaRegrow_brush_firstCorner, "left click text: first corner")
check(string.find(brush:getButtonSecondaryText(), "5"), "right click text: whole plantation (5): " .. tostring(brush:getButtonSecondaryText()))
brush:draw()
check(string.find(CURSOR.message, "5"), "cursor hint names the plantation: " .. CURSOR.message)

brush:onButtonPrimary()
eq(#BananaRegrow.corners, 1, "first corner set by click")
brush:update(300)
eq(brush:getButtonPrimaryText(), TEXTS.bananaRegrow_brush_secondCorner, "left click text: opposite corner")
eq(brush:getButtonSecondaryText(), TEXTS.bananaRegrow_brush_removeCorner, "right click text: remove corner")
moveCursor(14, 602)
DRAWN = 0
brush:draw()
check(DRAWN >= 8, "area up to the cursor drawn while choosing the second corner (" .. DRAWN .. " lines)")
eq(CURSOR.message, TEXTS.bananaRegrow_hud_oneCorner, "cursor asks for the opposite corner")

brush:onButtonPrimary()
check(BananaRegrow.rect ~= nil, "second click makes the area")
eq(BananaRegrow.preview.numPlants, 5, "area counts G's 5 plants")
eq(BananaRegrow.preview.numNeedCut, 4, "4 of them need cutting")
brush:update(300)
eq(brush:getButtonPrimaryText(), string.format(TEXTS.bananaRegrow_brush_cut, 4), "left click text: cut back 4 plants")
eq(CURSOR.color, GuiTopDownCursor.SHAPES_COLORS.SELECT, "cursor colour shows a ready cut")
brush:draw()
check(string.find(CURSOR.message, "4"), "cursor shows the counts: " .. CURSOR.message)

g_time = g_time + 100
brush:onButtonPrimary()
for _, i in ipairs({1, 2, 4, 5}) do eq(dlcPlantStates(G, i)[1], S.cutDownFully, "tool cut G plant " .. i) end
eq(dlcPlantStates(G, 3)[1], S.harvestReady, "tool left the ripe G plant 3")
brush:draw()
check(string.find(CURSOR.message, "4 "), "result shown at the cursor: " .. CURSOR.message)
LISTENER:update(2000)
eq(BananaRegrow.preview.numNeedCut, 0, "recount after the cut: nothing left")
g_time = g_time + 5000
brush:update(300)
eq(brush:getButtonPrimaryText(), TEXTS.bananaRegrow_brush_newArea, "left click text: start a new area")
brush:draw()
check(string.find(CURSOR.message, "5") and string.find(CURSOR.message, "0"), "after the message times out the counts show again: " .. CURSOR.message)

brush:onButtonSecondary()
eq(#BananaRegrow.corners, 1, "right click takes back the second corner")
check(BananaRegrow.rect == nil and BananaRegrow.preview == nil, "area and counts gone with it")
check(brush:canCancel(), "Esc can cancel")
brush:cancel()
eq(#BananaRegrow.corners, 0, "Esc clears the corners")

-- right click with nothing marked: the whole plantation under the cursor
moveCursor(3, 701)
brush:update(300)
eq(brush.hoverCount, 3, "plantation H under the cursor")
g_time = g_time + 100
brush:onButtonSecondary()
eq(dlcPlantStates(H, 1)[1], S.cutDownFully, "right click cut H plant 1")
eq(dlcPlantStates(H, 2)[1], S.cutDownFully, "right click cut H plant 2")
eq(dlcPlantStates(H, 3)[1], S.noFruits, "right click left the growing H plant 3")

-- nothing under the cursor: right click does nothing
moveCursor(900, 900)
brush:update(300)
check(brush.hoverCount == nil and brush:getButtonSecondaryText() == nil, "no plantation under the cursor: no right click action")
brush:onButtonPrimary()
eq(#BananaRegrow.corners, 1, "corner can be set anywhere")
brush:deactivate()
eq(#BananaRegrow.corners, 0, "leaving the tool clears the selection")

-- the technical dump runs
print(CONSOLE.brInfo())
LISTENER:deleteMap()
for _, l in ipairs(LOG) do if string.sub(l, 1, 1) == "W" then print("LOG " .. l) end end
if INGAME_NOTIFICATIONS ~= nil then error("CHECK FAILED: the game's top-right notification list was used") end
print("ok  messages only on the own screen, never in the game's notification list")
print("ALL CHECKS PASSED")
"""


def load_texts():
    xml = (MOD_DIR / "translations" / "translation_en.xml").read_text(encoding="utf-8")
    texts = dict(re.findall(r'<text name="([^"]+)" text="([^"]*)"/>', xml))
    return {k: v.replace("&amp;", "&") for k, v in texts.items()}


def main():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    texts = lua.table_from(load_texts())
    lua.globals().TEXTS = texts
    lua.globals().g_currentModDirectory = str(MOD_DIR).replace('\\', '/') + '/'
    lua.execute(PRELUDE)
    for rel in ("scripts/events/BananaRegrowCutEvent.lua", "scripts/events/BananaRegrowResultEvent.lua", "scripts/BananaRegrow.lua"):
        code = (MOD_DIR / rel).read_text(encoding="utf-8")
        lua.execute(code)
        print("loaded", rel)
    lua.execute(NOTIFY_SPY)
    lua.execute(SCENARIO)
    return 0


if __name__ == "__main__":
    sys.exit(main())
