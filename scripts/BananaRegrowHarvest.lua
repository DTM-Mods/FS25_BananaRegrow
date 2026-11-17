--[[
    Banana Regrow - harvest every ripe plant at once, the bananas go straight into the washing station

    How the game harvests with the machete (seen with brTrace, 2026-11-07): the machete hand tool calls
    executeHarvest(x, y, z, false) at the bunch. That turns the plant to "harvested" and creates a BananaBunch object
    (fillLevel = liters, fillType = BANANA) that hangs in the player's HANDS (base game HandToolHands,
    spec_hands.heldItemNode; g_currentMission:getNodeObject(node) is the bunch). Normally the player then carries it to
    the washing station or hooks it on the rail, and the station adds the liters to its storage.

    Here, per ripe plant: machete in the hand (player:setCurrentHandTool), executeHarvest, take the bunch out of the
    hands (dropHeldItem), delete it and add its liters to the farm's nearest washing station's storage (base game
    Storage:setFillLevel, which syncs to all players). So the game still decides how many liters each plant gives.

      brHarvest [radius|all]   all ripe plants within radius m (default 10), or with "all" the whole plantation
                               next to you. Hold the machete. brHarvest again stops.

    In multiplayer this runs on the server (BananaRegrow.serverCut) with the requesting player's machete; the bunch
    is looked for in that player's hands and, failing that, as a new entry of bananaRailSystem.activeBunches. The log
    lines also go to the requesting player's log.txt ("[server] ..." lines).

    Lines start with [BananaRegrow:harvest].
]]

BananaRegrowHarvest = {}
local H = BananaRegrowHarvest

H.RIPE_STATE_NAMES = {"harvestReady", "harvestReady2", "harvestReadySick", "harvestReadySick2"}
H.MIN_RIPE_SHARE = 0.5       -- a plant counts as ripe when at least half its banana pixels are ripe (edges overlap)
H.BUNCH_HEIGHT = 1.9         -- m above the plant node: where the machete aims (bunch at y 101.9 on ground 100)
H.PLANTS_PER_FRAME = 20
H.MAX_MISSES = 5             -- plants in a row without a bunch -> stop
H.DEFAULT_RADIUS = 10
H.MAX_RADIUS = 100

H.queue = nil

local function log(fmt, ...)
    local line = "[BananaRegrow:harvest] " .. BananaRegrow.format(fmt, ...)
    print(line)
    -- on a server, the requesting player gets the lines in their own log.txt too
    local q = H.queue
    local connection = (q ~= nil and q.connection) or H.logConnection
    if connection ~= nil and BananaRegrowProbe ~= nil and BananaRegrowProbe.relay ~= nil then
        BananaRegrowProbe.relay(line, connection)
    end
end

--- density ranges of the ripe states, or nil
function H.getRipeRanges()
    local desc = BananaRegrow.getFruit()
    if desc == nil or BananaRegrow.resolveStates() == nil then
        return nil
    end
    local list = {}
    for _, name in ipairs(H.RIPE_STATE_NAMES) do
        local index = BananaRegrow.getStateIndex(desc, name)
        if index ~= nil then
            list[#list + 1] = index
        end
    end
    table.sort(list)
    local ranges = {}
    for _, v in ipairs(list) do
        local last = ranges[#ranges]
        if last ~= nil and last[2] == v - 1 then
            last[2] = v
        else
            ranges[#ranges + 1] = {v, v}
        end
    end
    return #ranges > 0 and ranges or nil
end

--- is the plant ripe (most of its pixels in a ripe state)?
function H.isRipe(plant, ranges)
    local states = BananaRegrow.resolveStates()
    local ripe, all = 0, 0
    for _, section in ipairs(plant.sections) do
        ripe = ripe + BananaRegrow.applyRanges(section, ranges, nil)
        all = all + BananaRegrow.applyRanges(section, {{1, states.numStates}}, nil)
    end
    return ripe > 0 and ripe >= all * H.MIN_RIPE_SHARE
end

local function isKnife(tool)
    return type(tool) == "table" and string.find(tostring(tool.typeName), "bananaKnife", 1, true) ~= nil
        and type(tool.executeHarvest) == "function"
end

local function carrierOf(tool)
    if type(tool.getCarryingPlayer) == "function" then
        return tool:getCarryingPlayer()
    end
    return tool.carryingPlayer
end

local function isHeld(tool)
    if type(tool.getIsHeld) == "function" then
        return tool:getIsHeld() == true
    end
    return tool.isHeld == true
end

local function playerTools(player)
    local tools = {}
    local system = g_currentMission ~= nil and g_currentMission.handToolSystem or nil
    if player ~= nil and system ~= nil and type(system.handTools) == "table" then
        for _, tool in pairs(system.handTools) do
            if type(tool) == "table" and carrierOf(tool) == player then
                tools[#tools + 1] = tool
            end
        end
    end
    return tools
end

--- the machete the player carries (held or not) and whether it is in the hand
function H.findKnife(player)
    for _, tool in ipairs(playerTools(player)) do
        if isKnife(tool) then
            return tool, isHeld(tool)
        end
    end
    return nil, false
end

--- the hands tool holding a bunch: hands, bunch object
function H.findHeldBunch(player)
    for _, tool in ipairs(playerTools(player)) do
        local spec = tool.spec_hands
        if type(spec) == "table" and spec.heldItemNode ~= nil then
            local bunch = nil
            if type(g_currentMission.getNodeObject) == "function" then
                bunch = g_currentMission:getNodeObject(spec.heldItemNode)
            end
            return tool, bunch
        end
    end
    return nil
end

--- the bunch objects the rail system knows (it lists every bunch, also one in the hands or on the ground)
function H.activeBunchSet()
    local set = {}
    local rail = g_currentMission.bananaRailSystem
    if rail ~= nil and type(rail.activeBunches) == "table" then
        for k, v in pairs(rail.activeBunches) do
            if type(k) == "table" and k.fillLevel ~= nil then
                set[k] = true
            end
            if type(v) == "table" and v.fillLevel ~= nil then
                set[v] = true
            end
        end
    end
    return set
end

--- is this object a banana bunch (class pdlc_beansAndAlpacasPack.BananaBunch, fields fillLevel/fillType/hook)?
--- While it is being created the liters may not be set yet, so the class name counts first.
function H.isBunch(object)
    if type(object) ~= "table" then
        return false
    end
    local name = tostring(object.className or "") .. " " .. tostring(object.typeName or "")
    if ClassUtil ~= nil and type(ClassUtil.getClassNameByObject) == "function" then
        local cn = ClassUtil.getClassNameByObject(object)
        if cn ~= nil then
            name = name .. " " .. tostring(cn)
        end
    end
    if string.find(name, "BananaBunch", 1, true) then
        return true
    end
    return type(rawget(object, "fillLevel")) == "number" and rawget(object, "fillType") ~= nil and rawget(object, "hook") ~= nil
end

--- Puts g_currentMission.addNodeObject back the way it was before callCapturingBunch (also after an error inside fn,
--- which leaves the capture in place until the next call or the end of the harvest)
function H.restoreAddNodeObject()
    local capture = H.capture
    if capture ~= nil then
        H.capture = nil
        rawset(capture.mission, "addNodeObject", capture.own)    -- nil again when the function came from the class
    end
end

--- Calls fn(...) and returns the first banana bunch registered with g_currentMission:addNodeObject during the call
--- (that is how the bunch the machete creates becomes known, also on a dedicated server where it does not end up in
--- the player's hands), or nil
function H.callCapturingBunch(fn, ...)
    H.restoreAddNodeObject()
    local mission = g_currentMission
    local original = mission.addNodeObject
    local created
    if type(original) == "function" then
        H.capture = {mission = mission, own = rawget(mission, "addNodeObject")}
        mission.addNodeObject = function(self, node, object, ...)
            if created == nil and H.isBunch(object) then
                created = object
            end
            return original(self, node, object, ...)
        end
    end
    fn(...)
    H.restoreAddNodeObject()
    return created
end

--- washing stations: {placeable=, storage=, fillTypeIndex=}
function H.getWashingStations()
    local list = {}
    local placeables = g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables or {}
    for _, placeable in pairs(placeables) do
        if type(placeable) == "table" and type(placeable.getIsBananaWashingStation) == "function" then
            for k, spec in pairs(placeable) do
                if type(k) == "string" and string.find(k, "bananaWashingStation", 1, true) and type(spec) == "table"
                    and type(spec.storage) == "table" and type(spec.storage.setFillLevel) == "function" then
                    list[#list + 1] = {placeable = placeable, storage = spec.storage, fillTypeIndex = spec.bananaFillTypeIndex}
                end
            end
        end
    end
    return list
end

local function freeRoom(station, fillType)
    local storage = station.storage
    if type(storage.getFreeCapacity) == "function" and fillType ~= nil then
        local free = storage:getFreeCapacity(fillType)
        if type(free) == "number" then
            return free
        end
    end
    return 0
end

--- the farm's washing station nearest to (x, z) with room for liters of fillType
function H.findStation(x, z, farmId, liters, fillType)
    local best, bestDist
    for _, station in ipairs(H.getWashingStations()) do
        local placeable = station.placeable
        local owner = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or placeable.ownerFarmId
        if owner == farmId and placeable.rootNode ~= nil and freeRoom(station, fillType or station.fillTypeIndex) >= liters then
            local sx, _, sz = getWorldTranslation(placeable.rootNode)
            local d = (sx - x) * (sx - x) + (sz - z) * (sz - z)
            if bestDist == nil or d < bestDist then
                best, bestDist = station, d
            end
        end
    end
    return best
end

local function stationName(station)
    if type(station.placeable.getName) == "function" then
        local name = station.placeable:getName()
        if name ~= nil then
            return tostring(name)
        end
    end
    return "washing station"
end

local function equip(player, tool)
    if type(player) ~= "table" or type(player.setCurrentHandTool) ~= "function" or type(tool) ~= "table" then
        return false
    end
    player:setCurrentHandTool(tool, false)
    return isHeld(tool)
end

---------------------------------------------------------------------------------------------------------------------

--- Starts harvesting the ripe plants accepted by accept(placeable, node, x, z) (BananaRegrow.collectPlants).
--- onDone(summary) runs when it is finished (summary = {harvested=, liters=, reason=}); when onDone is given, the
--- result is not announced (the caller does that). Returns started, reason/count:
---   true, numRipe        harvesting runs
---   false, "noRipe"|"noMachete"|"noStation"|"noStates"|"noVineSystem"|"busy", numRipe
function H.begin(accept, label, onDone, player, farmId, connection)
    player = player or g_localPlayer
    farmId = farmId or BananaRegrow.getFarmId()
    if H.queue ~= nil then
        return false, "busy", 0
    end
    local ranges = H.getRipeRanges()
    if ranges == nil then
        return false, "noStates", 0
    end
    local plants = BananaRegrow.collectPlants(accept)
    if plants == nil then
        return false, "noVineSystem", 0
    end
    local ripe = {}
    for _, plant in ipairs(plants) do
        if BananaRegrow.canFarmAccess(farmId, plant.placeable) and H.isRipe(plant, ranges) then
            ripe[#ripe + 1] = plant
        end
    end
    log("start: %d plants %s, %d of them ripe", #plants, label, #ripe)
    if #ripe == 0 then
        return false, "noRipe", 0
    end
    local knife = H.findKnife(player)
    if knife == nil then
        return false, "noMachete", #ripe
    end
    if #H.getWashingStations() == 0 then
        return false, "noStation", #ripe
    end
    H.queue = {plants = ripe, index = 0, knife = knife, player = player, farmId = farmId, ranges = ranges,
               harvested = 0, liters = 0, misses = 0, stations = {}, onDone = onDone, connection = connection,
               isServerOnly = g_server ~= nil and player ~= g_localPlayer}
    return true, #ripe
end

--- Console: radius = number, or nil for the whole plantation next to the player. Returns a message.
function H.start(radius)
    local x, _, z = BananaRegrow.getActorPosition()
    if x == nil then
        return "no player position"
    end
    local accept, label
    if radius ~= nil then
        local r2 = radius * radius
        accept = function(_, _, px, pz)
            return (px - x) * (px - x) + (pz - z) * (pz - z) <= r2
        end
        label = string.format("within %.0f m", radius)
    else
        local plantation = BananaRegrow.findPlantationNear(x, z)
        if not plantation then
            return "no banana plantation next to you"
        end
        accept = function(placeable)
            return placeable == plantation
        end
        label = "in the plantation"
    end
    local started, reason = H.begin(accept, label, nil)
    if started then
        return string.format("harvesting %d ripe plants", reason)
    end
    local messages = {noRipe = "no ripe plants found", noMachete = "carry the machete first", busy = "already harvesting",
                      noStation = "no washing station on the map", noStates = "banana states not available",
                      noVineSystem = "no vine system on this map"}
    return messages[reason] or tostring(reason)
end

function H.finish(reason)
    local q = H.queue
    H.queue = nil
    H.restoreAddNodeObject()
    if q == nil then
        return
    end
    equip(q.player, q.knife)
    local parts = {}
    for _, entry in pairs(q.stations) do
        parts[#parts + 1] = string.format("%.0f l to %s", entry.liters, stationName(entry.station))
    end
    log("%s: %d plants harvested, %.1f l bananas (%s)", reason, q.harvested, q.liters, table.concat(parts, ", "))
    local summary = {harvested = q.harvested, liters = q.liters, reason = reason}
    if q.onDone ~= nil then
        q.onDone(summary)
        return
    end
    BananaRegrow.notify(H.summaryText(summary), reason ~= "done")
end

function H.summaryText(summary)
    local message = BananaRegrow.text("bananaRegrow_result_harvested", summary.harvested, math.floor(summary.liters + 0.5))
    if summary.reason ~= "done" then
        message = message .. " - " .. BananaRegrow.text("bananaRegrow_result_harvestStopped") .. ": " .. tostring(summary.reason)
    end
    return message
end

--- Harvests one plant. Returns true to go on with the next plant this frame, false to wait for the next frame,
--- or nil, reason to stop.
function H.harvestOne(q, plant)
    local knife, held = q.knife, isHeld(q.knife)
    if not held and not equip(q.player, knife) then
        -- a remote player's tool may not show as held on the server at once: wait a little, then try anyway
        q.equipWait = (q.equipWait or 0) + 1
        if q.equipWait < 3 then
            return false
        end
        if not q.equipWarned then
            q.equipWarned = true
            log("machete not shown as held (server side), harvesting anyway")
        end
    else
        q.equipWait = 0
    end
    local before = select(2, H.findHeldBunch(q.player))
    local listedBefore = H.activeBunchSet()
    if type(knife.executeHarvest) ~= "function" or knife.isDeleted then
        return nil, "the machete is gone"
    end
    local created = H.callCapturingBunch(knife.executeHarvest, knife, plant.x, plant.y + H.BUNCH_HEIGHT, plant.z, false)
    local hands, bunch = H.findHeldBunch(q.player)
    local foundIn = "hands"
    if bunch == nil or bunch == before then
        bunch = nil
        if created ~= nil then
            bunch, foundIn = created, "new objects"
        else
            for b in pairs(H.activeBunchSet()) do
                if not listedBefore[b] then
                    bunch, foundIn = b, "rail list"
                end
            end
        end
    end
    if q.harvested == 0 and q.misses == 0 then
        log("first plant: machete held %s, bunch %s%s", tostring(isHeld(knife)), tostring(bunch ~= nil),
            bunch ~= nil and (" (found in the " .. foundIn .. ", " .. tostring(bunch.fillLevel) .. " l)") or "")
    end
    if bunch == nil then
        q.misses = q.misses + 1
        local states = BananaRegrow.stateHistogram(plant.sections[1])
        log("plant at %.1f %.1f gave no bunch (%s), skipped", plant.x, plant.z, tostring(states))
        if q.misses >= H.MAX_MISSES then
            return nil, "the machete stopped harvesting"
        end
        return true
    end
    q.misses = 0
    if hands ~= nil and type(hands.dropHeldItem) == "function" then
        hands:dropHeldItem(false)
    end
    local liters, station, reason = H.deliverBunch(bunch, plant.x, plant.z, q.farmId)
    if liters == nil then
        return nil, reason
    end
    q.harvested = q.harvested + 1
    q.liters = q.liters + liters
    local entry = q.stations[station.placeable]
    if entry == nil then
        entry = {station = station, liters = 0}
        q.stations[station.placeable] = entry
    end
    entry.liters = entry.liters + liters
    return true
end

--- Puts a bunch's liters into the farm's washing station nearest to (x, z) and deletes the bunch.
--- Returns liters, station, or nil, nil, reason.
function H.deliverBunch(bunch, x, z, farmId)
    local liters = tonumber(bunch.fillLevel) or 0
    local fillType = tonumber(bunch.fillType)
    local station = H.findStation(x, z, farmId, liters, fillType)
    if station == nil then
        return nil, nil, "no washing station of your farm has room (the last bunch lies on the ground)"
    end
    fillType = fillType or station.fillTypeIndex
    if type(bunch.delete) ~= "function" or bunch.isDeleted then
        return nil, nil, "could not remove the bunch object (it lies on the ground)"
    end
    bunch:delete()
    local storage = station.storage
    local current = storage.getFillLevel ~= nil and storage:getFillLevel(fillType) or 0
    storage:setFillLevel(current + liters, fillType)
    return liters, station
end

--- Server: every banana bunch lying loose within radius of (x, z) goes into the farm's washing station (bunches moving
--- along a rail are left alone). Returns number, liters, skipped.
function H.collectLoose(x, z, radius, farmId)
    local found, seen = {}, {}
    local r2 = radius * radius
    for node, object in pairs(g_currentMission.nodeToObject or {}) do
        if not seen[object] and H.isBunch(object) then
            seen[object] = true
            if type(node) == "number" and entityExists(node) then
                local bx, _, bz = getWorldTranslation(node)
                if (bx - x) * (bx - x) + (bz - z) * (bz - z) <= r2 then
                    found[#found + 1] = {bunch = object, x = bx, z = bz}
                end
            end
        end
    end
    local count, liters, skipped = 0, 0, 0
    for _, f in ipairs(found) do
        local b = f.bunch
        local onRail = (tonumber(rawget(b, "currentSegmentIndex")) or 0) > 0
        local owner = rawget(b, "ownerFarmId")
        if onRail or (owner ~= nil and owner ~= 0 and owner ~= farmId) then
            skipped = skipped + 1
        else
            local l = H.deliverBunch(b, f.x, f.z, farmId)
            if l == nil then
                break
            end
            count, liters = count + 1, liters + l
        end
    end
    log("collect: %d loose bunches within %.0f m put into the washing station (%.1f l), %d left (on a rail or another farm's)",
        count, radius, liters, skipped)
    return count, liters, skipped
end

function H.step()
    local q = H.queue
    for _ = 1, H.PLANTS_PER_FRAME do
        local plant = q.plants[q.index + 1]
        if plant == nil then
            H.finish("done")
            return
        end
        if not H.isRipe(plant, q.ranges) then
            q.index = q.index + 1
        else
            local goOn, reason = H.harvestOne(q, plant)
            if goOn == nil then
                H.finish(reason)
                return
            end
            if not goOn then
                q.waitFrames = (q.waitFrames or 0) + 1
                if q.waitFrames > 30 then
                    H.finish("could not put the machete in your hand")
                end
                return
            end
            q.waitFrames = 0
            q.index = q.index + 1
        end
    end
end

function H:update(dt)
    local q = H.queue
    if q ~= nil then
        if q.stepping then
            -- the last step stopped with an error (it is in the log above): end the harvest instead of repeating it
            log("the last harvest step failed, see the error above")
            H.finish("error, see log.txt")
            return
        end
        q.stepping = true
        H.step()
        q.stepping = false
    end
end

function H:consoleHarvest(arg)
    if H.queue ~= nil then
        H.finish("stopped by brHarvest")
        return "[BananaRegrow] harvest stopped"
    end
    local radius
    if string.lower(tostring(arg)) ~= "all" then
        radius = math.max(1, math.min(tonumber(arg) or H.DEFAULT_RADIUS, H.MAX_RADIUS))
    end
    return "[BananaRegrow] " .. tostring(H.start(radius))
end

function H:loadMap()
    if addConsoleCommand ~= nil then
        addConsoleCommand("brHarvest", "Banana Regrow: harvest all ripe plants within [radius=10] m (or 'all' = the plantation next to you)"
            .. " into the washing station; carry the machete", "consoleHarvest", H)
    end
end

function H:deleteMap()
    H.queue = nil
    H.restoreAddNodeObject()
    if removeConsoleCommand ~= nil then
        removeConsoleCommand("brHarvest")
    end
end

addModEventListener(H)
