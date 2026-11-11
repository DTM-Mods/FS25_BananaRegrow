-- Banana Regrow research tools (brProbe / brTrace / brRipen) in multiplayer.
--
-- client -> server: run the probe, switch the trace on/off, or ripen the plants around a position on the SERVER
--                   (that is where the harvest, the bunches and the rail run). Admins only.
-- server -> client: log lines of the server's probe/trace, so they end up in the requesting player's own log.txt.
BananaRegrowResearchEvent = {}
local BananaRegrowResearchEvent_mt = Class(BananaRegrowResearchEvent, Event)

InitEventClass(BananaRegrowResearchEvent, "BananaRegrowResearchEvent")

BananaRegrowResearchEvent.ACTION_PROBE = 1
BananaRegrowResearchEvent.ACTION_TRACE = 2    -- data = {on = bool}
BananaRegrowResearchEvent.ACTION_RIPEN = 3    -- data = {x =, z =, radius =}
BananaRegrowResearchEvent.ACTION_LOG = 4      -- data = {text = "line\nline..."} (server -> client)
BananaRegrowResearchEvent.ACTION_COLLECT = 5  -- data = {x =, z =, radius =}: loose bunches into the washing station
local ACTION_BITS = 3

function BananaRegrowResearchEvent.emptyNew()
    return Event.new(BananaRegrowResearchEvent_mt)
end

function BananaRegrowResearchEvent.new(action, data)
    local self = BananaRegrowResearchEvent.emptyNew()
    self.action = action
    self.data = data or {}
    return self
end

function BananaRegrowResearchEvent:readStream(streamId, connection)
    self.action = streamReadUIntN(streamId, ACTION_BITS)
    self.data = {}
    if self.action == BananaRegrowResearchEvent.ACTION_TRACE then
        self.data.on = streamReadBool(streamId)
    elseif self.action == BananaRegrowResearchEvent.ACTION_RIPEN or self.action == BananaRegrowResearchEvent.ACTION_COLLECT then
        self.data.x = streamReadFloat32(streamId)
        self.data.z = streamReadFloat32(streamId)
        self.data.radius = streamReadFloat32(streamId)
    elseif self.action == BananaRegrowResearchEvent.ACTION_LOG then
        self.data.text = streamReadString(streamId)
    end
    self:run(connection)
end

function BananaRegrowResearchEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.action, ACTION_BITS)
    if self.action == BananaRegrowResearchEvent.ACTION_TRACE then
        streamWriteBool(streamId, self.data.on == true)
    elseif self.action == BananaRegrowResearchEvent.ACTION_RIPEN or self.action == BananaRegrowResearchEvent.ACTION_COLLECT then
        streamWriteFloat32(streamId, self.data.x or 0)
        streamWriteFloat32(streamId, self.data.z or 0)
        streamWriteFloat32(streamId, self.data.radius or 0)
    elseif self.action == BananaRegrowResearchEvent.ACTION_LOG then
        streamWriteString(streamId, self.data.text or "")
    end
end

function BananaRegrowResearchEvent:run(connection)
    if BananaRegrowProbe == nil then
        return
    end
    if self.action == BananaRegrowResearchEvent.ACTION_LOG then
        BananaRegrowProbe.onServerLog(self.data.text)
    elseif g_server ~= nil then
        BananaRegrowProbe.serverAction(self.action, self.data, connection)
    end
end
