local Widget = require("ui/widget/widget")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local Design = require("ui.gameplay_design")
local FittedText = require("ui.fitted_text")

local Hud = Widget:extend{width=1016,height=164,data=nil,bottom=false}
local function round(n) return math.floor(n+.5) end
function Hud:init() self.k=self.width/1016; self.widgets={}; self:setData(self.data or {}) end
function Hud:getSize() return {w=self.width,h=self.height} end
function Hud:_text(s,size,color)
    local w=TextWidget:new{text=s or "",face=Font:getFace("cfont",math.max(8,round(size*self.k))),
        fgcolor=color or Blitbuffer.COLOR_BLACK,padding=0}
    self.widgets[#self.widgets+1]=w; return w
end
function Hud:_boundedText(s,size,max_h,color)
    local w
    repeat
        w=TextWidget:new{text=s or "",face=Font:getFace("cfont",math.max(8,size)),
            fgcolor=color or Blitbuffer.COLOR_BLACK,padding=0}
        if w:getSize().h<=max_h or size<=8 then break end
        w:free(); size=size-1
    until false
    self.widgets[#self.widgets+1]=w
    return w
end
function Hud:_fitted(s,role,rect,color,dynamic)
    local made=FittedText.new{text=s,role=role,rect=Design.rect(rect,self.k),k=self.k,
        color=color,dynamic=dynamic}
    self.widgets[#self.widgets+1]=made.widget
    return made.widget
end
function Hud:setData(d)
    for _,w in ipairs(self.widgets or {}) do if w.free then w:free() end end
    self.widgets={}; self.data=d or {}; local gray=Blitbuffer.COLOR_DARK_GRAY
    if not self.bottom then
        self.labels={}; self.values={}
        for i,label in ipairs({"PUZZLE","PUZZLE / YOU","TYPE"}) do
            self.labels[i]=self:_fitted(label,"puzzle_kicker",{w=Design.columns[i].w,h=35},gray,true)
            self.values[i]=self:_fitted(({d.progress or "",d.rating or "",d.type_label or ""})[i],
                "puzzle_primary",{w=Design.columns[i].w,h=45},nil,true)
        end
    else
        -- Footer type is specified in physical framebuffer pixels. Deliberately
        -- bypass k/Screen scaling and cap against the renderer's real bounds.
        self.moves_label=self:_fitted("MOVES","moves_label",{w=220,h=23},gray,false)
        self.moves=self:_fitted(d.moves or "","notation",{w=240,h=35},nil,true)
        self.feedback=self:_fitted(d.feedback or "YOUR MOVE","status",{w=Design.puzzle.status.w,h=32},nil,false)
    end
end
function Hud:paintTo(bb,x,y)
    local k=self.k; local sx=function(n)return x+round(n*k)end; local sy=function(n)return y+round(n*k)end
    if not self.bottom then
        for i,col in ipairs(Design.columns) do
            self.labels[i]:paintTo(bb,sx(col.x),sy(Design.top.kicker_y))
            self.values[i]:paintTo(bb,sx(col.x),sy(Design.top.value_y))
        end
    else
        -- Every coordinate is a top-left widget bound, never a baseline.
        self.moves_label:paintTo(bb,sx(58),sy(20)); self.moves:paintTo(bb,sx(58),sy(48))
        local fs=self.feedback:getSize()
        local status_right=sx(Design.puzzle.status.right)
        local status_y=sy(Design.puzzle.status.y)
        if self.width==1016 then
            assert(fs.w<=398,"puzzle status must fit its right-aligned region")
            assert(self.moves_label:getSize().h<=23,"MOVES label exceeds its rendered bound")
            assert(self.moves:getSize().h<=35,"move notation exceeds its rendered bound")
            assert(fs.h<=32,"puzzle status exceeds its rendered bound")
            local info_bottom=math.max(48+self.moves:getSize().h,48+fs.h)
            assert(116-info_bottom>=16,"footer information needs 16px button clearance")
        end
        self.feedback:paintTo(bb,status_right-fs.w,status_y)
    end
end
return Hud
