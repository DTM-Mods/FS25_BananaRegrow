-- Banana Regrow: client -> server request "cut back the banana plants in this area / of this plantation".
-- The server does the work (density map writes only replicate from the server) and answers the requesting
-- client with a BananaRegrowResultEvent. Same skeleton as the base game's request events (readStream/writeStream/run).
BananaRegrowCutEvent = {}
local BananaRegrowCutEvent_mt = Class(BananaRegrowCutEvent, Event)

InitEventClass(BananaRegrowCutEvent, "BananaRegrowCutEvent")

BananaRegrowCutEvent.MODE_RECT = 1      -- rectangle given by two corners (world x/z)
BananaRegrowCutEvent.MODE_ORCHARD = 2   -- one whole plantation placeable
local FARM_ID_BITS = (FarmManager ~= nil and FarmManager.FARM_ID_SEND_NUM_BITS) or 4

function BananaRegrowCutEvent.emptyNew()
    local self = Event.new(BananaRegrowCutEvent_mt)
    return self
end

--- @param request table {farmId=, mode=, rect={minX,minZ,maxX,maxZ} | placeable=, cutAll=bool, harvest=bool}
function BananaRegrowCutEvent.new(request)
    local self = BananaRegrowCutEvent.emptyNew()
    self.request = request
    return self
end

function BananaRegrowCutEvent:readStream(streamId, connection)
    local request = {}
    request.farmId = streamReadUIntN(streamId, FARM_ID_BITS)
    request.cutAll = streamReadBool(streamId)
    request.harvest = streamReadBool(streamId)
    if streamReadBool(streamId) then
        request.mode = BananaRegrowCutEvent.MODE_RECT
        request.rect = {streamReadFloat32(streamId), streamReadFloat32(streamId), streamReadFloat32(streamId), streamReadFloat32(streamId)}
    else
        request.mode = BananaRegrowCutEvent.MODE_ORCHARD
        request.placeable = NetworkUtil.readNodeObject(streamId)
    end
    self.request = request
    self:run(connection)
end

function BananaRegrowCutEvent:writeStream(streamId, connection)
    local request = self.request
    streamWriteUIntN(streamId, request.farmId or 0, FARM_ID_BITS)
    streamWriteBool(streamId, request.cutAll == true)
    streamWriteBool(streamId, request.harvest == true)
    local isRect = request.mode == BananaRegrowCutEvent.MODE_RECT
    streamWriteBool(streamId, isRect)
    if isRect then
        local r = request.rect
        streamWriteFloat32(streamId, r[1])
        streamWriteFloat32(streamId, r[2])
        streamWriteFloat32(streamId, r[3])
        streamWriteFloat32(streamId, r[4])
    else
        NetworkUtil.writeNodeObject(streamId, request.placeable)
    end
end

function BananaRegrowCutEvent:run(connection)
    -- only the server acts on it; connection is the requesting client's connection
    if g_server ~= nil and BananaRegrow ~= nil then
        BananaRegrow.serverCut(self.request, connection)
    end
end
