-- Upright, three-column analysis HUD used when exactly one side is human.
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local CapturedStrip = require("ui.captured_strip")
local Design = require("ui.gameplay_design")

local ComputerHud = Widget:extend{ width=1016, height=164, data=nil }
local function rounded(n) return math.floor(n + 0.5) end

function ComputerHud:init()
    self.k = self.width / 1016
    self.data, self.widgets = self.data or {}, {}
    self.captures = CapturedStrip:new{size=math.max(16, rounded(31*self.k)), step=math.max(12, rounded(25*self.k))}
    self:setData(self.data)
end

function ComputerHud:getSize() return {w=self.width,h=self.height} end

function ComputerHud:_text(text, size, color)
    local w = TextWidget:new{text=text or "", face=Font:getFace("cfont", math.max(8, rounded(size*self.k))),
        fgcolor=color or Blitbuffer.COLOR_BLACK}
    self.widgets[#self.widgets+1] = w
    return w
end

function ComputerHud:setData(data)
    self.data = data or {}
    for _, w in ipairs(self.widgets or {}) do if w.free then w:free() end end
    self.widgets = {}
    self.captures.white = self.data.human_color == "w"
    self.captures:setPieces(self.data.captures or {})
    local gray = Blitbuffer.COLOR_DARK_GRAY
    self.kickers = {computer=self:_text("COMPUTER",14,gray), recent=self:_text("RECENT EVALS",14,gray),
        suggested=self:_text("SUGGESTED MOVES",14,gray)}
    self.rating, self.elo = self:_text(tostring(self.data.elo or 1500),19), self:_text("ELO",9,gray)
    self.recent = {}
    for i=1,3 do local row=(self.data.recent or {})[i] or {}
        self.recent[i]={self:_text(row.move or "",14),self:_text(row.eval or "",14,gray)} end
    self.suggested = {}
    for i=1,2 do local row=(self.data.suggested or {})[i] or {}
        self.suggested[i]={self:_text(row.move or "",16),self:_text(row.eval or "",16,gray)} end
end

local function rightPaint(w, bb, right, y) w:paintTo(bb,right-w:getSize().w,y) end
function ComputerHud:paintTo(bb,x,y)
    local k,d=self.k,self.data
    local sx=function(n) return x+rounded(n*k) end
    local sy=function(n) return y+rounded(n*k) end
    local c=Design.columns
    self.kickers.computer:paintTo(bb,sx(c[1].x),sy(Design.top.kicker_y))
    if d.show_elo ~= false then
        self.rating:paintTo(bb,sx(c[1].x),sy(Design.top.value_y))
        self.elo:paintTo(bb,sx(c[1].x)+self.rating:getSize().w+rounded(7*k),sy(55))
    end
    if d.show_captures ~= false then self.captures:paintTo(bb,sx(c[1].x),sy(Design.top.row_y[3])) end
    if d.show_recent ~= false then
        self.kickers.recent:paintTo(bb,sx(c[2].x),sy(Design.top.kicker_y))
        for i,row in ipairs(self.recent) do local yy=sy(Design.top.row_y[i])
            row[1]:paintTo(bb,sx(c[2].x),yy); rightPaint(row[2],bb,sx(c[2].x+c[2].w),yy) end
    end
    if d.show_suggestions ~= false then
        self.kickers.suggested:paintTo(bb,sx(c[3].x),sy(Design.top.kicker_y))
        for i,row in ipairs(self.suggested) do local yy=sy(Design.top.row_y[i])
            row[1]:paintTo(bb,sx(c[3].x),yy); rightPaint(row[2],bb,sx(c[3].x+c[3].w),yy+rounded(5*k)) end
    end
end

function ComputerHud:free(full)
    for _,w in ipairs(self.widgets or {}) do if w.free then w:free(full) end end
    if self.captures and self.captures.free then self.captures:free(full) end
end
return ComputerHud
