-- CaptureGutter: the taken pieces, stacked down the board's right
-- gutter.
--
-- NOT a window: a plain painter laid over the board's row, sharing an
-- OverlapGroup with the board itself. The layout reserves a right
-- gutter as the mirror of the left's rank-label chrome but leaves it
-- empty -- this widget claims it. Geometry is relative to the board
-- widget's origin (the OverlapGroup's), derived from the board's
-- measured grid, so the columns always line up with the squares.
--
-- The gutter's halves belong to the board's sides: taken white pieces
-- (Black's spoils) stack on Black's side, taken black pieces (White's
-- spoils) on White's side -- each side's captures pile up on their own
-- edge, and which half is which follows the board flip. Each half
-- anchors at its own edge of the grid and grows toward the middle:
-- the far half hangs from the top (the opponent's "bottom"), the near
-- half rises from the grid's bottom edge. Pieces render with the
-- board's own piece SVGs; the far half points at the player across
-- the board (its 180° variants, like the rotated top strip), the near
-- half stays upright for the reader.
--
-- Two columns per half, pawns first: a column fills from the half's
-- edge, then the next one starts. Icons size to the gutter's own
-- width (whatever slack the symmetric gutters leave); if a half runs
-- out of room (small screens, a whole army taken), the icons shrink
-- to fit rather than drop pieces.

local Screen = require("device").screen
local Widget = require("ui/widget/widget")
local IconWidget = require("ui/widget/iconwidget")
local iconresolver = require("ui.icons")

local CaptureGutter = Widget:extend{
    -- Board whose flip decides which half holds which spoils.
    board = nil,
    -- Spoils area relative to the board widget's origin: x/y of its
    -- top-left corner, its width, and the grid height it must span.
    x = 0,
    y = 0,
    width = 0,
    grid_h = 0,
    taken = nil, -- { w = {"P", ...}, b = {...} } taken white/black pieces
}

local GAP = 6 -- pt, between and around the columns

local MIN_ICON = 10 -- pt, floor for the shrink-to-fit path

local function pieceIcon(letter, white, size, rotated)
    local name = "slatechess/"
        .. (white and "w" or "b") .. letter
        .. (rotated and "_rot" or "")
    local file = iconresolver.resolve(name)
    return IconWidget:new{
        icon    = file and nil or name,
        file    = file,
        alpha   = true,
        width   = size,
        height  = size,
        is_icon = true,
    }
end

function CaptureGutter:init()
    self.taken = { w = {}, b = {} }
    self._icons = { top = {}, bottom = {} }
end

--- Rebuilds the icon stacks from two piece-letter lists (taken white
-- pieces, taken black pieces; pawns first). Sizing is derived here so
-- a full half always fits: two columns of the grid's half height,
-- shrinking the icons when the count outruns the room.
function CaptureGutter:update(taken_w, taken_b)
    self.taken = { w = taken_w or {}, b = taken_b or {} }
    local gap = Screen:scaleBySize(GAP)
    local half_h = math.floor(self.grid_h / 2)
    -- Nominal icon size: two columns across the available width.
    local icon = math.floor((self.width - 3 * gap) / 2)
    -- The fuller half must fit in 2 columns of half the grid height;
    -- when it can't, shrink the icons to the pitch that fits.
    local n = math.max(#self.taken.w, #self.taken.b)
    local min_icon = Screen:scaleBySize(MIN_ICON)
    if n > 0 and math.ceil(n / 2) * (icon + gap) - gap > half_h then
        icon = math.max(min_icon,
            math.floor((half_h + gap) / math.ceil(n / 2)) - gap)
    end
    self.icon = icon
    self.pitch = icon + gap
    self.rows = math.max(1, math.floor((half_h + gap) / self.pitch))

    -- Which half holds which spoils follows the board flip: the half
    -- on a side shows the pieces that side took (the opposite color).
    -- The far half's icons render with their 180° variants, pointing
    -- at the player who sits across from them -- same convention as
    -- the rotated top strip; the near half stays upright for the
    -- reader.
    local flipped = self.board and self.board.flipped
    local top, bottom, top_white
    if flipped then
        top, bottom, top_white = self.taken.b, self.taken.w, false
    else
        top, bottom, top_white = self.taken.w, self.taken.b, true
    end
    self._icons.top = {}
    self._icons.bottom = {}
    for i, letter in ipairs(top) do
        self._icons.top[i] = pieceIcon(letter, top_white, icon, true)
    end
    for i, letter in ipairs(bottom) do
        self._icons.bottom[i] = pieceIcon(letter, not top_white, icon, false)
    end
end

--- Column-major placement per half: from the half's edge, then the
--- next column. The far half hangs from the grid's top edge (the
--- opponent's "bottom"); the near half rises from the grid's bottom
--- edge. The two-column block centers in the available width.
function CaptureGutter:paintTo(bb, x, y)
    if not self._icons or self.icon == 0 then return end
    local gap = Screen:scaleBySize(GAP)
    local col_w = self.icon + gap
    local block_w = 2 * self.icon + gap
    local ox = x + self.x + math.floor((self.width - block_w) / 2)
    local top_y = y + self.y
    local grid_bottom = top_y + self.grid_h
    for i, w in ipairs(self._icons.top) do
        local col = math.floor((i - 1) / self.rows)
        local row = (i - 1) % self.rows
        w:paintTo(bb, ox + col * col_w, top_y + row * self.pitch)
    end
    for i, w in ipairs(self._icons.bottom) do
        local col = math.floor((i - 1) / self.rows)
        local row = (i - 1) % self.rows
        w:paintTo(bb, ox + col * col_w,
            grid_bottom - (row + 1) * self.pitch + gap)
    end
end

function CaptureGutter:getSize()
    return { w = self.width, h = self.grid_h }
end

return CaptureGutter
