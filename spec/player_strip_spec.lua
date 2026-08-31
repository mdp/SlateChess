-- Tests for ui.player_strip — the player's bracket on one side of the
-- board: [notation block][clock], with Black's copy being the same
-- strip rotated 180°. These pin the geometry contract the app relies
-- on: the strip is as tall as its taller half, the notation never
-- runs under the timer, the clock's right edge sits on the strip's
-- right edge, and rotation mirrors the content around the strip's box.
--
-- The suite runs outside KOReader, so the two module-level deps are
-- stubbed: ffi/blitbuffer with a tiny grayscale pixel model (enough
-- for the strip's fill/rotate/blit path and pixel-level rotation
-- assertions), and ui/widget/widget with just the extend/new contract
-- the strip uses (new calls init).

package.loaded["ffi/blitbuffer"] = {
    COLOR_WHITE = 255,
    COLOR_BLACK = 0,
}

package.loaded["ui/widget/widget"] = {
    extend = function(class, proto)
        proto = proto or {}
        setmetatable(proto, { __index = class })
        return proto
    end,
    new = function(class, o)
        o = class:extend(o)
        if o.init then o:init() end
        return o
    end,
}

local BB = package.loaded["ffi/blitbuffer"]

function BB.new(w, h)
    local buf = { w = w, h = h }
    function buf:fill(color)
        self.px = {}
        for y = 0, h - 1 do
            self.px[y] = {}
            for x = 0, w - 1 do self.px[y][x] = color end
        end
    end
    function buf:paintRect(x, y, pw, ph, color)
        for yy = y, y + ph - 1 do
            for xx = x, x + pw - 1 do self.px[yy][xx] = color end
        end
    end
    function buf:rotatedCopy(degrees)
        assert(degrees == 180, "stub supports 180 only")
        local rot = BB.new(self.w, self.h)
        rot:fill(BB.COLOR_WHITE)
        for y = 0, self.h - 1 do
            for x = 0, self.w - 1 do
                rot.px[self.h - 1 - y][self.w - 1 - x] = self.px[y][x]
            end
        end
        return rot
    end
    function buf:blitFrom(src, dx, dy)
        for y = 0, src.h - 1 do
            for x = 0, src.w - 1 do
                self.px[dy + y][dx + x] = src.px[y][x]
            end
        end
    end
    function buf:free() end -- luacheck: ignore self
    buf:fill(BB.COLOR_WHITE)
    return buf
end

local PlayerStrip = require("ui.player_strip")

-- A minimal paintable child: records the offsets it was painted at and
-- optionally paints a probe rectangle so rotation can be verified
-- pixel-wise.
local function stubWidget(w, h, probe)
    local painted = {}
    local widget = {}
    function widget:getSize() return { w = w, h = h } end -- luacheck: ignore self
    function widget:paintTo(bb, x, y) -- luacheck: ignore self
        table.insert(painted, { x = x, y = y })
        if probe then
            -- Paint a black rect at the widget's right edge inside its
            -- own box: after a 180° rotation of the strip, it must come
            -- out on the mirrored side of the strip's area.
            bb:paintRect(x + w - probe, y, probe, h, BB.COLOR_BLACK)
        end
    end
    function widget:free() end -- luacheck: ignore self
    return widget, painted
end

describe("PlayerStrip", function()
    it("is as tall as its taller half, the other centered in it", function()
        local notation = stubWidget(60, 20)
        local clock = stubWidget(30, 44)
        local strip = PlayerStrip:new{
            row_w = 100, width = 100, offset_x = 0,
            notation = notation, clock = clock,
        }
        assert.equals(44, strip:getSize().h)
        -- Notation centers: (44 - 20) / 2.
        strip:paintTo({}, 0, 0)
        assert.equals(12, strip.notation_dy)
        -- Clock fills the height, pinned to the right edge.
        assert.equals(70, strip.clock_dx) -- 100 - 30
        assert.equals(0, strip.clock_dy)
    end)

    it("paints the clock's right edge on the strip's right edge", function()
        local notation = stubWidget(60, 20)
        local clock, clock_paints = stubWidget(30, 44)
        local strip = PlayerStrip:new{
            row_w = 100, width = 100, offset_x = 7,
            notation = notation, clock = clock,
        }
        strip:paintTo({}, 3, 5)
        -- Row offset (3) + grid offset (7) + (width - clock_w).
        assert.equals(3 + 7 + 70, clock_paints[1].x)
    end)

    it("reports the full row width so unit rows stack evenly", function()
        local notation = stubWidget(60, 20)
        local strip = PlayerStrip:new{
            row_w = 480, width = 100, offset_x = 12, notation = notation,
        }
        assert.equals(480, strip:getSize().w)
        assert.equals(20, strip:getSize().h)
    end)

    it("builds clockless strips (untimed games) at notation height", function()
        local notation = stubWidget(80, 30)
        local strip = PlayerStrip:new{
            row_w = 100, width = 100, offset_x = 0,
            notation = notation,
        }
        assert.equals(30, strip:getSize().h)
        strip:paintTo({}, 0, 0)
        assert.equals(0, strip.notation_dy)
    end)

    it("paints the rotated strip's content mirrored into the row", function()
        -- A notation probe 4px wide sits at the notation block's RIGHT
        -- edge (x [56, 60) of the scratch buffer). After the strip's
        -- 180° rotation it must land mirrored at x [40, 44), and the
        -- old position must be white again -- flipped away.
        local probe = 4
        local notation, notation_paints = stubWidget(60, 20, probe)
        local strip = PlayerStrip:new{
            row_w = 100, width = 100, offset_x = 10, rotated = true,
            notation = notation,
        }
        local target = BB.new(100, 20)
        strip:paintTo(target, 0, 0)
        -- Painted once, into the scratch buffer (the strip blits the
        -- rotated copy itself).
        assert.equals(1, #notation_paints)
        for i = 0, probe - 1 do
            assert.equals(BB.COLOR_BLACK, target.px[0][10 + 40 + i])
            assert.equals(BB.COLOR_WHITE, target.px[0][10 + 56 + i])
        end
    end)

    it("swallows events when rotated, forwards them when upright", function()
        local handled = 0
        local notation = stubWidget(60, 20)
        notation.handleEvent = function() handled = handled + 1; return true end
        local upright = PlayerStrip:new{
            row_w = 100, width = 100, offset_x = 0, notation = notation,
        }
        assert.is_true(upright:handleEvent({}))
        assert.equals(1, handled)
        local flipped = PlayerStrip:new{
            row_w = 100, width = 100, offset_x = 0, rotated = true,
            notation = notation,
        }
        assert.is_false(flipped:handleEvent({}))
        assert.equals(1, handled)
    end)
end)
