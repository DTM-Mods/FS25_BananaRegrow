"""Offline test of BananaRegrowMenuSlots on Lua 5.1.

A fake TabbedMenu with 6 bottom-bar slots and the FS25 slot-filling loop (one slot per button, extra buttons dropped).
With 7 buttons the 7th ("Manage workers") must get a slot of its own; with fewer buttons nothing is added; more than
MAX_SLOTS buttons stop at MAX_SLOTS.

Usage: python tools/test/run_menuslots_stub.py
"""
import sys
from pathlib import Path

from lupa import lua51

MOD_DIR = Path(__file__).resolve().parent.parent.parent

SCENARIO = r"""
INFO = {}
Logging = {info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end,
           warning = function(fmt, ...) INFO[#INFO + 1] = "WARNING " .. string.format(fmt, ...) end}
Utils = {}
function Utils.prependedFunction(old, new) return function(...) new(...); return old(...) end end

-- GUI elements: clone(parent) adds the copy to the parent, like GuiElement:clone
Element = {}
Element.__index = Element
function Element.new(parent) local e = setmetatable({children = {}, visible = false, parent = parent}, Element)
    if parent ~= nil then table.insert(parent.children, e) end; return e end
function Element:clone(parent) local e = Element.new(parent); e.cloned = true; return e end
function Element:setVisible(v) self.visible = v end
function Element:setText(t) self.text = t end
LAYOUTS = 0
function Element:invalidateLayout() LAYOUTS = LAYOUTS + 1 end

-- the FS25 loop: every slot shows the button with its index, buttons past the last slot are dropped
TabbedMenu = {}
function TabbedMenu:assignMenuButtonInfo(menuButtonInfo)
    for i, button in ipairs(self.menuButton) do
        local info = menuButtonInfo[i]
        button:setVisible(info ~= nil)
        if info ~= nil then button:setText(info.text) end
    end
end

function newMenu()
    local panel = Element.new(nil)
    local menu = setmetatable({buttonsPanel = panel, menuButton = {}}, {__index = TabbedMenu})
    for i = 1, 6 do menu.menuButton[i] = Element.new(panel) end
    return menu
end
function buttons(n)
    local list = {}
    local names = {"Back", "Next menu", "Previous menu", "Tag place", "Visit", "Spawn goods", "Manage workers"}
    for i = 1, n do list[i] = {text = names[i] or ("Extra " .. i)} end
    return list
end
function shown(menu)
    local t = {}
    for _, b in ipairs(menu.menuButton) do if b.visible then t[#t + 1] = b.text end end
    return t
end
"""

CHECKS = r"""
-- the washing station page with Spawn goods: 7 buttons, all shown
local menu = newMenu()
menu:assignMenuButtonInfo(buttons(7))
local s = shown(menu)
assert(#menu.menuButton == 7, "expected 7 slots, got " .. #menu.menuButton)
assert(#s == 7 and s[7] == "Manage workers", "Manage workers not shown: " .. table.concat(s, ", "))
assert(menu.buttonsPanel.children[7] == menu.menuButton[7] and menu.menuButton[7].cloned, "slot not added to the panel")
assert(LAYOUTS == 1, "layout not refreshed")

-- the same page again: no new slots
menu:assignMenuButtonInfo(buttons(7))
assert(#menu.menuButton == 7 and LAYOUTS == 1, "slots added twice")

-- a page with fewer buttons: the extra slot is hidden, nothing added
menu:assignMenuButtonInfo(buttons(4))
assert(#shown(menu) == 4 and not menu.menuButton[7].visible, "extra slot still visible")

-- far too many buttons: capped at MAX_SLOTS
local big = newMenu()
big:assignMenuButtonInfo(buttons(15))
assert(#big.menuButton == BananaRegrowMenuSlots.MAX_SLOTS, "cap not applied: " .. #big.menuButton)

-- a menu without slots or panel is left alone
local odd = setmetatable({menuButton = {}}, {__index = TabbedMenu})
odd:assignMenuButtonInfo(buttons(7))
assert(#odd.menuButton == 0)
return table.concat(INFO, "\n")
"""


def main():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SCENARIO)
    lua.execute((MOD_DIR / "scripts" / "BananaRegrowMenuSlots.lua").read_text(encoding="utf-8"))
    info = lua.execute(CHECKS)
    print("menu slots OK")
    print(info)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"FAILED: {e}")
