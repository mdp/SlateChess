local D=require("ui.gameplay_design")

describe("gameplay design tokens",function()
    it("pins every master region and shared track",function()
        assert.same({x=32,w=1016},D.master.content)
        assert.same({x=32,y=12,w=1016,h=164},D.regions.top_hud)
        assert.same({x=32,y=184,w=1016,h=1016,cell=127},D.regions.board)
        assert.same({x=32,y=1200,w=1016,h=40},D.regions.file_rail)
        assert.same({x=32,y=1263,w=1016,h=175},D.regions.chess_bottom)
        assert.same({x=32,y=1244,w=1016,h=196},D.regions.puzzle_bottom)
        assert.same({{x=8,w=312},{x=352,w=312},{x=696,w=312}},D.columns)
        assert.same({x=336,w=345,h=5,overlap=2},D.active_tab)
        assert.is_true(D.assertMaster())
    end)

    it("pins footer, hamburger, and interaction geometry",function()
        assert.same({x=324,y=116,w=220,h=58},D.puzzle.previous)
        assert.same({x=556,y=116,w=220,h=58},D.puzzle.next)
        assert.same({x=788,y=116,w=220,h=58},D.puzzle.hint)
        assert.same({x=30,y=1380,w=48,h=30},D.hamburger.chess)
        assert.same({x=18,y=1359,w=72,h=72},D.hamburger.chess_target)
    end)

    it("scales with rounded framebuffer geometry and disjoint columns",function()
        for _,size in ipairs({{600,800},{758,1024},{1072,1448},{1236,1648},
            {1264,1680},{1404,1872},{1440,1920},{1860,2480},{1980,2640},
            {1024,1416},{2160,2468}}) do
            local k=D.scaleFor(size[1],size[2]); local cols=D.columnsAt(k)
            assert.is_true(cols[1].x+cols[1].w<=cols[2].x)
            assert.is_true(cols[2].x+cols[2].w<=cols[3].x)
            assert.equals(math.floor(1016*k/8)*8,
                require("ui.layout").compute{screen_w=size[1],screen_h=size[2]}.board.w)
        end
    end)
end)
