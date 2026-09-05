-- App: the SlateChess widget — the single controller of the game.
--
-- Every state transition funnels through here: human input from the board,
-- engine replies, undo/redo, resets, settings changes, game restore. After
-- each transition the App re-derives everything else (board orientation,
-- status bar, move log, eval line, clocks) in one place.
--
-- The rules (core.game), the clock (core.clock), the eval line (core.eval),
-- the opening book (core.openings) and the engine protocol (engine.*) live
-- in their own modules; see CONTEXT.md for the domain language.

local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Size = require("ui/size")
local Geometry = require("ui/geometry")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local util = require("util")
local json = require("json")
local logger = require("logger")

local CenterContainer = require("ui/widget/container/centercontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local ButtonWidget = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")
local InputText = require("ui/widget/inputtext")
local PathChooser = require("ui/widget/pathchooser")
local ConfirmBox = require("ui/widget/confirmbox")

local Game = require("core.game")
local Eval = require("core.eval")
local Openings = require("core.openings")
local Uci = require("engine.uci")
local ChessBoard = require("ui.board")
local ClockPanel = require("ui.clock_panel")
local PlayerStrip = require("ui.player_strip")
local CaptureGutter = require("ui.capture_gutter")
local CapturedStrip = require("ui.captured_strip")
local ComputerHud = require("ui.computer_hud")
local OverlapGroup = require("ui/widget/overlapgroup")
local SettingsWidget = require("ui.settings_dialog")
local Arbiter = require("core.arbiter")
local MarksOverlay = require("ui.marks_overlay")
local GameplayFrame = require("ui.gameplay_frame")
local HudRule = require("ui.hud_rule")
local GameplayDesign = require("ui.gameplay_design")
local _ = require("gettext")

local WHITE, BLACK = Game.WHITE, Game.BLACK

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

local function chmodX(path)
    os.execute('chmod +x "' .. path .. '"')
end

local function getPluginPath()
    -- This file lives in the plugin root, so its directory is the plugin path.
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return normalizePath(src:match("^(.*[/\\])") or "./")
end

local PLUGIN_PATH = getPluginPath()
local ENGINES_DIR = joinPath(PLUGIN_PATH, "engines")
local GAMES_PATH = joinPath(PLUGIN_PATH, "Games")

-- Brand constants for the About dialog (_meta.lua stays the single
-- source for the version; CHANGELOG.md for the change list).
local VERSION = tostring(dofile(joinPath(PLUGIN_PATH, "_meta.lua")).version or "?")
local ABOUT_URL = "https://github.com/mdp/SlateChess"

--- Parses the top `max_sections` "## heading" blocks out of CHANGELOG.md
-- (which ships in the package and is the single source of truth).
-- Returns nil when the file is missing or has no usable sections.
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

local function getEnginePath()
    -- Engine binaries live here, named per platform:
    --   berserk          -- the Kindle build (Linux ARM, musl static)
    --   berserk-arm64    -- the macOS build
    --   stockfish     -- optional Stockfish fallback (Linux ARM)
    --   stockfish-arm64, stockfish-x64 -- optional Stockfish fallbacks
    -- Berserk is the primary engine. Stockfish binaries are honoured as
    -- fallbacks when present.
    local arch = jit and jit.arch and jit.arch:gsub("%W", "") or nil
    local candidates = {}
    if arch then
        candidates[#candidates + 1] = "berserk-" .. arch
    end
    candidates[#candidates + 1] = "berserk"
    if arch then
        candidates[#candidates + 1] = "stockfish-" .. arch
    end
    candidates[#candidates + 1] = "stockfish"
    for _, name in ipairs(candidates) do
        local path = joinPath(ENGINES_DIR, name)
        if fileExists(path) then
            chmodX(path)
            return path
        end
    end
    return nil
end

local UCI_ENGINE_PATH = getEnginePath()

-- Copy a file in pure Lua (no reliance on /bin/cp being available, and
-- errors are reported instead of silently swallowed).
local function copyFile(src, dest)
    local rin, rerr = io.open(src, "rb")
    if not rin then return nil, tostring(rerr) end
    local content = rin:read("*a")
    rin:close()
    local wout, werr = io.open(dest, "wb")
    if not wout then return nil, tostring(werr) end
    wout:write(content)
    wout:close()
    return true
end

-- Layout constants ------------------------------------------------------------

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE
local LOG_FONT = "smallinfofont"
local LOG_FONT_SIZE = 14
-- All screen geometry (the uniform FRAME_PAD frame, the margin lines,
-- chrome heights, board cell, clock gutter) is decided by ui/layout.lua
-- and consumed here; see that module for the frame contract.
local Layout = require("ui.layout")
local FRAME_PAD = Layout.SIDE_PAD

-- Icons (IconWidget only searches KOReader's data dir, so the SVGs are
-- copied there at startup; UI code resolves them via ui.icons) ---------------

local function installIconsIfNeeded()
    local src_dir = joinPath(PLUGIN_PATH, "icons")
    local dest_dir = DataStorage:getDataDir() .. "/icons/slatechess"
    if lfs.attributes(src_dir, "mode") ~= "directory" then
        logger.warn("slatechess: icons source dir not found at", src_dir)
        return
    end
    if not util.makePath(dest_dir) then
        logger.warn("slatechess: could not create icon dir", dest_dir)
        return
    end
    -- One-time cleanup of the pre-rename icon dir (the PlyChess era).
    local legacy_dir = DataStorage:getDataDir() .. "/icons/plychess"
    if lfs.attributes(legacy_dir, "mode") == "directory" then
        for entry in lfs.dir(legacy_dir) do
            if entry ~= "." and entry ~= ".." then
                os.remove(legacy_dir .. "/" .. entry)
            end
        end
        os.remove(legacy_dir)
        logger.info("slatechess: removed legacy icon dir", legacy_dir)
    end
    local copied, skipped, failed = 0, 0, 0
    for entry in lfs.dir(src_dir) do
        local src_file = joinPath(src_dir, entry)
        local dest_file = dest_dir .. "/" .. entry
        if entry:match("%.svg$") and lfs.attributes(src_file, "mode") == "file" then
            -- Re-copy if missing or a stale/partial previous copy.
            local dst_size = lfs.attributes(dest_file, "mode") == "file"
                and lfs.attributes(dest_file, "size") or -1
            local src_size = lfs.attributes(src_file, "size") or 0
            if dst_size ~= src_size then
                local ok, err = copyFile(src_file, dest_file)
                if ok then
                    copied = copied + 1
                else
                    failed = failed + 1
                    logger.warn("slatechess: failed copying icon", entry, err)
                end
            else
                skipped = skipped + 1
            end
        end
    end
    logger.info("slatechess: icons installed to", dest_dir,
        string.format("(copied=%d skipped=%d failed=%d)", copied, skipped, failed))
end

-- App widget -------------------------------------------------------------------

local App = FrameContainer:extend{
    name = "slatechess",
    background = BACKGROUND_COLOR,
    bordersize = 0,
    -- The frame: the content box is the glass inset by FRAME_PAD on
    -- all four sides; every element's ink aligns to its edges (see
    -- ui/layout.lua).
    padding = 0,
    padding_left = FRAME_PAD,
    padding_right = FRAME_PAD,
    padding_top = Layout.VERTICAL_PAD,
    padding_bottom = Layout.VERTICAL_PAD,
    full_width = Screen:getWidth(),
    full_height = Screen:getHeight(),
    notation_font = LOG_FONT,
    notation_size = LOG_FONT_SIZE,
}

function App:init()
    self:applyScreenGeometry(self.full_width, self.full_height)
    self.covers_fullscreen = true
    Dispatcher:registerAction("slatechess", {
        category = "none", event = "SlateChessStart", title = _("SlateChess"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    installIconsIfNeeded()
    local settings_path = DataStorage:getSettingsDir() .. "/slatechess.lua"
    local legacy_settings = DataStorage:getSettingsDir() .. "/plychess.lua"
    if not fileExists(settings_path) and fileExists(legacy_settings) then
        -- One-time migration from the PlyChess era: same format, new name.
        copyFile(legacy_settings, settings_path)
        logger.info("slatechess: migrated settings from", legacy_settings)
    end
    self.settings = LuaSettings:open(settings_path)
end

function App:applyScreenGeometry(w, h)
    GameplayFrame.applyGeometry(self, w, h)
end

-- SDL broadcasts both events while the emulator window is being resized.
-- Rebuild once per distinct framebuffer size so all hit targets and rendered
-- geometry continue to match the live glass instead of the launch size.
function App:onSetDimensions(dimen)
    if not dimen or (dimen.w == self.full_width and dimen.h == self.full_height) then
        return false
    end
    local old = self[1]
    self:applyScreenGeometry(dimen.w, dimen.h)
    if self.game then
        self:buildUILayout()
        self:updateBoardOrientation()
        self.board:updateBoard()
        self:updateTimerDisplay()
    end
    if old and old ~= self[1] and old.free then old:free() end
    UIManager:setDirty(self, "full")
    return true
end

App.onScreenResize = App.onSetDimensions

function App:onSlateChessStart()
    self:startGame()
    return true
end

-- App is a FrameContainer, not an InputContainer, so `ges_events` would
-- never be evaluated here. Handle the raw KOReader Gesture event directly.
function App:onGesture(ges)
    return GameplayFrame.gesture(self, ges)
end

function App:openGameplayMenu() return self:openGameMenu() end

function App:handleEvent(event)
    -- Dispatcher can launch the game while this widget is not on the stack.
    if event.handler == "onSlateChessStart" then
        return self:onSlateChessStart()
    end
    -- FileManager can still propagate child events after UIManager:close().
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
    if self.board then self.board:clearValidMoves() end
    self:stopClockTicker()
    self:shutdownEngine()
end

function App:addToMainMenu(menu_items)
    menu_items.slatechess = {
        text = _("SlateChess"), sorting_hint = "tools",
        callback = function() self:startGame() end, keep_menu_open = false,
    }
    -- Engine diagnostics: what the app knows about the engine process
    -- (not found / handshake / last UCI line). Lives here because when
    -- the engine fails, the only symptom is "the computer never moves".
    menu_items.slatechess_diagnostics = {
        text = _("SlateChess: engine diagnostics"), sorting_hint = "tools",
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = self:getEngineStatusText(),
                cancel_text = _("Close"),
                cancel_callback = function() return true end,
                ok_text = _("Restart engine"),
                ok_callback = function()
                    self:stopSearch()
                    -- Tell the arbiter the engine is being torn down and
                    -- respawned; the next uciok re-arms options and
                    -- relaunches whatever is on move.
                    if self.arbiter then
                        self:dispatch(self.arbiter:transition{ kind = "engine_restart" })
                    end
                    self:shutdownEngine()
                    self:startEngine()
                end,
            })
        end,
        keep_menu_open = true,
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

function App:loadEngineSettings()
    local defaults = {
        skill_level     = 0,
        engine_depth    = 2,
        engine_movetime = 1,
        blunder_chance  = 0.20,
    }
    for key, value in pairs(defaults) do
        if self.settings:readSetting(key) == nil then
            self:setSetting(key, value)
        end
    end
    self.current_skill = self:getSetting("skill_level", defaults.skill_level)
    local d = tonumber(self:getSetting("engine_depth", defaults.engine_depth)) or defaults.engine_depth
    -- 0 is a legitimate preset value (unlimited depth); anything else
    -- outside 1..5 is corrupt and falls back to the default -- never to
    -- 0, which would silently pick the strongest engine.
    self.engine_depth = (d == 0 or (d >= 1 and d <= 5)) and d or defaults.engine_depth
    self.engine_movetime = math.max(1, math.min(10,
        tonumber(self:getSetting("engine_movetime", defaults.engine_movetime)) or defaults.engine_movetime))
    self.blunder_chance = math.max(0, math.min(1,
        tonumber(self:getSetting("blunder_chance", defaults.blunder_chance)) or defaults.blunder_chance))
    if self.blunderer then
        self.blunderer:setChance(self.blunder_chance)
    end
end

function App:getEngineStatusText()
    if not UCI_ENGINE_PATH then
        return "No engine binary found.\n"
            .. "Looked in " .. ENGINES_DIR .. "/ for\n"
            .. "berserk[-<arch>] or stockfish[-<arch>]."
    end
    if self.engine and self.engine.state and self.engine.state.uciok then
        return "Engine is ready: " .. UCI_ENGINE_PATH
    end
    local text = "Engine is not ready.\nPath:\n" .. UCI_ENGINE_PATH
    local detail = self.engine_status_text
        or self.engine_last_output
        or (self.engine and self.engine.state and (self.engine.state.last_error or self.engine.state.last_output))
    if detail and detail ~= "" then
        text = text .. "\n\nLast engine output:\n" .. detail
    end
    return text
end

-- Game lifecycle ---------------------------------------------------------------

function App:startGame()
    self.last_cp = nil
    self.last_mate = nil
    self.eval_history = {}
    self.running = false
    self._closed = false
    self._arb_slots = {}

    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:close(self)
        -- onCloseWidget latches _closed; re-arm the driver for the fresh
        -- session before any dispatch.
        self._closed = false
        self._arb_slots = {}
    end

    self:loadEngineSettings()
    self:loadOpenings()
    -- The Arbiter owns game/clock/roles/search. Build it from the settings
    -- snapshot, feed it the restore bundle, and let its effects drive us.
    self.arbiter = Arbiter:new(self:readArbCfg(), {
        -- UIManager:getTime() is monotonic fts (µs since boot); the
        -- clock contract is seconds, so convert once here.
        now = function()
            return time.to_s(UIManager:getTime())
        end,
        rng = function() return math.random() end,
    })
    self:dispatch(self.arbiter:transition{ kind = "start", restore = self:readRestore() })
    self:startEngine()
    self:buildUILayout()
    self:updateBoardOrientation()
    self.board:updateBoard()
    self:updateTimerDisplay()
    UIManager:show(self)
end

--- Settings snapshot the Arbiter starts from (one faithful read of the
--- persisted settings). The arbiter then persists every change it accepts.
function App:readArbCfg()
    local s = self.settings
    return {
        human_white         = s:readSetting("human_white", true),
        human_black         = s:readSetting("human_black", false),
        timed               = s:readSetting("timed", false),
        time_base_white     = tonumber(s:readSetting("time_base_white", 900)) or 900,
        time_base_black     = tonumber(s:readSetting("time_base_black", 900)) or 900,
        time_incr_white     = tonumber(s:readSetting("time_incr_white", 10)) or 10,
        time_incr_black     = tonumber(s:readSetting("time_incr_black", 10)) or 10,
        skill_level         = self.current_skill,
        engine_depth        = self.engine_depth,
        engine_movetime     = self.engine_movetime,
        blunder_chance      = self.blunder_chance,
        flip_board          = s:readSetting("flip_board", false),
        rotate_top_pieces   = s:readSetting("rotate_top_pieces", false),
        flip_pieces_each_turn = s:readSetting("flip_pieces_each_turn", false),
        show_eval           = s:readSetting("show_eval", true),
        show_hints          = s:readSetting("show_hints", false),
        figurine_pgn        = s:readSetting("figurine_pgn", false),
        thinking_indicator  = s:readSetting("thinking_indicator", true),
        learning_mode       = s:readSetting("learning_mode", false),
        show_selected       = s:readSetting("show_selected", true),
        previous_move_hints = s:readSetting("previous_move_hints", true),
        opponent_hints      = s:readSetting("opponent_hints", false),
        check_hints        = s:readSetting("check_hints", false),
        saved_pgn          = s:readSetting("saved_pgn", "") or "",
        saved_time_white   = tonumber(s:readSetting("saved_time_white", nil)),
        saved_time_black   = tonumber(s:readSetting("saved_time_black", nil)),
        saved_running      = s:readSetting("saved_running", false),
        openings           = self.openings,
    }
end

--- Read the restore bundle (nil when there is no saved game).
function App:readRestore()
    local s = self.settings
    local pgn = s:readSetting("saved_pgn", "")
    if not pgn or pgn == "" then return nil end
    return {
        pgn     = pgn,
        t_w     = tonumber(s:readSetting("saved_time_white", nil)),
        t_b     = tonumber(s:readSetting("saved_time_black", nil)),
        running = s:readSetting("saved_running", false),
    }
end

--- Mirrors the arbiter's authoritative references back into the legacy
--- render code (updateNotation/buildUILayout/updateTimerDisplay/
--- updateBoardOrientation read self.game/self.clock/self.running/
--- self.eval_history/self.last_cp ...).
function App:syncFromArbiter()
    local a = self.arbiter
    if not a then return end
    self.game            = a.game
    self.clock           = a.clock
    self.timed           = a:cfgbool("timed")
    self.running         = a.running
    self.eval_history    = a.eval_history
    self.last_cp         = a._current_cp
    self.last_mate       = a._current_mate
    self.current_skill   = a.cfg.skill_level
    self.engine_depth    = a.cfg.engine_depth
    self.engine_movetime = a.cfg.engine_movetime
    self.blunder_chance  = a.cfg.blunder_chance
end

--- Performs the canonical-ordered effect list from a transition. Effects
--- run in order, so persist writes land before repaints read them back.
function App:dispatch(fx)
    if self._closed or not self.arbiter then return end
    self:syncFromArbiter()
    for _, e in ipairs(fx or {}) do
        local kind = e.kind
        if kind == "persist" then
            self:setSetting(e.key, e.value)
        elseif kind == "uci" then
            self:performUci(e)
        elseif kind == "cancel" then
            self:performCancel(e.token)
        elseif kind == "schedule" then
            self:performSchedule(e.token, e.delay)
        elseif kind == "repaint" then
            self:performRepaint(e.target)
        elseif kind == "announce" then
            self:performAnnounce(e)
        end
    end
end

--- Performs one `uci` effect on the engine process.
function App:performUci(e)
    local engine = self.engine
    if not (engine and engine.state and engine.state.uciok) then return end
    local cmd = e.cmd
    if cmd == "setoption" then
        engine:setOption(e.name, e.value)
    elseif cmd == "ucinewgame" then
        engine:ucinewgame()
    elseif cmd == "position" then
        engine:position({ moves = e.moves })
    elseif cmd == "go" then
        -- The engine has no notion of our go ids; whatever bestmove lands
        -- next answers this search.
        self._current_go_id = e.id
        engine:go(e.spec)
    elseif cmd == "stop" then
        engine:stop()
    end
end

--- Arms an arbiter timer on the UI scheduler and re-enters the funnel.
function App:performSchedule(token, delay)
    local en = { dead = false }
    self._arb_slots[token] = en
    local fn = function()
        if en.dead or self._closed or not self.arbiter then return end
        if self._arb_slots[token] ~= en then return end
        self._arb_slots[token] = nil
        self:dispatch(self.arbiter:transition{ kind = "scheduled", token = token })
    end
    en.fn = fn
    UIManager:scheduleIn(delay, fn)
end

function App:performCancel(token)
    local en = self._arb_slots and self._arb_slots[token]
    if not en then return end
    en.dead = true
    if en.fn then UIManager:unschedule(en.fn) end
    self._arb_slots[token] = nil
end

--- Performs a repaint target: layout/board/clocks/notation.
function App:performRepaint(target)
    if not self.board then return end
    if target == "layout" then
        self:buildUILayout()
        self:updateBoardOrientation()
        self.board:updateBoard()
        self:updateTimerDisplay()
    elseif target == "board" then
        self:syncBoardFlags()
        self:updateBoardOrientation()
        self.board:updateBoard()
        self.board:markCheckHint()
    elseif target == "clocks" then
        self:updateTimerDisplay()
    elseif target == "notation" then
        self:updateNotation()
        if self.arbiter then
            local v = self.arbiter:view()
            if self.hints_widgets then
                for _, w in ipairs(self.hints_widgets) do w:setText(v.hints_text) end
            end
        end
    end
    UIManager:setDirty(self, "ui")
end

--- Reasserts the board's interface toggles from the persisted settings
--- (the arbiter persists them; the board reads them only at build time).
function App:syncBoardFlags()
    local board = self.board
    if not board then return end
    board.learning_mode        = self:getSetting("learning_mode", false)
    board.show_selected        = self:getSetting("show_selected", true)
    board.previous_move_hints  = self:getSetting("previous_move_hints", true)
    board.opponent_hints       = self:getSetting("opponent_hints", false)
    board.check_hints          = self:getSetting("check_hints", false)
end

--- Performs an announce effect.
function App:performAnnounce(e)
    if e.announce_kind == "game_over" then
        UIManager:show(ConfirmBox:new{
            text = e.text,
            ok_text = _("Continue"),
            cancel_text = nil,
            ok_callback = function()
                if self.arbiter then
                    self:dispatch(self.arbiter:transition{ kind = "reset" })
                end
                self:updateNotation()
                UIManager:setDirty(self, "ui")
            end,
        })
    elseif e.announce_kind == "engine_failed" then
        self:markEngineInvalid(e.text)
        UIManager:setDirty(self, "ui")
    elseif e.announce_kind == "error" then
        UIManager:show(InfoMessage:new{ text = e.text })
    end
end

function App:loadOpenings()
    if self.openings then return end
    local f = io.open(joinPath(PLUGIN_PATH, "data/aperturas.json"), "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    self.openings = Openings.load(content, json.decode)
end

-- Engine lifecycle ---------------------------------------------------------------

function App:markEngineInvalid(reason)
    self.engine_status_text = reason or "Engine is not ready."
end

--- Starts the chess engine subprocess (Berserk, or Stockfish when its
--- binary is present instead). There is no Lua fallback: without an
--- engine there are no evals, no hints and no computer opponent --
--- the diagnostics dialog explains what to install.
function App:startEngine()
    self.engine_status_text = nil
    self.engine_last_output = nil

    if not UCI_ENGINE_PATH then
        self:markEngineInvalid(
            "No engine binary found for this platform.\n"
            .. "Copy the engine binary to:\n" .. ENGINES_DIR .. "/"
            .. "\n(berserk-<arch>, e.g. berserk-arm64, or berserk)")
        return
    end

    local engine = Uci.UCIEngine.spawn(UCI_ENGINE_PATH, {})
    if not engine then
        self:markEngineInvalid("Engine process could not be created.")
        return
    end
    self.engine = engine
    self:wireEngineHandlers(engine)
    engine:uci()
end

--- One event wiring for both engine implementations. Every line the engine
--- speaks becomes an arbiter event; the arbiter's effects drive the engine.
function App:wireEngineHandlers(engine)
    engine:on("read", function(data)
        if self.engine ~= engine then return end
        if not data then return end
        for line in tostring(data):gmatch("[^\r\n]+") do
            self.engine_last_output = line
            logger.dbg("slatechess: engine <", line)
            if line:match("execvp failed") then
                self:markEngineInvalid(line)
            elseif self.arbiter then
                self:dispatch(self.arbiter:transition{ kind = "engine_info", line = line })
            end
        end
    end)

    engine:on("uciok", function()
        if self.engine ~= engine then return end
        self.engine_status_text = nil
        if self.arbiter then
            self:dispatch(self.arbiter:transition{ kind = "engine_ready" })
        end
        UIManager:setDirty(self, "ui")
    end)

    engine:on("bestmove", function(move_uci)
        if self.engine ~= engine then return end
        if self.arbiter then
            self:dispatch(self.arbiter:transition{
                kind = "engine_bestmove",
                id   = self._current_go_id,
                move = move_uci,
            })
        end
    end)

    engine:on("process_error", function(err)
        if self.engine ~= engine then return end
        if self.arbiter then
            self:dispatch(self.arbiter:transition{ kind = "engine_failed",
                reason = err or "Engine process failed." })
        else
            self:markEngineInvalid(err or "Engine process failed.")
        end
    end)

    engine:on("uci_timeout", function(last_output)
        if self.engine ~= engine then return end
        local text = "Timed out waiting for the engine's UCI response."
        if last_output and last_output ~= "" then text = text .. "\n" .. last_output end
        if self.arbiter then
            self:dispatch(self.arbiter:transition{ kind = "engine_failed", reason = text })
        else
            self:markEngineInvalid(text)
        end
    end)

    engine:on("go_timeout", function(last_output)
        if self.engine ~= engine then return end
        local text = "Timed out waiting for the engine's bestmove."
        if last_output and last_output ~= "" then text = text .. "\n" .. last_output end
        if self.arbiter then
            self:dispatch(self.arbiter:transition{ kind = "search_timeout", detail = text })
        else
            self:markEngineInvalid(text)
        end
    end)
end

function App:shutdownEngine()
    if self.engine and not self.engine.closed then
        self.engine:quit()
    end
    self.engine = nil
end

function App:stopSearch()
    -- Defensive halt used by the diagnostics restart path; the arbiter
    -- normally serializes engine traffic through its own effects.
    if self.engine and not self.engine.closed and self.engine.state.uciok then
        self.engine:stop()
    end
end

-- Eval hooks ---------------------------------------------------------------------

-- Board orientation (derived state) --------------------------------------------------

--- The side the board renders for. "Flip pieces to player on each turn"
--- (human-vs-human only) rotates the whole board toward the side to move
--- while the game runs; off (default) keeps a fixed board that renders
--- for white. The face-color machinery stays on the board widget either
--- way — this just decides which face drives it.
function App:currentFaceColor()
    local game = self.game
    if game and self.running and game:isHumanVsHuman()
        and self:getSetting("flip_pieces_each_turn", false) then
        return game:turn()
    end
    return WHITE
end

--- Board is flipped (Black's side at the bottom) when the human plays
--- black, or when the user toggled Flip Board in the hamburger menu --
--- the manual preference inverts whatever the derived orientation is.
function App:shouldFlipBoard()
    local derived = self.game
        and self.game:isHuman(BLACK)
        and not self.game:isHuman(WHITE)
    local flip_pref = self:getSetting("flip_board", false) and true or false
    return (derived and true or false) ~= flip_pref
end

--- Flip Board menu item: swap which player's side sits at the bottom.
--- The arbiter toggles and persists the preference; the flip moves the
--- layout signature, so its layout-repaint rebuilds everything.
function App:toggleBoardFlip()
    if not self.arbiter then return end
    self:dispatch(self.arbiter:transition{ kind = "flip_toggle" })
end

--- Re-derives orientation from the game and repaints once.
function App:updateBoardOrientation()
    if not (self.board and self.game) then return end
    local hvh = self.game:isHumanVsHuman()
    local flip_each_turn = self:getSetting("flip_pieces_each_turn", false) and true or false
    self.board:setFlipped(self:shouldFlipBoard())
    -- The player strips follow the flip (which side sits at the bottom
    -- is decided in buildUILayout); the clock cards keep their fixed
    -- row order, so each player's own time stays nearest them in both
    -- positions.
    -- Piece angles: human-vs-human either pivots the whole board toward
    -- the side to move each turn ("Flip pieces to player on each turn"
    -- on) or keeps a fixed board with each side's far pieces angled
    -- toward their own player (off). In one-player mode both armies face
    -- the sole human at the bottom.
    if hvh then
        self.board.rotate_top_pieces = (not flip_each_turn) and true or false
    else
        self.board.rotate_top_pieces = false
    end
    self.board:setFaceColor(self:currentFaceColor())
end

local function createToolbarButton(icon, w, h, cb)
    return ButtonWidget:new{ icon = icon, width = w, icon_width = w, icon_height = h,
        padding = 0, margin = 0, bordersize = 0, callback = cb }
end

-- Layout -------------------------------------------------------------------------------

function App:buildUILayout()
    local status_h = 0

    -- One geometry decision for the whole screen: ui/layout.lua owns
    -- the FRAME_PAD frame, the margin lines, the chrome heights and the
    -- board's cell. This builder only arranges widgets inside the rects
    -- it hands back -- nothing here measures the result, so zones can't
    -- drift apart. The clock cards are the exception: their measured
    -- height is an input (like status_h), because the layout must
    -- reserve room for them above and below the board.
    local scale_fn = function(n) return Screen:scaleBySize(n) end
    local M = Layout.boardMetrics(scale_fn)
    -- Boolean AND of the setting and the clock object -- note the whole
    -- conjunction is never nil (false when the setting is off, the clock
    -- otherwise), so a `~= nil` check here is always true and the cards
    -- would show on untimed games.
    local timed = self.timed and self.clock ~= nil

    -- Both player strips always exist -- one per side, the top one
    -- rotated 180° -- in every game mode, so each side always has its
    -- own bracket right side up. Which player's strip sits at the
    -- bottom (nearest the reader) follows the board flip: unflipped,
    -- White's side is at the bottom; flipped, Black's.
    local white_at_bottom = not self:shouldFlipBoard()
    local strip_colors = { WHITE, BLACK }

    -- Chess clocks (timed games only): one compact card per player
    -- strip. Cards always paint upright and show both times; the
    -- strip rotates the top bracket (card included) for the player
    -- sitting on the far side. Positions are fixed to the board's
    -- grid and do not follow its flips.
    self.clock_panels = nil
    local card_h = 0
    if timed then
        self.clock_panels = {}
        for _, color in ipairs(strip_colors) do
            -- Your own time is the one nearest you. White's card
            -- reads upright: White's time at the bottom (near White).
            -- Black's card goes in the flipped strip, so it's built
            -- the other way around: after the strip's 180° rotation,
            -- Black's time is the one nearest Black.
            local panel = ClockPanel:new{
                white     = self.clock:remaining(WHITE),
                black     = self.clock:remaining(BLACK),
                white_top = (color == BLACK),
            }
            panel:update(
                self.clock:remaining(WHITE),
                self.clock:remaining(BLACK),
                self.running and self.clock.turn or nil)
            self.clock_panels[color] = { panel = panel }
            card_h = math.max(card_h, panel:getSize().h)
        end
    end

    -- The player strips are part of the board's unit, so their heights
    -- are inputs to the layout (like status_h): the notation block or
    -- the clock card, whichever is taller. The strips mirror each
    -- other exactly -- two history lines plus, when the settings ask
    -- for them, an eval row (Engine Evals) and an Engine Hints row on
    -- BOTH strips (the far side reads them rotated) -- so one height
    -- serves the top and bottom alike.
    local line_h = Layout.logLineHeight(scale_fn)
    local base_h = 2 * line_h
    local extras_h = 0
    if self:getSetting("show_eval", true) then extras_h = extras_h + line_h end
    if self:getSetting("show_hints", false) then extras_h = extras_h + line_h end
    local strip_h = math.max(base_h + extras_h, card_h)
    local bottom_strip_h = strip_h

    local L = Layout.compute{
        screen_w = self.full_width,
        screen_h = self.full_height,
        status_h = status_h,
        strip_h  = strip_h,
        bottom_strip_h = bottom_strip_h,
        metrics  = M,
        scale    = scale_fn,
    }
    logger.dbg("slatechess: layout",
        string.format("content %dx%d zone %d status %d strip %d bottom_strip %d board cell %d squares %d gutter %d",
            L.content.w, L.content.h, L.board.zone_h, status_h, strip_h,
            bottom_strip_h, L.board.cell, L.board.squares_w, L.board.gutter_w))

    local content_w = L.content.w
    local content_h = L.content.h

    self:initializeBoard(L)

    -- The strips attach to the board's real measured grid edges: the
    -- clock card's right edge sits on the grid's right edge, and the
    -- card's ink is right-aligned inside the card, so the visible time
    -- -- not just the card's invisible box -- lines up with the board's
    -- end (the card is sized for the longest possible time, so a
    -- left-aligned short time would drift left of the edge). The
    -- notation block starts on the grid's left edge and is capped at
    -- 2/3 of the grid's width so it can never run under the timer. The
    -- strips paint at that offset inside full-width rows, so the unit
    -- [Black's strip][board][White's strip] centers as a whole and the
    -- strips cannot collide with the board.
    local grid = self.board:gridGeometry()
    local grid_x = math.floor((content_w - self.board[1]:getSize().w) / 2) + grid.left
    local strip_w = grid.w
    local strip_x = grid_x

    -- Spoils gutter: the taken pieces stack down the board's right
    -- gutter -- the symmetric mirror of the left's rank-label chrome,
    -- which stays empty of chrome. The gutter shares the board's row
    -- (OverlapGroup below), so its geometry is relative to the board
    -- widget: from the measured grid's right edge to the frame's
    -- right padding, spanning the grid's full height. Skipped when
    -- the glass leaves no usable slack there.
    local board_w = self.board:getSize().w
    local gutter_gap = Screen:scaleBySize(6)
    local gutter_x = grid.left + grid.w + gutter_gap
    local gutter_w = board_w - self.board.board_padding / 2 - gutter_x
    self.capture_gutter = nil
    if gutter_w >= Screen:scaleBySize(20) then
        self.capture_gutter = CaptureGutter:new{
            board  = self.board,
            x      = gutter_x,
            y      = grid.top,
            width  = gutter_w,
            grid_h = grid.h,
        }
    end

    -- One strip per color (both always built; the top one rotated, so
    -- each player still reads their own bracket right side up -- and
    -- each clock card keeps its fixed row order, own time nearest the
    -- reader, in either position). The strips MIRROR each other:
    -- identical rows on both, eval and Engine Hints included, so the
    -- far side reads the same verdict the near side does -- even when
    -- that far side is a computer.
    self.notation_history = { white = nil, black = nil }
    self.notation_totals = { white = nil, black = nil }
    -- The strips' Engine Hints rows, when built (one per strip --
    -- hints text lands on every row). Rebuilt with the layout (flip,
    -- settings), so the references are always fresh.
    self.hints_widgets = {}

    -- Compact, borderless two-ply history control in the otherwise open
    -- center of the bottom HUD.
    local history_scale = content_w / 1016
    local history_button_w = GameplayDesign.round(40,history_scale)
    local history_text_w = GameplayDesign.round(232,history_scale)
    local history_h = math.max(30, math.floor(40 * history_scale + 0.5))
    local history_icon_h = math.max(26, math.floor(34 * history_scale + 0.5))
    local nav_text = TextWidget:new{
        text="", face=Font:getFace("smallinfofont", math.max(17,
            math.floor(21 * history_scale + 0.5))),
        max_width=history_text_w - math.max(8,
            math.floor(12 * history_scale + 0.5)),
        fgcolor=Blitbuffer.COLOR_DARK_GRAY,
    }
    self.nav_notation = nav_text
    local history = HorizontalGroup:new{
        createToolbarButton("chevron.left", history_button_w, history_icon_h,
            function() self:handleUndoMove(false) end),
        CenterContainer:new{
            dimen=Geometry:new{w=history_text_w,h=history_h}, nav_text,
        },
        createToolbarButton("chevron.right", history_button_w, history_icon_h,
            function() self:handleRedoMove(false) end),
    }

    local function buildStrip(color)
        local at_bottom = ((color == WHITE) == white_at_bottom)
        local captures = CapturedStrip:new{white=(color == BLACK),size=31,step=24}
        self.captured_strips = self.captured_strips or {}
        self.captured_strips[color] = captures
        local card = (self.clock_panels and self.clock_panels[color])
            and self.clock_panels[color].panel or nil
        return PlayerStrip:new{
            row_w    = content_w,
            width    = strip_w,
            offset_x = strip_x,
            rotated  = not at_bottom,
            notation = captures,
            center   = at_bottom and history or nil,
            clock    = card,
            slots    = {
                notation=GameplayDesign.rect(GameplayDesign.chess_bottom.captures,history_scale),
                center=GameplayDesign.rect(GameplayDesign.chess_bottom.replay,history_scale),
                clock=GameplayDesign.rect(GameplayDesign.chess_bottom.clock,history_scale),
            },
        }
    end
    self.white_strip = nil
    self.black_strip = nil
    for _, color in ipairs(strip_colors) do
        if color == WHITE then
            self.white_strip = buildStrip(WHITE)
        else
            self.black_strip = buildStrip(BLACK)
        end
    end

    -- The middle zone is ONE centered unit: [top strip][board][bottom
    -- strip] -- both strips in every game mode, the top one rotated
    -- 180°. The strips are rows of the unit, so they cannot collide
    -- with the board; the leftover slack splits around it. Which strip
    -- is on top follows the flip (see white_at_bottom). The board's
    -- row is an OverlapGroup so the spoils gutter paints beside the
    -- squares, in the gutter the layout reserves; the gutter paints
    -- itself at its own offsets from the row's (the board's) origin.
    local top_strip = white_at_bottom and self.black_strip or self.white_strip
    local bottom_strip = white_at_bottom and self.white_strip or self.black_strip
    local one_player = self.game:isHuman(WHITE) ~= self.game:isHuman(BLACK)
    if one_player then
        self.computer_hud = ComputerHud:new{width=strip_w,height=L.top_hud.h,data=self:computerHudData()}
        top_strip = self.computer_hud
    else
        self.computer_hud = nil
    end
    local board_row = self.board
    if self.capture_gutter then
        board_row = OverlapGroup:new{
            dimen = Geometry:new{ w = content_w, h = self.board:getSize().h },
            allow_mirroring = false,
            self.board,
            self.capture_gutter,
        }
    end
    -- Fixed heads-up stack. HUD content is centered inside its 164px band;
    -- its separator is an independent overlay so text metrics cannot move it.
    local function hud(strip, color, top, height)
        height = height or L.top_hud.h
        return OverlapGroup:new{
            dimen=Geometry:new{w=content_w,h=height},
            allow_mirroring=false,
            CenterContainer:new{
                dimen=Geometry:new{w=content_w,h=height}, strip,
            },
            HudRule:new{active=function() return self.game:turn()==color end,width=content_w,
                height=height,top=top},
        }
    end

    local top_color = white_at_bottom and BLACK or WHITE
    local bottom_color = white_at_bottom and WHITE or BLACK
    self.status_bar = nil
    self[1] = VerticalGroup:new{
        align="center", width=content_w, height=content_h,
        hud(top_strip, top_color, false),
        VerticalSpan:new{width=L.chrome.strip_gap},
        board_row,
        VerticalSpan:new{width=L.bottom_hud.y - (L.board.y + L.board.height)},
        hud(bottom_strip, bottom_color, true, L.bottom_hud.h),
    }

    -- The strips start empty; fill them from the current game state.
    self:updateNotation()

    -- The marks overlay paints the move/selection brackets over the
    -- board; re-bind it to the (possibly rebuilt) board.
    self:refreshMarksOverlay()
end

--- Binds the marks painter (ui/marks_overlay.lua) to the live board.
--- It is not a window -- the app paints it after its own paintTo --
--- so there is nothing to show, raise, or close.
function App:refreshMarksOverlay()
    if not self.marks then self.marks = MarksOverlay:new{} end
    self.marks.board = self.board
    self.marks.app = self
end

--- Paints the game, then the move/selection brackets on top.
function App:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    GameplayFrame.paintOverlay(self, bb, x, y)
end

function App:initializeBoard(L)
    self.board = ChessBoard:new{
        game          = self.game,
        width         = L.content.w,
        height        = L.board.height,
        -- The layout owns the size decision: paint squares of exactly
        -- its cell so the gutters it computed are the gutters we get.
        cell          = L.board.cell,
        moveCallback  = function(move) self:onMoveExecuted(move) end,
        onPromotionNeeded = function(f, t, c) self:openPromotionDialog(f, t, c) end,
        learning_mode = self:getSetting("learning_mode", false),
        show_selected = self:getSetting("show_selected", true),
        previous_move_hints = self:getSetting("previous_move_hints", true),
        opponent_hints = self:getSetting("opponent_hints", false),
        check_hints = self:getSetting("check_hints", false),
        flipped = self:shouldFlipBoard(),
        rotate_top_pieces = self:getSetting("rotate_top_pieces", false),
    }
end

--- The settings dialog (lives in the hamburger menu; the gear icon
--- left the top bar). Applying translates the dialog's draft into the
--- arbiter's flat change map; the arbiter persists + repaints everything.
function App:openSettings()
    if not self.arbiter then return end
    -- The dialog only reads the clock to prefill time pickers; untimed
    -- games have no Clock object (the arbiter owns it), so hand it a
    -- read-only stub built from the persisted values.
    local clock_stub = self.clock or {
        base = {
            w = self:getSetting("time_base_white", 900),
            b = self:getSetting("time_base_black", 900),
        },
        increment = {
            w = self:getSetting("time_incr_white", 10),
            b = self:getSetting("time_incr_black", 10),
        },
    }
    SettingsWidget:new{
        engine = self.engine,
        clock  = clock_stub,
        game   = self.game,
        parent = self,
        onApply = function(s)
            self:dispatch(self.arbiter:transition{ kind = "settings", changes = {
                human_white         = s.human_choice[WHITE],
                human_black         = s.human_choice[BLACK],
                timed               = s.timed and true or false,
                time_base_white     = s.time_control[WHITE].base_minutes * 60,
                time_base_black     = s.time_control[BLACK].base_minutes * 60,
                time_incr_white     = s.time_control[WHITE].incr_seconds,
                time_incr_black     = s.time_control[BLACK].incr_seconds,
                skill_level         = s.skill_level,
                engine_depth        = s.engine_depth,
                engine_movetime     = s.engine_movetime,
                blunder_chance      = s.blunder_chance,
                learning_mode       = s.learning_mode,
                show_selected       = s.show_selected,
                previous_move_hints = s.previous_move_hints,
                opponent_hints      = s.opponent_hints,
                check_hints         = s.check_hints,
                rotate_top_pieces   = s.rotate_top_pieces,
                flip_pieces_each_turn = s.flip_pieces_each_turn,
                thinking_indicator  = s.thinking_indicator,
                show_eval           = s.show_eval,
                show_hints          = s.show_hints,
                figurine_pgn        = s.figurine_pgn,
            }})
            -- Interface toggles that don't move the board (selection,
            -- hints, learning mode) leave the board's own flags stale:
            -- reassert them and reconcile the check hint now.
            self:syncBoardFlags()
            if self.board then
                if self.board.learning_mode and self.board.check_hints then
                    self.board:markCheckHint()
                else
                    self.board:clearCheckHint()
                end
            end
            UIManager:setDirty(self, "ui")
        end,
    }:show()
end

--- Opens the in-game menu from any affordance (corner notch, swipe, or a
--- future toolbar button). Keeping this in one method prevents the compact
--- gameplay screen from growing multiple, subtly different menus.
function App:openGameMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            { { text = _("Settings"), callback = function()
                    UIManager:close(dialog)
                    self:openSettings()
                end } },
            { { text = _("New Game"), callback = function()
                    UIManager:close(dialog)
                    self:confirmNewGame()
                end } },
            { { text = _("Save PGN"), callback = function()
                    UIManager:close(dialog)
                    UIManager:show(self:openSaveDialog())
                end } },
            { { text = _("Load PGN"), callback = function()
                    UIManager:close(dialog)
                    self:openLoadPgnDialog()
                end } },
            { { text = _("Flip Board"), callback = function()
                    UIManager:close(dialog)
                    self:toggleBoardFlip()
                end } },
            { { text = _("About SlateChess"), callback = function()
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

function App:createStatusBar()
    -- The one control row, ink pinned to the frame's top line: the
    -- undo/redo chevrons centered, the hamburger's ink right-justified
    -- on the right line. There is no bottom bar anymore -- the roster
    -- line is gone and the board's zone runs down to the bottom line.
    -- The plugin SVGs render box == ink, so padding-free buttons pin
    -- exactly where their containers put them. The gear lives in the
    -- hamburger menu (App:openSettings); the hamburger runs a third
    -- under the old title-bar icons (those were scale(32)), the
    -- chevrons keep the old nav-button size.
    local content_w = self.full_width - 2 * FRAME_PAD
    local icon_size = Screen:scaleBySize(21)
    local nav_h     = Screen:scaleBySize(16)
    local nav_w     = math.floor(content_w / 10)
    local nav_gap   = Screen:scaleBySize(6)
    local bar_h     = math.max(icon_size, nav_h)
    return OverlapGroup:new{
        dimen = Geometry:new{ w = content_w, h = bar_h },
        allow_mirroring = false,
        CenterContainer:new{
            dimen = Geometry:new{ w = content_w, h = bar_h },
            HorizontalGroup:new{
                createToolbarButton("chevron.left", nav_w, nav_h,
                    function() self:handleUndoMove(false) end),
                HorizontalSpan:new{ width = nav_gap },
                createToolbarButton("chevron.right", nav_w, nav_h,
                    function() self:handleRedoMove(false) end),
            },
        },
        RightContainer:new{
            dimen = Geometry:new{ w = content_w, h = bar_h },
            createToolbarButton("slatechess/menu", icon_size, icon_size,
                function() self:openGameMenu() end),
        },
    }
end

--- New Game confirmation (lives in the hamburger menu).
function App:confirmNewGame()
    UIManager:show(ConfirmBox:new{
        text        = _("Start a new game?"),
        ok_text     = _("New Game"),
        ok_callback = function() self:resetGame() end,
    })
end

--- About dialog (lives in the hamburger menu): version, recent changelog,
-- and the project URL. The GitHub button only appears on devices that
-- can open links; elsewhere the URL is shown as plain text.
function App:showAbout() -- luacheck: ignore self
    local text = "SlateChess v" .. VERSION .. "\n\n"
    local changes = loadRecentChangelog(2)
    if changes then text = text .. changes .. "\n" end
    text = text .. ABOUT_URL
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text            = text,
            ok_text         = _("Open GitHub"),
            ok_callback     = function() Device:openLink(ABOUT_URL) end,
            cancel_text     = _("Close"),
            cancel_callback = function() return true end,
        })
    else
        UIManager:show(InfoMessage:new{ text = text })
    end
end

--- Exit confirmation shared by the hamburger menu.
function App:confirmExit()
    UIManager:show(ConfirmBox:new{
        text        = _("Exit Chess?"),
        ok_text     = _("Exit"),
        ok_callback = function()
            self:stopClockTicker()
            if self.clock then self.clock:stop() end
            self:saveGameState()
            UIManager:close(self, "full")
        end,
    })
end

-- Notation strips -------------------------------------------------------------------
--
-- Each player strip carries two history lines (the last four plies,
-- two per line, the most recent pair on the second line). The taken
-- pieces are not on the strips: they stack in the board's right
-- gutter (ui/capture_gutter), each side's spoils on their own edge.
-- The strips mirror each other: both may show an eval line (total
-- advantage plus the opening name) and the Engine Hints line;
-- buildUILayout decides which rows exist.

function App:updateNotation()
    local all_history = self.notation_history
    if not all_history then return end

    local sans = self.game:sanHistory()
    local n = #sans
    local show_eval = self:getSetting("show_eval", true)
    local figurines = self:getSetting("figurine_pgn", false)

    if self.nav_notation then
        local text, first = "", math.max(1, n - 1)
        for i = first, n do
            local move_no = math.floor((i - 1) / 2) + 1
            local ply
            if i % 2 == 1 then
                ply = move_no .. ". " .. sans[i]
            elseif i == first then
                ply = move_no .. "... " .. sans[i]
            else
                ply = sans[i]
            end
            text = text == "" and ply or (text .. "  " .. ply)
        end
        self.nav_notation:setText(text)
    end

    -- One ply as text. White's plies carry the move number, Black's
    -- follow bare, so a full move reads "22. Nf3 Bc4". Figurine mode
    -- swaps piece letters for glyphs (the face falls back to
    -- FreeSerif for those glyphs). Each ply also carries its own eval
    -- from App.eval_history (committed when the engine finishes
    -- searching that position).
    local function ply_text(i)
        local move_no = math.floor((i - 1) / 2) + 1
        local prefix = (i % 2 == 1) and (move_no .. ". ") or ""
        local move_txt = sans[i]
        if figurines then
            move_txt = Eval.figurine(move_txt, (i % 2 == 1) and "w" or "b")
        end
        local txt = prefix .. move_txt
        if show_eval and self.eval_history then
            local ev = Eval.short(self.eval_history[i])
            if ev ~= "" then txt = txt .. "  " .. ev end
        end
        return txt
    end

    -- Two plies per line; the first line stays empty until four plies
    -- have been played.
    local lines = { "", "" }
    for row = 1, 2 do
        local hi = n - (2 - row) * 2
        if hi >= 1 then
            local parts = {}
            for i = math.max(1, hi - 1), hi do
                parts[#parts + 1] = ply_text(i)
            end
            lines[row] = table.concat(parts, " ")
        end
    end

    -- Taken pieces, replayed from the move history (see core.eval):
    -- stacked down the board's right gutter, each side's spoils on
    -- their own edge of the board.
    local caps = Eval.capturedPieces(self.game:moveHistory())
    if self.captured_strips then
        if self.captured_strips[WHITE] then
            self.captured_strips[WHITE]:setPieces(caps.b)
        end
        if self.captured_strips[BLACK] then
            self.captured_strips[BLACK]:setPieces(caps.w)
        end
    end

    -- Eval line (mirrored on both strips): the latest position
    -- eval plus the opening name. White's perspective, bare number:
    -- the sign says who's better.
    local total_txt = ""
    if show_eval then
        local eval_txt = Eval.short{ cp = self.last_cp, mate = self.last_mate }
        total_txt = eval_txt
        local opening = self:detectOpening()
        if opening then
            local head = string.format("%s (%s)", opening.name, opening.eco or "?")
            total_txt = (eval_txt ~= "") and (head .. " · " .. eval_txt) or head
        end
    end
    -- The arbiter's thinking latch replaces the eval line while the
    -- computer works, exactly like the old thinking indicator.
    if show_eval and self.running and self.arbiter and self.arbiter.thinking then
        total_txt = _("Computer thinking...")
    end

    for _, color in ipairs({ WHITE, BLACK }) do
        local history = all_history[color]
        if history then
            history[1]:setText(lines[1])
            history[2]:setText(lines[2])
        end
        local total = self.notation_totals[color]
        if total then total:setText(total_txt) end
    end
    if self.capture_gutter then
        self.capture_gutter:update(caps.w, caps.b)
    end
    if self.computer_hud then self.computer_hud:setData(self:computerHudData()) end
    UIManager:setDirty(self, "ui")
end

local ELO_PRESETS = {
    {0,1,1,.50,600}, {0,1,1,.35,750}, {0,1,1,.25,900}, {0,2,1,.20,1050},
    {0,2,1,.10,1200}, {0,3,1,.10,1350}, {3,3,1,.05,1500}, {5,4,1,.05,1650},
    {7,4,1,0,1800}, {9,5,1,0,1950}, {10,0,1,0,2100}, {20,0,10,0,2400},
}

function App:computerElo()
    local best,distance=1050,math.huge
    for _,p in ipairs(ELO_PRESETS) do
        local d=math.abs((self.current_skill or 0)-p[1])*2+math.abs((self.engine_depth or 2)-p[2])*2
            +math.abs((self.engine_movetime or 1)-p[3])+math.abs((self.blunder_chance or .2)-p[4])*20
        if d<distance then best,distance=p[5],d end
    end
    return best
end

function App:computerHudData()
    local sans,recent=self.game:sanHistory(),{}
    local human=self.game:isHuman(WHITE) and WHITE or BLACK
    local sign=human==WHITE and 1 or -1
    for i=math.max(1,#sans-2),#sans do
        local move_no=math.floor((i-1)/2)+1
        local prefix=i%2==1 and (move_no..". ") or (move_no.."... ")
        local ev=self.eval_history and self.eval_history[i] or nil
        local adjusted=ev and {cp=ev.cp and ev.cp*sign or nil,mate=ev.mate and ev.mate*sign or nil} or nil
        recent[#recent+1]={move=prefix..sans[i],eval=Eval.short(adjusted)}
    end
    local suggested={}
    if self.arbiter and self.arbiter._hint_pvs then
        for i=1,2 do local pv=self.arbiter._hint_pvs[i]
            if pv and pv.move then suggested[#suggested+1]={move=self.arbiter:_uciToSan(pv.move),
                eval=Eval.short{cp=pv.cp and pv.cp*sign or nil,mate=pv.mate and pv.mate*sign or nil}} end
        end
    end
    local caps=Eval.capturedPieces(self.game:moveHistory())
    return {elo=self:computerElo(),human_color=human,captures=human==WHITE and caps.w or caps.b,
        recent=recent,suggested=suggested,
        show_elo=self:getSetting("show_engine_elo",true),
        show_captures=self:getSetting("show_computer_captures",true),
        show_recent=self:getSetting("show_eval",true),
        show_suggestions=self:getSetting("show_hints",false) and self.game:turn()==human}
end

function App:detectOpening()
    if not self.openings then return nil end
    return Openings.match(self.openings, self.game:sanHistory())
end

--- Clock cards: push the current remaining times (when timed).
function App:updateTimerDisplay()
    if self.timed and self.clock_panels then
        local w, b = self.clock:remaining(WHITE), self.clock:remaining(BLACK)
        local active = self.running and self.clock.turn or nil
        for _, entry in pairs(self.clock_panels) do
            entry.panel:update(w, b, active)
            UIManager:setDirty(entry.panel, "ui")
        end
    end
end

--- The arbiter owns the clock ticker and flag detection; this stub keeps
--- the old call sites (close/exit) meaningful without duplicating them.
function App:stopClockTicker() -- luacheck: ignore self
end

-- Move flow ------------------------------------------------------------------------

--- Called by the board with the desired move `{from, to, promotion}`.
--- The arbiter validates and plays it, and its repaint effects redraw.
function App:onMoveExecuted(move)
    if not (self.arbiter and move) then return end
    self:dispatch(self.arbiter:transition{
        kind = "human_move",
        from = move.from,
        to   = move.to,
        promotion = move.promotion,
    })
end

function App:handleUndoMove(all)
    if not self.arbiter then return end
    self:dispatch(self.arbiter:transition{ kind = "undo", all = all })
end

function App:handleRedoMove(all)
    if not self.arbiter then return end
    self:dispatch(self.arbiter:transition{ kind = "redo", all = all })
end

--- New game / reset. The reset transition already auto-launches when a
--- computer opens and the engine is ready; analysis resumes on the first
--- human move.
function App:resetGame()
    if not self.arbiter then return end
    if self.board then
        self.board:clearValidMoves()
        self.board:clearPreviousMoveHints()
        self.board:clearCheckHint()
    end
    self:dispatch(self.arbiter:transition{ kind = "reset" })
end

-- Persistence -----------------------------------------------------------------------

function App:saveGameState()
    if self.arbiter then
        self:dispatch(self.arbiter:transition{ kind = "save_requested" })
    end
end

-- PGN load / save dialogs -------------------------------------------------------------

function App:openLoadPgnDialog()
    UIManager:show(
        PathChooser:new{
            path = GAMES_PATH,
            title = _("Load PGN File"),
            select_directory = false,
            onConfirm = function(path)
                if not path then return end
                local fh = io.open(path, "r")
                if not fh then
                    UIManager:show(InfoMessage:new{ text = _("Could not open file:\n") .. path })
                    return
                end
                local pgn_data = fh:read("*a")
                fh:close()

                -- The arbiter parses the PGN, restores the previous game on
                -- failure, and its repaint effects redraw everything.
                if self.arbiter then
                    self:dispatch(self.arbiter:transition{ kind = "pgn_loaded", pgn = pgn_data })
                end
                UIManager:setDirty(self, "ui")
                        end,
        }
    )
end

function App:handleSaveFile(dialog, filename_input, current_dir)
    filename_input:onCloseKeyboard()
    local file = filename_input:getText():gsub("\n$", "")
    if not file:lower():match("%.pgn$") then
        file = file .. ".pgn"
    end

    local sep = package.config:sub(1, 1)
    local fullpath = current_dir .. sep .. file
    local fh, err = io.open(fullpath, "w")
    if not fh then
        UIManager:show(InfoMessage:new{ text = _("Could not save file:\n") .. tostring(err) })
        return
    end
    fh:write(self.game:pgn())
    fh:close()

    UIManager:close(dialog)
    UIManager:show(InfoMessage:new{ text = _("Game saved to:\n") .. fullpath })
end

function App:openSaveDialog()
    local current_dir = GAMES_PATH
    local dialog
    local filename_input

    local function onSaveConfirm()
        self:handleSaveFile(dialog, filename_input, current_dir)
    end

    dialog = InputDialog:new{
        title = _("Save current game as"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        filename_input:onCloseKeyboard()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = onSaveConfirm,
                },
            }
        }
    }

    local dir_label = TextWidget:new{
        text = current_dir,
        face = Font:getFace("smallinfofont"),
        truncate_left = true,
        max_width = dialog:getSize().w * 0.8,
    }

    local browse_button = ButtonWidget:new{
        text = "...",
        callback = function()
            UIManager:show(
                PathChooser:new{
                    path = current_dir,
                    title = _("Select Save Folder"),
                    select_file = false,
                    show_files = true,
                    parent = dialog,
                    onConfirm = function(chosen)
                        if chosen and #chosen > 0 then
                            current_dir = chosen
                            dir_label:setText(chosen)
                            UIManager:setDirty(dialog, "ui")
                        end
                    end
                }
            )
        end,
    }

    filename_input = InputText:new{
        text = "game.pgn",
        focused = true,
        parent = dialog,
        enter_callback = onSaveConfirm,
    }

    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "left",
            dialog.title_bar,
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Folder") .. ":", face = Font:getFace("cfont", 22) },
                dir_label,
                HorizontalSpan:new{ width = Size.padding.small },
                browse_button,
            },
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Filename") .. ":", face = Font:getFace("cfont", 22) },
                filename_input,
            },
            CenterContainer:new{
                dimen = Geometry:new{
                    w = dialog.title_bar:getSize().w,
                    h = dialog.button_table:getSize().h,
                },
                dialog.button_table
            },
        },
    }

    dialog.movable = MovableContainer:new{ content }
    dialog[1] = CenterContainer:new{ dimen = Screen:getSize(), dialog.movable }
    dialog:refocusWidget()
    return dialog
end

-- Promotion ---------------------------------------------------------------------------

function App:openPromotionDialog(from, to, color)
    local choices = { q = Game.QUEEN, r = Game.ROOK, b = Game.BISHOP, n = Game.KNIGHT }
    local icons_p = {
        [Game.QUEEN]  = { [WHITE] = "slatechess/wQ", [BLACK] = "slatechess/bQ" },
        [Game.ROOK]   = { [WHITE] = "slatechess/wR", [BLACK] = "slatechess/bR" },
        [Game.BISHOP] = { [WHITE] = "slatechess/wB", [BLACK] = "slatechess/bB" },
        [Game.KNIGHT] = { [WHITE] = "slatechess/wN", [BLACK] = "slatechess/bN" },
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
                -- The arbiter plays and repaints; here we just report the
                -- desired promotion like any other board move.
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

return App
