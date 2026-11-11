--[[
    Banana Regrow

    Cuts back all banana plants in a marked area (or a whole plantation) at once, the way the Beans & Alpacas Pack
    machete does one plant at a time, so they regrow.

    How bananas work (base game data/foliage/banana/banana.xml, DLC orchards): a plantation is a vine-system
    placeable (PlaceableVine: rows are fence segments, every panel is a "vine node" registered in
    g_currentMission.vineSystem.nodes with node -> placeable). The plants themselves are a foliage density layer of
    fruit type BANANA with these states, in XML order (1-based):
        regrowSmall, regrowMiddle, regrowMiddle2, noFruits, greenSmall, greenBig, greenBigSick, harvestReady,
        harvestReady2, harvestReadySick, harvestReadySick2, withered, harvested, cutDownHalf, cutDownFully
    Growth only continues from cutDownFully (-> regrowSmall -> ... -> noFruits -> fruit again). harvested and
    cutDownHalf never change by themselves: that is what the machete's cut-down swings are for.

    What this mod does: for every banana vine node in the area it sets the pixels in the states that need the
    machete (harvested, cutDownHalf, withered) to cutDownFully with a DensityMapModifier on the banana layer, then
    calls placeable:updateVineNode(node) so the plant model switches to the cut-down look. Plants with fruit or
    still growing are untouched (console brCutAll switches to "everything that stands" for a full reset).
    State numbers are never hard-coded: they are resolved by name from the fruit type description at runtime.

    Multiplayer: density map writes only replicate from the server, so a client sends BananaRegrowCutEvent, the
    server cuts and answers with BananaRegrowResultEvent. Marking, preview counts and drawing are local.
]]

BananaRegrow = {}
BananaRegrow.MOD_NAME = g_currentModName
BananaRegrow.FRUIT_NAME = "BANANA"
BananaRegrow.CUT_STATE_NAMES = {"harvested", "cutDownHalf", "withered"}    -- what the machete has to cut down
BananaRegrow.KEEP_STATE_NAMES = {"regrowSmall", "regrowMiddle", "regrowMiddle2"} -- never touched, not even by brCutAll
BananaRegrow.TARGET_STATE_NAME = "cutDownFully"
BananaRegrow.ORCHARD_PICK_RADIUS = 15     -- m: with no area marked, the plantation with a plant this close is taken
BananaRegrow.RECT_MARGIN = 0.5            -- m added around the two marked corners
BananaRegrow.PREVIEW_REFRESH_MS = 10000   -- the plant counts of a marked area are refreshed this often
BananaRegrow.RESULT_RECOUNT_MS = 1500     -- and this long after a cut (the density map needs a moment to sync)
BananaRegrow.MAX_DRAWN_PLANTS = 2000
BananaRegrow.DEBUG = false
BananaRegrow.MESSAGE_MS = 6000          -- on foot, a message stays this long on the player's screen
BananaRegrow.MAX_MESSAGES = 3
BananaRegrow.messages = {}
-- what happened to the ripe plants (sent back with the result)
BananaRegrow.HARVEST_NONE = 0        -- nothing ripe / no harvest asked
BananaRegrow.HARVEST_DONE = 1
BananaRegrow.HARVEST_STOPPED = 2     -- started, stopped early (reason in the log)
BananaRegrow.HARVEST_NO_MACHETE = 3
BananaRegrow.HARVEST_NO_STATION = 4
BananaRegrow.HARVEST_BUSY = 5
BananaRegrow.HARVEST_REASONS = {noMachete = 3, noStation = 4, busy = 5, noRipe = 0, noStates = 0, noVineSystem = 0}
BananaRegrow.cutAll = false

BananaRegrow.corners = {}      -- up to two {x, y, z}
BananaRegrow.rect = nil        -- {minX, minZ, maxX, maxZ}
BananaRegrow.preview = nil     -- {numPlants=, numNeedCut=, plants={{x=,y=,z=,needsCut=}, ...}}
BananaRegrow.previewTimer = 0
BananaRegrow.recountTimer = nil
BananaRegrow.eventIds = {}
BananaRegrow.placeableFruit = setmetatable({}, {__mode = "k"})

local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    Logging.info("[BananaRegrow] " .. (ok and s or tostring(fmt)))
end

local function warn(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    Logging.warning("[BananaRegrow] " .. (ok and s or tostring(fmt)))
end

local function dbg(fmt, ...)
    if BananaRegrow.DEBUG then
        log(fmt, ...)
    end
end

local function text(key, ...)
    local s = g_i18n:getText(key)
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, s, ...)
        if ok then
            return formatted
        end
    end
    return s
end
BananaRegrow.text = text

---------------------------------------------------------------------------------------------------------------------
-- fruit type, states, density map
---------------------------------------------------------------------------------------------------------------------
function BananaRegrow.getTerrainNode()
    return g_terrainNode or (g_currentMission ~= nil and g_currentMission.terrainRootNode) or nil
end

function BananaRegrow.getTerrainHeight(x, z)
    local terrain = BananaRegrow.getTerrainNode()
    if terrain ~= nil then
        return getTerrainHeightAtWorldPos(terrain, x, 0, z)
    end
    return 0
end

function BananaRegrow.getFruit()
    if BananaRegrow.fruit == nil then
        local desc = nil
        if g_fruitTypeManager ~= nil then
            desc = g_fruitTypeManager:getFruitTypeByName(BananaRegrow.FRUIT_NAME)
        end
        BananaRegrow.fruit = desc or false
    end
    return BananaRegrow.fruit or nil
end

--- Growth state index of a foliage state name, from the fruit description (FruitTypeDesc keeps
--- growthStateToName / nameToGrowthState and offers getGrowthStateByName). nil when the game does not know it.
function BananaRegrow.getStateIndex(desc, name)
    if desc.getGrowthStateByName ~= nil then
        local ok, index = pcall(desc.getGrowthStateByName, desc, name)
        if ok and type(index) == "number" then
            return index
        end
    end
    if type(desc.nameToGrowthState) == "table" then
        local index = desc.nameToGrowthState[string.upper(name)]
        if type(index) == "number" then
            return index
        end
    end
    if type(desc.growthStateToName) == "table" then
        for index, stateName in pairs(desc.growthStateToName) do
            if stateName == name and type(index) == "number" then
                return index
            end
        end
    end
    return nil
end

--- Contiguous ranges {{from, to}, ...} of a list of state indices, for BETWEEN filters
local function toRanges(list)
    local sorted = {}
    for i, v in ipairs(list) do
        sorted[i] = v
    end
    table.sort(sorted)
    local ranges = {}
    for _, v in ipairs(sorted) do
        local last = ranges[#ranges]
        if last ~= nil and v == last[2] then
            -- duplicate
        elseif last ~= nil and v == last[2] + 1 then
            last[2] = v
        else
            ranges[#ranges + 1] = {v, v}
        end
    end
    return ranges
end

--- Resolves the banana states and density map data once. Returns the table or nil (then the mod is idle).
function BananaRegrow.resolveStates()
    if BananaRegrow.states ~= nil then
        return BananaRegrow.states or nil
    end

    local desc = BananaRegrow.getFruit()
    if desc == nil then
        BananaRegrow.states = false
        warn("fruit type %s not found, the mod stays idle", BananaRegrow.FRUIT_NAME)
        return nil
    end

    local target = BananaRegrow.getStateIndex(desc, BananaRegrow.TARGET_STATE_NAME)
    local cut, missing = {}, {}
    for _, name in ipairs(BananaRegrow.CUT_STATE_NAMES) do
        local index = BananaRegrow.getStateIndex(desc, name)
        if index ~= nil then
            cut[#cut + 1] = index
        else
            missing[#missing + 1] = name
        end
    end
    local keep = {}
    for _, name in ipairs(BananaRegrow.KEEP_STATE_NAMES) do
        local index = BananaRegrow.getStateIndex(desc, name)
        if index ~= nil then
            keep[index] = true
        end
    end

    local numStates = desc.numFoliageStates
    if type(numStates) ~= "number" or numStates <= 0 then
        numStates = type(desc.growthStateToName) == "table" and #desc.growthStateToName or 0
    end

    if target == nil or #cut == 0 or numStates == 0 or desc.terrainDataPlaneId == nil then
        BananaRegrow.states = false
        warn("banana growth states not resolved (target %s=%s, cut states found %d of %d, missing: %s, states %d, density map %s). The mod stays idle.",
            BananaRegrow.TARGET_STATE_NAME, tostring(target), #cut, #BananaRegrow.CUT_STATE_NAMES, table.concat(missing, ","), numStates,
            tostring(desc.terrainDataPlaneId))
        return nil
    end

    -- "all": everything that stands except the regrowing states and the target itself
    local all = {}
    for i = 1, numStates do
        if i ~= target and not keep[i] then
            all[#all + 1] = i
        end
    end

    BananaRegrow.states = {
        target = target,
        cut = cut,
        cutRanges = toRanges(cut),
        all = all,
        allRanges = toRanges(all),
        numStates = numStates,
        mapId = desc.terrainDataPlaneId,
        firstChannel = desc.startStateChannel or 0,
        numChannels = desc.numStateChannels or 4,
    }
    if #missing > 0 then
        warn("state(s) %s not found in the banana fruit type, cutting only %d state(s)", table.concat(missing, ","), #cut)
    end
    log("ready: %s=%d, cut states %s -> %d, %d foliage states, channels %d+%d", BananaRegrow.TARGET_STATE_NAME, target,
        table.concat(cut, ","), target, numStates, BananaRegrow.states.firstChannel, BananaRegrow.states.numChannels)
    return BananaRegrow.states
end

function BananaRegrow.getStateRanges()
    local states = BananaRegrow.resolveStates()
    if states == nil then
        return nil
    end
    return BananaRegrow.cutAll and states.allRanges or states.cutRanges
end

--- Modifier + filter on the banana layer (created once per map). nil when the engine refuses.
function BananaRegrow.getModifier()
    if BananaRegrow.modifier == false then
        return nil
    end
    if BananaRegrow.modifier == nil then
        local states = BananaRegrow.resolveStates()
        local terrain = BananaRegrow.getTerrainNode()
        if states == nil or terrain == nil or DensityMapModifier == nil or DensityMapFilter == nil then
            BananaRegrow.modifier = false
            return nil
        end
        local ok, modifier = pcall(DensityMapModifier.new, states.mapId, states.firstChannel, states.numChannels, terrain)
        if not ok or modifier == nil then
            BananaRegrow.modifier = false
            warn("DensityMapModifier for the banana layer failed: %s", tostring(modifier))
            return nil
        end
        local okF, filter = pcall(DensityMapFilter.new, modifier)
        if not okF or filter == nil then
            BananaRegrow.modifier = false
            warn("DensityMapFilter failed: %s", tostring(filter))
            return nil
        end
        BananaRegrow.modifier, BananaRegrow.filter = modifier, filter
    end
    return BananaRegrow.modifier, BananaRegrow.filter
end

--- Counts (setValue == nil) or sets the pixels of a section whose state lies in one of the ranges.
--- section = {startX, startZ, widthX, widthZ, heightX, heightZ} (PlaceableVine section layout)
function BananaRegrow.applyRanges(section, ranges, setValue)
    local modifier, filter = BananaRegrow.getModifier()
    if modifier == nil then
        return 0
    end
    modifier:setParallelogramWorldCoords(section[1], section[2], section[3], section[4], section[5], section[6], DensityCoordType.POINT_POINT_POINT)
    local total = 0
    for _, range in ipairs(ranges) do
        if range[1] == range[2] then
            filter:setValueCompareParams(DensityValueCompareType.EQUAL, range[1])
        else
            filter:setValueCompareParams(DensityValueCompareType.BETWEEN, range[1], range[2])
        end
        -- count with executeGet (returns _, numPixels, totalPixels like in the game's own code); executeSet's return
        -- values are not a pixel count, so the pixels to change are counted before the set
        local _, pixels = modifier:executeGet(filter)
        pixels = tonumber(pixels) or 0
        if setValue ~= nil and pixels > 0 then
            modifier:executeSet(setValue, filter)
        end
        total = total + pixels
    end
    return total
end

---------------------------------------------------------------------------------------------------------------------
-- plantations and their plants (vine nodes)
--
-- Two layouts exist. Base game vineyards (PlaceableVine): spec_vine.nodes[node] = {sections = {...}}. The Beans &
-- Alpacas orchards (placeable type pdlc_beansAndAlpacasPack.orchard: placement + newFence + orchard spec): every fence
-- segment carries segment.vineNodes[node] = {growthValues = ..., sections = ...}. Both register their nodes in
-- g_currentMission.vineSystem.nodes (node -> placeable).
---------------------------------------------------------------------------------------------------------------------
BananaRegrow.nodeDataCache = setmetatable({}, {__mode = "k"})   -- placeable -> {map = {node -> data}, spec = table|false}

--- The spec table of the placeable that stores plant data (spec_vine, or the DLC orchard spec), or nil
function BananaRegrow.findPlantSpec(placeable)
    if type(placeable.spec_vine) == "table" then
        return placeable.spec_vine
    end
    local best = nil
    for key, value in pairs(placeable) do
        if type(key) == "string" and string.sub(key, 1, 5) == "spec_" and type(value) == "table" then
            if string.find(key, "[Oo]rchard") or string.find(key, "[Vv]ine") then
                return value
            end
            if type(value.nodes) == "table" and best == nil then
                best = value
            end
        end
    end
    return best
end

--- The fence of the placeable (PlaceableFence / PlaceableNewFence): placeable:getFence() or the spec table
function BananaRegrow.getFence(placeable)
    if placeable.getFence ~= nil then
        local ok, fence = pcall(placeable.getFence, placeable)
        if ok and type(fence) == "table" then
            return fence
        end
    end
    if type(placeable.spec_newFence) == "table" then
        return placeable.spec_newFence
    end
    if type(placeable.spec_fence) == "table" then
        return placeable.spec_fence
    end
    return nil
end

--- node -> data map of a placeable, built from spec.nodes and from segment.vineNodes of its fence segments
local function buildNodeMap(placeable)
    local map, count = {}, 0
    local spec = BananaRegrow.findPlantSpec(placeable)
    if spec ~= nil and type(spec.nodes) == "table" then
        for node, data in pairs(spec.nodes) do
            if type(data) == "table" then
                map[node] = data
                count = count + 1
            end
        end
    end
    local fence = BananaRegrow.getFence(placeable)
    local segments = fence ~= nil and fence.segments or nil
    if type(segments) == "table" then
        for _, segment in pairs(segments) do
            local vineNodes = type(segment) == "table" and segment.vineNodes or nil
            if type(vineNodes) == "table" then
                for node, data in pairs(vineNodes) do
                    if map[node] == nil and type(data) == "table" then
                        map[node] = data
                        count = count + 1
                    end
                end
            end
        end
    end
    return map, spec, count
end

--- The plant data table of a vine node and the placeable's plant spec. Cached per placeable; rebuilt on a miss.
function BananaRegrow.getNodeData(placeable, node)
    local cache = BananaRegrow.nodeDataCache[placeable]
    if cache == nil or cache.map[node] == nil then
        local map, spec = buildNodeMap(placeable)
        cache = {map = map, spec = spec or false}
        BananaRegrow.nodeDataCache[placeable] = cache
    end
    return cache.map[node], cache.spec or nil
end

--- Does this placeable grow the fruit? Cached per placeable.
function BananaRegrow.isFruitPlaceable(placeable, fruitIndex)
    local known = BananaRegrow.placeableFruit[placeable]
    if known == nil then
        known = false
        if placeable.getVineFruitTypeIndex ~= nil then
            local ok, index = pcall(placeable.getVineFruitTypeIndex, placeable)
            if ok and type(index) == "number" then
                known = index
            end
        end
        if known == false then
            local spec = BananaRegrow.findPlantSpec(placeable)
            if spec ~= nil and type(spec.fruitType) == "table" and type(spec.fruitType.index) == "number" then
                known = spec.fruitType.index
            end
        end
        BananaRegrow.placeableFruit[placeable] = known
    end
    return known == fruitIndex
end

local function isSection(t)
    if type(t) ~= "table" then
        return false
    end
    for i = 1, 6 do
        if type(t[i]) ~= "number" then
            return false
        end
    end
    return true
end

--- Area of a node from its transform, the way PlaceableVine.getVineAreaByNode does it (node at the panel start,
--- plants along +z, width centred on the node)
function BananaRegrow.computeNodeArea(node, width, length)
    local x, _, z = getWorldTranslation(node)
    local dirX, _, dirZ = localDirectionToWorld(node, 0, 0, 1)
    local normX, normZ = -dirZ, dirX
    local halfWidth = width * 0.5
    local startX, startZ = x - normX * halfWidth, z - normZ * halfWidth
    return {startX, startZ, startX + normX * width, startZ + normZ * width, startX + dirX * length, startZ + dirZ * length}
end

--- The density sections of a vine node: the stored sections, else the placeable's area function, else a box from the
--- node transform (the state filter keeps a too-large box harmless: only banana pixels in the cut states change).
--- Returns the list and how it was found ("sections", "api", "computed").
function BananaRegrow.getNodeSections(placeable, node)
    local data, spec = BananaRegrow.getNodeData(placeable, node)
    if type(data) == "table" then
        local sections = data.sections
        if type(sections) ~= "table" or not isSection(sections[1]) then
            sections = data.areas or data.sectionAreas
        end
        if type(sections) == "table" and isSection(sections[1]) then
            return sections, "sections"
        end
        if isSection(data.area) then
            return {data.area}, "sections"
        end
    end
    if placeable.getVineAreaByNode ~= nil then
        local ok, sx, sz, wx, wz, hx, hz = pcall(placeable.getVineAreaByNode, placeable, node)
        if ok and type(sx) == "number" and type(hz) == "number" then
            return {{sx, sz, wx, wz, hx, hz}}, "api"
        end
    end
    local width = spec ~= nil and (tonumber(spec.width) or tonumber(spec.rowWidth) or tonumber(spec.plantWidth)) or nil
    local length = spec ~= nil and (tonumber(spec.length) or tonumber(spec.plantLength) or tonumber(spec.spacing)) or nil
    return {BananaRegrow.computeNodeArea(node, width or 2, length or 3)}, "computed"
end

--- Centre of the plant: mean of its sections' parallelogram centres
function BananaRegrow.getSectionsCenter(sections)
    local sx, sz = 0, 0
    for _, s in ipairs(sections) do
        -- start + (width - start)/2 + (height - start)/2
        sx = sx + (s[3] + s[5]) * 0.5
        sz = sz + (s[4] + s[6]) * 0.5
    end
    return sx / #sections, sz / #sections
end

--- All banana vine nodes accepted by accept(placeable, node, centerX, centerZ).
--- Returns a list of {placeable=, node=, x=, y=, z=, sections=, source=}, or nil when the map has no vine system at all.
function BananaRegrow.collectPlants(accept)
    local vineSystem = g_currentMission ~= nil and g_currentMission.vineSystem or nil
    if vineSystem == nil or type(vineSystem.nodes) ~= "table" then
        return nil
    end
    local fruit = BananaRegrow.getFruit()
    local plants = {}
    if fruit == nil then
        return plants
    end
    for node, placeable in pairs(vineSystem.nodes) do
        if type(placeable) == "table" and BananaRegrow.isFruitPlaceable(placeable, fruit.index) and entityExists(node) then
            local sections, source = BananaRegrow.getNodeSections(placeable, node)
            local x, z = BananaRegrow.getSectionsCenter(sections)
            if accept(placeable, node, x, z) then
                local _, y, _ = getWorldTranslation(node)
                plants[#plants + 1] = {placeable = placeable, node = node, x = x, y = y, z = z, sections = sections, source = source}
            end
        end
    end
    return plants
end

local function rectAccept(rect)
    return function(_, _, x, z)
        return x >= rect[1] and x <= rect[3] and z >= rect[2] and z <= rect[4]
    end
end

function BananaRegrow.canFarmAccess(farmId, placeable)
    local accessHandler = g_currentMission ~= nil and g_currentMission.accessHandler or nil
    if accessHandler ~= nil and accessHandler.canFarmAccess ~= nil then
        local ok, allowed = pcall(accessHandler.canFarmAccess, accessHandler, farmId, placeable)
        if ok and type(allowed) == "boolean" then
            return allowed
        end
    end
    if placeable.getOwnerFarmId ~= nil then
        local ok, owner = pcall(placeable.getOwnerFarmId, placeable)
        if ok then
            return owner == farmId
        end
    end
    return false
end

--- Tells the placeable that the density under a node changed, so its plant model follows
function BananaRegrow.refreshNode(placeable, node)
    for _, name in ipairs({"updateVineNode", "updateOrchardNode", "updateNode"}) do
        if placeable[name] ~= nil then
            local ok, err = pcall(placeable[name], placeable, node, false)
            if not ok then
                warn("%s failed: %s", name, tostring(err))
            end
            return
        end
    end
    local vineSystem = g_currentMission.vineSystem
    if vineSystem ~= nil and type(vineSystem.dirtyNodes) == "table" then
        vineSystem.dirtyNodes[node] = true
    end
end

local function keysOf(t, limit)
    limit = limit or 60
    local keys = {}
    for k, v in pairs(t) do
        if type(k) == "string" or type(k) == "number" then
            local tv = type(v)
            local s
            if tv == "table" then
                local n = 0
                for _ in pairs(v) do n = n + 1 end
                s = string.format("%s={%d}", tostring(k), n)
            elseif tv == "function" then
                s = tostring(k) .. "()"
            else
                s = tostring(k) .. "=" .. tostring(v)
            end
            keys[#keys + 1] = s
        end
    end
    table.sort(keys)
    if #keys > limit then
        local cut = {}
        for i = 1, limit do cut[i] = keys[i] end
        cut[#cut + 1] = string.format("(+%d more)", #keys - limit)
        keys = cut
    end
    return table.concat(keys, " ")
end

--- Writes everything about a plantation and one of its nodes to the log (console brInfo, and once automatically when
--- a cut finds plants but no usable area)
function BananaRegrow.describePlaceable(placeable, node)
    local specNames, methods = {}, {}
    for k in pairs(placeable) do
        if type(k) == "string" and string.sub(k, 1, 5) == "spec_" then
            specNames[#specNames + 1] = k
        end
    end
    local t, depth = placeable, 0
    while type(t) == "table" and depth < 8 do
        for k, v in pairs(t) do
            if type(k) == "string" and type(v) == "function" and (string.find(k, "[Vv]ine") or string.find(k, "[Oo]rchard") or string.find(k, "[Bb]anana")
                or string.find(k, "[Ss]egment") or string.find(k, "[Gg]rowth") or string.find(k, "[Pp]lant")) then
                methods[k] = true
            end
        end
        local mt = getmetatable(t)
        t = mt ~= nil and mt.__index or nil
        depth = depth + 1
    end
    local methodList = {}
    for k in pairs(methods) do methodList[#methodList + 1] = k end
    table.sort(specNames)
    table.sort(methodList)
    log("plantation type=%s cfg=%s owner=%s", tostring(placeable.typeName), tostring(placeable.configFileName),
        tostring(placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or "?"))
    log("  specs: %s", table.concat(specNames, ", "))
    log("  methods: %s", table.concat(methodList, ", "))
    local spec = BananaRegrow.findPlantSpec(placeable)
    if spec ~= nil then
        log("  plant spec fields: %s", keysOf(spec, 80))
    else
        log("  no plant spec found")
    end
    local fence = BananaRegrow.getFence(placeable)
    if fence ~= nil then
        log("  fence fields: %s", keysOf(fence, 40))
        local segments = fence.segments
        if type(segments) == "table" then
            local first
            for _, segment in pairs(segments) do first = segment break end
            if type(first) == "table" then
                log("  segment[1] fields: %s", keysOf(first, 60))
                if type(first.vineNodes) == "table" then
                    for n, data in pairs(first.vineNodes) do
                        log("  segment[1].vineNodes[%s] fields: %s", tostring(n), type(data) == "table" and keysOf(data, 40) or tostring(data))
                        if type(data) == "table" and type(data.sections) == "table" then
                            local sec = data.sections[1]
                            log("    sections[1] = %s", type(sec) == "table" and keysOf(sec, 12) or tostring(sec))
                        end
                        break
                    end
                end
            end
        end
    else
        log("  no fence found")
    end
    if node ~= nil then
        local data = BananaRegrow.getNodeData(placeable, node)
        log("  node %s data: %s", tostring(node), data ~= nil and keysOf(data, 40) or "nil")
        local sections, source = BananaRegrow.getNodeSections(placeable, node)
        log("  node %s: %d section(s) from %s, first = %s", tostring(node), #sections, source, keysOf(sections[1], 12))
        local fruit = BananaRegrow.getFruit()
        local states = BananaRegrow.resolveStates()
        if states ~= nil and BananaRegrow.getModifier() ~= nil then
            for i, section in ipairs(sections) do
                local parts = {}
                for s = 1, states.numStates do
                    local pixels = BananaRegrow.applyRanges(section, {{s, s}}, nil)
                    if pixels > 0 then
                        parts[#parts + 1] = string.format("%s:%d", tostring(fruit.growthStateToName ~= nil and fruit.growthStateToName[s] or s), pixels)
                    end
                end
                log("  section %d banana pixels by state: %s", i, #parts > 0 and table.concat(parts, " ") or "none")
            end
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- marking an area (local)
---------------------------------------------------------------------------------------------------------------------

--- World position of the local player, or of the vehicle they sit in
function BananaRegrow.getActorPosition()
    local player = g_localPlayer
    if player == nil then
        return nil
    end
    local vehicle = nil
    if player.getCurrentVehicle ~= nil then
        local ok, v = pcall(player.getCurrentVehicle, player)
        if ok then
            vehicle = v
        end
    end
    if vehicle == nil and g_currentMission ~= nil then
        vehicle = g_currentMission.controlledVehicle
    end
    local node = (type(vehicle) == "table" and vehicle.rootNode) or player.rootNode
    if node == nil or not entityExists(node) then
        return nil
    end
    return getWorldTranslation(node)
end

function BananaRegrow.getFarmId()
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        return g_localPlayer.farmId
    end
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        return g_currentMission:getFarmId()
    end
    return 1
end

function BananaRegrow.notify(message, isWarning)
    if g_currentMission == nil or g_dedicatedServer ~= nil then
        log("%s", message)
        return
    end
    -- only on this player's own screen: the construction brush shows the latest message at its cursor, on foot the
    -- last few are drawn under the area line (no entries in the game's top-right notification list)
    local entry = {text = message, isWarning = isWarning == true, time = g_time or 0}
    BananaRegrow.lastMessage = entry
    local list = BananaRegrow.messages
    list[#list + 1] = entry
    while #list > BananaRegrow.MAX_MESSAGES do
        table.remove(list, 1)
    end
    dbg("notify: %s", message)
end

--- On-foot key: a corner at the player's (or vehicle's) position
function BananaRegrow.markCorner()
    local x, y, z = BananaRegrow.getActorPosition()
    if x == nil then
        return
    end
    BananaRegrow.addCorner(x, y, z)
end

--- Adds a corner; the second one makes the rectangle and counts its plants. A third starts a new area.
function BananaRegrow.addCorner(x, y, z)
    if #BananaRegrow.corners >= 2 then
        BananaRegrow.corners = {}
        BananaRegrow.rect = nil
        BananaRegrow.preview = nil
    end
    local corners = BananaRegrow.corners
    corners[#corners + 1] = {x, y, z}
    dbg("corner %d at %.1f %.1f", #corners, x, z)
    if #corners == 2 then
        local m = BananaRegrow.RECT_MARGIN
        BananaRegrow.rect = {
            math.min(corners[1][1], corners[2][1]) - m, math.min(corners[1][3], corners[2][3]) - m,
            math.max(corners[1][1], corners[2][1]) + m, math.max(corners[1][3], corners[2][3]) + m,
        }
        BananaRegrow.refreshPreview()
        local p = BananaRegrow.preview
        if p ~= nil and p.noVineSystem then
            BananaRegrow.notify(text("bananaRegrow_noDlc"), true)
        elseif p ~= nil and p.numPlants == 0 then
            BananaRegrow.notify(text("bananaRegrow_noPlants"), true)
        end
    end
end

--- Takes back the last corner (the construction tool's right click)
function BananaRegrow.removeLastCorner()
    local corners = BananaRegrow.corners
    if #corners > 0 then
        corners[#corners] = nil
        BananaRegrow.rect = nil
        BananaRegrow.preview = nil
    end
end

function BananaRegrow.clearSelection(silent)
    local had = #BananaRegrow.corners > 0
    BananaRegrow.corners = {}
    BananaRegrow.rect = nil
    BananaRegrow.preview = nil
    if had and not silent then
        BananaRegrow.notify(text("bananaRegrow_cleared"))
    end
end

--- Recounts the plants of the marked area (how many, how many need cutting). Local, reads the density map.
function BananaRegrow.refreshPreview()
    local rect = BananaRegrow.rect
    if rect == nil then
        BananaRegrow.preview = nil
        return
    end
    local plants = BananaRegrow.collectPlants(rectAccept(rect))
    if plants == nil then
        BananaRegrow.preview = {numPlants = 0, numNeedCut = 0, plants = {}, noVineSystem = true}
        return
    end
    local ranges = BananaRegrow.getStateRanges()
    local H = BananaRegrowHarvest
    local ripeRanges = H ~= nil and H.getRipeRanges() or nil
    local numNeedCut, numRipe = 0, 0
    for _, plant in ipairs(plants) do
        plant.isRipe = ripeRanges ~= nil and H.isRipe(plant, ripeRanges)
        if plant.isRipe then
            numRipe = numRipe + 1
        end
        plant.needsCut = false
        if ranges ~= nil then
            local pixels = 0
            for _, section in ipairs(plant.sections) do
                pixels = pixels + BananaRegrow.applyRanges(section, ranges, nil)
            end
            plant.needsCut = pixels > 0
        end
        if plant.needsCut then
            numNeedCut = numNeedCut + 1
        end
    end
    BananaRegrow.preview = {numPlants = #plants, numNeedCut = numNeedCut, numRipe = numRipe, plants = plants}
    BananaRegrow.previewTimer = BananaRegrow.PREVIEW_REFRESH_MS
    dbg("preview: %d plants, %d need cutting (cutAll=%s)", #plants, numNeedCut, tostring(BananaRegrow.cutAll))
end

---------------------------------------------------------------------------------------------------------------------
-- cutting
---------------------------------------------------------------------------------------------------------------------

--- The banana plantation with a plant closest to (x, z) within ORCHARD_PICK_RADIUS, and its number of plants.
--- Returns nil when there is none, and false when the map has no vine system at all.
function BananaRegrow.findPlantationNear(x, z)
    local best, bestDistSq = nil, BananaRegrow.ORCHARD_PICK_RADIUS * BananaRegrow.ORCHARD_PICK_RADIUS
    local plants = BananaRegrow.collectPlants(function(placeable, _, px, pz)
        local distSq = (px - x) * (px - x) + (pz - z) * (pz - z)
        if distSq < bestDistSq then
            best, bestDistSq = placeable, distSq
        end
        return false
    end)
    if plants == nil then
        return false
    end
    if best == nil then
        return nil
    end
    local count = 0
    for _, placeable in pairs(g_currentMission.vineSystem.nodes) do
        if placeable == best then
            count = count + 1
        end
    end
    return best, count
end

--- Player pressed "cut back": send the request (the marked rectangle, or else the plantation next to the position
--- (x, z), by default the player's own position)
function BananaRegrow.requestCut(x, z)
    if BananaRegrow.resolveStates() == nil then
        BananaRegrow.notify(text("bananaRegrow_notReady"), true)
        return
    end
    local request = {farmId = BananaRegrow.getFarmId(), cutAll = BananaRegrow.cutAll}

    if BananaRegrow.rect ~= nil then
        local p = BananaRegrow.preview
        if p ~= nil and p.noVineSystem then
            BananaRegrow.notify(text("bananaRegrow_noDlc"), true)
            return
        end
        if p ~= nil and p.numPlants == 0 then
            BananaRegrow.notify(text("bananaRegrow_noPlants"), true)
            return
        end
        request.mode = BananaRegrowCutEvent.MODE_RECT
        request.rect = {BananaRegrow.rect[1], BananaRegrow.rect[2], BananaRegrow.rect[3], BananaRegrow.rect[4]}
    else
        if x == nil then
            local _
            x, _, z = BananaRegrow.getActorPosition()
            if x == nil then
                return
            end
        end
        local best, count = BananaRegrow.findPlantationNear(x, z)
        if best == false then
            BananaRegrow.notify(text("bananaRegrow_noDlc"), true)
            return
        end
        if best == nil then
            BananaRegrow.notify(text("bananaRegrow_noOrchard"), true)
            return
        end
        request.mode = BananaRegrowCutEvent.MODE_ORCHARD
        request.placeable = best
        BananaRegrow.notify(text("bananaRegrow_wholeOrchard", count))
    end

    -- the server harvests the ripe plants first (with the player's machete, into the washing station), then cuts
    request.harvest = BananaRegrowHarvest ~= nil
    if g_server ~= nil then
        BananaRegrow.serverCut(request, nil)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(BananaRegrowCutEvent.new(request))
    end
end

--- Server side: cut back the plants of the request, answer the requesting connection (nil = local player)
function BananaRegrow.serverCut(request, connection)
    local result = {numCut = 0, numChecked = 0, numDenied = 0, mode = request.mode or 0,
                    harvested = 0, liters = 0, harvestReason = BananaRegrow.HARVEST_NONE, numRipe = 0}
    local function reply()
        if connection ~= nil then
            connection:sendEvent(BananaRegrowResultEvent.new(result))
        else
            BananaRegrow.onResult(result)
        end
    end

    local states = BananaRegrow.resolveStates()
    if states == nil or BananaRegrow.getModifier() == nil then
        reply()
        return
    end

    -- the farm is the requesting player's farm, not whatever the client claims
    local farmId = request.farmId
    local player = connection == nil and g_localPlayer or nil
    if connection ~= nil and g_currentMission.playerSystem ~= nil and g_currentMission.playerSystem.getPlayerByConnection ~= nil then
        local ok, p = pcall(g_currentMission.playerSystem.getPlayerByConnection, g_currentMission.playerSystem, connection)
        if ok and type(p) == "table" then
            player = p
            if p.farmId ~= nil then
                farmId = p.farmId
            end
        end
    end

    local accept
    if request.mode == BananaRegrowCutEvent.MODE_RECT and request.rect ~= nil then
        accept = rectAccept(request.rect)
    elseif request.mode == BananaRegrowCutEvent.MODE_ORCHARD and request.placeable ~= nil then
        accept = function(placeable)
            return placeable == request.placeable
        end
    else
        reply()
        return
    end

    local ctx = {request = request, connection = connection, result = result, reply = reply, accept = accept,
                 farmId = farmId, states = states}
    local H = BananaRegrowHarvest
    if request.harvest and H ~= nil then
        local started, reason, numRipe = H.begin(accept, "for the cut", function(summary)
            result.harvested, result.liters = summary.harvested, summary.liters
            result.harvestReason = summary.reason == "done" and BananaRegrow.HARVEST_DONE or BananaRegrow.HARVEST_STOPPED
            BananaRegrow.finishCut(ctx)
        end, player, farmId, connection)
        if started then
            return
        end
        result.numRipe = numRipe or 0
        result.harvestReason = BananaRegrow.HARVEST_REASONS[reason] or BananaRegrow.HARVEST_NONE
    end
    BananaRegrow.finishCut(ctx)
end

--- after the harvest (or without one): cut back the plants and answer
function BananaRegrow.finishCut(ctx)
    local request, result, farmId, states = ctx.request, ctx.result, ctx.farmId, ctx.states
    local reply = ctx.reply
    local plants = BananaRegrow.collectPlants(ctx.accept) or {}
    local ranges = request.cutAll and states.allRanges or states.cutRanges
    local access = {}
    local touched = {}
    for _, plant in ipairs(plants) do
        result.numChecked = result.numChecked + 1
        local allowed = access[plant.placeable]
        if allowed == nil then
            allowed = BananaRegrow.canFarmAccess(farmId, plant.placeable)
            access[plant.placeable] = allowed
        end
        if not allowed then
            result.numDenied = result.numDenied + 1
        else
            local pixels = 0
            for _, section in ipairs(plant.sections) do
                pixels = pixels + BananaRegrow.applyRanges(section, ranges, states.target)
            end
            if pixels > 0 then
                result.numCut = result.numCut + 1
                touched[plant.placeable] = touched[plant.placeable] or {}
                touched[plant.placeable][plant.node] = true
            end
        end
    end

    -- the plant models follow the density map only when the placeable re-reads its node
    for placeable, nodes in pairs(touched) do
        for node in pairs(nodes) do
            BananaRegrow.refreshNode(placeable, node)
        end
    end

    -- nothing cut although plants were found: write the plantation's details to the log once, for fixing the lookup
    if result.numCut == 0 and result.numChecked > result.numDenied and not BananaRegrow.diagnosed then
        BananaRegrow.diagnosed = true
        local first = plants[1]
        warn("found %d plants but none had banana pixels in the cut states; plantation details follow (first plant area from '%s')",
            result.numChecked, tostring(first.source))
        pcall(BananaRegrow.describePlaceable, first.placeable, first.node)
        local ok, err = pcall(BananaRegrow.deepProbe, first.placeable, first.node)
        if not ok then
            warn("deep probe failed: %s", tostring(err))
        end
    end

    log("cut back %d of %d banana plants for farm %s (%d on other farms' land, mode %s, cutAll %s)", result.numCut, result.numChecked,
        tostring(farmId), result.numDenied, tostring(request.mode), tostring(request.cutAll))
    reply()
end

--- Client side: the server's answer
function BananaRegrow.onResult(result)
    local reason = result.harvestReason or BananaRegrow.HARVEST_NONE
    if (result.harvested or 0) > 0 then
        local message = text("bananaRegrow_result_harvested", result.harvested, math.floor((result.liters or 0) + 0.5))
        if reason == BananaRegrow.HARVEST_STOPPED then
            message = message .. " - " .. text("bananaRegrow_result_harvestStopped")
        end
        if result.numCut > 0 then
            message = message .. "; " .. text("bananaRegrow_result_cutShort", result.numCut)
        end
        BananaRegrow.notify(message, reason == BananaRegrow.HARVEST_STOPPED)
    elseif result.numCut > 0 then
        BananaRegrow.notify(text("bananaRegrow_result_cut", result.numCut))
    else
        BananaRegrow.notify(text("bananaRegrow_result_none", result.numChecked), true)
    end
    if reason == BananaRegrow.HARVEST_NO_MACHETE then
        BananaRegrow.notify(text("bananaRegrow_harvest_needMachete", result.numRipe or 0), true)
    elseif reason == BananaRegrow.HARVEST_NO_STATION then
        BananaRegrow.notify(text("bananaRegrow_harvest_noStation", result.numRipe or 0), true)
    elseif reason == BananaRegrow.HARVEST_BUSY then
        BananaRegrow.notify(text("bananaRegrow_harvest_busy", result.numRipe or 0), true)
    elseif reason == BananaRegrow.HARVEST_STOPPED and (result.harvested or 0) == 0 then
        BananaRegrow.notify(text("bananaRegrow_result_harvestStopped"), true)
    end
    if result.numDenied > 0 then
        BananaRegrow.notify(text("bananaRegrow_result_denied", result.numDenied), true)
    end
    BananaRegrow.recountTimer = BananaRegrow.RESULT_RECOUNT_MS
end

---------------------------------------------------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------------------------------------------------
BananaRegrow.ACTIONS = {
    {name = "BANANAREGROW_MARK", callback = function() BananaRegrow.markCorner() end},
    {name = "BANANAREGROW_CUT", callback = function() BananaRegrow.requestCut() end},
    {name = "BANANAREGROW_CLEAR", callback = function() BananaRegrow.clearSelection() end},
}

--- Called inside the game's player action-event registration (PlayerInputComponent), so the events land in the
--- player's input context and are removed with it. The target is the game's input component for the same reason.
function BananaRegrow.onRegisterPlayerActionEvents(inputComponent, contextName)
    if g_dedicatedServer ~= nil or g_inputBinding == nil or InputAction == nil then
        return
    end
    for _, action in ipairs(BananaRegrow.ACTIONS) do
        local inputAction = InputAction[action.name]
        if inputAction ~= nil then
            local ok, _, eventId = pcall(g_inputBinding.registerActionEvent, g_inputBinding, inputAction, inputComponent, action.callback, false, true, false, true)
            if ok and eventId ~= nil then
                g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_LOW)
                g_inputBinding:setActionEventText(eventId, text("input_" .. action.name))
                g_inputBinding:setActionEventTextVisibility(eventId, action.name ~= "BANANAREGROW_CLEAR" or #BananaRegrow.corners > 0)
                BananaRegrow.eventIds[action.name] = eventId
            else
                dbg("could not register %s in context %s", action.name, tostring(contextName))
            end
        end
    end
end

function BananaRegrow.updateClearVisibility()
    local eventId = BananaRegrow.eventIds["BANANAREGROW_CLEAR"]
    local visible = #BananaRegrow.corners > 0
    if eventId ~= nil and visible ~= BananaRegrow.clearVisible and g_inputBinding ~= nil then
        pcall(g_inputBinding.setActionEventTextVisibility, g_inputBinding, eventId, visible)
        BananaRegrow.clearVisible = visible
    end
end

local function installInputHook()
    if PlayerInputComponent == nil or PlayerInputComponent.bananaRegrowHooked then
        return
    end
    PlayerInputComponent.bananaRegrowHooked = true
    if PlayerInputComponent.registerGlobalPlayerActionEvents ~= nil then
        -- runs inside the game's beginActionEventsModification(player context) block
        PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents,
            function(inputComponent, contextName)
                if BananaRegrow ~= nil then
                    BananaRegrow.onRegisterPlayerActionEvents(inputComponent, contextName)
                end
            end)
    elseif PlayerInputComponent.registerActionEvents ~= nil then
        PlayerInputComponent.registerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerActionEvents,
            function(inputComponent)
                if BananaRegrow == nil or inputComponent.player == nil or not inputComponent.player.isOwner then
                    return
                end
                g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
                BananaRegrow.onRegisterPlayerActionEvents(inputComponent, PlayerInputComponent.INPUT_CONTEXT_NAME)
                g_inputBinding:endActionEventsModification()
            end)
    else
        Logging.warning("[BananaRegrow] PlayerInputComponent has no action event registration to hook, keys unavailable")
    end
end

---------------------------------------------------------------------------------------------------------------------
-- mod event listener: update, draw, console
---------------------------------------------------------------------------------------------------------------------
function BananaRegrow:loadMap(name)
    BananaRegrow.corners = {}
    BananaRegrow.rect = nil
    BananaRegrow.preview = nil
    BananaRegrow.states = nil
    BananaRegrow.fruit = nil
    BananaRegrow.modifier = nil
    BananaRegrow.filter = nil
    BananaRegrow.eventIds = {}
    BananaRegrow.clearVisible = nil
    BananaRegrow.placeableFruit = setmetatable({}, {__mode = "k"})
    installInputHook()
    pcall(addConsoleCommand, "brDebug", "Banana Regrow: toggle debug logging", "consoleDebug", BananaRegrow)
    pcall(addConsoleCommand, "brCutAll", "Banana Regrow: toggle cutting ALL plants in the area (also ripe and growing ones)", "consoleCutAll", BananaRegrow)
    pcall(addConsoleCommand, "brInfo", "Banana Regrow: write the nearest banana plantation's technical details to the log", "consoleInfo", BananaRegrow)
    log("loaded (%s)", g_dedicatedServer ~= nil and "dedicated server" or (g_server ~= nil and "server" or "client"))
end

function BananaRegrow:deleteMap()
    pcall(removeConsoleCommand, "brDebug")
    pcall(removeConsoleCommand, "brCutAll")
    pcall(removeConsoleCommand, "brInfo")
    BananaRegrow.modifier = nil
    BananaRegrow.filter = nil
    BananaRegrow.states = nil
    BananaRegrow.fruit = nil
end

function BananaRegrow:update(dt)
    if BananaRegrow.recountTimer ~= nil then
        BananaRegrow.recountTimer = BananaRegrow.recountTimer - dt
        if BananaRegrow.recountTimer <= 0 then
            BananaRegrow.recountTimer = nil
            if BananaRegrow.rect ~= nil then
                BananaRegrow.refreshPreview()
            end
        end
    end
    if BananaRegrow.rect ~= nil and BananaRegrow.preview ~= nil and not BananaRegrow.preview.noVineSystem then
        BananaRegrow.previewTimer = BananaRegrow.previewTimer - dt
        if BananaRegrow.previewTimer <= 0 then
            BananaRegrow.refreshPreview()
        end
    end
    BananaRegrow.updateClearVisibility()
end

local function drawPost(x, z, height, r, g, b)
    local y = BananaRegrow.getTerrainHeight(x, z)
    drawDebugLine(x, y, z, r, g, b, x, y + height, z, r, g, b)
end
BananaRegrow.drawPost = drawPost

--- A line along the ground from (x1,z1) to (x2,z2), sampled so it follows the terrain
local function drawGroundLine(x1, z1, x2, z2, r, g, b)
    local dx, dz = x2 - x1, z2 - z1
    local length = math.sqrt(dx * dx + dz * dz)
    local steps = math.max(1, math.min(64, math.ceil(length / 3)))
    local px, pz = x1, z1
    local py = BananaRegrow.getTerrainHeight(px, pz) + 0.3
    for i = 1, steps do
        local t = i / steps
        local nx, nz = x1 + dx * t, z1 + dz * t
        local ny = BananaRegrow.getTerrainHeight(nx, nz) + 0.3
        drawDebugLine(px, py, pz, r, g, b, nx, ny, nz, r, g, b)
        px, py, pz = nx, ny, nz
    end
end

local function drawGroundRect(minX, minZ, maxX, maxZ, r, g, b)
    drawGroundLine(minX, minZ, maxX, minZ, r, g, b)
    drawGroundLine(maxX, minZ, maxX, maxZ, r, g, b)
    drawGroundLine(maxX, maxZ, minX, maxZ, r, g, b)
    drawGroundLine(minX, maxZ, minX, minZ, r, g, b)
end

--- Draws the corners, the area (with one corner: the area up to the cursor at cursorX/cursorZ, if given) and the plants
--- that need cutting. Returns the status text for the HUD or the cursor, or nil with nothing marked.
function BananaRegrow.drawSelection(cursorX, cursorZ, postHeight)
    local corners = BananaRegrow.corners
    if #corners == 0 then
        return nil
    end
    postHeight = postHeight or 3

    for _, c in ipairs(corners) do
        drawPost(c[1], c[3], postHeight, 1, 0.85, 0)
    end

    local rect = BananaRegrow.rect
    if rect == nil then
        if cursorX ~= nil then
            local c = corners[1]
            drawGroundRect(math.min(c[1], cursorX), math.min(c[3], cursorZ), math.max(c[1], cursorX), math.max(c[3], cursorZ), 1, 1, 1)
        end
        return text("bananaRegrow_hud_oneCorner")
    end

    drawGroundRect(rect[1], rect[2], rect[3], rect[4], 1, 0.85, 0)
    local p = BananaRegrow.preview
    if p == nil then
        return text("bananaRegrow_hud_counting")
    end
    for i, plant in ipairs(p.plants) do
        if i > BananaRegrow.MAX_DRAWN_PLANTS then
            break
        end
        if plant.isRipe then
            drawPost(plant.x, plant.z, 2, 1, 0.9, 0)
        elseif plant.needsCut then
            drawPost(plant.x, plant.z, 1.5, 0.2, 1, 0.2)
        elseif BananaRegrow.DEBUG then
            drawPost(plant.x, plant.z, 0.6, 0.6, 0.6, 0.6)
        end
    end
    local message = text("bananaRegrow_hud_selection", math.floor(rect[3] - rect[1] + 0.5), math.floor(rect[4] - rect[2] + 0.5), p.numPlants, p.numNeedCut)
    if (p.numRipe or 0) > 0 then
        message = message .. text("bananaRegrow_hud_ripe", p.numRipe)
    end
    if BananaRegrow.cutAll then
        message = message .. text("bananaRegrow_hud_cutAll")
    end
    return message
end

function BananaRegrow:draw()
    if g_dedicatedServer ~= nil or g_currentMission == nil then
        return
    end
    -- menus, and the construction screen (its brush draws the selection itself)
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then
        return
    end
    local message = BananaRegrow.drawSelection(nil, nil, 3)

    local lines = {}
    if message ~= nil then
        lines[#lines + 1] = {text = message, r = 1, g = 0.9, b = 0.3}
    end
    local now = g_time or 0
    for _, m in ipairs(BananaRegrow.messages) do
        if now - m.time < BananaRegrow.MESSAGE_MS then
            if m.isWarning then
                lines[#lines + 1] = {text = m.text, r = 1, g = 0.55, b = 0.1}
            else
                lines[#lines + 1] = {text = m.text, r = 0.6, g = 1, b = 0.5}
            end
        end
    end
    if #lines == 0 then
        return
    end
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)
    local size = getCorrectTextSize(0.018)
    for i, line in ipairs(lines) do
        local y = 0.92 - (i - 1) * 0.03
        setTextColor(0, 0, 0, 0.75)
        renderText(0.5 + 0.0012, y - 0.0018, size, line.text)
        setTextColor(line.r, line.g, line.b, 1)
        renderText(0.5, y, size, line.text)
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

function BananaRegrow:consoleDebug()
    BananaRegrow.DEBUG = not BananaRegrow.DEBUG
    return "[BananaRegrow] debug " .. (BananaRegrow.DEBUG and "ON" or "OFF")
end

function BananaRegrow:consoleCutAll()
    BananaRegrow.cutAll = not BananaRegrow.cutAll
    if BananaRegrow.rect ~= nil then
        BananaRegrow.refreshPreview()
    end
    return "[BananaRegrow] cut ALL plants (also ripe and growing): " .. (BananaRegrow.cutAll and "ON" or "OFF (only harvested, half-cut and withered)")
end

--- Technical dump of the nearest banana plantation, for fixing the mod against a game/DLC update
function BananaRegrow:consoleInfo()
    local fruit = BananaRegrow.getFruit()
    if fruit == nil then
        return "[BananaRegrow] fruit type BANANA not found"
    end
    local names = {}
    if type(fruit.growthStateToName) == "table" then
        for i = 1, #fruit.growthStateToName do
            names[#names + 1] = i .. "=" .. tostring(fruit.growthStateToName[i])
        end
    end
    log("fruit %s index %s dataPlane %s channels %s+%s states: %s", tostring(fruit.name), tostring(fruit.index), tostring(fruit.terrainDataPlaneId),
        tostring(fruit.startStateChannel), tostring(fruit.numStateChannels), table.concat(names, " "))
    BananaRegrow.states = nil
    BananaRegrow.resolveStates()

    local vineSystem = g_currentMission.vineSystem
    if vineSystem == nil or type(vineSystem.nodes) ~= "table" then
        return "[BananaRegrow] no vine system on this map"
    end
    local x, _, z = BananaRegrow.getActorPosition()
    x, z = x or 0, z or 0
    local numNodes, numBanana, best, bestNode, bestDist = 0, 0, nil, nil, math.huge
    for node, placeable in pairs(vineSystem.nodes) do
        numNodes = numNodes + 1
        if type(placeable) == "table" and BananaRegrow.isFruitPlaceable(placeable, fruit.index) and entityExists(node) then
            numBanana = numBanana + 1
            local nx, _, nz = getWorldTranslation(node)
            local d = (nx - x) * (nx - x) + (nz - z) * (nz - z)
            if d < bestDist then
                best, bestNode, bestDist = placeable, node, d
            end
        end
    end
    log("vine nodes on map: %d, banana nodes: %d", numNodes, numBanana)
    if best == nil then
        return "[BananaRegrow] no banana plantation found, see log"
    end
    log("nearest plantation %.0f m away:", math.sqrt(bestDist))
    BananaRegrow.describePlaceable(best, bestNode)
    local ok, err = pcall(BananaRegrow.deepProbe, best, bestNode)
    if not ok then
        warn("deep probe failed: %s", tostring(err))
    end
    return "[BananaRegrow] details written to log.txt"
end

--- Banana pixels by state name in a parallelogram, as "name:count ..." text
function BananaRegrow.stateHistogram(section)
    local fruit = BananaRegrow.getFruit()
    local states = BananaRegrow.resolveStates()
    if fruit == nil or states == nil or BananaRegrow.getModifier() == nil then
        return "unavailable"
    end
    local parts = {}
    for s = 1, states.numStates do
        local pixels = BananaRegrow.applyRanges(section, {{s, s}}, nil)
        if pixels > 0 then
            parts[#parts + 1] = string.format("%s:%d", tostring(fruit.growthStateToName ~= nil and fruit.growthStateToName[s] or s), pixels)
        end
    end
    return #parts > 0 and table.concat(parts, " ") or "none"
end

--- Finds where the plantation keeps data for one plant node: every table path (from the placeable, the vine system
--- and the segments) whose key is the node or whose .node field is the node. Bounded walk, logs what it finds.
local function findNodePaths(root, rootName, node, maxDepth, budget)
    local found, visited, queue, head = {}, {}, {{t = root, path = rootName, depth = 0}}, 1
    visited[root] = true
    local walked = 0
    while queue[head] ~= nil and walked < budget and #found < 8 do
        local item = queue[head]
        head = head + 1
        walked = walked + 1
        local t = item.t
        if rawget(t, node) ~= nil then
            found[#found + 1] = {path = item.path .. "[" .. tostring(node) .. "]", value = rawget(t, node)}
        end
        if rawget(t, "node") == node and item.depth > 0 then
            found[#found + 1] = {path = item.path, value = t}
        end
        if item.depth < maxDepth then
            for k, v in pairs(t) do
                if type(v) == "table" and not visited[v] and v ~= g_currentMission and k ~= "parentObject" and k ~= "mission" then
                    visited[v] = true
                    queue[#queue + 1] = {t = v, path = item.path .. "." .. tostring(k), depth = item.depth + 1}
                end
            end
        end
    end
    return found, walked
end

local function methodNamesOf(obj)
    local names, seen, t, depth = {}, {}, obj, 0
    while type(t) == "table" and depth < 8 do
        for k, v in pairs(t) do
            if type(k) == "string" and type(v) == "function" and not seen[k] then
                seen[k] = true
                names[#names + 1] = k
            end
        end
        local mt = getmetatable(t)
        t = mt ~= nil and mt.__index or nil
        depth = depth + 1
    end
    table.sort(names)
    return table.concat(names, ", ")
end

--- Everything needed to find the plant data of the DLC plantation (console brInfo, next to a plant)
function BananaRegrow.deepProbe(placeable, node)
    local nx, ny, nz = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    log("deep probe: node %s at %.2f %.2f %.2f, direction %.2f %.2f, parent %s", tostring(node), nx, ny, nz, dx, dz,
        tostring(getParent ~= nil and getParent(node) or "?"))

    -- the banana layer around the tree, and in the area the plantation reports for the node
    log("  banana pixels in 8x8 m around the node: %s", BananaRegrow.stateHistogram({nx - 4, nz - 4, nx + 4, nz - 4, nx - 4, nz + 4}))
    log("  banana pixels in 2x2 m around the node: %s", BananaRegrow.stateHistogram({nx - 1, nz - 1, nx + 1, nz - 1, nx - 1, nz + 1}))
    local sections, source = BananaRegrow.getNodeSections(placeable, node)
    for i, section in ipairs(sections) do
        log("  area %d (%s): %s", i, source, BananaRegrow.stateHistogram(section))
    end

    -- where is this node's data?
    local fence = BananaRegrow.getFence(placeable)
    local roots = {{placeable, "placeable"}, {g_currentMission.vineSystem, "vineSystem"}}
    if fence ~= nil then
        roots[#roots + 1] = {fence, "fence"}
    end
    for _, root in ipairs(roots) do
        local found, walked = findNodePaths(root[1], root[2], node, 6, 40000)
        log("  node %s found %d time(s) under %s (%d tables walked)", tostring(node), #found, root[2], walked)
        for _, f in ipairs(found) do
            local v = f.value
            log("    %s = %s", f.path, type(v) == "table" and keysOf(v, 40) or tostring(v))
            if type(v) == "table" and type(v.growthValues) == "table" then
                for i, gv in ipairs(v.growthValues) do
                    if type(gv) == "table" and type(gv.values) == "table" then
                        local parts = {}
                        for state, value in pairs(gv.values) do
                            if value ~= 0 then
                                local fruit = BananaRegrow.getFruit()
                                parts[#parts + 1] = string.format("%s:%s", tostring(fruit.growthStateToName[state] or state), tostring(value))
                            end
                        end
                        log("      growthValues[%d] totalArea=%s %s", i, tostring(gv.totalArea), table.concat(parts, " "))
                    end
                end
            end
            if type(v) == "table" and type(v.sections) == "table" then
                for i, s in ipairs(v.sections) do
                    log("      sections[%d] = %s", i, type(s) == "table" and keysOf(s, 12) or tostring(s))
                end
            end
        end
    end

    -- the segments: their class methods, and the plantation's own view of ripe / withered rows
    if fence ~= nil and type(fence.segments) == "table" then
        local first = fence.segments[1]
        if type(first) == "table" then
            log("  segment methods: %s", methodNamesOf(first))
            if type(first.metadata) == "table" then
                local n = 0
                for k, v in pairs(first.metadata) do
                    n = n + 1
                    if n <= 6 then
                        log("    segment[1].metadata[%s] = %s", tostring(k), type(v) == "table" and keysOf(v, 30) or tostring(v))
                    end
                end
            end
        end
        local fruit = BananaRegrow.getFruit()
        local numRipe, numWithered, numSegments = 0, 0, 0
        for _, segment in ipairs(fence.segments) do
            numSegments = numSegments + 1
            if placeable.getHasSegmentTargetGrowthState ~= nil then
                local okR, ripe = pcall(placeable.getHasSegmentTargetGrowthState, placeable, segment, fruit.index, true, false)
                local okW, withered = pcall(placeable.getHasSegmentTargetGrowthState, placeable, segment, fruit.index, false, true)
                if okR and ripe then numRipe = numRipe + 1 end
                if okW and withered then numWithered = numWithered + 1 end
            end
        end
        log("  plantation's own view: %d rows, %d with ripe plants, %d with withered plants", numSegments, numRipe, numWithered)
    end
    log("  vine system fields: %s", keysOf(g_currentMission.vineSystem, 40))
end

-- construction screen tool (Shift-P > Landscaping > Banana Regrow); the store item bananaRegrowTool.xml names the
-- brush type "FS25_BananaRegrow.bananaRegrow" (the manager prefixes the mod name)
if g_constructionBrushTypeManager ~= nil and g_constructionBrushTypeManager.addBrushType ~= nil then
    g_constructionBrushTypeManager:addBrushType("bananaRegrow", "ConstructionBrushBananaRegrow",
        g_currentModDirectory .. "scripts/ConstructionBrushBananaRegrow.lua")
else
    Logging.warning("[BananaRegrow] construction brush manager not found, the Shift-P tool is unavailable (keys still work)")
end

installInputHook()
addModEventListener(BananaRegrow)
