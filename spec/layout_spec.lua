local Layout = require("ui.layout")

describe("heads-up gameplay layout", function()
    local L = Layout.compute{screen_w=1080, screen_h=1440,
        scale=function(n) return n end, metrics=Layout.boardMetrics()}

    it("matches the 1080x1440 design master exactly", function()
        assert.same({x=32,y=12,w=1016,h=164,rotation=180}, L.top_hud)
        assert.equals(32, L.board.x)
        assert.equals(184, L.board.y)
        assert.equals(1016, L.board.w)
        assert.equals(1016, L.board.height)
        assert.equals(127, L.board.cell)
        assert.same({x=32,y=1200,w=1016,h=40}, L.file_rail)
        assert.same({x=1048,y=184,w=32,h=1016}, L.rank_rail)
        assert.same({x=32,y=1263,w=1016,h=175,rotation=0}, L.bottom_hud)
        assert.equals(23, L.bottom_hud.y - (L.file_rail.y + L.file_rail.h))
    end)

    it("reserves no coordinate space inside the square grid", function()
        local M = Layout.boardMetrics()
        assert.equals(0, M.side_zone_w)
        assert.equals(0, M.file_zone_h)
        assert.equals(25, M.coord_label)
    end)

    it("retains integral square geometry on other screens", function()
        local small = Layout.compute{screen_w=758, screen_h=1024}
        assert.equals(small.board.cell * 8, small.board.w)
        assert.equals(small.board.w, small.board.height)
        assert.is_true(small.board.x >= 0)
        assert.is_true(small.bottom_hud.y + small.bottom_hud.h <= 1024)
    end)

    it("keeps the complete gameplay frame on-screen across target devices", function()
        for _, size in ipairs({{600,800},{758,1024},{1072,1448},{1236,1648},
                {1264,1680},{1404,1872},{1440,1920},{1860,2480},{1980,2640},
                {1024,1416},{2160,2468}}) do
            local w,h=size[1],size[2]
            local g=Layout.compute{screen_w=w,screen_h=h}
            assert.equals(g.board.cell*8,g.board.w)
            assert.equals(g.board.w,g.board.height)
            assert.is_true(g.top_hud.y+g.top_hud.h<=g.board.y)
            assert.equals(g.board.y+g.board.height,g.file_rail.y)
            assert.is_true(g.file_rail.y+g.file_rail.h<=g.bottom_hud.y)
            assert.is_true(g.bottom_hud.y+g.bottom_hud.h<=h)
            assert.is_true(g.board.x>=0 and g.board.x+g.board.w<=w)
            local k=math.min(w/Layout.DESIGN_W,h/Layout.DESIGN_H)
            assert.is_true(math.max(18,math.floor(30*k+.5))+
                math.max(34,math.floor(48*k+.5))<=math.min(w,h))
        end
    end)

    it("lays out the lower puzzle action row at exact master coordinates", function()
        local a=Layout.puzzleActions(1016,196)
        assert.same({"previous","next","hint"},a.order)
        assert.same({x=324,y=116,w=220,h=58},a.previous)
        assert.same({x=556,y=116,w=220,h=58},a.next)
        assert.same({x=788,y=116,w=220,h=58},a.hint)
        assert.same({x=0,y=116,w=72,h=58},a.menu)
    end)

    it("places the puzzle footer on the corrected master boundary", function()
        local p = Layout.compute{screen_w=1080,screen_h=1440,puzzle_footer=true}
        assert.same({x=32,y=1244,w=1016,h=196,rotation=0},p.bottom_hud)
        assert.equals(4,p.bottom_hud.y-(p.file_rail.y+p.file_rail.h))
        local a=Layout.puzzleActions(p.bottom_hud.w,p.bottom_hud.h)
        assert.equals(116,a.y)
    end)

    it("fits the entire composition when height, not width, is limiting", function()
        local wide = Layout.compute{screen_w=2160, screen_h=2468}
        assert.is_true(wide.board.x > 32)
        assert.is_true(wide.bottom_hud.y + wide.bottom_hud.h <= 2468)
        assert.equals(wide.board.cell * 8, wide.board.w)
    end)
end)
