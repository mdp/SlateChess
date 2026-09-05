-- MarksOverlay: paints the last-move and selection corner brackets.
--
-- This is NOT a window: it never touches UIManager or the window
-- stack (a fullscreen window up top would swallow every tap before
-- the game sees it). The app simply calls paintTo after its own, so
-- the brackets land on top of the board; dialogs cover it by covering
-- the app.
--
-- It reads each marked square's BUTTON rect -- the square's real
-- pixel space -- which no bracket icon can reliably target: the icon
-- pipeline letterboxes square viewBoxes inside the padded content box,
-- floating the ink off the true corners. Gap from the square edge
-- equals the stroke width.
--
--   move origin      -> brackets on the top-left and bottom-right corners
--   move destination -> brackets on all four corners
--   selection  -> brackets on all four corners

local Widget = require("ui/widget/widget")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")

local Board = require("ui.board")

local MarksOverlay = Widget:extend{
    board = nil,
    app = nil,
}

--- Corner brackets for one square. dimen is the button's rect (the
--- full square); the gap from the edge equals the stroke width.
function MarksOverlay.paintCorners(bb, dimen, corners, stroke, arm, inset)
    inset = inset or 11
    local x0, y0 = dimen.x + inset, dimen.y + inset
    local x1, y1 = dimen.x + dimen.w - 1 - inset,
        dimen.y + dimen.h - 1 - inset
    for _, corner in ipairs(corners) do
        if corner == "bl" then
            bb:paintRect(x0, y1 - arm + 1, stroke, arm)
            bb:paintRect(x0, y1 - stroke + 1, arm, stroke)
        elseif corner == "tl" then
            bb:paintRect(x0, y0, stroke, arm)
            bb:paintRect(x0, y0, arm, stroke)
        elseif corner == "tr" then
            bb:paintRect(x1 - stroke + 1, y0, stroke, arm)
            bb:paintRect(x1 - arm + 1, y0, arm, stroke)
        elseif corner == "br" then
            bb:paintRect(x1 - stroke + 1, y1 - arm + 1, stroke, arm)
            bb:paintRect(x1 - arm + 1, y1 - stroke + 1, arm, stroke)
        end
    end
end

local function paintOutline(bb, d, inset, stroke)
    local x, y = d.x + inset, d.y + inset
    local w, h = d.w - 2 * inset, d.h - 2 * inset
    bb:paintRect(x, y, w, stroke, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + h - stroke, w, stroke, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, stroke, h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + w - stroke, y, stroke, h, Blitbuffer.COLOR_BLACK)
end

function MarksOverlay:paintTo(bb)
    local board = self.board
    if not (board and board.table) then return end

    local first = board.table:getButtonById(Board.chessToId("a1"))
    local last = board.table:getButtonById(Board.chessToId("h8"))
    local a, z = first and first.frame and first.frame.dimen,
        last and last.frame and last.frame.dimen
    local grid_right, grid_bottom
    if a and z then
        local left, right = math.min(a.x,z.x), math.max(a.x+a.w,z.x+z.w)
        local top, bottom = math.min(a.y,z.y), math.max(a.y+a.h,z.y+z.h)
        grid_right, grid_bottom = right, bottom
        bb:paintRect(left,top,right-left,1,Blitbuffer.COLOR_BLACK)
        bb:paintRect(left,bottom-1,right-left,1,Blitbuffer.COLOR_BLACK)
        bb:paintRect(left,top,1,bottom-top,Blitbuffer.COLOR_BLACK)
        bb:paintRect(right-1,top,1,bottom-top,Blitbuffer.COLOR_BLACK)
    end

    -- The origin is the quiet diagonal pair; the destination gets all four
    -- corners so the move direction remains obvious at a glance.
    if board._previous_move_squares then
        local pairs = {
            {"tl", "br"},
            {"tl", "tr", "br", "bl"},
        }
        for i, square in ipairs(board._previous_move_squares) do
            local id = Board.chessToId(square)
            local button = id and board.table:getButtonById(id) or nil
            local d = button and button.frame and button.frame.dimen or nil
            if d then self.paintCorners(bb, d, pairs[i], 3, 23, 11) end
        end
    end
    local selected = board.selected or board._hint_ring
    if selected then
        local id = Board.chessToId(selected)
        local button = id and board.table:getButtonById(id) or nil
        local d = button and button.frame and button.frame.dimen or nil
        if d then paintOutline(bb, d, 9, 3) end
    end

    -- Coordinates sit in the board's frame: files in a 30px rail directly
    -- beneath the grid, ranks centered in the physical right screen gutter.
    local coord_size = math.max(18, math.floor(board.button_size * 25 / 127 + 0.5))
    local face = Font:getFace("smallinfofont", coord_size)
    local files = board.flipped and {"h","g","f","e","d","c","b","a"}
        or {"a","b","c","d","e","f","g","h"}
    local ranks = board.flipped and {1,2,3,4,5,6,7,8}
        or {8,7,6,5,4,3,2,1}
    if not (grid_right and grid_bottom) then return end
    local screen_right = self.app and self.app.full_width or grid_right
    local rank_rail_w = math.max(0, screen_right - grid_right)
    local file_top_pad = math.max(6,
        math.floor(board.button_size * 10 / 127 + 0.5))
    local file_rail_h = math.max(22,
        math.floor(board.button_size * 30 / 127 + 0.5))
    for col = 1, 8 do
        local id = Board.chessToId(files[col] .. tostring(ranks[8]))
        local b = id and board.table:getButtonById(id) or nil
        local d = b and b.frame and b.frame.dimen or nil
        if d then
            local t = TextWidget:new{text=files[col],face=face,
                fgcolor=Blitbuffer.COLOR_DARK_GRAY}
            local s = t:getSize()
            t:paintTo(bb, d.x + math.floor((d.w-s.w)/2),
                grid_bottom + file_top_pad + math.floor((file_rail_h-s.h)/2))
            t:free()
        end
    end
    for row = 1, 8 do
        local id = Board.chessToId(files[8] .. tostring(ranks[row]))
        local b = id and board.table:getButtonById(id) or nil
        local d = b and b.frame and b.frame.dimen or nil
        if d then
            local t = TextWidget:new{text=tostring(ranks[row]),face=face,
                fgcolor=Blitbuffer.COLOR_DARK_GRAY}
            local s = t:getSize()
            t:paintTo(bb, grid_right + math.floor((rank_rail_w-s.w)/2),
                d.y + math.floor((d.h-s.h)/2))
            t:free()
        end
    end
end

return MarksOverlay
