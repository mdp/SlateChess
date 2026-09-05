-- Gameplay geometry. The 1080x1440 profile is the design master; other
-- screens keep the same relationships and integral chessboard squares.
local Design = require("ui.gameplay_design")
local Layout = {}

Layout.DESIGN_W = Design.master.w
Layout.DESIGN_H = Design.master.h
Layout.SIDE_PAD = Design.master.content.x
Layout.VERTICAL_PAD = 12
Layout.HUD_H = Design.regions.top_hud.h
Layout.BOTTOM_HUD_H = Design.regions.chess_bottom.h
Layout.PUZZLE_FOOTER_H = Design.regions.puzzle_bottom.h
Layout.HUD_BOARD_GAP = 8
Layout.FILE_HUD_GAP = 23 -- 8px rhythm plus 15px clearance below file notation
Layout.BOARD_NAV_GAP = 10
Layout.NAV_H = 46
Layout.FILE_RAIL_H = 40 -- 10px top air followed by the 30px notation band
Layout.FRAME_PAD_PTS = 32 -- compatibility for non-game callers

function Layout.logLineHeight(scale)
    scale = scale or function(n) return n end
    return scale(25) + 4
end

-- Coordinates are painted inside the edge squares and cost no board space.
function Layout.boardMetrics(scale)
    scale = scale or function(n) return n end
    return { board_padding=0, coord_label=scale(25), coord_row_h=0,
        coord_outer=0, coord_gap=0, side_zone_w=0, file_zone_h=0 }
end

function Layout.compute(opts)
    local sw, sh = assert(opts.screen_w), assert(opts.screen_h)
    local k = math.min(sw / Layout.DESIGN_W, sh / Layout.DESIGN_H)
    local hud_h = math.floor(Layout.HUD_H * k + 0.5)
    local bottom_hud_h = math.floor((opts.puzzle_footer and
        Layout.PUZZLE_FOOTER_H or Layout.BOTTOM_HUD_H) * k + 0.5)
    local hud_gap = math.floor(Layout.HUD_BOARD_GAP * k + 0.5)
    local file_hud_gap = math.floor(Layout.FILE_HUD_GAP * k + 0.5)
    local file_rail_h = math.floor(Layout.FILE_RAIL_H * k + 0.5)
    -- Scale the board with the complete 4:3 design, never independently from
    -- the window width. This is what keeps a resized/non-4:3 emulator from
    -- clipping the vertical composition.
    local cell = math.max(1, math.floor((Design.regions.board.w * k) / 8))
    local board_w = cell * 8
    local x = math.floor((sw - board_w) / 2)
    -- History now lives inside the bottom HUD. Keep that HUD on the lower
    -- design anchor; the former navigation row becomes a quiet spacer after
    -- the board's compact file rail.
    local composed_h = math.floor(Layout.DESIGN_H * k + 0.5)
    local top = math.max(0, math.floor((sh - composed_h) / 2))
    if sw == Layout.DESIGN_W and sh == Layout.DESIGN_H then top = 12 end
    local board_y = top + hud_h + hud_gap
    local file_rail_y = board_y + board_w
    -- Keep 23px between the 40px file rail (10px air + 30px notation band)
    -- and the bottom rule: the base 8px rhythm plus 15px extra clearance.
    -- used to belong to the full-width history toolbar.
    local bottom_hud_y = file_rail_y + file_rail_h + file_hud_gap
    if opts.puzzle_footer then
        -- The puzzle footer is pinned to the bottom edge. On the design
        -- master this puts its divider at y=1278 and its contents at y=1279.
        bottom_hud_y = sh - bottom_hud_h
    end

    return {
        pad=x, pad_x=x, pad_y=top,
        content={w=board_w, h=sh - 2 * top},
        lines={left=x, right=x+board_w, top=top, bottom=sh-top},
        chrome={line_h=Layout.logLineHeight(opts.scale), strip_gap=hud_gap},
        top_hud={x=x,y=top,w=board_w,h=hud_h,rotation=180},
        board={x=x,y=board_y,w=board_w,height=board_w,cell=cell,
            squares_w=board_w,zone_h=board_w,gutter_w=0,
            strip_h=hud_h,bottom_strip_h=hud_h},
        file_rail={x=x,y=file_rail_y,w=board_w,h=file_rail_h},
        rank_rail={x=x+board_w,y=board_y,w=sw-(x+board_w),h=board_w},
        bottom_hud={x=x,y=bottom_hud_y,w=board_w,h=bottom_hud_h,rotation=0},
    }
end

function Layout.puzzleActions(content_w, _bottom_h)
    local k=content_w/Design.master.content.w
    local function scaled(name) return Design.rect(Design.puzzle[name],k) end
    local y=Design.round(Design.puzzle.action_y,k); local h=Design.round(Design.puzzle.action_h,k)
    return {
        y=y,h=h,order={"previous","next","hint"},
        menu=scaled("menu"), previous=scaled("previous"),
        next=scaled("next"), hint=scaled("hint"),
    }
end

return Layout
