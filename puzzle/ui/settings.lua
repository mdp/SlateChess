-- PuzzleSettings: the SlatePuzzle settings dialog.
--
-- Deliberately smaller than SlateChess's: a difficulty radio group plus a
-- puzzle-type row (which opens the TypePicker sub-menu), and nothing else —
-- no clocks, engines, roles, or board decorations. Applying hands the draft
-- to the App, which routes it through the machine's `settings` transition
-- (re-filter + reload).
--
-- The type is draft state too: picking a type from the row only stamps
-- `self.changes.type` here; it is persisted + dispatched by the same Save
-- that applies difficulty. (The App's quick "Puzzle type…" hamburger entry
-- applies immediately instead.)

local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local InputDialog = require("ui/widget/inputdialog")
local TextWidget = require("ui/widget/textwidget")
local ButtonWidget = require("ui/widget/button")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geometry = require("ui/geometry")

local _ = require("gettext")

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE

local PuzzleSettings = {}
PuzzleSettings.__index = PuzzleSettings

local BAND_LABELS = {
    any    = _("Any"),
    adaptive = _("Adaptive"),
    easy   = _("Easy"),
    normal = _("Normal"),
    hard   = _("Hard"),
    expert = _("Expert"),
}

function PuzzleSettings.new(_self, opts)
    assert(opts.parent, "parent is required")
    assert(opts.onSave and type(opts.onSave) == "function",
        "onSave callback is required")
    assert(opts.bands, "bands (band list) is required")
    assert(opts.pickType and type(opts.pickType) == "function",
        "pickType callback is required (opens the TypePicker)")
    local init = opts.initial or {}
    local type_id = init.type_id or "any"
    local type_label = init.type_label or opts.type_label or type_id
    return setmetatable({
        parent  = opts.parent,
        onSave  = opts.onSave,
        bands   = opts.bands,
        pickType = opts.pickType,
        changes = {
            difficulty = init.difficulty or "adaptive",
            type       = type_id,
            show_hints = init.show_hints ~= false,
        },
        type_label = type_label,
        dialog = nil,
    }, PuzzleSettings)
end

function PuzzleSettings:show()
    local dlg = InputDialog:new{
        title = _("Puzzle Settings"),
        save_callback = function() self:saveAndClose() end,
        dismiss_callback = function() UIManager:close(self.dialog) end,
    }
    self.dialog = dlg

    local w = math.floor(dlg.width * 0.85)
    local rows = VerticalGroup:new{ width = w, spacing = Size.padding.large }
    local PuzzleTypes = require("core.puzzle_types")

    -- One radio group; `entries` are `{ value = raw, text = display }`.
    local function addRadios(key, label, entries)
        rows[#rows + 1] = TextWidget:new{
            text = label .. ":",
            face = Font:getFace("cfont", 22),
        }
        local buttons = {}
        for _, e in ipairs(entries) do
            buttons[#buttons + 1] = {
                { text = e.text, value = e.value, checked = (e.value == self.changes[key]) },
            }
        end
        local radios = RadioButtonTable:new{
            width = w,
            radio_buttons = buttons,
            parent = dlg,
            button_select_callback = function(entry)
                self.changes[key] = entry.value
            end,
        }
        rows[#rows + 1] = radios
    end

    -- Difficulty: adaptive progression, unrestricted, or a fixed band.
    local band_entries = {}
    for _, b in ipairs({ "adaptive", "any", unpack(self.bands) }) do
        band_entries[#band_entries + 1] = {
            value = b,
            text  = BAND_LABELS[b] or b,
        }
    end
    addRadios("difficulty", _("Difficulty"), band_entries)
    rows[#rows + 1] = VerticalSpan:new{ width = Size.padding.small }

    -- Show hints: whether the bulb appears next to the state line.
    addRadios("show_hints", _("Show hints"), {
        { value = true,  text = _("On") },
        { value = false, text = _("Off") },
    })
    rows[#rows + 1] = VerticalSpan:new{ width = Size.padding.small }

    -- Puzzle type: the current selection, tapping opens the TypePicker.
    local type_row = VerticalGroup:new{ align = "left", width = w }
    type_row[#type_row + 1] = TextWidget:new{
        text = _("Puzzle type:") ,
        face = Font:getFace("cfont", 22),
    }
    type_row[#type_row + 1] = VerticalSpan:new{ width = Size.padding.small }
    local type_desc = TextWidget:new{
        text = PuzzleTypes.desc(self.changes.type) or "",
        face = Font:getFace("infofont", 14),
        dim = true,
        width = w,
    }
    type_row[#type_row + 1] = type_desc
    -- One-line description of the currently selected type (dim helper text).
    local type_label = self.type_label
    local type_btn
    type_btn = ButtonWidget:new{
        text = type_label .. "  ›",
        width = w,
        bordersize = Size.border.default,
        radius = Size.radius.window,
        margin = 0,
        callback = function()
            self.pickType(function(new_id, new_label)
                self.changes.type = new_id
                type_btn:setText((new_label or new_id) .. "  ›")
                if type_desc then
                    type_desc:setText(PuzzleTypes.desc(new_id) or "")
                end
            end)
        end,
    }
    type_row[#type_row + 1] = type_btn
    rows[#rows + 1] = type_row

    local D = dlg
    local options_h = rows:getSize().h
    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = BACKGROUND_COLOR,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "left",
            D.title_bar,
            VerticalSpan:new{ width = Size.padding.large },
            CenterContainer:new{
                dimen = Geometry:new{ w = D.width, h = options_h },
                rows,
            },
            VerticalSpan:new{ width = Size.padding.large },
            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = D.button_table:getSize().h,
                },
                D.button_table,
            },
        },
    }
    D.movable = MovableContainer:new{ content }
    D[1] = CenterContainer:new{ dimen = Screen:getSize(), D.movable }
    D:refocusWidget()
    UIManager:show(D)
end

function PuzzleSettings:saveAndClose()
    self.onSave(self.changes)
    UIManager:close(self.dialog)
end

return PuzzleSettings
