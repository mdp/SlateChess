local Blitbuffer = require("ffi/blitbuffer")
local Widget = require("ui/widget/widget")
local Design = require("ui.gameplay_design")

local HudRule = Widget:extend{ width=0, height=0, top=false, active=nil,
    active_x=nil, active_width=nil }
function HudRule:getSize() return {w=self.width,h=self.height} end
function HudRule:paintTo(bb, x, y)
    local rule_y = self.top and y or (y + self.height - 1)
    bb:paintRect(x, rule_y, self.width, 1, Blitbuffer.COLOR_DARK_GRAY)
    if self.active and self.active() then
        local k=self.width/Design.master.content.w
        local w = self.active_width or Design.round(Design.active_tab.w,k)
        local active_x = self.active_x or Design.round(Design.active_tab.x,k)
        bb:paintRect(x + active_x, rule_y-2, w, 5,
            Blitbuffer.COLOR_BLACK)
    end
end
return HudRule
