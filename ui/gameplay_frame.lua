-- Shared fullscreen gameplay-frame mechanics. Apps inject their HUD and
-- board widgets in buildUILayout; this module owns glass geometry, resize,
-- overlay ordering and the physical bottom-edge menu affordances.
local Geometry = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Layout = require("ui.layout")
local Design = require("ui.gameplay_design")

local Frame = {}
function Frame.applyGeometry(app, w, h)
    app.full_width, app.full_height = w, h
    local L = Layout.compute{screen_w=w,screen_h=h}
    app.padding_left, app.padding_right = L.pad_x, w-L.pad_x-L.content.w
    app.padding_top, app.padding_bottom = L.pad_y, h-L.pad_y-L.content.h
    app.width, app.height = w, h
    app.dimensions = Geometry:new{w=w,h=h}
    if app.dimen then app.dimen.w, app.dimen.h = w, h end
    local k=Design.scaleFor(w,h)
    local hit = Design.round(Design.hamburger.target.w,k)
    local swipe = math.max(hit, math.floor(h*.12+.5))
    app.menu_hit_rect = Geometry:new{x=Design.round(Design.hamburger.chess_target.x,k),
        y=h-Design.round(81,k),w=hit,h=hit}
    app.menu_swipe_rect = Geometry:new{x=0,y=h-swipe,w=w,h=swipe}
    return L
end
function Frame.resize(app, dimen)
    if not dimen or (dimen.w==app.full_width and dimen.h==app.full_height) then return false end
    local old=app[1]; Frame.applyGeometry(app,dimen.w,dimen.h)
    if app.game then app:buildUILayout(); if app.updateBoardOrientation then app:updateBoardOrientation() end
        if app.board then app.board:updateBoard() end end
    if old and old~=app[1] and old.free then old:free() end
    require("ui/uimanager"):setDirty(app,"full")
    return true
end
function Frame.gesture(app, ges)
    if not (ges and ges.pos) then return false end
    if (ges.ges=="tap" and app.menu_hit_rect and app.menu_hit_rect:contains(ges.pos))
        or (ges.ges=="swipe" and ges.direction=="north" and app.menu_swipe_rect
            and app.menu_swipe_rect:contains(ges.pos)) then
        app:openGameplayMenu(); return true
    end
    return false
end
function Frame.paintOverlay(app, bb, x, y)
    if app.marks then app.marks:paintTo(bb) end
    local k=Design.scaleFor(app.full_width,app.full_height)
    local inset=Design.round(Design.hamburger.chess.x,k); local iw=Design.round(Design.hamburger.ink.w,k)
    local gap=Design.round(Design.hamburger.ink.cadence,k); local stroke=Design.round(Design.hamburger.ink.stroke,k)
    local nx,my
    if app.menu_button_rect then
        local d=app.menu_button_rect
        nx=x+d.x+math.floor((d.w-iw)/2)
        local glyph_h=2*gap+stroke
        my=y+d.y+math.floor((d.h-glyph_h)/2)+gap
    else
        nx=x+inset; my=y+app.full_height-inset-gap-stroke
    end
    for off=-gap,gap,gap do bb:paintRect(nx,my+off,iw,stroke,Blitbuffer.COLOR_DARK_GRAY) end
end
function Frame.bindMarks(app, MarksOverlay)
    if not app.marks then app.marks=MarksOverlay:new{} end
    app.marks.board=app.board; app.marks.app=app
end
return Frame
