--[[
    Banana Regrow - research tools for harvesting "like the machete" (read-only, console only)

    The Beans & Alpacas scripts are encrypted and undocumented. These two commands make the running game show how the
    machete harvests a bunch and hands it to the rail system, so the mod can make the same calls:

      brProbe   writes every class, function and event of the DLC script environment that deals with bananas, the rail,
                bunches, workers, the washing station, the orchard and the machete to log.txt, plus the live rail
                system, worker manager, washing stations and the machete (hold it while running the command).
      brTrace   ON/OFF. While on, every call into those classes and objects is written to log.txt with its arguments
                and return values (a few calls per function). Turn it on, take the machete, harvest one ripe plant and
                cut it down, turn it off.

      brRipen   [radius] makes the player's own banana plants within radius m (default 3) ripe, so there is something to
                harvest for the trace. This one DOES change the game (research only).

    In multiplayer the commands also run on the server (admins only), where the harvest and the rail really happen; the
    server's lines are sent back and appear in the player's own log.txt as "[server] ..." lines.

    Apart from brRipen nothing here changes the game state. Output lines start with [BananaRegrow:probe] /
    [BananaRegrow:trace].
]]

BananaRegrowProbe = {}
local P = BananaRegrowProbe

P.DLC_ENV_NAME = "pdlc_beansAndAlpacasPack"
P.WORDS = {"anana", "Orchard", "orchard", "Rail", "rail", "Bunch", "bunch", "Worker", "worker", "Knife", "knife",
           "Machete", "machete", "Washing", "washing", "Vine", "vine"}
P.MAX_LINES = 3000
P.TRACE_CALLS_PER_FUNCTION = 4
P.TRACE_MAX_LINES = 1500
P.TRACE_SKIP = {update = true, draw = true, onUpdate = true, onDraw = true, onUpdateTick = true, updateTick = true,
                mouseEvent = true, keyEvent = true, raiseActive = true, onUpdateEnd = true, frameUpdate = true}

P.RELAY_CHUNK = 1000        -- characters per relayed line piece
P.RELAY_EVENT_CHARS = 1800  -- characters per server -> client log event
P.RELAY_EVENTS_PER_FRAME = 3
P.RIPEN_DEFAULT_RADIUS = 3
P.RIPEN_MAX_RADIUS = 10
P.RIPE_STATE_NAME = "harvestReady"

---------------------------------------------------------------------------------------------------------------------
-- relaying the server's lines to the player who asked (multiplayer)
---------------------------------------------------------------------------------------------------------------------
P.relayTo = nil          -- connection that gets the lines printed right now (probe, ripen)
P.traceConnection = nil  -- connection that gets the trace lines while the server traces
P.relayQueue = {}

function P.relay(line, connection)
    connection = connection or P.relayTo
    if connection == nil then
        return
    end
    for i = 1, #line, P.RELAY_CHUNK do
        P.relayQueue[#P.relayQueue + 1] = {connection = connection, text = string.sub(line, i, i + P.RELAY_CHUNK - 1)}
    end
end

function P.flushRelay()
    local queue = P.relayQueue
    local sent = 0
    while #queue > 0 and sent < P.RELAY_EVENTS_PER_FRAME do
        local connection = queue[1].connection
        local parts, size = {}, 0
        while #queue > 0 and queue[1].connection == connection and (size == 0 or size + #queue[1].text < P.RELAY_EVENT_CHARS) do
            local entry = table.remove(queue, 1)
            parts[#parts + 1] = entry.text
            size = size + #entry.text + 1
        end
        pcall(connection.sendEvent, connection,
            BananaRegrowResearchEvent.new(BananaRegrowResearchEvent.ACTION_LOG, {text = table.concat(parts, "\n")}))
        sent = sent + 1
    end
end

--- Client: lines from the server's probe/trace
function P.onServerLog(text)
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        if line ~= "" then
            print("[server] " .. line)
        end
    end
end

P.lines = 0
local function out(prefix, fmt, ...)
    if P.lines >= P.MAX_LINES then
        return
    end
    P.lines = P.lines + 1
    local ok, s = pcall(string.format, fmt, ...)
    local line = prefix .. (ok and s or tostring(fmt))
    print(line)
    P.relay(line)
end
local function log(fmt, ...) out("[BananaRegrow:probe] ", fmt, ...) end

local function matches(name)
    if type(name) ~= "string" then
        return false
    end
    for _, w in ipairs(P.WORDS) do
        if string.find(name, w, 1, true) then
            return true
        end
    end
    return false
end

--- The real global table (a mod's _G is its own environment)
function P.getGlobals()
    if getfenv ~= nil then
        local ok, g = pcall(getfenv, 0)
        if ok and type(g) == "table" then
            return g
        end
    end
    return _G
end

local function className(obj)
    if ClassUtil ~= nil and ClassUtil.getClassNameByObject ~= nil then
        local ok, name = pcall(ClassUtil.getClassNameByObject, obj)
        if ok and type(name) == "string" then
            return name
        end
    end
    if type(obj) == "table" and type(rawget(obj, "className")) == "string" then
        return rawget(obj, "className")
    end
    return "?"
end

--- name -> function for an object: own fields and the __index chain of its metatables
local function functionsOf(obj)
    local fns, t, depth = {}, obj, 0
    while type(t) == "table" and depth < 10 do
        for k, v in pairs(t) do
            if type(k) == "string" and type(v) == "function" and fns[k] == nil then
                fns[k] = v
            end
        end
        local mt = getmetatable(t)
        if type(mt) ~= "table" then
            break
        end
        t = rawget(mt, "__index")
        depth = depth + 1
    end
    return fns
end

local function sortedNames(map)
    local names = {}
    for k in pairs(map) do
        names[#names + 1] = k
    end
    table.sort(names)
    return names
end

local function short(v, depth)
    local tv = type(v)
    if tv == "number" then
        if v == math.floor(v) then
            return tostring(v)
        end
        return string.format("%.3f", v)
    elseif tv == "string" then
        if #v > 60 then
            v = string.sub(v, 1, 57) .. "..."
        end
        return '"' .. v .. '"'
    elseif tv == "table" then
        local name = className(v)
        local n = 0
        for _ in pairs(v) do
            n = n + 1
        end
        local tag = rawget(v, "typeName") or rawget(v, "configFileName") or rawget(v, "name")
        if (depth or 0) < 1 and name == "?" and n <= 8 then
            local parts = {}
            for k, vv in pairs(v) do
                parts[#parts + 1] = tostring(k) .. "=" .. short(vv, (depth or 0) + 1)
            end
            return "{" .. table.concat(parts, " ") .. "}"
        end
        return string.format("<%s%s {%d}>", name, tag ~= nil and (" " .. tostring(tag)) or "", n)
    end
    return tostring(v)
end

local function fieldsOf(obj, limit)
    local parts, keys = {}, {}
    for k, v in pairs(obj) do
        if type(v) ~= "function" then
            keys[#keys + 1] = tostring(k)
        end
    end
    table.sort(keys)
    for i = 1, math.min(#keys, limit or 80) do
        local k = keys[i]
        local v = obj[k]
        if v == nil then
            v = obj[tonumber(k)]
        end
        parts[#parts + 1] = k .. "=" .. short(v, 1)
    end
    if #keys > (limit or 80) then
        parts[#parts + 1] = string.format("(+%d more)", #keys - (limit or 80))
    end
    return table.concat(parts, " ")
end

local function describe(label, obj)
    if type(obj) ~= "table" then
        log("%s: %s", label, tostring(obj))
        return
    end
    local mt = getmetatable(obj)
    log("%s: class=%s metatable=%s __index=%s", label, className(obj), type(mt), type(mt) == "table" and type(rawget(mt, "__index")) or "-")
    log("%s fields: %s", label, fieldsOf(obj, 100))
    log("%s functions: %s", label, table.concat(sortedNames(functionsOf(obj)), ", "))
end

--- first entry of every non-empty table field (to see the shape of bunches, hooks, trees, segments...)
local function describeChildren(label, obj)
    for k, v in pairs(obj) do
        if type(v) == "table" then
            local firstKey, firstVal = next(v)
            if firstKey ~= nil then
                local n = 0
                for _ in pairs(v) do
                    n = n + 1
                end
                log("%s.%s: %d entries, first [%s] = %s", label, tostring(k), n, short(firstKey),
                    type(firstVal) == "table" and (className(firstVal) .. " " .. fieldsOf(firstVal, 40)) or short(firstVal))
            end
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- brProbe
---------------------------------------------------------------------------------------------------------------------
function P.findDlcEnv()
    local G = P.getGlobals()
    local env = rawget(G, P.DLC_ENV_NAME)
    if type(env) == "table" then
        return env, P.DLC_ENV_NAME
    end
    for k, v in pairs(G) do
        if type(k) == "string" and type(v) == "table" and string.find(k, "beansAndAlpacas", 1, true) then
            return v, k
        end
    end
    return nil
end

--- class tables (and other tables) of interest: name -> table, from the DLC environment and the globals
function P.collectClasses()
    local classes = {}
    local env = P.findDlcEnv()
    if env ~= nil then
        for k, v in pairs(env) do
            if type(k) == "string" and type(v) == "table" and matches(k) then
                classes[k] = v
            end
        end
    end
    for k, v in pairs(P.getGlobals()) do
        if type(k) == "string" and type(v) == "table" and matches(k) and classes[k] == nil then
            classes[k] = v
        end
    end
    return classes
end

function P.runProbe()
    P.lines = 0
    local G = P.getGlobals()
    log("===== probe start (game %s) =====", tostring(g_gameVersionDisplay or g_gameVersion or "?"))
    local envNames = {}
    for k, v in pairs(G) do
        if type(k) == "string" and type(v) == "table" and (string.find(k, "^pdlc_") or string.find(k, "^FS25_")) then
            envNames[#envNames + 1] = k
        end
    end
    table.sort(envNames)
    log("script environments: %s", table.concat(envNames, ", "))

    local env, envName = P.findDlcEnv()
    if env == nil then
        log("DLC environment %s not found", P.DLC_ENV_NAME)
    else
        local all = {}
        for k, v in pairs(env) do
            if type(k) == "string" and rawget(_G, k) ~= v and rawget(G, k) ~= v then
                all[#all + 1] = k .. ":" .. type(v)
            end
        end
        table.sort(all)
        log("%s own names (%d): %s", envName, #all, table.concat(all, " "))
    end

    -- classes with all their functions
    local classes = P.collectClasses()
    for _, name in ipairs(sortedNames(classes)) do
        local cls = classes[name]
        local fns = sortedNames(functionsOf(cls))
        local isEvent = type(cls.readStream) == "function" and type(cls.writeStream) == "function"
        log("class %s%s (%d functions): %s", name, isEvent and " [EVENT]" or "", #fns, table.concat(fns, ", "))
        local consts = {}
        for k, v in pairs(cls) do
            if type(k) == "string" and (type(v) == "number" or type(v) == "string" or type(v) == "boolean") then
                consts[#consts + 1] = k .. "=" .. short(v)
            end
        end
        table.sort(consts)
        if #consts > 0 then
            log("  constants: %s", table.concat(consts, " "))
        end
    end

    -- live objects
    local mission = g_currentMission
    if mission ~= nil then
        local rail = mission.bananaRailSystem
        if rail ~= nil then
            describe("bananaRailSystem", rail)
            describeChildren("bananaRailSystem", rail)
            if type(rail.workerManager) == "table" then
                describe("workerManager", rail.workerManager)
                describeChildren("workerManager", rail.workerManager)
            end
        else
            log("g_currentMission.bananaRailSystem: nil")
        end
        for _, name in ipairs({"bananaCutDownEffectPool", "npcWorkerSystem", "orchardBuildManager", "vineSystem"}) do
            if mission[name] ~= nil then
                describe(name, mission[name])
            end
        end
        local placeables = mission.placeableSystem ~= nil and mission.placeableSystem.placeables or {}
        local seen = {}
        for _, placeable in pairs(placeables) do
            local typeName = tostring(placeable.typeName)
            if matches(typeName) and not seen[typeName] then
                seen[typeName] = true
                describe("placeable " .. typeName, placeable)
                for k, v in pairs(placeable) do
                    if type(k) == "string" and string.sub(k, 1, 5) == "spec_" and matches(k) and type(v) == "table" then
                        log("placeable %s %s: %s", typeName, k, fieldsOf(v, 80))
                        describeChildren("placeable " .. typeName .. " " .. k, v)
                    end
                end
            end
        end
        -- the machete in the player's hand
        local player = g_localPlayer
        if player ~= nil then
            local tool
            for _, getter in ipairs({"getHeldHandTool", "getCurrentHandTool", "getEquippedHandTool"}) do
                if tool == nil and type(player[getter]) == "function" then
                    local ok, t = pcall(player[getter], player)
                    if ok and type(t) == "table" then
                        tool = t
                    end
                end
            end
            if tool == nil then
                for k, v in pairs(player) do
                    if type(k) == "string" and string.find(k, "[Hh]and[Tt]ool") and type(v) == "table" and v.typeName ~= nil then
                        tool = v
                    end
                end
            end
            if tool == nil and mission.handToolSystem ~= nil and type(mission.handToolSystem.handTools) == "table" then
                for _, t in pairs(mission.handToolSystem.handTools) do
                    if type(t) == "table" and matches(tostring(t.typeName)) then
                        tool = t
                    end
                end
            end
            if tool ~= nil then
                describe("handTool " .. tostring(tool.typeName), tool)
                for k, v in pairs(tool) do
                    if type(k) == "string" and string.sub(k, 1, 5) == "spec_" and type(v) == "table" then
                        log("handTool %s: %s", k, fieldsOf(v, 80))
                    end
                end
            else
                log("no machete found: hold the machete while running brProbe")
            end
        end
    end
    log("===== probe end (%d lines) =====", P.lines)
    return "[BananaRegrow] probe written to log.txt"
end

---------------------------------------------------------------------------------------------------------------------
-- brTrace
---------------------------------------------------------------------------------------------------------------------
P.tracing = false
P.wrapped = {}       -- {owner=, key=, original=}
P.traceLines = 0
P.traceCounts = {}

local function tlog(fmt, ...)
    if P.traceLines >= P.TRACE_MAX_LINES then
        return
    end
    P.traceLines = P.traceLines + 1
    local ok, s = pcall(string.format, fmt, ...)
    local line = "[BananaRegrow:trace] " .. (ok and s or tostring(fmt))
    print(line)
    P.relay(line, P.traceConnection)
end

local function formatArgs(n, ...)
    local parts = {}
    for i = 1, n do
        parts[i] = short((select(i, ...)), 0)
    end
    return table.concat(parts, ", ")
end

local function wrap(owner, key, label)
    local original = rawget(owner, key)
    if type(original) ~= "function" or P.TRACE_SKIP[key] then
        return false
    end
    local fullName = label .. "." .. key
    local wrapper = function(...)
        local count = (P.traceCounts[fullName] or 0) + 1
        P.traceCounts[fullName] = count
        if not P.tracing or count > P.TRACE_CALLS_PER_FUNCTION then
            return original(...)
        end
        tlog("-> %s(%s)", fullName, formatArgs(select("#", ...), ...))
        local results = {original(...)}
        local n = 0
        for i in pairs(results) do
            if i > n then
                n = i
            end
        end
        if n > 0 then
            tlog("<- %s = %s", fullName, formatArgs(n, unpack(results, 1, n)))
        end
        return unpack(results, 1, n)
    end
    rawset(owner, key, wrapper)
    P.wrapped[#P.wrapped + 1] = {owner = owner, key = key, original = original, wrapper = wrapper}
    return true
end

local function wrapAll(owner, label)
    local n = 0
    local keys = {}
    for k, v in pairs(owner) do
        if type(k) == "string" and type(v) == "function" then
            keys[#keys + 1] = k
        end
    end
    for _, k in ipairs(keys) do
        if wrap(owner, k, label) then
            n = n + 1
        end
    end
    return n
end

function P.startTrace()
    P.traceLines = 0
    P.traceCounts = {}
    local total = 0
    -- class tables (functions found through __index and event listeners called on the class)
    for name, cls in pairs(P.collectClasses()) do
        if cls ~= BananaRegrow and cls ~= BananaRegrowProbe and cls ~= ConstructionBrushBananaRegrow
            and not string.find(name, "^BananaRegrow") then
            total = total + wrapAll(cls, name)
        end
    end
    -- objects: functions copied into instances by the specialization system
    local mission = g_currentMission
    if mission ~= nil then
        if type(mission.bananaRailSystem) == "table" then
            total = total + wrapAll(mission.bananaRailSystem, "bananaRailSystem")
            if type(mission.bananaRailSystem.workerManager) == "table" then
                total = total + wrapAll(mission.bananaRailSystem.workerManager, "workerManager")
            end
        end
        if type(mission.vineSystem) == "table" then
            total = total + wrapAll(mission.vineSystem, "vineSystem")
        end
        local placeables = mission.placeableSystem ~= nil and mission.placeableSystem.placeables or {}
        local wrappedTypes = {}
        for _, placeable in pairs(placeables) do
            local typeName = tostring(placeable.typeName)
            if matches(typeName) then
                -- every banana placeable (the orchards, the washing stations, the rails) is wrapped; the counter is
                -- per type name, so a call on any of them counts towards the same limit
                total = total + wrapAll(placeable, "placeable[" .. typeName .. "]")
                wrappedTypes[typeName] = true
            end
        end
        if mission.handToolSystem ~= nil and type(mission.handToolSystem.handTools) == "table" then
            P.wrappedTools = setmetatable({}, {__mode = "k"})
            for _, tool in pairs(mission.handToolSystem.handTools) do
                if type(tool) == "table" and matches(tostring(tool.typeName)) then
                    P.wrappedTools[tool] = true
                    total = total + wrapAll(tool, "handTool[" .. tostring(tool.typeName) .. "]")
                end
            end
        end
    end
    -- the engine density call the knife may use (same counters)
    if FSDensityMapUtil ~= nil then
        for _, key in ipairs({"updateVineCutArea", "resetVineArea", "updateVinePrepareArea", "setVineAreaValue", "updateVineAreaValues"}) do
            if wrap(FSDensityMapUtil, key, "FSDensityMapUtil") then
                total = total + 1
            end
        end
    end
    P.tracing = true
    P.newToolTimer = 0
    tlog("trace ON: %d functions wrapped. Take the machete, harvest one ripe plant, cut it down, then brTrace again.", total)
    return total
end

--- hand tools that appear while tracing (the banana bunch you carry after a harvest) are wrapped too
function P.wrapNewHandTools()
    local mission = g_currentMission
    if mission == nil or mission.handToolSystem == nil or type(mission.handToolSystem.handTools) ~= "table" then
        return
    end
    P.wrappedTools = P.wrappedTools or setmetatable({}, {__mode = "k"})
    for _, tool in pairs(mission.handToolSystem.handTools) do
        if type(tool) == "table" and not P.wrappedTools[tool] and matches(tostring(tool.typeName)) then
            P.wrappedTools[tool] = true
            local label = "handTool[" .. tostring(tool.typeName) .. "]"
            local n = wrapAll(tool, label)
            if n > 0 then
                tlog("new hand tool %s: %d functions wrapped (%s)", tostring(tool.typeName), n,
                    table.concat(sortedNames(functionsOf(tool)), ", "))
            end
        end
    end
end

function P.stopTrace()
    P.tracing = false
    for i = #P.wrapped, 1, -1 do
        local w = P.wrapped[i]
        if rawget(w.owner, w.key) == w.wrapper then
            rawset(w.owner, w.key, w.original)
        end
    end
    local n = #P.wrapped
    P.wrapped = {}
    P.wrappedTools = nil
    local called = {}
    for name, count in pairs(P.traceCounts) do
        called[#called + 1] = string.format("%s x%d", name, count)
    end
    table.sort(called)
    tlog("trace OFF: %d functions restored. Calls while on: %s", n, table.concat(called, ", "))
end

---------------------------------------------------------------------------------------------------------------------
-- brRipen: make the plants around the player ripe, so the machete can be traced (research only)
---------------------------------------------------------------------------------------------------------------------

--- Sets the banana plants of the farm whose centre is within radius of (x, z) to the ripe state. Returns the number
--- of plants changed and found, or nil and a reason.
function P.ripen(x, z, radius, farmId)
    if BananaRegrow == nil then
        return nil, "Banana Regrow not loaded"
    end
    local states = BananaRegrow.resolveStates()
    local desc = BananaRegrow.getFruit()
    if states == nil or desc == nil or BananaRegrow.getModifier() == nil then
        return nil, "banana fruit type or density map not available"
    end
    local ripe = BananaRegrow.getStateIndex(desc, P.RIPE_STATE_NAME)
    if ripe == nil then
        return nil, "state " .. P.RIPE_STATE_NAME .. " not found"
    end
    local ranges = {}
    if ripe > 1 then
        ranges[#ranges + 1] = {1, ripe - 1}
    end
    if ripe < states.numStates then
        ranges[#ranges + 1] = {ripe + 1, states.numStates}
    end
    local r2 = radius * radius
    local plants = BananaRegrow.collectPlants(function(_, _, px, pz)
        return (px - x) * (px - x) + (pz - z) * (pz - z) <= r2
    end)
    if plants == nil then
        return nil, "no vine system on this map"
    end
    local changed = 0
    for _, plant in ipairs(plants) do
        if BananaRegrow.canFarmAccess(farmId, plant.placeable) then
            local pixels = 0
            for _, section in ipairs(plant.sections) do
                pixels = pixels + BananaRegrow.applyRanges(section, ranges, ripe)
            end
            if pixels > 0 then
                changed = changed + 1
                BananaRegrow.refreshNode(plant.placeable, plant.node)
            end
        end
    end
    return changed, #plants
end

---------------------------------------------------------------------------------------------------------------------
-- server side of the multiplayer requests
---------------------------------------------------------------------------------------------------------------------

--- Is the requesting connection an admin (master user)? nil connection = the local player of a single player game
function P.getRequester(connection)
    if connection == nil then
        return true, BananaRegrow ~= nil and BananaRegrow.getFarmId() or 1
    end
    local mission = g_currentMission
    local player
    if mission.playerSystem ~= nil and mission.playerSystem.getPlayerByConnection ~= nil then
        local ok, p = pcall(mission.playerSystem.getPlayerByConnection, mission.playerSystem, connection)
        if ok and type(p) == "table" then
            player = p
        end
    end
    local user
    local userManager = mission.userManager
    if userManager ~= nil then
        if player ~= nil and player.userId ~= nil and userManager.getUserByUserId ~= nil then
            local ok, u = pcall(userManager.getUserByUserId, userManager, player.userId)
            if ok and type(u) == "table" then
                user = u
            end
        end
        if user == nil and userManager.getUserByConnection ~= nil then
            local ok, u = pcall(userManager.getUserByConnection, userManager, connection)
            if ok and type(u) == "table" then
                user = u
            end
        end
    end
    local isAdmin = false
    if user ~= nil and user.getIsMasterUser ~= nil then
        local ok, admin = pcall(user.getIsMasterUser, user)
        isAdmin = ok and admin == true
    end
    return isAdmin, player ~= nil and player.farmId or nil
end

function P.serverAction(action, data, connection)
    local isAdmin, farmId = P.getRequester(connection)
    P.relayTo = connection
    P.lines = 0
    if not isAdmin then
        log("server: %s refused - log in as admin first (Esc > admin login)", ({[1] = "brProbe", [2] = "brTrace", [3] = "brRipen", [5] = "brCollect"})[action] or "request")
        P.relayTo = nil
        return
    end
    if action == BananaRegrowResearchEvent.ACTION_PROBE then
        local ok, err = pcall(P.runProbe)
        if not ok then
            log("server probe failed: %s", tostring(err))
        end
    elseif action == BananaRegrowResearchEvent.ACTION_TRACE then
        if data.on and not P.tracing then
            P.traceConnection = connection
            local ok, err = pcall(P.startTrace)
            if not ok then
                log("server trace failed: %s", tostring(err))
                pcall(P.stopTrace)
                P.traceConnection = nil
            end
        elseif not data.on and (P.tracing or #P.wrapped > 0) then
            P.stopTrace()
            P.traceConnection = nil
        end
    elseif action == BananaRegrowResearchEvent.ACTION_COLLECT then
        local H = BananaRegrowHarvest
        if H ~= nil then
            local radius = math.max(1, math.min(tonumber(data.radius) or 30, 100))
            H.logConnection = connection
            local ok, err = pcall(H.collectLoose, data.x, data.z, radius, farmId)
            H.logConnection = nil
            if not ok then
                log("collect failed: %s", tostring(err))
            end
        end
    elseif action == BananaRegrowResearchEvent.ACTION_RIPEN then
        local radius = math.max(0.5, math.min(tonumber(data.radius) or P.RIPEN_DEFAULT_RADIUS, P.RIPEN_MAX_RADIUS))
        local ok, changed, found = pcall(P.ripen, data.x, data.z, radius, farmId)
        if not ok then
            log("ripen failed: %s", tostring(changed))
        elseif changed == nil then
            log("ripen: %s", tostring(found))
        else
            log("ripen: %d of %d banana plants within %.1f m of %.1f %.1f made ripe (farm %s)", changed, found, radius,
                data.x, data.z, tostring(farmId))
        end
    end
    P.relayTo = nil
end

---------------------------------------------------------------------------------------------------------------------
-- brMenu: the production menu's buttons (why "Manage workers" shows on one map and not on another)
---------------------------------------------------------------------------------------------------------------------
--- where a function comes from ("file:line"), or "?" when the debug library is not available
local function sourceOf(fn)
    if debug == nil or debug.getinfo == nil then
        return "?"
    end
    local ok, info = pcall(debug.getinfo, fn, "S")
    if not ok or type(info) ~= "table" then
        return "?"
    end
    return string.format("%s:%s", tostring(info.short_src or info.source), tostring(info.linedefined))
end

--- logs a hooked function and, through the upvalues of the Utils.*Function closures, every function it chains to
local function logHookChain(label, fn, depth, seen)
    depth, seen = depth or 0, seen or {}
    if type(fn) ~= "function" or seen[fn] or depth > 12 then
        return
    end
    seen[fn] = true
    log("%s%s %s", string.rep("  ", depth), label, sourceOf(fn))
    if debug == nil or debug.getupvalue == nil then
        return
    end
    for i = 1, 20 do
        local ok, name, value = pcall(debug.getupvalue, fn, i)
        if not ok or name == nil then
            break
        end
        if type(value) == "function" then
            logHookChain("upvalue " .. tostring(name), value, depth + 1, seen)
        end
    end
end

local function buttonText(info)
    if type(info) ~= "table" then
        return tostring(info)
    end
    local action = info.inputAction
    for name, value in pairs(InputAction or {}) do
        if value == action then
            action = name
            break
        end
    end
    return string.format("text=%s inputAction=%s profile=%s callback=%s", short(info.text), tostring(action),
        tostring(info.profile), type(info.callback))
end

--- the in-game menu's production page (the instance, not the class)
function P.findProductionFrame()
    local menu = g_inGameMenu
    if type(menu) ~= "table" then
        return nil
    end
    if type(menu.pageProduction) == "table" then
        return menu.pageProduction, "pageProduction"
    end
    for k, v in pairs(menu) do
        if type(v) == "table" and type(v.getSelectedProduction) == "function" and type(v.updateMenuButtons) == "function" then
            return v, tostring(k)
        end
    end
    return nil
end

function P.runMenuProbe()
    P.lines = 0
    log("===== menu probe start (game %s, map %s) =====", tostring(g_gameVersionDisplay or g_gameVersion or "?"),
        tostring(g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.mapId or "?"))
    log("debug library: %s", tostring(debug ~= nil and debug.getinfo ~= nil))

    local cls = InGameMenuProductionFrame
    if type(cls) ~= "table" then
        log("InGameMenuProductionFrame: %s", tostring(cls))
        return "[BananaRegrow] InGameMenuProductionFrame not found"
    end
    local own = {}
    for k, v in pairs(cls) do
        if type(k) == "string" and type(v) == "function" then
            own[#own + 1] = k
        end
    end
    table.sort(own)
    log("InGameMenuProductionFrame functions (%d): %s", #own, table.concat(own, ", "))
    local consts = {}
    for k, v in pairs(cls) do
        if type(k) == "string" and type(v) ~= "function" and type(v) ~= "table" then
            consts[#consts + 1] = k .. "=" .. short(v)
        end
    end
    table.sort(consts)
    log("InGameMenuProductionFrame constants: %s", table.concat(consts, " "))

    for _, name in ipairs({"updateMenuButtons", "onButtonToggleOutputMode", "onListSelectionChanged",
                           "setSelectedProductionPoint", "getSelectedProduction", "onFrameOpen"}) do
        logHookChain("InGameMenuProductionFrame." .. name, cls[name])
    end

    local frame, frameKey = P.findProductionFrame()
    if frame == nil then
        log("production page not found in g_inGameMenu")
        return "[BananaRegrow] menu probe: production page not found, see log.txt"
    end
    log("production page: g_inGameMenu.%s class=%s", frameKey, className(frame))
    for _, name in ipairs({"updateMenuButtons", "onButtonToggleOutputMode"}) do
        if rawget(frame, name) ~= nil then
            logHookChain("instance override " .. name, rawget(frame, name))
        end
    end

    local infoKeys = {}
    for k, v in pairs(frame) do
        if type(k) == "string" and type(v) == "table" and string.find(k, "ButtonInfo", 1, true) and k ~= "menuButtonInfo" then
            infoKeys[#infoKeys + 1] = k
        end
    end
    table.sort(infoKeys)
    for _, k in ipairs(infoKeys) do
        log("button %s: %s", k, buttonText(frame[k]))
    end
    local current = frame.menuButtonInfo
    if type(current) == "table" then
        log("bottom bar now (%d buttons):", #current)
        for i, info in ipairs(current) do
            local key = "?"
            for _, k in ipairs(infoKeys) do
                if frame[k] == info then
                    key = k
                    break
                end
            end
            log("  %d. [%s] %s", i, key, buttonText(info))
        end
    else
        log("menuButtonInfo: %s", tostring(current))
    end
    if frame.pointsSelector ~= nil and frame.pointsSelector.getState ~= nil then
        log("points selector state: %s (owned = %s)", tostring(frame.pointsSelector:getState()), tostring(cls.POINTS_OWNED))
    end

    local ok, production, productionPoint = pcall(frame.getSelectedProduction, frame)
    if not ok then
        log("getSelectedProduction failed: %s", tostring(production))
    elseif type(productionPoint) ~= "table" then
        log("no production point selected (select the washing station in the list first)")
    else
        log("selected production: %s", type(production) == "table" and short(production.id or production.name) or tostring(production))
        log("selected production point fields: %s", fieldsOf(productionPoint, 60))
        local placeable = productionPoint.owningPlaceable
        if type(placeable) == "table" then
            local specs = {}
            for k in pairs(placeable) do
                if type(k) == "string" and string.find(k, "^spec_") then
                    specs[#specs + 1] = k
                end
            end
            table.sort(specs)
            log("placeable %s (%s) farm %s specs: %s", tostring(placeable.typeName), tostring(placeable.configFileNameClean),
                tostring(placeable.ownerFarmId), table.concat(specs, " "))
            local fns = {}
            for name in pairs(functionsOf(placeable)) do
                if matches(name) then
                    fns[#fns + 1] = name
                end
            end
            table.sort(fns)
            log("placeable banana/worker functions: %s", table.concat(fns, ", "))
            for _, k in ipairs(specs) do
                if matches(k) then
                    log("%s fields: %s", k, fieldsOf(placeable[k], 60))
                end
            end
        end
    end
    log("===== menu probe end (%d lines) =====", P.lines)
    return "[BananaRegrow] menu probe written to log.txt"
end

local function isClientOnly()
    return g_server == nil and g_client ~= nil
end

local function sendToServer(action, data)
    local ok = pcall(function()
        g_client:getServerConnection():sendEvent(BananaRegrowResearchEvent.new(action, data))
    end)
    return ok
end

---------------------------------------------------------------------------------------------------------------------
-- console commands
---------------------------------------------------------------------------------------------------------------------
function P:consoleProbe()
    local ok, result = pcall(P.runProbe)
    if not ok then
        print("[BananaRegrow:probe] failed: " .. tostring(result))
        result = "[BananaRegrow] probe failed, see log.txt"
    end
    if isClientOnly() and sendToServer(BananaRegrowResearchEvent.ACTION_PROBE) then
        result = result .. " (the server's probe follows as [server] lines)"
    end
    return result
end

function P:consoleMenu()
    local ok, result = pcall(P.runMenuProbe)
    if not ok then
        print("[BananaRegrow:probe] menu probe failed: " .. tostring(result))
        return "[BananaRegrow] menu probe failed, see log.txt"
    end
    return result
end

function P:consoleTrace()
    if P.tracing or #P.wrapped > 0 then
        P.stopTrace()
        if isClientOnly() then
            sendToServer(BananaRegrowResearchEvent.ACTION_TRACE, {on = false})
        end
        return "[BananaRegrow] trace OFF, see log.txt"
    end
    local ok, n = pcall(P.startTrace)
    if not ok then
        print("[BananaRegrow:trace] failed: " .. tostring(n))
        pcall(P.stopTrace)
        return "[BananaRegrow] trace failed, see log.txt"
    end
    if isClientOnly() then
        sendToServer(BananaRegrowResearchEvent.ACTION_TRACE, {on = true})
    end
    return string.format("[BananaRegrow] trace ON (%d functions). Harvest one plant with the machete, cut it down, then brTrace again.", n)
end

function P:consoleRipen(radiusText)
    if BananaRegrow == nil then
        return "[BananaRegrow] not loaded"
    end
    local x, _, z = BananaRegrow.getActorPosition()
    if x == nil then
        return "[BananaRegrow] no player position"
    end
    local radius = tonumber(radiusText) or P.RIPEN_DEFAULT_RADIUS
    local data = {x = x, z = z, radius = radius}
    if g_server ~= nil then
        P.serverAction(BananaRegrowResearchEvent.ACTION_RIPEN, data, nil)
        return "[BananaRegrow] ripen done, see log.txt (look at the plant again if it still shows the old state)"
    end
    if sendToServer(BananaRegrowResearchEvent.ACTION_RIPEN, data) then
        return "[BananaRegrow] ripen sent to the server (admins only); the answer comes as a [server] line in log.txt"
    end
    return "[BananaRegrow] could not reach the server"
end

function P:consoleCollect(radiusText)
    if BananaRegrow == nil then
        return "[BananaRegrow] not loaded"
    end
    local x, _, z = BananaRegrow.getActorPosition()
    if x == nil then
        return "[BananaRegrow] no player position"
    end
    local data = {x = x, z = z, radius = tonumber(radiusText) or 30}
    if g_server ~= nil then
        P.serverAction(BananaRegrowResearchEvent.ACTION_COLLECT, data, nil)
        return "[BananaRegrow] collect done, see log.txt"
    end
    if sendToServer(BananaRegrowResearchEvent.ACTION_COLLECT, data) then
        return "[BananaRegrow] collect sent to the server (admins only); the answer comes as a [server] line in log.txt"
    end
    return "[BananaRegrow] could not reach the server"
end

function P:loadMap()
    pcall(addConsoleCommand, "brProbe", "Banana Regrow: write the DLC's banana/rail/machete classes and objects to the log", "consoleProbe", P)
    pcall(addConsoleCommand, "brMenu", "Banana Regrow: write the production menu's buttons and their hooks to the log (open the menu on the washing station first)", "consoleMenu", P)
    pcall(addConsoleCommand, "brTrace", "Banana Regrow: ON/OFF log every call into the banana/rail/machete code (use the machete while on)", "consoleTrace", P)
    pcall(addConsoleCommand, "brCollect", "Banana Regrow: put the banana bunches lying loose within [radius=30] m into your washing station", "consoleCollect", P)
    pcall(addConsoleCommand, "brRipen", "Banana Regrow (research): make your banana plants within [radius=3] m ripe", "consoleRipen", P)
end

function P:update(dt)
    if #P.relayQueue > 0 then
        P.flushRelay()
    end
    if P.tracing then
        P.newToolTimer = (P.newToolTimer or 0) - dt
        if P.newToolTimer <= 0 then
            P.newToolTimer = 250
            pcall(P.wrapNewHandTools)
        end
    end
end

function P:deleteMap()
    if #P.wrapped > 0 then
        P.stopTrace()
    end
    P.relayQueue = {}
    P.traceConnection = nil
    pcall(removeConsoleCommand, "brProbe")
    pcall(removeConsoleCommand, "brMenu")
    pcall(removeConsoleCommand, "brTrace")
    pcall(removeConsoleCommand, "brRipen")
    pcall(removeConsoleCommand, "brCollect")
end

addModEventListener(P)
