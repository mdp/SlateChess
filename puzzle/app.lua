-- App: the SlatePuzzle widget — the single controller of a puzzle session.
--
-- The puzzle flow lives in core.puzzle (the same transition/view contract
-- as SlateChess's Arbiter, minus clocks/engine/openings). This App performs
-- what the machine emits (repaints, scheduled auto-replies, announces,
-- cancels) and renders its view: the shared chess board + capture gutter,
-- a bottom status strip, prev/next navigation, the minimal settings dialog
-- and offline resume.
--
-- No engine: the opponent's replies come from the solution line itself,
-- never from a search process.

local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Size = require("ui/size")
local Geometry = require("ui/geometry")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local json = require("json")
local logger = require("logger")

local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local ButtonWidget = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local InputDialog = require("ui/widget/inputdialog")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")

local Game = require("core.game")
local ChessBoard = require("ui.board")
local Puzzles = require("core.puzzles")
local Puzzle = require("core.puzzle")
local MarksOverlay = require("ui.marks_overlay")
local CaptureGutter = require("ui.capture_gutter")
local PuzzleSettings = require("ui.settings")
local TypePicker = require("ui.type_picker")
local PuzzleStatus = require("ui.status")
local PuzzleHud = require("ui.hud")
local GameplayFrame = require("ui.gameplay_frame")
local HudRule = require("ui.hud_rule")
local _ = require("gettext")

-- Paths ---------------------------------------------------------------------

local function normalizePath(path)
    path = (path or ""):gsub("\\", "/")
    return path:gsub("/+", "/")
end

local function joinPath(...)
    local parts = { ... }
    local path = tostring(parts[1] or "")
    for i = 2, #parts do
        path = path:gsub("/+$", "") .. "/" .. tostring(parts[i]):gsub("^/+", "")
    end
    return normalizePath(path)
end

local function fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function getPluginPath()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return normalizePath(src:match("^(.*[/\\])") or "./")
end

local PLUGIN_PATH = getPluginPath()
local VERSION = tostring(dofile(joinPath(PLUGIN_PATH, "_meta.lua")).version or "?")
local ABOUT_URL = "https://github.com/mdp/SlateChess"

--- Parses the top `max_sections` "## heading" blocks out of CHANGELOG.md
-- (shipped with the package; single source of truth). nil when missing.
local function loadRecentChangelog(max_sections)
    local f = io.open(joinPath(PLUGIN_PATH, "CHANGELOG.md"), "r")
    if not f then return nil end
    local sections, current = {}, nil
    for line in f:lines() do
        local heading = line:match("^##%s+(.+)%s*$")
        if heading then
            current = { title = heading, items = {} }
            sections[#sections + 1] = current
        elseif current then
            local item = line:match("^%s*%-%s+(%S.*)$")
            if item then current.items[#current.items + 1] = item end
        end
    end
    f:close()
    local out = {}
    for i, section in ipairs(sections) do
        if i > max_sections then break end
        out[#out + 1] = section.title
        for _, item in ipairs(section.items) do
            out[#out + 1] = "· " .. item
        end
        out[#out + 1] = ""
    end
    if #out == 0 then return nil end
    return table.concat(out, "\n")
end

-- Layout constants ------------------------------------------------------------

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE
-- All screen geometry is decided by ui/layout.lua and consumed here.
local Layout = require("ui.layout")
local FRAME_PAD = Screen:scaleBySize(Layout.FRAME_PAD_PTS)

-- App widget -------------------------------------------------------------------

local App = FrameContainer:extend{
    name = "slatepuzzle",
    background = BACKGROUND_COLOR,
    bordersize = 0,
    padding = FRAME_PAD,
    full_width = Screen:getWidth(),
    full_height = Screen:getHeight(),
}

function App:init()
    GameplayFrame.applyGeometry(self, self.full_width, self.full_height)
    self.covers_fullscreen = true
    Dispatcher:registerAction("slatepuzzle", {
        category = "none", event = "SlatePuzzleStart", title = _("SlatePuzzle"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/slatepuzzle.lua")
end

function App:onSetDimensions(dimen) return GameplayFrame.resize(self, dimen) end
App.onScreenResize = App.onSetDimensions
function App:onGesture(ges) return GameplayFrame.gesture(self, ges) end
function App:openGameplayMenu() return self:openMenu() end

function App:onSlatePuzzleStart()
    self:startSession()
    return true
end

function App:handleEvent(event)
    -- Dispatcher can launch the app while this widget is not on the stack.
    if event.handler == "onSlatePuzzleStart" then
        return self:onSlatePuzzleStart()
    end
    local on_stack = false
    for i = #UIManager._window_stack, 1, -1 do
        if UIManager._window_stack[i].widget == self then
            on_stack = true
            break
        end
    end
    if not on_stack then return false end
    return FrameContainer.handleEvent(self, event)
end

function App:onCloseWidget()
    self._closed = true
    self.marks = nil
    self:persistResume()
    if self.board then
        self.board._hint_ring = nil
        self.board:clearValidMoves()
        self.board:clearPreviousMoveHints()
        self.board:clearCheckHint()
    end
end

function App:addToMainMenu(menu_items)
    menu_items.slatepuzzle = {
        text = _("SlatePuzzle"), sorting_hint = "tools",
        callback = function() self:startSession() end, keep_menu_open = false,
    }
end

-- Settings ---------------------------------------------------------------------

function App:getSetting(key, default)
    return self.settings:readSetting(key, default)
end

function App:setSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function App:persistResume()
    if self.plan then
        local id = self.plan:currentId()
        if id then self:setSetting("last_puzzle", id) end
    end
end

-- Session lifecycle --------------------------------------------------------------

--- Loads the puzzle bank: the bundled data/puzzles.json, overridden by a
--- `puzzles.json` dropped into KOReader's settings dir when present.
function App:loadBank()
    if self.bank then return end
    local bundled = joinPath(PLUGIN_PATH, "data/puzzles.json")
    local override = DataStorage:getSettingsDir() .. "/puzzles.json"
    local path = fileExists(override) and override or bundled
    local f = io.open(path, "r")
    if not f then
        logger.warn("slatepuzzle: no puzzle bank at", path)
        self.bank = {}
        return
    end
    local content = f:read("*a")
    f:close()
    self.bank = Puzzles.load(content, json.decode)
    logger.info(string.format("slatepuzzle: %d puzzles from %s", #self.bank, path))
end

function App:startSession()
    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:close(self)
        -- onCloseWidget latches _closed; re-arm for the fresh session.
        self._closed = false
        self._slots = {}
    end
    self._closed = false
    self._slots = {}

    self:loadBank()
    local resume = self:getSetting("last_puzzle", nil)
    self.plan = Puzzle:new({
        bank       = self.bank,
        difficulty = self:getSetting("puzzle_difficulty", "adaptive"),
        adaptive_rating = self:getSetting("puzzle_adaptive_rating", Puzzles.ADAPTIVE_DEFAULT),
        type       = self:getSetting("puzzle_type", "any"),
        resume     = resume and { id = resume } or nil,
    }, { rng = function() return math.random() end })
    self:dispatch(self.plan:transition{ kind = "start" })
    self:buildUILayout()
    UIManager:show(self)
end

--- Mirrors the machine's authoritative view onto the render code
--- (self.game is what the board reads). On an empty session the machine
--- has no game; the board still needs a valid (empty) Game to render, so
--- fall back to a piece-less board rather than letting the layout crash.
function App:syncFromPuzzle()
    if not self.plan then return end
    self.view = self.plan:view()
    local g = self.view and self.view.game
    if not g then
        g = self.game or Game:new{ fen = "8/8/8/8/8/8/8/8 w - - 0 1" }
    end
    self.game = g
end

--- Performs the canonical-ordered effect list from a transition.
function App:dispatch(fx)
    if self._closed or not self.plan then return end
    self:syncFromPuzzle()
    for _, e in ipairs(fx or {}) do
        local kind = e.kind
        if kind == "cancel" then
            self:performCancel(e.token)
        elseif kind == "schedule" then
            self:performSchedule(e.token, e.delay)
        elseif kind == "repaint" then
            self:performRepaint(e.target)
        elseif kind == "announce" then
            self:performAnnounce(e)
        elseif kind == "persist" then
            self:setSetting(e.key, e.value)
        end
    end
end

--- Arms a machine timer on the UI scheduler and re-enters the funnel.
function App:performSchedule(token, delay)
    local en = { dead = false }
    self._slots[token] = en
    local fn = function()
        if en.dead or self._closed or not self.plan then return end
        if self._slots[token] ~= en then return end
        self._slots[token] = nil
        self:dispatch(self.plan:transition{ kind = "scheduled", token = token })
    end
    en.fn = fn
    UIManager:scheduleIn(delay, fn)
end

function App:performCancel(token)
    local en = self._slots and self._slots[token]
    if not en then return end
    en.dead = true
    if en.fn then UIManager:unschedule(en.fn) end
    self._slots[token] = nil
end

--- Performs a repaint target: toast/board/status/reload.
function App:performRepaint(target)
    if not self.view then return end
    if target == "layout" or target == "all" then
        self:buildUILayout()
        self:updateStatusStrip()
    elseif target == "board" then
        self:updateBoardOrientation()
        if self.board then
            self.board:updateBoard()
            self:refreshMarksOverlay()
        end
    elseif target == "status" then
        self:updateStatusStrip()
    end
    UIManager:setDirty(self, "ui")
end

--- Performs an announce effect.
function App:performAnnounce(e)
    if e.announce_kind == "solved" then
        -- SOLVED is persistent in the bottom HUD; no duplicate toast.
        return
    elseif e.announce_kind == "error" then
        if self.view and self.view.puzzle_id then
            UIManager:show(Notification:new{text=e.text,timeout=2})
        else
            UIManager:show(InfoMessage:new{ text = e.text })
        end
    end
end

-- Move flow ----------------------------------------------------------------------

--- Called by the board with the desired move `{from, to, promotion}`.
function App:onMoveExecuted(move)
    if not (self.plan and move and self.view and self.view.input_enabled) then return end
    self:dispatch(self.plan:transition{
        kind = "human_move",
        from = move.from,
        to   = move.to,
        promotion = move.promotion,
    })
end

function App:openPromotionDialog(from, to, color)
    local choices = { q = Game.QUEEN, r = Game.ROOK, b = Game.BISHOP, n = Game.KNIGHT }
    local icons_p = {
        [Game.QUEEN]  = { [Game.WHITE] = "slatechess/wQ", [Game.BLACK] = "slatechess/bQ" },
        [Game.ROOK]   = { [Game.WHITE] = "slatechess/wR", [Game.BLACK] = "slatechess/bR" },
        [Game.BISHOP] = { [Game.WHITE] = "slatechess/wB", [Game.BLACK] = "slatechess/bB" },
        [Game.KNIGHT] = { [Game.WHITE] = "slatechess/wN", [Game.BLACK] = "slatechess/bN" },
    }
    local icon_size = Screen:scaleBySize(60)
    local dialog = InputDialog:new{ title = _("Promote to"), buttons = {} }
    local btns = {}
    for char, piece_type in pairs(choices) do
        table.insert(btns, ButtonWidget:new{
            icon = icons_p[piece_type][color],
            width = icon_size, icon_width = icon_size, icon_height = icon_size,
            callback = function()
                UIManager:close(dialog)
                self:onMoveExecuted{ from = from, to = to, promotion = char }
            end,
        })
    end
    local content = FrameContainer:new{
        radius = Size.radius.window, bordersize = Size.border.window,
        background = BACKGROUND_COLOR, padding = Size.padding.large,
        VerticalGroup:new{
            align = "center", dialog.title_bar,
            VerticalSpan:new{ width = 20 },
            HorizontalGroup:new{ spacing = 20, unpack(btns) },
        }
    }
    dialog.movable = MovableContainer:new{ content }
    dialog[1] = CenterContainer:new{ dimen = Screen:getSize(), dialog.movable }
    UIManager:show(dialog)
end

-- Board orientation (derived state) --------------------------------------------------

--- The board faces the puzzle's side to move, lichess-style: black-to-move
--- puzzles flip; pieces are never angled (no rotation in puzzles).
function App:updateBoardOrientation()
    if not (self.board and self.view) then return end
    self.board:setFlipped(self.view.flipped)
    self.board:setFaceColor(Game.WHITE)
    self.board.rotate_top_pieces = false
end

-- Chrome ----------------------------------------------------------------------------

local function createToolbarButton(icon, w, h, cb)
    return ButtonWidget:new{ icon = icon, width = w, icon_width = w, icon_height = h,
        padding = 0, margin = 0, bordersize = 0, callback = cb }
end

--- Top bar: the puzzle's meta readout on the LEFT frame line; the hamburger
-- menu button on the RIGHT. Replaces the old center-chevron top bar — the
-- chevrons now live in the bottom action row (lichess-style).
function App:createTopBar()
    local content_w = self.full_width - 2 * FRAME_PAD
    local icon_size = Screen:scaleBySize(21)
    local face = Font:getFace("smallinfofont", 14)
    local probe = TextWidget:new{ text = "H", face = face, padding = 0 }
    local bar_h = math.max(probe:getSize().h, icon_size)
    self.top_meta = TextWidget:new{ text = "", face = face, padding = 0 }
    return OverlapGroup:new{
        dimen = Geometry:new{ w = content_w, h = bar_h },
        allow_mirroring = false,
        LeftContainer:new{
            dimen = Geometry:new{ w = content_w, h = bar_h },
            self.top_meta,
        },
        RightContainer:new{
            dimen = Geometry:new{ w = content_w, h = bar_h },
            createToolbarButton("slatechess/menu", icon_size, icon_size,
                function() self:openMenu() end),
        },
    }
end

--- Bottom action row: prev/next centered, a labeled Skip on the right
-- (abandons the current puzzle, same as next).
function App:createActionBar()
    local content_w = self.full_width - 2 * FRAME_PAD
    local icon_size = Screen:scaleBySize(21)
    local nav_h     = Screen:scaleBySize(16)
    local nav_w     = math.floor(content_w / 12)
    local nav_gap   = Screen:scaleBySize(6)

    self.skip_btn = ButtonWidget:new{
        text = _("Skip"),
        face = Font:getFace("smallinfofont", 16),
        bordersize = 0,
        padding = 0,
        margin = 0,
        callback = function() self:navPuzzle(1) end,
    }
    local bar_h = math.max(icon_size, self.skip_btn:getSize().h)
    local gap_right = Screen:scaleBySize(4)
    self.skip_btn.overlap_offset = {
        content_w - self.skip_btn:getSize().w - gap_right,
        math.floor((bar_h - self.skip_btn:getSize().h) / 2),
    }
    return OverlapGroup:new{
        dimen = Geometry:new{ w = content_w, h = bar_h },
        allow_mirroring = false,
        CenterContainer:new{
            dimen = Geometry:new{ w = content_w, h = bar_h },
            HorizontalGroup:new{
                createToolbarButton("chevron.left", nav_w, nav_h,
                    function() self:navPuzzle(-1) end),
                HorizontalSpan:new{ width = nav_gap },
                createToolbarButton("chevron.right", nav_w, nav_h,
                    function() self:navPuzzle(1) end),
            },
        },
        self.skip_btn,
    }
end

--- The hint button, overlaid on the right of the state row (see
-- buildUILayout): a bulb. First tap reveals the next move by highlighting
-- the piece (brackets); later taps auto-play the current expected move,
-- and after the 1s opponent reply the next piece is highlighted — tap,
-- move, reply, repeat.
function App:createHintButton()
    local icon_size = Screen:scaleBySize(21)
    self.hint_btn = createToolbarButton("slatechess/lightbulb", icon_size, icon_size, function()
        if not self.view then return end
        if self.plan then
            if self.board then self.board:clearValidMoves() end
            self:dispatch(self.plan:transition{ kind = "hint" })
        end
    end)
    self.hint_btn.visible = false
    return self.hint_btn
end

--- The hamburger dialog (the app's menu).
function App:openMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            { { text = _("Puzzle Type…"), callback = function()
                    UIManager:close(dialog)
                    self:openTypePicker()
                end } },
            { { text = _("Settings"), callback = function()
                    UIManager:close(dialog)
                    self:openSettings()
                end } },
            { { text = _("Restart Puzzle"), callback = function()
                    UIManager:close(dialog)
                    self:dispatch(self.plan:transition{ kind = "restart" })
                end } },
            { { text = _("About SlatePuzzle"), callback = function()
                    UIManager:close(dialog)
                    self:showAbout()
                end } },
            { { text = _("Exit"), callback = function()
                    UIManager:close(dialog)
                    self:confirmExit()
                end } },
        },
    }
    UIManager:show(dialog)
end

function App:navPuzzle(dir)
    if self.plan then
        self:dispatch(self.plan:transition{ kind = dir > 0 and "next" or "prev" })
    end
end

--- About dialog.
function App:showAbout() -- luacheck: ignore self
    local text = "SlatePuzzle v" .. VERSION .. "\n\n"
    local changes = loadRecentChangelog(2)
    if changes then text = text .. changes .. "\n" end
    text = text .. ABOUT_URL
    UIManager:show(InfoMessage:new{ text = text })
end

function App:confirmExit()
    self:persistResume()
    UIManager:close(self, "full")
end

-- Layout -------------------------------------------------------------------------------

function App:buildUILayout()
    local scale_fn = function(n) return Screen:scaleBySize(n) end
    local L = Layout.compute{
        screen_w = self.full_width,
        screen_h = self.full_height,
        scale    = scale_fn,
        puzzle_footer = true,
    }
    logger.dbg("slatepuzzle: layout",
        string.format("content %dx%d board cell %d squares %d",
            L.content.w, L.content.h, L.board.cell, L.board.squares_w))

    local content_w = L.content.w
    local content_h = L.content.h
    self:initializeBoard(L)
    self.top_hud = PuzzleHud:new{width=content_w,height=L.top_hud.h}
    self.bottom_hud = PuzzleHud:new{width=content_w,height=L.bottom_hud.h,bottom=true}
    local top = OverlapGroup:new{dimen=Geometry:new{w=content_w,h=L.top_hud.h},allow_mirroring=false,
        self.top_hud,HudRule:new{width=content_w,height=L.top_hud.h,top=false,active=function()return false end}}
    local k=content_w/1016
    local bottom_rule=HudRule:new{width=content_w,height=L.bottom_hud.h,top=true,
        active_x=math.floor(336*k+.5),active_width=math.floor(345*k+.5),
        active=function()return self.view and self.view.input_enabled end}
    local bottom = OverlapGroup:new{dimen=Geometry:new{w=content_w,h=L.bottom_hud.h},allow_mirroring=false,
        self.bottom_hud,bottom_rule}
    local A=Layout.puzzleActions(content_w,L.bottom_hud.h)
    local function action(text, box, cb)
        return ButtonWidget:new{text=text,text_font_face="cfont",
            text_font_size=math.max(8,math.floor(14*k+.5)),text_font_bold=false,
            width=box.w,height=box.h,bordersize=math.max(1,math.floor(2*k+.5)),
            padding=0,margin=0,callback=cb}
    end
    self.prev_btn=action(_("PREVIOUS"),A.previous,function()self:navPuzzle(-1)end)
    self.next_btn=action(_("NEXT"),A.next,function()self:navPuzzle(1)end)
    self.hint_btn=action(_("HINT"),A.hint,function()
        if self.plan and self.view and self.view.input_enabled then
            self.board:clearValidMoves(); self:dispatch(self.plan:transition{kind="hint"})
        end
    end)
    local actions={{self.prev_btn,A.previous},{self.next_btn,A.next},{self.hint_btn,A.hint}}
    for _,item in ipairs(actions) do
        local b,box=item[1],item[2]
        b.overlap_offset={box.x,box.y}
        bottom[#bottom+1]=b
    end
    local chevron_w,chevron_h=math.floor(40*k+.5),math.floor(48*k+.5)
    local function replayButton(icon,dir,x)
        local b=ButtonWidget:new{icon=icon,alpha=true,width=chevron_w,height=chevron_h,
            icon_width=18,icon_height=31,bordersize=0,padding=0,margin=0,
            callback=function()
                if self.board then self.board:clearValidMoves() end
                self:dispatch(self.plan:transition{kind="replay",direction=dir})
            end}
        b.overlap_offset={math.floor(x*k+.5),math.floor(40*k+.5)}
        bottom[#bottom+1]=b
        return b
    end
    self.replay_back_btn=replayButton("slatechess/puzzle-chevron-left",-1,10)
    self.replay_forward_btn=replayButton("slatechess/puzzle-chevron-right",1,277)
    self.menu_button_rect=Geometry:new{x=L.bottom_hud.x+A.menu.x,
        y=L.bottom_hud.y+A.menu.y,w=A.menu.w,h=A.menu.h}
    local menu_hit=math.floor(72*k+.5)
    self.menu_hit_rect=Geometry:new{x=self.menu_button_rect.x,
        y=self.menu_button_rect.y+math.floor((self.menu_button_rect.h-menu_hit)/2),
        w=menu_hit,h=menu_hit}
    self[1] = VerticalGroup:new{
        align = "center", width = content_w, height = content_h,
        top,
        VerticalSpan:new{width=L.board.y-(L.top_hud.y+L.top_hud.h)},
        self.board,
        VerticalSpan:new{width=L.bottom_hud.y-(L.board.y+L.board.height)},
        bottom,
    }

    -- Board:init only builds the empty scaffold (squares + coordinates);
    -- every layout build must re-apply orientation and place the pieces.
    self:updateBoardOrientation()
    if self.board then self.board:updateBoard() end
    self:updateStatusStrip()
    self:refreshMarksOverlay()
end

function App:initializeBoard(L)
    self.board = ChessBoard:new{
        game          = self.game,
        width         = L.content.w,
        height        = L.board.height,
        cell          = L.board.cell,
        moveCallback  = function(move) self:onMoveExecuted(move) end,
        onPromotionNeeded = function(f, t, c) self:openPromotionDialog(f, t, c) end,
        -- Puzzle play: the board shows the last move and the selection but
        -- no learning-mode / hint machinery.
        learning_mode = false,
        show_selected = true,
        previous_move_hints = true,
        opponent_hints = false,
        check_hints = false,
        flipped = self.view and self.view.flipped or false,
        rotate_top_pieces = false,
    }
end

--- Binds the marks painter (ui/marks_overlay.lua) to the live board.
function App:refreshMarksOverlay()
    GameplayFrame.bindMarks(self, MarksOverlay)
end

--- Paints the game, then the move/selection brackets on top.
function App:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    GameplayFrame.paintOverlay(self, bb, x, y)
end

-- Status strip --------------------------------------------------------------------------

function App:updateStatusStrip()
    if not (self.top_hud and self.bottom_hud and self.view) then return end
    local v=self.view
    local rating = v.rating and tostring(v.rating) or "—"
    if v.difficulty == "adaptive" and v.adaptive_rating then
        rating = rating .. " / " .. tostring(v.adaptive_rating)
    end
    self.top_hud:setData{progress=("%d / %d"):format(v.index or 0,v.total or 0),
        rating=rating,type_label=(v.type_label or "RANDOM"):upper()}
    local feedback={your_move="YOUR MOVE",best_move="BEST MOVE",try_again="TRY ANOTHER MOVE",
        solved="SOLVED",review="REVIEW"}
    self.bottom_hud:setData{moves=v.recent_plies or PuzzleStatus.sanLine(v.san,2),
        feedback=feedback[v.feedback] or "YOUR MOVE",rated=v.rated}
    self:refreshHint(self.view)
    self:refreshActions(self.view)
    self:refreshReplay(self.view)
    self:refreshRevealHighlight(self.view)
    UIManager:setDirty(self, "ui")
end

--- Top-left meta readout: "7/120 · ★1359 · Back rank mate". The rating
-- becomes a dash once the round is unrated (hint / wrong first move).
function App:refreshTopMeta(v)
    if not self.top_meta then return end
    local txt = ""
    if v.puzzle_id then
        txt = ("%d/%d"):format(v.index, v.total)
        if v.rating then
            txt = txt .. " · ★" .. (v.rated and tostring(v.rating) or "–")
        end
        local label = nil
        if v.type and v.type ~= "any" and v.type ~= "random" and v.type_label then
            label = v.type_label
        elseif v.themes and #v.themes > 0 then
            local top, count = {}, 0
            for _, t in ipairs(v.themes) do
                if count < 2 then top[#top + 1] = t; count = count + 1 end
            end
            if #top > 0 then label = table.concat(top, ", ") end
        end
        if label then txt = txt .. " · " .. label end
    end
    self.top_meta:setText(txt)
end

--- The hint button is only live mid-puzzle (and only when hints are
-- enabled); it stays a bulb whether revealing or playing the move.
function App:refreshHint(v)
    local btn = self.hint_btn
    if not btn then return end
    local show_hints = self:getSetting("puzzle_show_hints", true) ~= false
    btn:setText(show_hints and _("HINT") or "", btn.width)
    btn:enableDisable(show_hints and v.input_enabled and v.hint ~= nil)
end

--- Skip only makes sense on a live puzzle (abandon it).
function App:refreshActions(v)
    local enabled=v.puzzle_id ~= nil
    if self.prev_btn then self.prev_btn:enableDisable(enabled) end
    if self.next_btn then self.next_btn:enableDisable(enabled) end
end

function App:refreshReplay(v)
    if self.replay_back_btn then
        self.replay_back_btn:enableDisable(v.can_replay_back == true)
    end
    if self.replay_forward_btn then
        self.replay_forward_btn:enableDisable(v.can_replay_forward == true)
    end
end

--- The reveal highlight: the piece the solver should move gets the
-- all-corner bracket ring (marks_overlay reads board._hint_ring).
-- While revealed, the highlight follows to the next expected move after
-- each opponent reply, so tapping the bulb plays move after move.
function App:refreshRevealHighlight(v)
    if not self.board then return end
    if v.revealed and v.hint and v.status == Puzzle.SOLVING then
        self.board._hint_ring = v.hint.from
    else
        self.board._hint_ring = nil
    end
    if self.marks then self.marks.board = self.board end
end

-- Settings ---------------------------------------------------------------------------------

--- Applies a type pick: persist + re-filter the machine (fresh draw).
--- Shared by the quick hamburger entry (immediate) and the settings dialog
--- (applied via Save there, but the callback is the same).
function App:applyType(id)
    if not self.plan or not id then return end
    self:setSetting("puzzle_type", id)
    self:dispatch(self.plan:transition{ kind = "settings", changes = { type = id } })
    if self.plan:view() and self.plan:view().puzzle_id then
        UIManager:setDirty(self, "ui")
    end
end

--- Opens the type picker over the current screen. `onSelect(id)` fires on
--- a concrete pick; sliding back just closes the picker.
function App:showTypePicker(onSelect)
    local Types = Puzzles.types()
    TypePicker.show{
        catalog = Types,
        counts  = Types.counts(self.bank),
        current = self:getSetting("puzzle_type", "any"),
        onSelect = onSelect,
    }
end

--- Quick path (hamburger): pick a type, apply immediately.
function App:openTypePicker()
    if not (self.plan and self.bank) then return end
    self:showTypePicker(function(id)
        self:applyType(id)
    end)
end

function App:openSettings()
    if not self.plan then return end
    local Types = Puzzles.types()
    local current_type = self:getSetting("puzzle_type", "any")
    PuzzleSettings:new{
        parent   = self,
        bands    = Puzzles.bandList(),
        initial  = {
            difficulty = self:getSetting("puzzle_difficulty", "adaptive"),
            type_id    = current_type,
            type_label = Types.label(current_type),
            show_hints = self:getSetting("puzzle_show_hints", true) ~= false,
        },
        pickType = function(picked)
            self:showTypePicker(function(id)
                picked(id, Types.label(id))
            end)
        end,
        onSave = function(changes)
            self:setSetting("puzzle_difficulty", changes.difficulty)
            self:setSetting("puzzle_show_hints", changes.show_hints ~= false)
            self:dispatch(self.plan:transition{ kind = "settings", changes = {
                difficulty = changes.difficulty,
            }})
            if changes.type and changes.type ~= current_type then
                -- Picked inside the dialog: apply it too (fresh draw).
                self:setSetting("puzzle_type", changes.type)
                self:dispatch(self.plan:transition{ kind = "settings", changes = {
                    type = changes.type,
                }})
            end
            local v = self.plan:view()
            if not (v and v.puzzle_id) then return end
            UIManager:setDirty(self, "ui")
        end,
    }:show()
end

return App
