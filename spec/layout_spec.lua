-- Tests for ui.layout — the screen's single geometry source.
--
-- These pin the layout invariants the UI is built on: the uniform
-- FRAME_PAD frame, the margin lines every element's ink aligns to, a
-- deterministic board cell (no measuring of built widgets), and
-- minimal symmetric notation gutters with the board dead center.

local Layout = require("ui.layout")

-- Identity scale: nominal points == pixels, so expectations stay readable.
local function identity(n) return n end

local function metrics(scale)
    return Layout.boardMetrics(scale or identity)
end

local function compute(over)
    local o = {
        screen_w = 758,
        screen_h = 1024,
        status_h = 76,
        scale = identity,
        metrics = metrics(),
    }
    for k, v in pairs(over or {}) do o[k] = v end
    return Layout.compute(o)
end

describe("Layout", function()
    it("insets the content box by FRAME_PAD on all four sides", function()
        local L = compute{}
        assert.equals(16, L.pad)
        assert.equals(758 - 32, L.content.w)
        assert.equals(1024 - 32, L.content.h)
        -- The four frame lines sit exactly one pad in from the glass.
        assert.equals(16, L.lines.left)
        assert.equals(758 - 16, L.lines.right)
        assert.equals(16, L.lines.top)
        assert.equals(1024 - 16, L.lines.bottom)
    end)

    it("exposes the frame pad as the one knob, scaled by the scale fn", function()
        -- Nothing else in the app may hardcode a screen-edge padding:
        -- components render box == ink and align to these lines.
        assert.equals(16, Layout.FRAME_PAD_PTS)
        local L = compute{ scale = function(n) return n * 2 end,
            metrics = metrics(function(n) return n * 2 end) }
        assert.equals(32, L.pad)
        assert.equals(758 - 64, L.content.w)
    end)

    it("gives the board a cell whose squares fit inside the content width", function()
        local L = compute{}
        local m = metrics()
        assert.is_true(L.board.squares_w <= L.content.w - m.board_padding - 2 * m.side_zone_w)
        assert.equals(L.board.cell * 8, L.board.squares_w)
    end)

    it("gives the board a cell whose squares fit the zone height", function()
        local L = compute{}
        local m = metrics()
        local built = L.board.squares_w + 2 * m.board_padding + m.file_zone_h
        assert.equals(L.board.height, built)
        assert.is_true(built <= L.board.zone_h)
    end)

    it("reserves exactly the notation width as symmetric gutters", function()
        -- The gutter is minimal: per side just [outer][rank col][gap];
        -- the right side mirrors the left so the squares stay centered.
        local L = compute{}
        local m = metrics()
        assert.equals(L.content.w, L.board.squares_w + 2 * L.board.gutter_w)
        assert.is_true(L.board.gutter_w >= m.side_zone_w + m.board_padding / 2)
    end)

    it("computes the gutter from the content width and squares, deterministically", function()
        local L = compute{}
        local expected = math.floor((L.content.w - L.board.squares_w) / 2)
        assert.equals(expected, L.board.gutter_w)
        local L2 = compute{}
        -- Same inputs, same gutter: no measuring of built widgets.
        assert.equals(L.board.cell, L2.board.cell)
        assert.equals(expected, L2.board.gutter_w)
    end)

    it("keeps the bottom bar tall enough for one row of toolbar ink", function()
        local L = compute{}
        assert.is_true(L.chrome.bottom_h >= 32)
    end)

    it("stacks the middle zone as one strip-board-strip unit", function()
        -- The zone runs from the top bar right down to the bottom bar;
        -- the unit [strip][board][strip] plus its gaps fits inside.
        local L = compute{ strip_h = 40 }
        local unit = 2 * 40 + 2 * L.chrome.strip_gap + L.board.height
        assert.is_true(unit <= L.board.zone_h)
        assert.equals(L.content.h - 76 - L.chrome.bottom_h, L.board.zone_h)
        assert.equals(40, L.board.strip_h)
        -- The bottom strip mirrors the top unless told otherwise.
        assert.equals(40, L.board.bottom_strip_h)
    end)

    it("prices a taller bottom strip once, not twice", function()
        -- The Engine Hints line makes only the bottom strip taller; the
        -- board should shrink by that extra height alone.
        local even = compute{ screen_h = 800, strip_h = 40 }
        local hints = compute{ screen_h = 800, strip_h = 40, bottom_strip_h = 60 }
        assert.equals(40, hints.board.strip_h)
        assert.equals(60, hints.board.bottom_strip_h)
        assert.equals(even.board.zone_h, hints.board.zone_h)
        -- The extra 20px come out of the board's budget, and only once:
        -- the cell gives back between 2 and 3 px per side.
        assert.is_true(hints.board.cell <= even.board.cell - 2)
        assert.is_true(hints.board.cell >= even.board.cell - 3)
    end)

    it("shrinks the board for taller strips, not for one-sided cards", function()
        -- Both strips are part of the unit now, so a taller strip costs
        -- the board twice what it used to when only Black's card counted.
        -- (On a width-bound screen the cell cannot shrink at all; use a
        -- short screen where the height is the binding constraint.)
        local untimed = compute{ screen_h = 800 }
        local timed = compute{ screen_h = 800, strip_h = 40 }
        assert.is_true(timed.board.cell < untimed.board.cell)
        assert.is_true(timed.board.squares_w + 4 < untimed.board.squares_w)
        -- A strip never grows the board, whatever binds.
        local wide = compute{ strip_h = 40 }
        assert.is_true(wide.board.cell <= compute{}.board.cell)
        -- The strips are always part of the unit: strip_h defaults to 0
        -- only in specs; the app always measures one.
        assert.equals(0, untimed.board.strip_h)
    end)

    it("board metrics match the board's nominal chrome", function()
        local m = metrics()
        assert.equals(8, m.board_padding)
        assert.equals(23, m.side_zone_w)  -- outer(1) + label(16) + gap(6)
        assert.equals(27, m.file_zone_h)  -- row(21) + gap(6)
    end)
end)
