-- PlayerStrip: the player's bracket attached to one side of the board.
--
-- One horizontal strip, as wide as the board's measured grid:
--
--   [ history line 1                ][ clock card ]
--   [ history line 2                ][ (the notation block is capped
--   [ eval / hints                  ]    at 2/3 of the grid, so it can
--                                       never run under the timer)  ]
--
-- The block carries two history lines (the last four plies), the eval
-- row and the Engine Hints row, per the settings -- the taken pieces
-- live off the strips entirely, stacked in the board's right gutter
-- (ui/capture_gutter).
--
-- White's strip stands upright below the board; Black's is the SAME
-- strip rotated 180° above the board -- its timer lands on Black's
-- right-hand side (screen-left for a White-side viewer), its notation
-- on Black's left. Both strips show the same content, so each player
-- reads an identical bracket right side up from their side of the
-- board, in every game mode. Untimed games build strips without a
-- clock; the notation block keeps its place and the right third stays
-- empty.
--
-- The strip paints at `offset_x` inside a full-content-width row (the
-- board widget is also full width), so [Black's strip][board][White's
-- strip] stacks as one centered unit with the notation pinned to the
-- grid's left edge and the timer to its right edge.
--
-- Events cascade down the widget tree; the upright strip forwards them
-- to its children exactly like Overlay does. The rotated strip swallows
-- them -- its children's hit ranges are in rotated coordinates.

local Blitbuffer = require("ffi/blitbuffer")
local Widget = require("ui/widget/widget")

local PlayerStrip = Widget:extend{
    row_w    = nil, -- reported width: the full content row (for VG stacking)
    width    = nil, -- content width: the grid's measured width
    offset_x = nil, -- the grid's left edge inside the row
    rotated  = false,
    notation = nil, -- the stacked [pgn][eval] block widget
    center   = nil, -- optional compact history control (bottom HUD only)
    clock    = nil, -- ClockPanel or nil (untimed games)
    slots    = nil, -- optional named x/w slots from gameplay_design
}

function PlayerStrip:init()
    local n_h = self.notation:getSize().h
    local c_h = self.clock and self.clock:getSize().h or 0
    local m_h = self.center and self.center:getSize().h or 0
    -- The strip is as tall as its taller half; the other centers in it.
    self.height = math.max(n_h, c_h, m_h)
    self.notation_dy = math.floor((self.height - n_h) / 2)
    self.notation_dx = self.slots and self.slots.notation.x or 0
    if self.clock then
        local c_w = self.clock:getSize().w
        self.clock_dx = self.slots and
            (self.slots.clock.x+self.slots.clock.w-c_w) or (self.width-c_w)
        self.clock_dy = math.floor((self.height - c_h) / 2)
    end
    if self.center then
        local m = self.center:getSize()
        self.center_dx = self.slots and
            (self.slots.center.x+math.floor((self.slots.center.w-m.w)/2)) or
            math.floor((self.width-m.w)/2)
        self.center_dy = math.floor((self.height - m.h) / 2)
    end
end

function PlayerStrip:getSize()
    return { w = self.row_w, h = self.height }
end

function PlayerStrip:paintTo(bb, x, y)
    if not self.rotated then
        self.notation:paintTo(bb, x + self.offset_x + self.notation_dx, y + self.notation_dy)
        if self.center then
            self.center:paintTo(bb, x + self.offset_x + self.center_dx,
                y + self.center_dy)
        end
        if self.clock then
            self.clock:paintTo(bb, x + self.offset_x + self.clock_dx, y + self.clock_dy)
        end
        return
    end
    -- Black's strip: the same content, flipped 180°, so it reads right
    -- side up from Black's side of the board. Rendered upright into a
    -- scratch buffer first, then blitted rotated at the grid's edge.
    local tmp = Blitbuffer.new(self.width, self.height)
    tmp:fill(Blitbuffer.COLOR_WHITE)
    self.notation:paintTo(tmp, self.notation_dx, self.notation_dy)
    if self.clock then
        self.clock:paintTo(tmp, self.clock_dx, self.clock_dy)
    end
    local rot = tmp:rotatedCopy(180)
    tmp:free()
    bb:blitFrom(rot, x + self.offset_x, y, 0, 0, rot.w, rot.h)
    rot:free()
end

-- Input events (taps on the scrollable notation) cascade down the
-- widget tree via handleEvent; as a plain Widget the strip would
-- swallow them. Forward them like WidgetContainer does -- unless
-- rotated, whose children live in flipped coordinates.
function PlayerStrip:handleEvent(event)
    if self.rotated then return false end
    local consumed = false
    for _, child in ipairs({ self.notation, self.center, self.clock }) do
        if child and child.handleEvent and child:handleEvent(event) then
            consumed = true
        end
    end
    return consumed
end

function PlayerStrip:free(full)
    if self.notation and self.notation.free then self.notation:free(full) end
    if self.center and self.center.free then self.center:free(full) end
    if self.clock and self.clock.free then self.clock:free(full) end
end

return PlayerStrip
