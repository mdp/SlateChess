-- Compact horizontal strip of enemy pieces captured by one player.
local Widget = require("ui/widget/widget")
local IconWidget = require("ui/widget/iconwidget")
local iconresolver = require("ui.icons")

local CapturedStrip = Widget:extend{ size=31, step=24, pieces=nil, white=false }

function CapturedStrip:init()
    self.pieces = {}
    self.icons = {}
end

function CapturedStrip:setPieces(pieces)
    self.pieces, self.icons = pieces or {}, {}
    for i, letter in ipairs(self.pieces) do
        local name = "slatechess/" .. (self.white and "w" or "b") .. letter
        local file = iconresolver.resolve(name)
        self.icons[i] = IconWidget:new{icon=file and nil or name,file=file,
            alpha=true,width=self.size,height=self.size,is_icon=true}
    end
end

function CapturedStrip:getSize()
    local w = (#self.icons == 0) and 1 or (self.size + (#self.icons - 1) * self.step)
    return {w=w,h=self.size}
end

function CapturedStrip:paintTo(bb, x, y)
    for i, icon in ipairs(self.icons) do icon:paintTo(bb,x+(i-1)*self.step,y) end
end

return CapturedStrip
