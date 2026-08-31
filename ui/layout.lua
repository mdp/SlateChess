-- Layout: single source of truth for the main screen's geometry.
--
-- THE FRAME CONTRACT
-- ------------------
-- FRAME_PAD_PTS below is the ONE padding knob in the app. The content
-- box is the glass inset by that much on all four sides, and every
-- element's visible ink lives inside it, touching the frame line it
-- aligns to: gear / move notation / prev-next chevrons on the left line,
-- hamburger / player roster on the right, icon ink on the top line,
-- chevron and roster ink on the bottom line.
--
-- That holds without per-element nudges because components render
-- box == ink -- no hidden padding of their own:
--   * SVG icons ship with viewBoxes cropped to their exact ink bounds
--     (icons/settings.svg, icons/menu.svg),
--   * buttons are frameless (bordersize 0, no horizontal padding; the
--     tap zone grows upward/around, never inward),
--   * text widgets' ~1px font side bearings are the accepted tolerance.
--
-- When adding an element: give it zero hidden padding, then align its
-- box to a frame line. Never shift an element to compensate for its
-- own internals -- fix the component instead. Change FRAME_PAD_PTS and
-- the whole frame follows.
--
-- Everything else here is the usual single-source geometry: chrome
-- zone heights, board cell, notation gutters. `compute` is pure math --
-- no KOReader imports, no widgets. Callers pass the glass size, a
-- pt->px `scale` function and `status_h` (the one measured input), and
-- get back plain rects. Builders elsewhere consume those rects and
-- measure nothing, so a change in one zone can no longer silently
-- resize another, and spec/layout_spec.lua can pin the invariants.
--
-- Coordinates are relative to the CONTENT box (its origin is FRAME_PAD
-- in from the glass top-left). `lines` holds the absolute glass
-- coordinates of the frame lines.

local Layout = {}

-- Nominal (unscaled) inset from the glass on all four sides: the frame
-- every element's ink aligns to. See THE FRAME CONTRACT above.
Layout.FRAME_PAD_PTS = 16

-- Chrome zone metrics (nominal pts).
local CHROME = {
    nav_button_h = 20, -- bottom bar's one-row basis (bar ink is pinned
                       -- to the bottom line; the rest is its air)
    toolbar_pad  = 4,  -- vertical padding around toolbar buttons
    bottom_extra = 4,  -- extra breathing room under the bottom bar
    log_font     = 14, -- eval / pgn line font
    log_lines    = 2,  -- pgn line + eval line
    strip_gap    = 4,  -- between a player strip and the board
}

--- Height of one notation line (the pgn line or the eval line). Both
--- the strip-height input (computed by the app before `compute`) and
--- the pgn/eval widgets consume this one number.
function Layout.logLineHeight(scale)
    scale = scale or function(n) return n end
    return scale(CHROME.log_font) + 4
end

--- Scaled chrome sizes of the board's coordinate frame. Notation lives
--- on the LEFT (ranks) and BOTTOM (files) only; the right gutter mirrors
--- the left so the squares stay centered. Both the board widget
--- (Board:init) and the cell math below consume this one table, so the
--- budget here and the widget there can never drift apart.
function Layout.boardMetrics(scale)
    scale = scale or function(n) return n end
    local board_padding = scale(8)
    -- Coordinate labels, sized for legibility at arm's length; the row
    -- height tracks the label. The gap keeps the labels off the board's
    -- squares (it also pads the file letters' row below the grid).
    local coord_label   = scale(16)
    local coord_row_h   = scale(21)
    local coord_outer   = scale(1)
    local coord_gap     = scale(6)
    return {
        board_padding = board_padding,
        coord_label   = coord_label,
        coord_row_h   = coord_row_h,
        coord_outer   = coord_outer,
        coord_gap     = coord_gap,
        -- Per-side horizontal chrome (left AND right, mirrored): the
        -- notation gutter is exactly [outer margin][rank col][gap] --
        -- nothing more, the squares need no wider a frame.
        side_zone_w   = coord_outer + coord_label + coord_gap,
        -- Vertical chrome BELOW the grid: [file row][gap]. The top has
        -- no notation, so no zone is reserved there.
        file_zone_h   = coord_row_h + coord_gap,
    }
end

--- Compute the screen layout.
---
--- opts:
---   screen_w, screen_h : glass size
---   status_h           : measured top bar height (the one measured input)
---   strip_h            : measured top player strip height (notation
---                        block vs clock card, whichever is taller)
---   bottom_strip_h     : measured bottom strip height (defaults to
---                        strip_h; taller when the Engine Hints line
---                        adds a third notation row). Both strips are
---                        part of the board's unit.
---   scale              : pt -> px (defaults to identity, for specs)
---   metrics            : Layout.boardMetrics(scale) (required)
---
--- Returns (all x/y relative to the content box):
---   pad, content {w,h}, lines {left,right,top,bottom} (glass coords),
---   chrome {line_h, strip_gap, bottom_h},
---   board {cell, height, squares_w, zone_h, gutter_w, strip_h}.
function Layout.compute(opts)
    assert(opts.metrics, "Layout.compute: board metrics required")
    local scale = opts.scale or function(n) return n end
    local M = opts.metrics

    local pad = scale(Layout.FRAME_PAD_PTS)
    local content_w = opts.screen_w - 2 * pad
    local content_h = opts.screen_h - 2 * pad

    -- Chrome zone heights, stacked inside the content box: top bar
    -- (measured), the middle zone, bottom bar. The middle zone is ONE
    -- centered unit -- [Black's strip][board][White's strip] -- so it
    -- spans from the top bar right down to the bottom bar.
    local line_h   = Layout.logLineHeight(scale)
    local bottom_h = scale(CHROME.nav_button_h) + 2 * scale(CHROME.toolbar_pad)
        + scale(CHROME.bottom_extra)
    local zone_h   = content_h - opts.status_h - bottom_h
    assert(zone_h > 0, "Layout.compute: screen too short for the board")

    -- The unit's vertical chrome: both strips plus the gaps that
    -- separate them from the board. Whatever is left is the board's.
    local strip_h   = opts.strip_h or 0
    local bottom_strip_h = opts.bottom_strip_h or strip_h
    local strip_gap = scale(CHROME.strip_gap)
    local h_budget  = zone_h - strip_h - bottom_strip_h - 2 * strip_gap
        - M.file_zone_h - 2 * M.board_padding
    assert(h_budget > 0, "Layout.compute: screen too short for the board")

    -- Board: one cell size decides everything. The board widget paints
    -- its squares at exactly the given cell (ButtonTable honours
    -- per-button widths), so squares_w == 8*cell and the gutter is
    -- whatever the coordinate chrome leaves over -- computed here,
    -- before anything is built. The gutters are symmetric by
    -- construction: each side reserves exactly the notation width plus
    -- the frame's side padding, so the squares sit dead center in the
    -- content box.
    local w_budget = content_w - M.board_padding - 2 * M.side_zone_w
    local cell = math.min(math.floor(w_budget / 8), math.floor(h_budget / 8))
    assert(cell > 0, "Layout.compute: screen too narrow for the board")

    local squares_w = cell * 8
    local gutter_w = math.floor((content_w - squares_w) / 2)

    return {
        pad = pad,
        content = { w = content_w, h = content_h },
        lines = {
            left = pad,
            right = opts.screen_w - pad,
            top = pad,
            bottom = opts.screen_h - pad,
        },
        chrome = {
            line_h = line_h,
            strip_gap = strip_gap,
            bottom_h = bottom_h,
        },
        board = {
            cell = cell,
            -- Matches the board widget's real built height: grid, the
            -- padding frame around it, and the file-label row below.
            height = squares_w + 2 * M.board_padding + M.file_zone_h,
            squares_w = squares_w,
            zone_h = zone_h,
            gutter_w = gutter_w,
            strip_h = strip_h,
            bottom_strip_h = bottom_strip_h,
        },
    }
end

return Layout
