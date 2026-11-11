--[[
    Banana Regrow - construction screen tool (Shift-P > Landscaping > Banana Regrow)

    Sourced by g_constructionBrushTypeManager:addBrushType (BananaRegrow.lua), not listed in modDesc. Uses the screen's
    top-down camera and cursor like the base game brushes:
      left click   first corner, second corner (the area is counted and its plants marked), then "harvest R, cut back
                   N plants": ripe plants are harvested into the washing station first (BananaRegrowHarvest), then cut;
                   with a finished area that has nothing to cut, a left click starts a new area
      right click  remove the last corner; with nothing marked: harvest and cut back the whole plantation under the
                   cursor
      Esc          clear the area
    The selection, counting, drawing and the cut request are shared with the on-foot keys (BananaRegrow.*).
]]

ConstructionBrushBananaRegrow = {}
local ConstructionBrushBananaRegrow_mt = Class(ConstructionBrushBananaRegrow, ConstructionBrush)

ConstructionBrushBananaRegrow.MESSAGE_MS = 4000     -- how long a result message stays at the cursor
ConstructionBrushBananaRegrow.HOVER_REFRESH_MS = 250 -- how often the plantation under the cursor is looked up

function ConstructionBrushBananaRegrow.new(subclass_mt, cursor)
    local self = ConstructionBrush.new(subclass_mt or ConstructionBrushBananaRegrow_mt, cursor)
    self.supportsPrimaryButton = true
    self.supportsSecondaryButton = true
    if Farm ~= nil and Farm.PERMISSION ~= nil then
        self.requiredPermission = Farm.PERMISSION.LANDSCAPING
    end
    self.activatedTime = 0
    self.hoverTimer = 0
    self.hoverCount = nil      -- plants of the plantation under the cursor (nothing marked), or nil
    self.textState = nil
    return self
end

function ConstructionBrushBananaRegrow:activate()
    ConstructionBrushBananaRegrow:superClass().activate(self)
    self.cursor:setRotationEnabled(false)
    self.cursor:setShape(GuiTopDownCursor.SHAPES.CIRCLE)
    self.cursor:setShapeSize(1)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SUCCESS)
    self.cursor:setTerrainOnly(true)
    BananaRegrow.clearSelection(true)
    BananaRegrow.lastMessage = nil     -- messages from on foot are not shown at the cursor
    self.activatedTime = g_time or 0
    self.hoverTimer = 0
    self.hoverCount = nil
    self.textState = nil
    self:setInputTextDirty()
end

function ConstructionBrushBananaRegrow:deactivate()
    BananaRegrow.clearSelection(true)
    self.cursor:setTerrainOnly(false)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT, nil)
    ConstructionBrushBananaRegrow:superClass().deactivate(self)
end

function ConstructionBrushBananaRegrow:canCancel()
    return #BananaRegrow.corners > 0
end

function ConstructionBrushBananaRegrow:cancel()
    BananaRegrow.clearSelection(true)
    self:setInputTextDirty()
end

--- Plants a click would harvest and cut in the finished area (ripe ones are harvested first and then cut too),
--- or nil while the area is not finished
local function numToCut()
    local p = BananaRegrow.preview
    if BananaRegrow.rect == nil or p == nil then
        return nil
    end
    if BananaRegrow.cutAll then
        return p.numNeedCut, p.numRipe or 0
    end
    return p.numNeedCut + (p.numRipe or 0), p.numRipe or 0
end

function ConstructionBrushBananaRegrow:update(dt)
    local x, _, z = self.cursor:getPosition()

    -- with nothing marked, a right click cuts the plantation under the cursor: look it up a few times a second
    self.hoverTimer = self.hoverTimer - dt
    if self.hoverTimer <= 0 then
        self.hoverTimer = ConstructionBrushBananaRegrow.HOVER_REFRESH_MS
        self.hoverCount = nil
        if x ~= nil and #BananaRegrow.corners == 0 then
            local best, count = BananaRegrow.findPlantationNear(x, z)
            if best then
                self.hoverCount = count
            end
        end
    end

    -- the button texts depend on the corners, the count and the plantation under the cursor
    local state = string.format("%d|%s|%s", #BananaRegrow.corners, tostring(numToCut()), tostring(self.hoverCount))
    if state ~= self.textState then
        self.textState = state
        self:setInputTextDirty()
    end

    if #BananaRegrow.corners == 2 and (numToCut() or 0) > 0 then
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT)
    else
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SUCCESS)
    end
end

function ConstructionBrushBananaRegrow:draw()
    local x, _, z = self.cursor:getPosition()
    local status = BananaRegrow.drawSelection(x, z, 3)

    local last = BananaRegrow.lastMessage
    local now = g_time or 0
    if last ~= nil and last.time >= self.activatedTime and now - last.time < ConstructionBrushBananaRegrow.MESSAGE_MS then
        if last.isWarning then
            self.cursor:setErrorMessage(last.text)
        else
            self.cursor:setMessage(last.text)
        end
    elseif status ~= nil then
        self.cursor:setMessage(status)
    elseif self.hoverCount ~= nil then
        self.cursor:setMessage(BananaRegrow.text("bananaRegrow_brush_hintPlantation", self.hoverCount))
    else
        self.cursor:setMessage(BananaRegrow.text("bananaRegrow_brush_hint"))
    end
end

function ConstructionBrushBananaRegrow:onButtonPrimary()
    local x, y, z = self.cursor:getPosition()
    if x == nil then
        return
    end
    if (numToCut() or 0) > 0 then
        BananaRegrow.requestCut()
    else
        BananaRegrow.addCorner(x, y, z)
    end
    self:setInputTextDirty()
end

function ConstructionBrushBananaRegrow:onButtonSecondary()
    if #BananaRegrow.corners > 0 then
        BananaRegrow.removeLastCorner()
    else
        local x, _, z = self.cursor:getPosition()
        if x ~= nil and self.hoverCount ~= nil then
            BananaRegrow.requestCut(x, z)
        end
    end
    self:setInputTextDirty()
end

function ConstructionBrushBananaRegrow:getButtonPrimaryText()
    local numCorners = #BananaRegrow.corners
    if numCorners == 0 then
        return BananaRegrow.text("bananaRegrow_brush_firstCorner")
    elseif numCorners == 1 then
        return BananaRegrow.text("bananaRegrow_brush_secondCorner")
    end
    local n, numRipe = numToCut()
    if n ~= nil and numRipe > 0 then
        return BananaRegrow.text("bananaRegrow_brush_harvestCut", numRipe, n)
    end
    if n ~= nil and n > 0 then
        return BananaRegrow.text("bananaRegrow_brush_cut", n)
    end
    return BananaRegrow.text("bananaRegrow_brush_newArea")
end

function ConstructionBrushBananaRegrow:getButtonSecondaryText()
    if #BananaRegrow.corners > 0 then
        return BananaRegrow.text("bananaRegrow_brush_removeCorner")
    end
    if self.hoverCount ~= nil then
        return BananaRegrow.text("bananaRegrow_brush_cutPlantation", self.hoverCount)
    end
    return nil
end
