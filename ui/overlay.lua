-- Overlay: paints several children on top of each other.
--
-- Group widgets (VerticalGroup / HorizontalGroup) stack their children,
-- which is useless when one child must float over another (e.g. a clock
-- column hanging in the board's side gutter). An Overlay reports the
-- union of its layers' extents and paints each layer at its offset.

local Widget = require("ui/widget/widget")

local Overlay = Widget:extend{
    layers = nil, -- { { widget = w, dx = 0, dy = 0 }, ... }
}

function Overlay:getSize()
    local w, h = 0, 0
    for _, layer in ipairs(self.layers or {}) do
        local s = layer.widget:getSize()
        w = math.max(w, (layer.dx or 0) + s.w)
        h = math.max(h, (layer.dy or 0) + s.h)
    end
    return { w = w, h = h }
end

function Overlay:paintTo(bb, x, y)
    for _, layer in ipairs(self.layers or {}) do
        layer.widget:paintTo(bb, x + (layer.dx or 0), y + (layer.dy or 0))
    end
end

-- Input events (taps on board squares) cascade down the widget tree via
-- handleEvent; as a plain Widget the Overlay would swallow them, so it
-- must forward them to its layers like WidgetContainer does.
function Overlay:handleEvent(event)
    for _, layer in ipairs(self.layers or {}) do
        if layer.widget.handleEvent and layer.widget:handleEvent(event) then
            return true
        end
    end
    return false
end

function Overlay:free(full)
    for _, layer in ipairs(self.layers or {}) do
        if layer.widget.free then layer.widget:free(full) end
    end
end

return Overlay
