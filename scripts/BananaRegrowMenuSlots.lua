--[[
    Banana Regrow - more button slots in the menus' bottom bar

    The in-game menu has a fixed number of bottom-bar button slots (6). TabbedMenu:assignMenuButtonInfo fills them in
    order and silently drops every button past the last slot. On a Beans & Alpacas washing station the production page
    has 7 buttons when ProductionStorageControl adds "Spawn goods", so the DLC's "Manage workers" (the 7th) never shows
    although it is there and its key is bound.

    Before the slots are filled, this clones the last slot until there is one for every button (at most MAX_SLOTS), so
    nothing gets dropped. Client-side GUI only; nothing is synced or saved.
]]

BananaRegrowMenuSlots = {}
local S = BananaRegrowMenuSlots

S.MAX_SLOTS = 10
S.logged = {}

local function logOnce(key, fmt, ...)
    if not S.logged[key] then
        S.logged[key] = true
        Logging.info("[BananaRegrow] menu slots: " .. fmt, ...)
    end
end

--- makes sure menu.menuButton has a slot for each of numButtons buttons; returns the number of slots added
function S.ensureSlots(menu, numButtons)
    local slots = menu.menuButton
    if type(slots) ~= "table" or #slots == 0 or numButtons <= #slots then
        return 0
    end
    local template = slots[#slots]
    local parent = menu.buttonsPanel or template.parent
    if parent == nil or type(template.clone) ~= "function" then
        logOnce("noClone", "cannot add slots (no button panel or clone), %d buttons for %d slots", numButtons, #slots)
        return 0
    end

    local before = #slots
    local target = math.min(numButtons, S.MAX_SLOTS)
    while #slots < target do
        local ok, clone = pcall(template.clone, template, parent)
        if not ok or clone == nil then
            logOnce("cloneFailed", "cloning a button slot failed: %s", tostring(clone))
            break
        end
        table.insert(slots, clone)
    end

    local added = #slots - before
    if added > 0 then
        if parent.invalidateLayout ~= nil then
            parent:invalidateLayout()
        end
        logOnce("added" .. tostring(#slots), "%d buttons for %d slots, added %d (now %d)", numButtons, before, added, #slots)
    end
    if numButtons > #slots then
        logOnce("tooMany", "%d buttons, only %d shown (limit %d)", numButtons, #slots, S.MAX_SLOTS)
    end
    return added
end

function S.beforeAssign(menu, menuButtonInfo)
    if type(menu) ~= "table" or type(menuButtonInfo) ~= "table" then
        return
    end
    local ok, err = pcall(S.ensureSlots, menu, #menuButtonInfo)
    if not ok then
        logOnce("error", "%s", tostring(err))
    end
end

if TabbedMenu ~= nil and TabbedMenu.assignMenuButtonInfo ~= nil then
    TabbedMenu.assignMenuButtonInfo = Utils.prependedFunction(TabbedMenu.assignMenuButtonInfo, S.beforeAssign)
else
    Logging.warning("[BananaRegrow] TabbedMenu.assignMenuButtonInfo not found, menus keep their button slots")
end
