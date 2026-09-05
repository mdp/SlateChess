local _ = require("gettext")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui.compat")
local FrameContainer = require("ui/widget/container/framecontainer")
local Chess = require("chess/src/chess")
local Device = require("device")
local Screen = Device.screen
local Size = require("ui/size")
local UIManager = require("ui/uimanager")

local OverlapGroup = require("ui/widget/overlapgroup")
local IconWidget   = require("ui/widget/iconwidget")
local iconresolver = require("ui.icons")

local BOARD_SIZE = 8
-- Button borders are kept at zero; selection is a true inset overlay rather
-- than a border that changes a square's measured geometry.
local SELECTED_BORDER = 0

local icons = { empty = "slatechess/empty" }
for _, letter in ipairs({ "P", "N", "B", "R", "Q", "K" }) do
    local piece_type = string.lower(letter)
    icons[piece_type] = {
        [Chess.WHITE] = "slatechess/w" .. letter,
        [Chess.BLACK] = "slatechess/b" .. letter,
        rotated = {
            [Chess.WHITE] = "slatechess/w" .. letter .. "_rot",
            [Chess.BLACK] = "slatechess/b" .. letter .. "_rot",
        },
    }
end

local Board = FrameContainer:extend{
    game = nil,
    width = 250,
    height = 250,
    moveCallback = nil,
    holdCallback = nil,
    onPromotionNeeded = nil,
    bordersize = 0,
    padding = 0,
    background = Blitbuffer.COLOR_WHITE,
    board_padding = nil,
    --- Explicit cell size (square edge, px) from ui/layout.lua. When
    --- set, the board skips its own budget math and paints squares of
    --- exactly this size -- the Layout owns the size decision.
    cell = nil,
    learning_mode  = false,
    show_selected  = true,
    previous_move_hints = true,
    opponent_hints = false,
    check_hints = false,
    flipped = false,
    rotate_top_pieces = false,
    face_color = Chess.WHITE,
    _hint_squares  = nil,
    _previous_move_squares = nil,
    _check_square = nil,
    _peek_square = nil,
}

function Board:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

--- Geometry of the 8x8 grid relative to this widget, MEASURED from the
--- real built layout (left_pad slack, real table width incl. square
--- borders): `left`/`top` are the grid's top-left corner, `w`/`h` its
--- full size, `cell` the square edge length. This is the one source of
--- truth for anything that must line up with the squares (the clock
--- cards) -- never recompute it from nominal constants.
function Board:gridGeometry()
    local c = self._coord
    if c and c.inline then
        return { left=c.left, top=c.top, w=c.table_w, h=c.table_h,
            cell=self.button_size }
    end
    return {
        -- [left_pad slack][outer margin][rank col][gap][frame pad] ->
        -- the grid's left edge.
        left = (c and c.left_pad or 0)
            + self.coord_outer_margin
            + self.coord_label_size
            + self.coord_inner_gap
            + self.board_padding / 2,
        top  = self.board_padding,
        w    = c and c.table_w or self.button_size * BOARD_SIZE,
        h    = c and c.table_h or self.button_size * BOARD_SIZE,
        cell = self.button_size,
    }
end

function Board:init()
    if not self.game then
        error("Kochess Board: must be initialized with a Game object")
        return
    end

    -- Cache the frame's padding (_padding_* used by paintTo) and keep
    -- the margins for the fallback budget below. Board:getSize()
    -- overrides the base class without that setup, so this must run on
    -- every init, cell or not.
    local margins = self:allMarginSizes()
    -- Board chrome comes from ui/layout.lua's shared metrics table: the
    -- layout computes the cell size from the same numbers, so the
    -- widget and the budget can never drift apart.
    local Layout = require("ui.layout")
    local m = Layout.boardMetrics()
    self.board_padding = m.board_padding
    -- Coordinate labels (a-h / 1-8) live in narrow gutters: ranks on the
    -- left, files along the bottom. The right gutter mirrors the left's
    -- width but stays empty of chrome -- the taken pieces live there
    -- (ui/capture_gutter), painted over the empty slack.
    self.coord_label_size = m.coord_label
    self.coord_label_row_h = m.coord_row_h
    self.coord_outer_margin = m.coord_outer
    self.coord_inner_gap = m.coord_gap
    local side_zone_w = m.side_zone_w
    local file_zone_h = m.file_zone_h
    local cell
    if self.cell then
        cell = self.cell
    else
        -- Full reserved structure: [outer margin][rank col][gap] per
        -- side (the right side mirrors it, empty), the frame's padding
        -- around the grid, and one file row below.
        local usable_w = self.width  - self.board_padding - 2 * side_zone_w
        local usable_h = self.height - 2 * self.board_padding - file_zone_h
        cell = math.min(
            math.floor(usable_w / BOARD_SIZE) - margins.w,
            math.floor(usable_h / BOARD_SIZE) - margins.h
        )
    end
    self.button_size  = cell
    self.icon_height  = math.floor(cell * 0.78 + 0.5)

    self.selected = nil

    local grid = {}
    local rank_start, rank_stop, rank_step = BOARD_SIZE - 1, 0, -1
    local file_start, file_stop, file_step = 0, BOARD_SIZE - 1, 1
    if self.flipped then
        rank_start, rank_stop, rank_step = 0, BOARD_SIZE - 1, 1
        file_start, file_stop, file_step = BOARD_SIZE - 1, 0, -1
    end

    for rank = rank_start, rank_stop, rank_step do
        local row = {}
        for file = file_start, file_stop, file_step do
            table.insert(row, self:createSquareButton(file, rank))
        end
        table.insert(grid, row)
    end

    local board_px = cell * BOARD_SIZE
    self.table = ButtonTable:new{
        width = board_px,
        buttons = grid,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end,
    }

    self:applySquareColors()
    -- The heads-up board has no external coordinate frame.  Keep the table
    -- as the whole widget and let ui/marks_overlay paint coordinates inside
    -- its edge squares after pieces and move marks.
    local CenterContainer = require("ui/widget/container/centercontainer")
    local table_size = self.table:getSize()
    local left = math.floor((self.width - table_size.w) / 2)
    local top = math.floor((self.height - table_size.h) / 2)
    self._coord = { inline=true, left=left, top=top,
        table_w=table_size.w, table_h=table_size.h }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w=self.width, h=self.height }, self.table,
    }
end

-- Rebuild the coordinate layout: notation lives on the left (ranks) and
-- along the bottom (files) only. The right gutter mirrors the left's
-- width but stays empty of chrome; the taken pieces paint over its
-- slack, so the squares remain perfectly centered.
function Board:rebuildCoordinateLayout()
    local c = self._coord
    local CC, VG, HG, HSpan, VSpan, CGeom =
        c.CenterContainer, c.VerticalGroup, c.HorizontalGroup, c.HorizontalSpan,
        c.VerticalSpan, c.Geom
    local side_w = c.side_zone_w
    local inner_g = self.coord_inner_gap
    local label_w = self.coord_label_size
    local zone_h = c.file_zone_h
    local mid_h = c.table_h + 2 * self.board_padding

    -- Empty placeholder with the same footprint as a label zone.
    local function blank(w, h)
        return CC:new{ dimen = CGeom:new{ w = w, h = h }, HSpan:new{ width = 0 } }
    end

    -- The cell budget leaves a few px of slack (frame padding, button
    -- margins, rounding). Distribute it evenly around the row block so
    -- the grid is centered in the widget and the left / right gutters
    -- match. Per side: [outer margin][rank col][gap][frame pad] -- and
    -- nothing more; the spoils columns center in the right gutter's
    -- slack.
    local row_w = 2 * side_w + self.board_padding + c.table_w
    local slack = math.max(0, self.width - row_w)
    local left_pad = math.floor(slack / 2)
    c.left_pad = left_pad

    -- The letters sit at the bottom of the file zone: the gap above
    -- them separates them from the squares, not from the glass.
    local file_cell = VG:new{
        VSpan:new{ width = inner_g },
        c.file_row,
    }

    self[1] = VG:new{
        align = "left",
        -- The grid row: rank column left, padding frame, mirror gutter right.
        HG:new{
            HSpan:new{ width = left_pad },
            HSpan:new{ width = self.coord_outer_margin },
            c.rank_col,
            HSpan:new{ width = inner_g },
            c.padded,
            HSpan:new{ width = inner_g },
            blank(label_w, mid_h),
            HSpan:new{ width = self.coord_outer_margin },
            HSpan:new{ width = slack - left_pad },
        },
        -- The file row: letters along the bottom edge, shifted by the
        -- frame's left padding so they stay centered under their squares.
        HG:new{
            HSpan:new{ width = left_pad },
            HSpan:new{ width = self.coord_outer_margin },
            blank(label_w, zone_h),
            HSpan:new{ width = inner_g },
            HSpan:new{ width = self.board_padding / 2 },
            file_cell,
            HSpan:new{ width = self.board_padding / 2 },
            HSpan:new{ width = inner_g },
            blank(label_w, zone_h),
            HSpan:new{ width = self.coord_outer_margin },
            HSpan:new{ width = slack - left_pad },
        },
    }
end

-- Coordinate labels follow the displayed grid, not fixed chess colors:
-- unflipped (White's view) ranks read 8-1 top to bottom and files a-h
-- left to right; flipped (Black's view) the grid mirrors, so ranks read
-- 1-8 and files h-a.
function Board:updateCoordinates()
    if not (self._rank_labels and self._file_labels) then return end
    local files = { "a", "b", "c", "d", "e", "f", "g", "h" }
    for i = 1, BOARD_SIZE do
        local rank = self.flipped and i or (BOARD_SIZE + 1 - i)
        local file = self.flipped and (BOARD_SIZE + 1 - i) or i
        self._rank_labels[i]:setText(tostring(rank))
        self._file_labels[i]:setText(files[file])
    end
    if not self._coord_laid_out then
        self._coord_laid_out = true
        self:rebuildCoordinateLayout()
    end
end

function Board:setFlipped(flipped)
    flipped = flipped and true or false
    if self.flipped == flipped then return end
    self.flipped = flipped
    self.selected = nil
    self._hint_squares = nil
    self._hint_ring = nil
    self._previous_move_squares = nil
    self._check_square = nil
    self._peek_square = nil
    self:init()
    self:updateBoard()
end

function Board:setRotateTopPieces(rotate_top_pieces)
    rotate_top_pieces = rotate_top_pieces and true or false
    if self.rotate_top_pieces == rotate_top_pieces then return end
    self.rotate_top_pieces = rotate_top_pieces
    self:updateBoard()
end

-- Draw every piece (both colors) with its 180°-rotated variant so the whole
-- position reads upright for the player of `color`. Used in human-vs-human:
-- the board always faces the side to move.
function Board:setFaceColor(color)
    if color ~= Chess.BLACK then color = Chess.WHITE end
    if self.face_color == color then return end
    self.face_color = color
    self:updateBoard()
end

function Board:createSquareButton(file, rank)
    return {
        id = Board.toId(file, rank),
        icon = icons.empty,
        alpha = true,
        width      = self.button_size,
        -- ButtonTable always adds its own vertical padding around `height`.
        -- Compensate here so the OUTER button frame is exactly cell x cell;
        -- passing cell directly would make every row 2*padding pixels tall
        -- and the 8-row grid would spill into both HUDs.
        height     = math.max(1, self.button_size - 2 * Size.padding.buttontable),
        icon_width = self.button_size,
        icon_height = self.icon_height,
        bordersize = Screen:scaleBySize(SELECTED_BORDER),
        margin = 0,
        padding = 0,
        allow_hold_when_disabled = true,
        callback = function() self:handleClick(file, rank) end,
        hold_callback = self.holdCallback,
    }
end

function Board:applySquareColors()
    for rank = 0, BOARD_SIZE - 1 do
        for file = 0, BOARD_SIZE - 1 do
            local button = self.table:getButtonById(Board.toId(file, rank))
            local color = ((file + rank) % 2 == 1)
                and Blitbuffer.COLOR_LIGHT_GRAY
                or Blitbuffer.COLOR_DARK_GRAY

            button.frame.background = color
            button.frame.border_color = color
        end
    end
end

function Board:handleClick(file, rank)
    local id = Board.toId(file, rank)
    local square = Board.idToPosition(id)

    if self._peek_square then
        self:unmarkSelected(self._peek_square)
        self:clearValidMoves()
        self._peek_square = nil
    end
    self:clearCheckHint()

    if self.game and not self.game:isHuman(self.game:turn()) then
        if self.selected then
            self:unmarkSelected(self.selected)
            self.selected = nil
        end
        return
    end

    local clicked_piece = self.game:pieceAt(square)
    local is_my_piece = clicked_piece and (clicked_piece.color == self.game:turn())
    -- Peeking an opponent piece needs only Opponent Hints; Player Hints
    -- is an independent toggle for one's own pieces.
    local can_peek_opponent = clicked_piece and not is_my_piece and self.opponent_hints

    if self.selected then
        if self.selected == square then
            self:unmarkSelected(square)
            self:clearValidMoves()
            self.selected = nil

        elseif is_my_piece then
            self:unmarkSelected(self.selected)
            self:clearValidMoves()
            self.selected = square
            self:markSelected(square)
            self:markValidMoves(square)

        elseif can_peek_opponent and not self:isLegalMoveTarget(self.selected, square) then
            self:unmarkSelected(self.selected)
            self:clearValidMoves()
            self.selected = nil
            self._peek_square = square
            self:markSelected(square)
            self:markValidMoves(square)

        else
            self:clearValidMoves()
            self:handleMove(self.selected, square)
        end
    else
        if is_my_piece then
            self.selected = square
            self:markSelected(square)
            self:markValidMoves(square)
        elseif can_peek_opponent then
            self._peek_square = square
            self:markSelected(square)
            self:markValidMoves(square)
        end
    end
end

function Board:isLegalMoveTarget(from, to)
    local moves = self.game:legalMoves({ verbose = true, square = from })
    if not moves then return false end
    for _, move in ipairs(moves) do
        if move.to == to then
            return true
        end
    end
    return false
end

function Board:getLegalMove(from, to)
    local moves = self.game:legalMoves({ verbose = true, square = from })
    if not moves then return nil end
    for _, move in ipairs(moves) do
        if move.to == to then
            return move
        end
    end
    return nil
end

function Board:handleMove(from, to)
    self.selected = nil
    self:clearValidMoves()

    local piece = self.game:pieceAt(from)
    local legal_move = self:getLegalMove(from, to)

    local is_pawn_promotion = false
    if legal_move and piece and piece.type == Chess.PAWN and legal_move.promotion then
        is_pawn_promotion = true
    end

    if is_pawn_promotion and self.onPromotionNeeded then
        self:unmarkSelected(from)
        self.onPromotionNeeded(from, to, piece.color)
    elseif legal_move then
        -- The controller owns the game now: report the desired move and
        -- let it play and repaint (through the arbiter).
        if self.moveCallback then
            self.moveCallback{ from = from, to = to, promotion = nil }
        end
    else
        self:unmarkSelected(from)
        self:updateBoard()
    end
end

function Board:handleGameMove(move)
    if not move then return end

    self:updateSquare(move.from)
    self:updateSquare(move.to)

    local extra_squares = self:handleMoveFlags(move, move.to) or {}
    self:markPreviousMove(move)
    self:markCheckHint()
    self:clearEinkGhosts({ move.from, move.to, unpack(extra_squares) })

    if self.moveCallback then
        self.moveCallback(move)
    end
end

--- The tapped square's press flash inverts it in KOReader's "fast"
--- e-ink mode right before the move repaints it; the A2 waveform
--- leaves a ghost of the departed piece on the origin square that
--- survives partial refreshes until a full one. A gray-cleaning
--- "partial" refresh over just the touched squares clears it without
--- a black flash. Software screens have no waveform memory, so skip.
function Board:clearEinkGhosts(squares)
    if not Device:hasEinkScreen() then return end
    local region
    for _, square in ipairs(squares) do
        local id = Board.chessToId(square)
        local button = id and self.table:getButtonById(id) or nil
        local d = button and button.frame and button.frame.dimen or nil
        if d then
            d = d:copy()
            -- Pad a little: the tap flash's invert region is square and
            -- overshoots the (wider than tall) cell by a few pixels.
            d.x, d.y = d.x - 4, d.y - 4
            d.w, d.h = d.w + 8, d.h + 8
            region = region and region:combine(d) or d
        end
    end
    if not region then return end
    -- Let the fast tap-flash refresh settle first, then clean it up.
    UIManager:scheduleIn(0.3, function()
        UIManager:setDirty(nil, "partial", region)
    end)
end

function Board:handleMoveFlags(move, to)
    if not move.flags then return {} end

    local touched = {}
    local to_id_result = Board.chessToId(to)
    if not to_id_result then return touched end
    local to_id = to_id_result

    if move.flags == Chess.FLAGS.EP_CAPTURE then
        local captured_pawn_rank_offset = (move.color == Chess.BLACK and 1 or -1)
        local captured_pawn_id = to_id + captured_pawn_rank_offset --C78 * BOARD_SIZE
        local captured_pawn_square_result = Board.idToPosition(captured_pawn_id)
        if captured_pawn_square_result then
            self:updateSquare(captured_pawn_square_result)
            touched[#touched + 1] = captured_pawn_square_result
        end
    elseif move.flags == Chess.FLAGS.KSIDE_CASTLE then
        local rook_from_file_id = 7
        local rook_to_file_id = 5
        local rank_index = (move.color == Chess.WHITE and 0 or 7)
        local rook_from = Board.idToPosition(Board.toId(rook_from_file_id, rank_index))
        local rook_to = Board.idToPosition(Board.toId(rook_to_file_id, rank_index))
        self:updateSquare(rook_from)
        self:updateSquare(rook_to)
        touched[#touched + 1] = rook_from
        touched[#touched + 1] = rook_to
    elseif move.flags == Chess.FLAGS.QSIDE_CASTLE then
        local rook_from_file_id = 0
        local rook_to_file_id = 3
        local rank_index = (move.color == Chess.WHITE and 0 or 7)
        local rook_from = Board.idToPosition(Board.toId(rook_from_file_id, rank_index))
        local rook_to = Board.idToPosition(Board.toId(rook_to_file_id, rank_index))
        self:updateSquare(rook_from)
        self:updateSquare(rook_to)
        touched[#touched + 1] = rook_from
        touched[#touched + 1] = rook_to
    end
    return touched
end

local OVERLAY_ORDER = { "previous", "check", "hint" }

local function newOverlayIcon(icon_name, w, h)
    local file = iconresolver.resolve(icon_name)
    return IconWidget:new{
        icon        = file and nil or icon_name,
        file        = file,
        alpha       = true,
        width       = w,
        height      = h,
        is_icon     = true,
    }
end

local function rebuildOverlayGroup(og, w, h)
    for i = #og, 2, -1 do
        og[i] = nil
    end
    for _, purpose in ipairs(OVERLAY_ORDER) do
        local icon_name = og._overlay_icons[purpose]
        if icon_name then
            og[#og + 1] = newOverlayIcon(icon_name, w, h)
        end
    end
end

local function overlayIcon(button, purpose, icon_name, w, h)
    local label_container = button.frame[1]
    if not label_container then return end
    local orig = label_container[1]
    if not orig then return end
    local og = orig

    if not og._is_overlay then
        og = OverlapGroup:new{
            dimen = Geom:new{ w = w, h = h },
            orig,
        }
        og._is_overlay = true
        og._orig_widget = orig
        og._overlay_icons = {}
        og._overlay_w = w
        og._overlay_h = h
        label_container[1] = og
    end

    og._overlay_icons[purpose] = icon_name
    rebuildOverlayGroup(og, w, h)
end

local function clearOverlay(button, purpose)
    local label_container = button.frame[1]
    if not label_container then return end
    local og = label_container[1]
    if og and og._is_overlay then
        if purpose then
            og._overlay_icons[purpose] = nil
        else
            og._overlay_icons = {}
        end

        for _, p in ipairs(OVERLAY_ORDER) do
            if og._overlay_icons[p] then
                rebuildOverlayGroup(og, og._overlay_w, og._overlay_h)
                return
            end
        end

        label_container[1] = og._orig_widget
    end
end

function Board:markSelected(_square)
    -- Selection is drawn by the corner brackets (ui/marks_overlay.lua),
    -- which read self.selected at paint time; this only triggers the
    -- repaint that shows them.
    if not self.show_selected then return end
    UIManager:setDirty("all", "ui")
end

-- luacheck: push ignore self
function Board:unmarkSelected(_square)
    UIManager:setDirty("all", "ui")
end
-- luacheck: pop

function Board:getLegalMovesForSquare(square)
    local piece = self.game:pieceAt(square)
    if not piece then return {} end
    if piece.color == self.game:turn() then
        return self.game:legalMoves({ verbose = true, square = square })
    end
    if not self.opponent_hints then return {} end
    return self:getOpponentPotentialMoves(square, piece)
end

local function squareFromCoords(file, rank)
    if file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return string.char(string.byte("a") + file - 1) .. tostring(rank)
end

local function coordsFromSquare(square)
    if type(square) ~= "string" or #square ~= 2 then return nil end
    local file = string.byte(square:sub(1, 1)) - string.byte("a") + 1
    local rank = tonumber(square:sub(2, 2))
    if not file or not rank or file < 1 or file > 8 or rank < 1 or rank > 8 then
        return nil
    end
    return file, rank
end

function Board:getOpponentPotentialMoves(square, piece)
    local file, rank = coordsFromSquare(square)
    if not file then return {} end

    local moves = {}
    local function addIfAvailable(to_square)
        if not to_square then return false end
        local target = self.game:pieceAt(to_square)
        if target and target.color == piece.color then return false end
        moves[#moves + 1] = { from = square, to = to_square }
        return target == nil
    end

    local function addRay(df, dr)
        local f, r = file + df, rank + dr
        while true do
            local to_square = squareFromCoords(f, r)
            if not to_square then break end
            if not addIfAvailable(to_square) then break end
            f, r = f + df, r + dr
        end
    end

    if piece.type == Chess.PAWN then
        local dir = (piece.color == Chess.WHITE) and 1 or -1
        local one = squareFromCoords(file, rank + dir)
        if one and not self.game:pieceAt(one) then
            moves[#moves + 1] = { from = square, to = one }
            local start_rank = (piece.color == Chess.WHITE) and 2 or 7
            local two = squareFromCoords(file, rank + dir * 2)
            if rank == start_rank and two and not self.game:pieceAt(two) then
                moves[#moves + 1] = { from = square, to = two }
            end
        end
        for _, df in ipairs({ -1, 1 }) do
            local capture = squareFromCoords(file + df, rank + dir)
            local target = capture and self.game:pieceAt(capture)
            if target and target.color ~= piece.color then
                moves[#moves + 1] = { from = square, to = capture }
            end
        end
    elseif piece.type == Chess.KNIGHT then
        for _, d in ipairs({ {1, 2}, {2, 1}, {2, -1}, {1, -2}, {-1, -2}, {-2, -1}, {-2, 1}, {-1, 2} }) do
            addIfAvailable(squareFromCoords(file + d[1], rank + d[2]))
        end
    elseif piece.type == Chess.BISHOP then
        for _, d in ipairs({ {1, 1}, {1, -1}, {-1, -1}, {-1, 1} }) do
            addRay(d[1], d[2])
        end
    elseif piece.type == Chess.ROOK then
        for _, d in ipairs({ {1, 0}, {0, -1}, {-1, 0}, {0, 1} }) do
            addRay(d[1], d[2])
        end
    elseif piece.type == Chess.QUEEN then
        for _, d in ipairs({ {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1} }) do
            addRay(d[1], d[2])
        end
    elseif piece.type == Chess.KING then
        for _, d in ipairs({ {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1} }) do
            addIfAvailable(squareFromCoords(file + d[1], rank + d[2]))
        end
    end

    return moves
end

function Board:markValidMoves(square)
    self._hint_squares = {}
    -- Player Hints and Opponent Hints are independent: each controls the
    -- hints for its own color (own piece = Player Hints, opponent piece
    -- peek = Opponent Hints).
    local piece = self.game:pieceAt(square)
    local is_my_piece = piece and piece.color == self.game:turn()
    local hints_on = (is_my_piece and self.learning_mode)
        or (not is_my_piece and self.opponent_hints)
    if hints_on and not self.show_selected then
        -- With "Highlight Selected" off, hinted squares still need to
        -- show WHICH piece is selected. The bracket overlay reads
        -- _hint_ring at paint time; clearValidMoves resets it.
        self._hint_ring = square
    end
    if not hints_on then return end
    local legal = self:getLegalMovesForSquare(square)
    if not legal or #legal == 0 then return end
    for _, m in ipairs(legal) do
        local target = m.to
        local id_result = Board.chessToId(target)
        if id_result then
            local button = self.table:getButtonById(id_result)
            overlayIcon(button, "hint", "slatechess/hint", self.button_size, self.icon_height)
            table.insert(self._hint_squares, target)
        end
    end
    UIManager:setDirty("all", "ui")
end

function Board:clearValidMoves()
    if not self._hint_squares then return end
    self._hint_ring = nil
    for _, square in ipairs(self._hint_squares) do
        local id_result = Board.chessToId(square)
        if id_result then
            clearOverlay(self.table:getButtonById(id_result), "hint")
        end
    end
    self._hint_squares = {}
    UIManager:setDirty("all", "ui")
end

function Board:markPreviousMove(move)
    self:clearPreviousMoveHints()
    if not (self.previous_move_hints and move) then return end

    -- The └ ┐ corner brackets (ui/marks_overlay.lua) draw the last move;
    -- this only records which squares to mark and triggers the repaint.
    self._previous_move_squares = { move.from, move.to }
    UIManager:setDirty("all", "ui")
end

function Board:clearPreviousMoveHints()
    if not self._previous_move_squares then return end
    self._previous_move_squares = nil
    UIManager:setDirty("all", "ui")
end

function Board:getKingSquare(color)
    local board = self.game:board()
    for file_idx = 0, BOARD_SIZE - 1 do
        for rank_idx = 0, BOARD_SIZE - 1 do
            local element = board[BOARD_SIZE - rank_idx][file_idx + 1]
            if element and element.type == Chess.KING and element.color == color then
                return Board.idToPosition(Board.toId(file_idx, rank_idx))
            end
        end
    end
end

function Board:markCheckHint()
    self:clearCheckHint()
    if not (self.learning_mode and self.check_hints and self.game:inCheck()) then return end

    local square = self:getKingSquare(self.game:turn())
    local id_result = square and Board.chessToId(square)
    if not id_result then return end

    self._check_square = square
    overlayIcon(
        self.table:getButtonById(id_result),
        "check",
        "slatechess/hint",
        self.button_size,
        self.icon_height
    )
    UIManager:setDirty("all", "ui")
end

function Board:clearCheckHint()
    if not self._check_square then return end
    local id_result = Board.chessToId(self._check_square)
    if id_result then
        clearOverlay(self.table:getButtonById(id_result), "check")
    end
    self._check_square = nil
    UIManager:setDirty("all", "ui")
end

function Board:placePiece(square, piece, color)
    local icon = icons.empty
    local piece_icons = piece and icons[piece]
    if piece_icons then
        icon = piece_icons[color] or icons.empty
        local top_color = self.flipped and Chess.WHITE or Chess.BLACK
        local use_rotated = self.face_color == Chess.BLACK
            or (self.rotate_top_pieces and color == top_color)
        if use_rotated and piece_icons.rotated then
            icon = piece_icons.rotated[color] or icon
        end
    end
    local id_result = Board.chessToId(square)
    if not id_result then return end

    local button = self.table:getButtonById(id_result)
    button:setIcon(icon, self.button_size)

    local original_color = Board.positionToColor(square)
    button.frame.background = original_color
    button.frame.border_color = original_color

    UIManager:setDirty(self, "ui")
end

function Board:updateSquare(square)
    local piece = self.game:pieceAt(square)
    if piece then
        self:placePiece(square, piece.type, piece.color)
    else
        self:placePiece(square)
    end
end

function Board:updateBoard()
    self:updateCoordinates()
    local board_fen = self.game:board()
    for file_idx = 0, BOARD_SIZE - 1 do
        for rank_idx = 0, BOARD_SIZE - 1 do
            local element = board_fen[BOARD_SIZE - rank_idx][file_idx + 1]
            local square = Board.idToPosition(Board.toId(file_idx, rank_idx))
            if element then
                self:placePiece(square, element.type, element.color)
            else
                self:placePiece(square)
            end
        end
    end
    -- setIcon() rebuilds every square button, wiping overlays; re-derive the
    -- last move from the game so the highlight survives flips/undo/redraws.
    self:markPreviousMove(self.game:lastMove())
    UIManager:setDirty(self, "ui")
end

function Board.toId(file, rank) return file * BOARD_SIZE + rank + 1 end

function Board.chessToId(position)
    if type(position) == "string" and #position == 2 then
        local file_char = position:sub(1, 1)
        local rank_char = position:sub(2, 2)
        if 'a' <= file_char and file_char <= 'h' and '1' <= rank_char and rank_char <= '8' then
            local file_idx = string.byte(file_char) - string.byte('a')
            local rank_idx = tonumber(rank_char) - 1
            return Board.toId(file_idx, rank_idx)
        end
    end
    return nil
end

function Board.idToPosition(id)
    if type(id) == "number" and id >= 1 and id <= BOARD_SIZE * BOARD_SIZE then
        local zero_id = id - 1
        local file_idx = math.floor(zero_id / BOARD_SIZE)
        local rank_idx = zero_id % BOARD_SIZE
        local file_char = string.char(file_idx + string.byte('a'))
        local rank_char = tostring(rank_idx + 1)
        return file_char .. rank_char
    end
    return nil
end

function Board.positionToColor(position)
    if type(position) == "string" and #position == 2 then
        local file_char = position:sub(1, 1)
        local rank_char = position:sub(2, 2)
        if 'a' <= file_char and file_char <= 'h' and '1' <= rank_char and rank_char <= '8' then
            local file_idx = string.byte(file_char) - string.byte('a')
            local rank_idx = tonumber(rank_char) - 1
            return (file_idx + rank_idx) % 2 == 1 and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY
        end
    end
    return nil
end

function Board:allMarginSizes()
    self._padding_top = self.padding_top or self.padding
    self._padding_right = self.padding_right or self.padding
    self._padding_bottom = self.padding_bottom or self.padding
    self._padding_left = self.padding_left or self.padding
    return Geom:new{
        w = (self.margin + self.bordersize) * 2 + self._padding_right + self._padding_left,
        h = (self.margin + self.bordersize) * 2 + self._padding_top + self._padding_bottom,
    }
end

return Board
