local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geometry = require("ui/geometry")
local Size = require("ui/size")
local CenterContainer = require("ui/widget/container/centercontainer")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local InputDialog = require("ui/widget/inputdialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonWidget    = require("ui/widget/button")
local ButtonProgressWidget = require("ui/widget/buttonprogresswidget")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ConfirmBox = require("ui/widget/confirmbox")

local CheckButton = require("ui/widget/checkbutton")

local Chess = require("core.game")
local InterfaceWidget = require("ui.interface_dialog")
local _ = require("gettext")

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE

local SettingsWidget = {}
SettingsWidget.__index = SettingsWidget

function SettingsWidget.new(_self, opts)
    assert(opts.clock, "clock is required")
    assert(opts.game,   "game is required")
    assert(opts.onApply and type(opts.onApply) == "function",
           "onApply callback is required")
    assert(opts.parent,   "parent is required")

    local widget = setmetatable({
        engine     = opts.engine,
        clock      = opts.clock,
        game       = opts.game,
        onApply    = opts.onApply,
        onCancel   = opts.onCancel,
        parent     = opts.parent,
        dialog     = nil,
        changes    = {},
    }, SettingsWidget)

    widget:initializeState()
    return widget
end

function SettingsWidget:initializeState()

    self.min_base_min = 1
    self.max_base_min = 180
    self.min_incr_sec = 0
    self.max_incr_sec = 60

    local currentSkill = (self.parent and tonumber(self.parent.current_skill)) or nil

    local engine_options = (self.engine and self.engine.state and self.engine.state.options) or {}

    if not currentSkill then
        local skillOpt = engine_options["Skill Level"]
        currentSkill = (skillOpt and tonumber(skillOpt.value)) or 0
    end
    currentSkill = math.max(0, math.min(20, currentSkill))

    self.changes = {
        human_choice = {
            [Chess.WHITE] = self.game:isHuman(Chess.WHITE),
            [Chess.BLACK] = self.game:isHuman(Chess.BLACK),
        },
        skill_level     = currentSkill,
        engine_depth    = (self.parent and self.parent.engine_depth) or 2,
        engine_movetime = (self.parent and self.parent.engine_movetime) or 1,
        blunder_chance  = (self.parent and self.parent.blunder_chance) or 0.20,
        timed           = (self.parent and self.parent.getSetting and self.parent:getSetting("timed", false)) or false,
        learning_mode   = (self.parent and self.parent.board and self.parent.board.learning_mode == true) or false,
        show_selected   = not (self.parent and self.parent.board and self.parent.board.show_selected == false),
        previous_move_hints = not (self.parent and self.parent.board
            and self.parent.board.previous_move_hints == false),
        opponent_hints = (self.parent and self.parent.board and self.parent.board.opponent_hints == true) or false,
        check_hints = (self.parent and self.parent.board
            and self.parent.board.check_hints == true) or false,
        rotate_top_pieces = (self.parent and self.parent.board
            and self.parent.board.rotate_top_pieces == true) or false,
        flip_pieces_each_turn = (self.parent and self.parent.getSetting
            and self.parent:getSetting("flip_pieces_each_turn", false) == true) or false,
        thinking_indicator = not (self.parent and self.parent.getSetting
            and self.parent:getSetting("thinking_indicator", true) == false),
        show_eval = (self.parent and self.parent.getSetting
            and self.parent:getSetting("show_eval", true) ~= false),
        show_engine_elo = not (self.parent and self.parent.getSetting
            and self.parent:getSetting("show_engine_elo", true) == false),
        show_computer_captures = not (self.parent and self.parent.getSetting
            and self.parent:getSetting("show_computer_captures", true) == false),
        show_hints = (self.parent and self.parent.getSetting
            and self.parent:getSetting("show_hints", false) == true),
        figurine_pgn = (self.parent and self.parent.getSetting
            and self.parent:getSetting("figurine_pgn", false) == true),
        time_control = {
            [Chess.WHITE] = {
                base_minutes  = self.clock.base[Chess.WHITE] / 60,
                incr_seconds  = self.clock.increment[Chess.WHITE],
            },
            [Chess.BLACK] = {
                base_minutes  = self.clock.base[Chess.BLACK] / 60,
                incr_seconds  = self.clock.increment[Chess.BLACK],
            },
        },
    }
end

function SettingsWidget:show()
    local dlg = InputDialog:new{
        title          = _("Game Settings"),
        save_callback  = function() self:applyAndClose() end,
        dismiss_callback = function()
            if self.onCancel then self.onCancel() end
        end,
    }
    dlg.element_width = math.floor(dlg.width * 0.8)
    self.dialog = dlg

    self:buildPlayerTypeGroup()
    self:buildDifficultyGroup()
    self:buildInterfaceButton()
    self:assembleContent()

    dlg:refocusWidget()
    UIManager:show(dlg)
end

function SettingsWidget:markDirty()
    -- InputDialog uses this private hook to enable Save while editing.
    if self.dialog._buttons_edit_callback then
        self.dialog:_buttons_edit_callback(true)
    end
    UIManager:setDirty(self.parent, "ui")
end

function SettingsWidget:buildPlayerTypeGroup()
    local w = self.dialog.element_width

    local function fmt(b, i)
        if i > 0 then return string.format("%d min  +%ds", b, i)
        else return string.format("%d min", b) end
    end

    local function openTimePicker(color, btn)
        local cur = self.changes.time_control[color]
        local color_name = (color == Chess.WHITE) and _("White") or _("Black")
        UIManager:show(DoubleSpinWidget:new{
            title_text    = color_name .. " " .. _("Time"),
            left_text     = _("Minutes"),
            left_min      = self.min_base_min,
            left_max      = self.max_base_min,
            left_value    = cur.base_minutes,
            left_default  = 15,
            right_text    = _("Increment (s)"),
            right_min     = self.min_incr_sec,
            right_max     = self.max_incr_sec,
            right_value   = cur.incr_seconds,
            right_default = 10,
            callback = function(left_val, right_val)
                cur.base_minutes = left_val
                cur.incr_seconds = right_val
                btn.text = fmt(left_val, right_val)
                btn:init()
                self:markDirty()
                UIManager:setDirty(self, "ui")
            end,
        })
    end

    local function onSelect(entry)
        self.changes.human_choice[entry.color] = (entry.text == _("Human"))
        self:markDirty()
    end

    -- Timed games are opt-in; untimed by default. The per-player
    -- time-control buttons only make sense with clocks on, so the
    -- checkbox rebuilds the group and they appear/disappear with it.
    self.timedCheck = CheckButton:new{
        text = _("Timed game (use clocks)"),
        checked = self.changes.timed,
        width = w,
        callback = function()
            self.changes.timed = self.timedCheck.checked
            self:refreshPlayerSettingsGroup()
            self:markDirty()
        end,
        parent = self.dialog,
    }

    local function makeRow(color)
        local cur = self.changes.time_control[color]
        local radio_w = math.floor(w * 0.60)
        local btn_w   = math.floor(w * 0.35)
        local label = (color == Chess.WHITE) and _("White") or _("Black")
        local btn
        btn = ButtonWidget:new{
            text     = fmt(cur.base_minutes, cur.incr_seconds),
            width    = btn_w,
            radius   = Size.radius.button,
            padding  = Size.padding.small,
            callback = function() openTimePicker(color, btn) end,
        }
        local radios = RadioButtonTable:new{
            width  = radio_w,
            radio_buttons = {
                {{ text = _("Human"),    checked =     self.changes.human_choice[color], color = color }},
                {{ text = _("Computer"), checked = not self.changes.human_choice[color], color = color }},
            },
            button_select_callback = onSelect,
            parent = self.dialog,
        }
        local radioCol = VerticalGroup:new{
            width = radio_w,
            TextWidget:new{ text = label .. ":", face = Font:getFace("cfont", 22) },
            VerticalSpan:new{ width = Size.padding.small },
            radios,
        }
        -- Untimed game: no clocks anywhere -- the time-control button
        -- is omitted and the radio column takes the full row width.
        if not self.changes.timed then
            return VerticalGroup:new{ width = w, radioCol }
        end
        return HorizontalGroup:new{
            width   = w,
            spacing = Size.padding.large,
            radioCol,
            btn,
        }
    end

    self.playerSettingsGroup = VerticalGroup:new{
        width   = w,
        spacing = Size.padding.large,
        self.timedCheck,
        makeRow(Chess.WHITE),
        makeRow(Chess.BLACK),
    }
end

-- Rebuilds the player section in place after the "Timed game" checkbox
-- toggles: the time-control buttons exist only when clocks are on, and
-- the rows re-flow to the full width without them. Re-assembling the
-- content (like show() does) keeps the dialog's measured geometry
-- honest instead of leaving a hole where the buttons were.
function SettingsWidget:refreshPlayerSettingsGroup()
    self:buildPlayerTypeGroup()
    self:assembleContent()
    UIManager:setDirty(self.dialog, "ui")
end

function SettingsWidget:buildDifficultyGroup()
    local w = self.dialog.element_width

    self.difficultyPresets = {
        -- The preset IS the difficulty UI; `elo` is a hand-picked
        -- ballpark for the label (no formula -- the raw knobs behind
        -- each preset live in its skill/depth/movetime/blunder fields).
        {
            name          = _("Newcomer"),
            elo           = 600,
            skill_level   = 0,
            engine_depth  = 1,
            engine_movetime = 1,
            blunder_chance  = 0.50,
        },
        {
            name          = _("Beginner"),
            elo           = 750,
            skill_level   = 0,
            engine_depth  = 1,
            engine_movetime = 1,
            blunder_chance  = 0.35,
        },
        {
            name          = _("Learner"),
            elo           = 900,
            skill_level   = 0,
            engine_depth  = 1,
            engine_movetime = 1,
            blunder_chance  = 0.25,
        },
        {
            name          = _("Casual"),
            elo           = 1050,
            skill_level   = 0,
            engine_depth  = 2,
            engine_movetime = 1,
            blunder_chance  = 0.20,
        },
        {
            name          = _("Developing"),
            elo           = 1200,
            skill_level   = 0,
            engine_depth  = 2,
            engine_movetime = 1,
            blunder_chance  = 0.10,
        },
        {
            name          = _("Intermediate"),
            elo           = 1350,
            skill_level   = 0,
            engine_depth  = 3,
            engine_movetime = 1,
            blunder_chance  = 0.10,
        },
        {
            name          = _("Skilled"),
            elo           = 1500,
            skill_level   = 3,
            engine_depth  = 3,
            engine_movetime = 1,
            blunder_chance  = 0.05,
        },
        {
            name          = _("Strong"),
            elo           = 1650,
            skill_level   = 5,
            engine_depth  = 4,
            engine_movetime = 1,
            blunder_chance  = 0.05,
        },
        {
            name          = _("Expert"),
            elo           = 1800,
            skill_level   = 7,
            engine_depth  = 4,
            engine_movetime = 1,
            blunder_chance  = 0.0,
        },
        {
            name          = _("Advanced"),
            elo           = 1950,
            skill_level   = 9,
            engine_depth  = 5,
            engine_movetime = 1,
            blunder_chance  = 0.0,
        },
        {
            name          = _("Club Player"),
            elo           = 2100,
            skill_level   = 10,
            engine_depth  = 0,
            engine_movetime = 1,
            blunder_chance  = 0.0,
        },
        {
            name          = _("Master"),
            elo           = 2400,
            skill_level   = 20,
            engine_depth  = 0,
            engine_movetime = 10,
            blunder_chance  = 0.0,
        },
    }
    local PRESETS = self.difficultyPresets

    self.difficultyLabelWidget = TextWidget:new{
        text = self:getDifficultyLabel(),
        face = Font:getFace("cfont", 22),
    }

    local function applyPreset(pos)
        local p = PRESETS[pos]
        if not p then return end
        self.changes.skill_level     = p.skill_level
        self.changes.engine_depth    = p.engine_depth
        self.changes.engine_movetime = p.engine_movetime
        self.changes.blunder_chance  = p.blunder_chance
        self:applyEngineChanges(self.changes)
        self:refreshDifficultyLabel()
        self:markDirty()
        UIManager:setDirty(self.parent, "ui")
    end

    local cur = self:getCurrentDifficultyPosition() or 4
    self.difficultyProgress = ButtonProgressWidget:new{
        width       = w,
        num_buttons = #PRESETS,
        position    = cur,
        fine_tune   = true,
        callback    = function(pos)
            local p = self:getCurrentDifficultyPosition() or 1
            if pos == "+" then p = math.min(#PRESETS, p + 1)
            elseif pos == "-" then p = math.max(1, p - 1)
            else p = pos end
            self.difficultyProgress.position = p
            applyPreset(p)
        end,
    }

    self.difficultyGroup = VerticalGroup:new{
        width = w,
        self.difficultyLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.difficultyProgress,
    }
end

function SettingsWidget:getCurrentDifficultyPosition()
    for i, p in ipairs(self.difficultyPresets or {}) do
        if p.skill_level == self.changes.skill_level
        and p.engine_depth == self.changes.engine_depth
        and p.engine_movetime == self.changes.engine_movetime
        and math.abs((p.blunder_chance or 0) - (self.changes.blunder_chance or 0)) < 0.01
        then
            return i
        end
    end
end

function SettingsWidget:getDifficultyLabel()
    local pos = self:getCurrentDifficultyPosition()
    if pos then
        local p = self.difficultyPresets[pos]
        return p.name .. "  ELO: ~" .. tostring(p.elo)
    end
    return _("Custom")
end

function SettingsWidget:refreshDifficultyLabel()
    if self.difficultyLabelWidget then
        self.difficultyLabelWidget:setText(self:getDifficultyLabel())
    end
end

function SettingsWidget:buildInterfaceButton()
    local w = self.dialog.element_width
    self.interfaceButton = ButtonWidget:new{
        text    = _("Interface"),
        width   = w,
        radius  = Size.radius.button,
        padding = Size.padding.small,
        callback = function()
            local iw = InterfaceWidget:new{
                parent = self.parent,
                initial = {
                    show_selected = self.changes.show_selected,
                    learning_mode = self.changes.learning_mode,
                    previous_move_hints = self.changes.previous_move_hints,
                    opponent_hints = self.changes.opponent_hints,
                    check_hints = self.changes.check_hints,
                    rotate_top_pieces = self.changes.rotate_top_pieces,
                    flip_pieces_each_turn = self.changes.flip_pieces_each_turn,
                    thinking_indicator = self.changes.thinking_indicator,
                    show_eval = self.changes.show_eval,
                    show_hints = self.changes.show_hints,
                    show_engine_elo = self.changes.show_engine_elo,
                    show_computer_captures = self.changes.show_computer_captures,
                    figurine_pgn = self.changes.figurine_pgn,
                },
                onSave = function(saved)
                    self.changes.show_selected = saved.show_selected
                    self.changes.learning_mode = saved.learning_mode
                    self.changes.previous_move_hints = saved.previous_move_hints
                    self.changes.opponent_hints = saved.opponent_hints
                    self.changes.check_hints = saved.check_hints
                    self.changes.rotate_top_pieces = saved.rotate_top_pieces
                    self.changes.flip_pieces_each_turn = saved.flip_pieces_each_turn
                    self.changes.thinking_indicator = saved.thinking_indicator
                    self.changes.show_eval = saved.show_eval
                    self.changes.show_hints = saved.show_hints
                    self.changes.show_engine_elo = saved.show_engine_elo
                    self.changes.show_computer_captures = saved.show_computer_captures
                    self.changes.figurine_pgn = saved.figurine_pgn
                    self:applyInterfaceChanges(saved)
                    self:markDirty()
                    UIManager:setDirty(self.parent, "ui")
                end,
            }
            iw:show()
        end,
    }
end

function SettingsWidget:applyInterfaceChanges(s)
    if self.parent and self.parent.board then
        local board = self.parent.board
        board.show_selected = s.show_selected and true or false
        board.learning_mode = s.learning_mode and true or false
        board.previous_move_hints = s.previous_move_hints and true or false
        board.opponent_hints = s.opponent_hints and true or false
        board.check_hints = s.check_hints and true or false
        -- Piece orientation is derived by the parent (updateBoardOrientation);
        -- just persist the preference here.
        if not board.learning_mode then
            board:clearValidMoves()
            board:clearCheckHint()
        elseif board.check_hints then
            board:markCheckHint()
        else
            board:clearCheckHint()
        end
        if not board.show_selected and board.selected then
            board:unmarkSelected(board.selected)
        end
    end
    if self.parent and self.parent.setSetting then
        local p = self.parent
        local prev_hints = p:getSetting("show_hints", false) and true or false
        local prev_eval = p:getSetting("show_eval", true) ~= false
        p:setSetting("learning_mode", s.learning_mode and true or false)
        p:setSetting("show_selected", s.show_selected and true or false)
        p:setSetting("previous_move_hints", s.previous_move_hints and true or false)
        p:setSetting("opponent_hints", s.opponent_hints and true or false)
        p:setSetting("check_hints", s.check_hints and true or false)
        p:setSetting("rotate_top_pieces", s.rotate_top_pieces and true or false)
        p:setSetting("flip_pieces_each_turn", s.flip_pieces_each_turn and true or false)
        p:setSetting("thinking_indicator", s.thinking_indicator ~= false)
        p:setSetting("show_eval", s.show_eval ~= false)
        p:setSetting("show_hints", s.show_hints and true or false)
        p:setSetting("show_engine_elo", s.show_engine_elo ~= false)
        p:setSetting("show_computer_captures", s.show_computer_captures ~= false)
        p:setSetting("figurine_pgn", s.figurine_pgn and true or false)
        -- Piece orientation (the rotate preference and the hvh per-turn
        -- flip) is derived by the parent; re-run it so the change lands on
        -- the real board immediately.
        if p.updateBoardOrientation and p.board then
            p:updateBoardOrientation()
            p.board:updateBoard()
        end
        -- The Engine Hints and eval lines change the strips' height
        -- (both strips mirror each other), so the layout must be
        -- rebuilt when one of them toggles; figurines only change the
        -- rendered glyphs, which updateNotation picks up on the next
        -- repaint.
        local new_hints = s.show_hints and true or false
        local new_eval = s.show_eval ~= false
        if p.buildUILayout and p.board
            and (new_hints ~= prev_hints or new_eval ~= prev_eval) then
            p:buildUILayout()
            p:updateBoardOrientation()
            p.board:updateBoard()
            p:updateTimerDisplay()
        end
        if p.updateNotation then p:updateNotation() end
    end
end

function SettingsWidget:applyEngineChanges(s)
    local engine_options = (self.engine and self.engine.state and self.engine.state.options) or {}
    local optSkill = engine_options["Skill Level"]
    local v = math.max(0, math.min(20, tonumber(s.skill_level) or 0))
    if optSkill and self.engine then self.engine:setOption("Skill Level", tostring(v)) end
    if self.parent then
        self.parent.current_skill = v
        self.parent.engine_movetime = math.max(1, math.min(10, tonumber(s.engine_movetime) or 1))
        local d = tonumber(s.engine_depth) or 0
        self.parent.engine_depth = (d == 0 or (d >= 1 and d <= 5)) and d or 2
        local bc = math.max(0.0, math.min(1.0, tonumber(s.blunder_chance) or 0.0))
        self.parent.blunder_chance = bc
        if self.parent.weakening then self.parent.weakening:setChance(bc) end
    end
    if self.parent and self.parent.setSetting then
        local p = self.parent
        p:setSetting("skill_level",     v)
        p:setSetting("engine_depth",    self.parent.engine_depth)
        p:setSetting("engine_movetime", self.parent.engine_movetime)
        p:setSetting("blunder_chance",  self.parent.blunder_chance)
    end
end

function SettingsWidget:assembleContent()
    local D = self.dialog
    local content = FrameContainer:new{
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        background = BACKGROUND_COLOR,
        padding    = 0,
        margin     = 0,

        VerticalGroup:new{
            align = "left",
            D.title_bar,

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.playerSettingsGroup:getSize().h },
                self.playerSettingsGroup
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.difficultyGroup:getSize().h },
                self.difficultyGroup,
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{ w=D.width, h=self.interfaceButton:getSize().h },
                self.interfaceButton,
            },

            VerticalSpan:new{ width = Size.padding.large },

            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = D.button_table:getSize().h,
                },
                D.button_table
            },
            VerticalSpan:new{ width = Size.padding.small },
            CenterContainer:new{
                dimen = Geometry:new{
                    w = D.title_bar:getSize().w,
                    h = Screen:scaleBySize(32),
                },
                ButtonWidget:new{
                    text     = _("Reset to Defaults"),
                    radius   = Size.radius.button,
                    padding  = Size.padding.small,
                    width    = math.floor(D.width * 0.8),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text       = _("Reset all settings to defaults?"),
                            ok_text    = _("Reset"),
                            ok_callback = function() self:resetToDefaults() end,
                        })
                    end,
                },
            },
        }
    }

    D.movable = MovableContainer:new{ content }
    D[1]      = CenterContainer:new{ dimen = Screen:getSize(), D.movable }
end

function SettingsWidget:resetToDefaults()
    self.changes.skill_level     = 0
    self.changes.engine_depth    = 2
    self.changes.blunder_chance  = 0.20
    self.changes.engine_movetime = 1
    self.changes.timed           = false
    self.changes.learning_mode   = false
    self.changes.show_selected   = true
    self.changes.previous_move_hints = true
    self.changes.opponent_hints = false
    self.changes.check_hints = false
    self.changes.rotate_top_pieces = false
    self.changes.thinking_indicator = true
    self.changes.show_eval = true
    self.changes.show_hints = false
    self.changes.figurine_pgn = false
    self.changes.human_choice    = { [Chess.WHITE] = true, [Chess.BLACK] = false }
    self.changes.time_control    = {
        [Chess.WHITE] = { base_minutes = 15, incr_seconds = 10 },
        [Chess.BLACK] = { base_minutes = 15, incr_seconds = 10 },
    }
    self:applyEngineChanges(self.changes)
    self:applyInterfaceChanges(self.changes)
    self:applyAndClose()
end
function SettingsWidget:applyAndClose()
    local s = self.changes
    -- The App's onApply is the single mutation path now: it hands the
    -- draft to the arbiter, which persists every accepted change and
    -- emits the repaints. Nothing here mutates the game/clock/settings
    -- directly anymore.
    if self.parent and self.parent.updateBoardOrientation then
        self.parent:updateBoardOrientation()
    end
    self.onApply(s)
    UIManager:close(self.dialog)
end

return SettingsWidget
