-- TypePicker: the SlatePuzzle "puzzle type" dropdown.
--
-- A full-screen KOReader Menu grouped like Lichess's own training themes:
-- Random first, then sections (Mates / Tactics / Mating patterns / Endgames
-- / Pawn play / Phases / Openings by name), each a submenu of concrete types.
-- The current selection is marked; selecting a type hands its id to
-- `onSelect` and closes. Per-type puzzle counts (from the live bank) are
-- shown next to every entry.
--
-- Purely presentational: all state lives in the caller (the App), which
-- persists + dispatches the picked id through the machine's `settings`
-- transition.

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local _ = require("gettext")

local TypePicker = {}

function TypePicker.show(opts)
    assert(opts.catalog, "opts.catalog (pattern types module) is required")
    assert(opts.onSelect and type(opts.onSelect) == "function",
        "opts.onSelect callback is required")
    local current = opts.current or "random"
    local counts = opts.counts or {}

    local menu
    local function leaf(entry)
        local text = _(entry.label)
        if counts[entry.id] and counts[entry.id] > 0 then
            text = text .. ("  (%d)"):format(counts[entry.id])
        end
        if entry.id == current then
            text = text .. "  ✓"
        end
        return {
            text = text,
            callback = function()
                UIManager:close(menu)
                if opts.onSelect then opts.onSelect(entry.id) end
            end,
        }
    end

    local function sectionItems(group_id)
        local items = {}
        for idx = 1, #opts.catalog.LIST do
            local e = opts.catalog.LIST[idx]
            if e.group == group_id then
                items[#items + 1] = leaf(e)
            end
        end
        return items
    end

    -- Top level: Random, then one submenu per section.
    local item_table = {}
    local random_entry = opts.catalog.byId("random")
    if random_entry then item_table[#item_table + 1] = leaf(random_entry) end
    for idx = 1, #opts.catalog.GROUPS do
        local g = opts.catalog.GROUPS[idx]
        local subs = sectionItems(g.id)
        if #subs > 0 then
            item_table[#item_table + 1] = {
                text = _(g.label),
                sub_item_table = subs,
            }
        end
    end

    menu = Menu:new{
        title = _("Puzzle type"),
        item_table = item_table,
        is_borderless = true,
        on_return = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
    return menu
end

return TypePicker