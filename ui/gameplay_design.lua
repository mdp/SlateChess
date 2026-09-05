-- Executable design language for the SlateChess/SlatePuzzle gameplay glass.
-- All numbers in this file are 1080x1440 framebuffer-master pixels.
local D = {}

D.master = { w=1080, h=1440, content={x=32,w=1016} }
D.regions = {
    top_hud={x=32,y=12,w=1016,h=164},
    board={x=32,y=184,w=1016,h=1016,cell=127},
    file_rail={x=32,y=1200,w=1016,h=40},
    chess_bottom={x=32,y=1263,w=1016,h=175},
    puzzle_bottom={x=32,y=1244,w=1016,h=196},
}
D.columns = {
    {x=8,w=312}, {x=352,w=312}, {x=696,w=312},
}
D.merged_columns = { left={x=8,w=312}, right={x=352,w=656} }
D.divider = {h=1}
D.active_tab = {x=336,w=345,h=5,overlap=2}
D.top = {
    kicker_y=12, value_y=42, row_y={42,76,110}, content_bottom=141,
    final_graphic_max_h=31,
}
D.chess_bottom = {
    content={y=16,h=143},
    captures={x=8,w=312}, replay={x=352,w=312}, clock={x=696,w=312},
    replay_back={x=352,w=40}, replay_notation={x=392,w=232}, replay_forward={x=624,w=40},
}
D.puzzle = {
    moves_label={x=58,y=20}, moves={x=58,y=48},
    replay_back={x=10,y=40,w=40,h=48}, replay_forward={x=277,y=40,w=40,h=48},
    status={right=1008,y=48,w=398}, info_action_clearance=16,
    action_y=116, action_h=58,
    menu={x=0,y=116,w=72,h=58},
    previous={x=324,y=116,w=220,h=58},
    next={x=556,y=116,w=220,h=58},
    hint={x=788,y=116,w=220,h=58},
}
D.hamburger = {
    ink={w=48,h=30,stroke=6,cadence=12},
    chess={x=30,y=1380,w=48,h=30}, chess_target={x=18,y=1359,w=72,h=72},
    puzzle_slot={x=0,y=116,w=72,h=58}, target={w=72,h=72}, swipe_fraction=.12,
}
D.type = {
    -- KOReader face sizes are nominal rather than pixel heights. A low floor
    -- is required on low-resolution/DPI profiles; measured caps, not the
    -- nominal request, remain the authoritative constraint.
    kicker={target=14,min=1,max_h=18}, primary={target=19,min=1,max_h=25},
    compact={target=14,min=1,max_h=19}, emphasized={target=16,min=1,max_h=21},
    micro={target=9,min=1,max_h=12}, moves_label={target=20,min=1,max_h=23},
    notation={target=30,min=1,max_h=35}, status={target=28,min=1,max_h=32},
    action={target=14,min=1,max_h=18}, clock_far={target=19,min=1,max_h=42},
    clock_near={target=30,min=1,max_h=64},
    -- Puzzle HUD type is intentionally ~66% larger than the fresh chess HUD:
    -- the puzzle has no engine lines or clocks to carry, so the three column
    -- labels and values own the band. min stays at the old targets so the
    -- dynamic fitter keeps a sane floor on dense device font stacks.
    puzzle_kicker={target=23,min=14,max_h=35},
    puzzle_primary={target=32,min=19,max_h=45},
}

function D.scaleFor(w,h) return math.min(w/D.master.w,h/D.master.h) end
function D.round(n,k) return math.floor(n*(k or 1)+.5) end
function D.rect(rect,k)
    local out={}
    for _,key in ipairs({"x","y","w","h"}) do
        if rect[key] then out[key]=D.round(rect[key],k) end
    end
    return out
end
function D.columnsAt(k)
    local out={}
    for i,c in ipairs(D.columns) do out[i]=D.rect(c,k) end
    return out
end
function D.assertMaster()
    assert(D.regions.board.w==D.regions.board.cell*8,"board cells must be integral")
    for i=1,#D.columns-1 do
        assert(D.columns[i].x+D.columns[i].w<=D.columns[i+1].x,"HUD columns overlap")
    end
    for _,name in ipairs({"previous","next","hint"}) do
        local b=D.puzzle[name]
        assert(b.w==220 and b.y==D.puzzle.action_y and b.h==D.puzzle.action_h,
            "puzzle actions must be equal-role controls")
    end
    assert(D.puzzle.hint.x+D.puzzle.hint.w<=1008,"puzzle actions exceed text-safe edge")
    return true
end
D.assertMaster()
return D
