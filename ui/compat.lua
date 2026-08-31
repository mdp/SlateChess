-- KOReader's stock Button/ButtonTable do not pass alpha through to IconWidget,
-- so transparent chess SVGs would be flattened against white.
--
-- Additionally, IconWidget only searches KOReader's data dir (and bundled
-- resources) for named icons like "slatechess/wP". Relying on a startup copy
-- of the SVGs into the data dir is fragile, so here we resolve any
-- "slatechess/*" icon name to an absolute file inside the plugin's own
-- icons/ directory and pass it as `file=`, which always works.

local ButtonTable = require("ui/widget/buttontable")
local Button      = require("ui/widget/button")
local IconWidget  = require("ui/widget/iconwidget")
local IconButton  = require("ui/widget/iconbutton")
local iconresolver = require("ui.icons")

local _orig_btn_init = Button.init

function Button:init()
    _orig_btn_init(self)
    if self.icon and self.alpha and self.label_widget then
        self.label_widget:free()
        local file = iconresolver.resolve(self.icon)
        self.label_widget = IconWidget:new{
            icon           = file and nil or self.icon,
            file           = file,
            alpha          = self.alpha,
            rotation_angle = self.icon_rotation_angle,
            dim            = not self.enabled,
            width          = self.icon_width,
            height         = self.icon_height,
        }
        self.frame[1][1] = self.label_widget
    end
end

local _orig_bt_init = ButtonTable.init
local _orig_btn_new = Button.new
local _patching     = false

function ButtonTable:init()
    if _patching then
        _orig_bt_init(self)
        return
    end

    -- Match the row/column order used by ButtonTable:init().
    local alpha_queue = {}
    for _, row in ipairs(self.buttons or {}) do
        for _, entry in ipairs(row) do
            table.insert(alpha_queue, entry.alpha)
        end
    end

    local call_count = 0
    _patching = true

    Button.new = function(cls, opts)
        call_count = call_count + 1
        local alpha = alpha_queue[call_count]
        if alpha ~= nil and opts then
            opts.alpha = alpha
        end
        return _orig_btn_new(cls, opts)
    end

    local ok, err = pcall(_orig_bt_init, self)

    Button.new = _orig_btn_new
    _patching  = false

    if not ok then error(err) end
end

-- Same story for IconButton (title bar gear / hamburger): IconWidget only
-- searches KOReader's own icon dirs for named icons, so re-point any
-- "slatechess/*" icon at the plugin's own file after the fact.
local _orig_ib_init = IconButton.init

function IconButton:init()
    _orig_ib_init(self)
    local file = type(self.icon) == "string" and iconresolver.resolve(self.icon) or nil
    if file then
        self.image:free()
        self.image = IconWidget:new{
            file           = file,
            alpha          = true,
            width          = self.width,
            height         = self.height,
        }
        self.horizontal_group[2] = self.image
        -- Re-derive the tap dimen around the new image (same math as
        -- IconButton:update).
        self.dimen = self.image:getSize()
        self.dimen.w = self.dimen.w + self.padding_left + self.padding_right
        self.dimen.h = self.dimen.h + self.padding_top + self.padding_bottom
        self:initGesListener()
    end
end

return ButtonTable
