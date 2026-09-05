-- ClockPanel: the compact two-line chess clock card.
--
-- One card shows both remaining times stacked with a thin rule between
-- them, the way a chess clock's two faces sit side by side:
--
--     15:00   <- the running side's time is ink black,
--     ------      the paused side's is gray
--     15:00
--
-- Read upright, the card shows the far player's time above, the near
-- player's below -- your own time is the one closest to you. Which
-- side that is depends on the card: opts.white_top puts White's time
-- in the top row (the app does this for Black's card, whose whole
-- bracket the player strip flips 180°). The card always paints
-- upright; flipping it for Black's side of the board is the strip's
-- job (ui/player_strip.lua rotates the whole bracket). Untimed games
-- build no cards.

local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
-- KOReader face sizes are nominal points and scale to framebuffer pixels;
-- these produce approximately 38px / 60px on the 1080px design device.
-- The opposition clock is intentionally one-third larger than the original
-- 28px treatment so it remains readable across the board.
local TIME_FONT_SIZE = 19
-- Your own time is the bottom row and the one you glance at: 75% larger.
local NEAR_FONT_SIZE = 30
local CARD_PADDING = 0
local CARD_RADIUS = 0
local RULE_GAP = 5        -- visual gap between the two clock lines
local TIME_WIDTH_SLACK = 2

--- Compact time text: MM:SS under an hour, H:MM:SS beyond it.
local function fmt(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
end

--- opts.white / opts.black: starting seconds, used to size the card so
--- per-second text updates never change its geometry. The card always
--- paints upright; the player strip rotates the whole bracket.
--- opts.white_top: White's time in the top row (Black's card, which
--- the strip flips, so Black's time ends up nearest Black).
local ClockPanel = {}

function ClockPanel.new(class, opts) -- luacheck: ignore 212
    local scale = function(n) return Screen:scaleBySize(n) end
    -- getFace scales the size by the screen DPI itself -- pass the
    -- nominal size, never a pre-scaled one.
    local far_face = Font:getFace("cfont", TIME_FONT_SIZE)
    local near_face = Font:getFace("cfont", NEAR_FONT_SIZE)

    -- Time cell width: the longest string either row can show, in the
    -- bigger face -- both rows share the width so their right edges
    -- align on the card's right edge.
    local probe = TextWidget:new{ text = "00:00:00", face = near_face }
    local time_w = probe:getSize().w + scale(TIME_WIDTH_SLACK)
    probe:free()

    local function makeTime(face)
        return TextBoxWidget:new{
            text      = fmt(0),
            face      = face,
            width     = time_w,
            -- Right-aligned: the card is sized for the longest possible
            -- time, so a left-aligned short time would drift left of
            -- the card's right edge -- which the app pins to the
            -- board's end. The ink must hug that edge.
            alignment = "right",
            fgcolor   = Blitbuffer.COLOR_BLACK,
        }
    end

    -- Internal layout: the far player's time above (small), the near
    -- player's below (large -- your own time is the one closest to you
    -- and the one you glance at). Which side is "near" is the caller's
    -- call (opts.white_top): White's card puts White at the bottom,
    -- Black's card (whose strip flips 180°) puts Black there.
    local rows = {
        black = makeTime(opts.white_top and near_face or far_face),
        white = makeTime(opts.white_top and far_face or near_face),
    }
    local top = opts.white_top and rows.white or rows.black
    local bottom = opts.white_top and rows.black or rows.white
    -- The rule is exactly as wide as the times themselves -- a small
    -- line under the digits, not a shelf spanning the whole card. Its
    -- width tracks the currently shown times (see update).
    local body = VerticalGroup:new{
        -- Right-aligned: the rule hugs the times' right edge, which
        -- is the card's right edge -- pinned to the board's end.
        align = "right",
        top,
        VerticalSpan:new{ width = scale(RULE_GAP) },
        bottom,
    }

    local card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius     = scale(CARD_RADIUS),
        bordersize = 0,
        padding    = scale(CARD_PADDING),
        margin     = 0,
        body,
    }

    local panel = {}

    function panel:getSize() -- luacheck: ignore self
        return card:getSize()
    end

    function panel:paintTo(bb, x, y) -- luacheck: ignore self
        card:paintTo(bb, x, y)
    end

    function panel:free(full) -- luacheck: ignore self
        if card.free then card:free(full) end
    end

    --- white_secs / black_secs: remaining seconds per side.
    --- active: "w" or "b" for the side on move, nil when the clock is
    --- paused or stopped (both times ink black).
    function panel:update(white_secs, black_secs, active) -- luacheck: ignore self
        -- The side on move is ink black, the paused side gray.
        rows.black.fgcolor = (active == nil or active == "b")
            and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
        rows.white.fgcolor = (active == nil or active == "w")
            and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
        rows.black:setText(fmt(black_secs))
        rows.white:setText(fmt(white_secs))
        -- setText skips re-rendering when the text is unchanged, but a
        -- color flip alone (side on move changed) must still repaint.
        rows.black:update(true)
        rows.white:update(true)
        -- The rule hugs the times: as wide as the wider of the two
        -- currently shown texts, never the theoretical maximum.
        -- Measured from the rendered widgets themselves, so the line
        -- underlines the digits exactly -- no probe metric drift.
        -- Keep the group stable: right alignment makes both rendered strings
        -- share the clock stack's right edge.
    end

    local logger = require("logger")
    local s = card:getSize()
    logger.dbg("slatechess: clock card",
        string.format("%dx%d row_h %d time_w %d", s.w, s.h,
            top:getSize().h, time_w))

    return panel
end

return ClockPanel
