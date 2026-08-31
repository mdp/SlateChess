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
--   last move  -> brackets on the bottom-left and top-right corners
--   selection  -> brackets on all four corners

local Widget = require("ui/widget/widget")

local Board = require("ui.board")

local MarksOverlay = Widget:extend{
    board = nil,
}

--- Corner brackets for one square. dimen is the button's rect (the
--- full square); the gap from the edge equals the stroke width.
function MarksOverlay.paintCorners(bb, dimen, corners, stroke, arm)
    local x0, y0 = dimen.x, dimen.y
    local x1, y1 = x0 + dimen.w - 1, y0 + dimen.h - 1
    for _, corner in ipairs(corners) do
        if corner == "bl" then
            bb:paintRect(x0 + stroke, y1 - stroke - arm + 1, stroke, arm)
            bb:paintRect(x0 + stroke, y1 - 2 * stroke + 1, arm, stroke)
        elseif corner == "tl" then
            bb:paintRect(x0 + stroke, y0 + stroke, stroke, arm)
            bb:paintRect(x0 + stroke, y0 + stroke, arm, stroke)
        elseif corner == "tr" then
            bb:paintRect(x1 - 2 * stroke + 1, y0 + stroke, stroke, arm)
            bb:paintRect(x1 - stroke - arm + 1, y0 + stroke, arm, stroke)
        elseif corner == "br" then
            bb:paintRect(x1 - 2 * stroke + 1, y1 - stroke - arm + 1, stroke, arm)
            bb:paintRect(x1 - stroke - arm + 1, y1 - 2 * stroke + 1, arm, stroke)
        end
    end
end

function MarksOverlay:paintTo(bb)
    local board = self.board
    if not (board and board.table) then return end

    -- Collect the marked squares and their bracket sets.
    local marks = {}
    if board._previous_move_squares then
        for _, square in ipairs(board._previous_move_squares) do
            marks[square] = { "bl", "tr" }
        end
    end
    local selected = board.selected or board._hint_ring
    if selected then
        marks[selected] = { "tl", "tr", "br", "bl" }
    end
    if not next(marks) then return end

    local stroke = math.max(2, math.floor(board.button_size * 0.04 + 0.5))
    local arm = math.floor(board.button_size * 0.30 + 0.5)
    for square, corners in pairs(marks) do
        local id = Board.chessToId(square)
        local button = id and board.table:getButtonById(id) or nil
        local dimen = button and button.frame and button.frame.dimen or nil
        if dimen then
            self.paintCorners(bb, dimen, corners, stroke, arm)
        end
    end
end

return MarksOverlay
