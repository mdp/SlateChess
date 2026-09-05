-- PuzzleStatus: the SlatePuzzle strip under the board — the moves so far
-- and the session state line. The header (progress · rating · type) lives
-- in the top bar (puzzle/app.lua); this strip is the two thin rows under
-- the board.
--
-- A plain painter like PlayerStrip (no rotation): the strip is as wide as
-- the full content row and paints its two fixed-height text rows at the
-- board grid's left edge (offset_x), so the text aligns with the squares.
-- Rows are pinned to the layout's line height by their containers.
--
-- The two rows:
--   Moves  — the SAN history (move numbers, most recent visible)
--   State  — "Your move…" / "✓ Best move — keep going" / "✗ Not the move —
--            try again" / "Solved!"
--
-- The hint button is NOT here: the App overlays it (OverlapGroup) on the
-- right of the state row so it stays a real tappable button.

local Widget = require("ui/widget/widget")
local _ = require("gettext")

local PuzzleStatus = Widget:extend{
    row_w    = nil, -- reported width: the full content row (for VG stacking)
    width    = nil, -- content width: the grid's measured width
    offset_x = nil, -- the grid's left edge inside the row
    line_h   = nil,
    rows     = nil, -- the two TextWidgets, presentational only
}

function PuzzleStatus:init()
    local line_h = self.line_h
    local w = self.width
    local Geom = require("ui/geometry")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local LeftContainer = require("ui/widget/container/leftcontainer")

    local face = Font:getFace("smallinfofont", 14)
    local mk = function()
        return TextWidget:new{ text = "", face = face, padding = 0 }
    end
    self.rows = {}
    local stack = VerticalGroup:new{ align = "left", width = w }
    for i = 1, 2 do
        local t = mk()
        self.rows[i] = t
        stack[#stack + 1] = LeftContainer:new{
            dimen = Geom:new{ w = w, h = line_h },
            t,
        }
    end
    self.height = 2 * line_h
    self.stack = stack
    self[1] = stack
end

function PuzzleStatus:getSize()
    return { w = self.row_w, h = self.height }
end

function PuzzleStatus:paintTo(bb, x, y)
    if self.stack then
        self.stack:paintTo(bb, x + self.offset_x, y)
    end
end

function PuzzleStatus:handleEvent() -- luacheck: ignore self
    return false
end

--- Build the SAN history line with move numbers, e.g. "1. e4 e5 2. Nf3".
-- The most recent plies stay visible (the left truncates). `cut` limits
-- how many plies are shown (the most recent `cut`).
function PuzzleStatus.sanLine(sans, cut)
    if not sans or #sans == 0 then return "" end
    local start = 1
    if cut and #sans > cut then start = #sans - cut + 1 end
    local parts = {}
    for i = start, #sans do
        local move_no = math.floor((i - 1) / 2) + 1
        if i % 2 == 1 then
            parts[#parts + 1] = move_no .. "." .. sans[i]
        else
            parts[#parts + 1] = sans[i]
        end
    end
    return table.concat(parts, " ")
end

--- Refresh the two rows from the machine's view model.
function PuzzleStatus:update(v)
    if not v then return end
    if self.rows[1] then
        self.rows[1]:setText(PuzzleStatus.sanLine(v.san, 8))
    end

    local state
    if v.status == "empty" then
        state = _("No puzzles match these settings.")
    elseif v.status == "solved" then
        state = _("Solved!")
        if not v.rated then state = state .. " (" .. _("unrated") .. ")" end
    elseif v.wrong_attempts and v.wrong_attempts > 0 then
        state = _("✗ Not the move — try again")
    elseif v.consumed and v.consumed > 0 then
        state = _("✓ Best move — keep going")
    else
        state = _("Your move …")
    end
    if self.rows[2] then self.rows[2]:setText(state) end
end

return PuzzleStatus