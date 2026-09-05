-- Measured text fitting. The small pure `choose` function is deliberately
-- injectable so geometry can be tested without booting KOReader.
local Design = require("ui.gameplay_design")
local Fitted = {}

local function chars(s)
    local out={}
    for c in tostring(s or ""):gmatch("[\1-\127\194-\244][\128-\191]*") do out[#out+1]=c end
    return out
end

function Fitted.choose(text, role, rect, k, measure, dynamic)
    local spec=assert(Design.type[role],"unknown typography role: "..tostring(role))
    local target=math.max(1,Design.round(spec.target,k))
    local minimum=math.max(1,Design.round(spec.min,k))
    local max_h=Design.round(spec.max_h,k)
    local function fits(s,size)
        local m=measure(s,size)
        return m.w<=rect.w and m.h<=math.min(rect.h or max_h,max_h),m
    end
    for size=target,minimum,-1 do
        local ok,m=fits(text,size)
        if ok then return {text=text,size=size,w=m.w,h=m.h,truncated=false} end
    end
    assert(dynamic,"fixed copy does not fit its typography rectangle ("..role..")")
    local glyphs=chars(text)
    for n=#glyphs-1,0,-1 do
        local candidate=table.concat(glyphs,"",1,n).."…"
        local ok,m=fits(candidate,minimum)
        if ok then return {text=candidate,size=minimum,w=m.w,h=m.h,truncated=true} end
    end
    error("ellipsis does not fit its typography rectangle (" .. role .. ")")
end

function Fitted.new(opts)
    local Font=require("ui/font")
    local TextWidget=require("ui/widget/textwidget")
    local function make(s,size)
        return TextWidget:new{text=s,face=Font:getFace(opts.face or "cfont",size),
            fgcolor=opts.color,padding=0}
    end
    local made={}
    local result=Fitted.choose(opts.text or "",opts.role,opts.rect,opts.k or 1,function(s,size)
        local w=make(s,size); local m=w:getSize(); w:free()
        return {w=m.w,h=m.h}
    end,opts.dynamic)
    local widget=make(result.text,result.size)
    made.widget=widget; made.fit=result
    return made
end
return Fitted
