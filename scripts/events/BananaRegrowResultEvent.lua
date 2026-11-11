-- Banana Regrow: server -> requesting client "this is what was harvested and cut back". Only shows a notification there.
BananaRegrowResultEvent = {}
local BananaRegrowResultEvent_mt = Class(BananaRegrowResultEvent, Event)

InitEventClass(BananaRegrowResultEvent, "BananaRegrowResultEvent")

BananaRegrowResultEvent.NUM_BITS = 16

function BananaRegrowResultEvent.emptyNew()
    local self = Event.new(BananaRegrowResultEvent_mt)
    return self
end

--- @param result table {numCut=, numChecked=, numDenied=, mode=, harvested=, liters=, harvestReason=, numRipe=}
function BananaRegrowResultEvent.new(result)
    local self = BananaRegrowResultEvent.emptyNew()
    self.result = result
    return self
end

local function clamp16(v)
    return math.max(0, math.min(math.floor(v or 0), 65535))
end

function BananaRegrowResultEvent:readStream(streamId, connection)
    self.result = {
        numCut = streamReadUIntN(streamId, BananaRegrowResultEvent.NUM_BITS),
        numChecked = streamReadUIntN(streamId, BananaRegrowResultEvent.NUM_BITS),
        numDenied = streamReadUIntN(streamId, BananaRegrowResultEvent.NUM_BITS),
        mode = streamReadUIntN(streamId, 2),
        harvested = streamReadUIntN(streamId, BananaRegrowResultEvent.NUM_BITS),
        liters = streamReadFloat32(streamId),
        harvestReason = streamReadUIntN(streamId, 3),
        numRipe = streamReadUIntN(streamId, BananaRegrowResultEvent.NUM_BITS),
    }
    self:run(connection)
end

function BananaRegrowResultEvent:writeStream(streamId, connection)
    local r = self.result
    streamWriteUIntN(streamId, clamp16(r.numCut), BananaRegrowResultEvent.NUM_BITS)
    streamWriteUIntN(streamId, clamp16(r.numChecked), BananaRegrowResultEvent.NUM_BITS)
    streamWriteUIntN(streamId, clamp16(r.numDenied), BananaRegrowResultEvent.NUM_BITS)
    streamWriteUIntN(streamId, math.max(0, math.min(r.mode or 0, 3)), 2)
    streamWriteUIntN(streamId, clamp16(r.harvested), BananaRegrowResultEvent.NUM_BITS)
    streamWriteFloat32(streamId, r.liters or 0)
    streamWriteUIntN(streamId, math.max(0, math.min(r.harvestReason or 0, 7)), 3)
    streamWriteUIntN(streamId, clamp16(r.numRipe), BananaRegrowResultEvent.NUM_BITS)
end

function BananaRegrowResultEvent:run(connection)
    if BananaRegrow ~= nil then
        BananaRegrow.onResult(self.result)
    end
end
