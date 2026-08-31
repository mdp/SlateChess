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
local BottomContainer = require("ui/widget/container/bottomcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TitleBarWidget = require("ui/widget/titlebar")
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
local Clock = require("core.clock")
local Eval = require("core.eval")
local Openings = require("core.openings")
local Blunder = require("core.blunder")
local Uci = require("engine.uci")
local ChessBoard = require("ui.board")
local ClockPanel = require("ui.clock_panel")
local PlayerStrip = require("ui.player_strip")
local SettingsWidget = require("ui.settings_dialog")
local MarksOverlay = require("ui.marks_overlay")
local _ = require("gettext")

local WHITE, BLACK = Game.WHITE, Game.BLACK

-- Minimum seconds between the engine starting to think and its move landing
-- on the board, so fast replies never look instantaneous.
local MIN_ENGINE_MOVE_DELAY = 1

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
    --   chal          -- the Kindle build (Linux ARM, musl static)
    --   chal-arm64    -- the macOS build
    --   stockfish     -- optional Stockfish fallback (Linux ARM)
    --   stockfish-arm64, stockfish-x64 -- optional Stockfish fallbacks
    -- Chal is the primary engine: a ~75KB UCI engine with proper evals
    -- (see engines/chal.c), small enough for any device and fast enough
    -- for the emulator.  Stockfish binaries are honoured when present.
    local arch = jit and jit.arch and jit.arch:gsub("%W", "") or nil
    local candidates = {}
    if arch then
        candidates[#candidates + 1] = "chal-" .. arch
    end
    candidates[#candidates + 1] = "chal"
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
local FRAME_PAD = Screen:scaleBySize(Layout.FRAME_PAD_PTS)



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
    padding = FRAME_PAD,
    full_width = Screen:getWidth(),
    full_height = Screen:getHeight(),
    notation_font = LOG_FONT,
    notation_size = LOG_FONT_SIZE,
}

function App:init()
    self.dimensions = Geometry:new{ w = self.full_width, h = self.full_height }
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

function App:onSlateChessStart()
    self:startGame()
    return true
end

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
                    self:shutdownEngine()
                    -- The uciok handler relaunches whatever is on move.
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
            .. "chal[-<arch>] or stockfish[-<arch>]."
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
    self.eval_turn = nil
    self.eval_history = {}
    self._analysis_active = false
    self.running = false

    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:close(self)
    end

    self:loadEngineSettings()
    self:newGame()
    self:startEngine()
    self:loadOpenings()
    self:buildUILayout()
    self:updateTimerDisplay()
    self:restoreGameState()
    self:updateBoardOrientation()
    self.board:updateBoard()
    UIManager:show(self)
    self:launchComputerMove()
end

--- Creates the Game, the Clock and the Blunder damper from settings.
function App:newGame()
    self.game = Game:new()
    self.game:setHuman(WHITE, self:getSetting("human_white", true))
    self.game:setHuman(BLACK, self:getSetting("human_black", false))
    self.timed = self:getSetting("timed", false) and true or false
    self.clock = Clock:new{
        base = {
            w = self:getSetting("time_base_white", 900),
            b = self:getSetting("time_base_black", 900),
        },
        increment = {
            w = self:getSetting("time_incr_white", 10),
            b = self:getSetting("time_incr_black", 10),
        },
    }
    self.running = false
    self.blunderer = Blunder:new(self.game, self.blunder_chance or 0.0)
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

--- Starts the chess engine subprocess (chal, or Stockfish when its
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
            .. "\n(stockfish-<arch>, e.g. stockfish-arm64, or stockfish)")
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

--- One event wiring for both engine implementations.
function App:wireEngineHandlers(engine)
    engine:on("read", function(data)
        if self.engine ~= engine then return end
        if not data then return end
        for line in tostring(data):gmatch("[^\r\n]+") do
            self.engine_last_output = line
            logger.dbg("slatechess: engine <", line)
            if line:match("execvp failed") then
                self:markEngineInvalid(line)
            else
                self:captureEval(line)
                self:captureHints(line)
            end
        end
    end)

    engine:on("uciok", function()
        if self.engine ~= engine then return end
        self.engine_status_text = nil
        self:applyEngineOptions(engine)
        engine:ucinewgame()

        if not (self:getSetting("saved_pgn", "") or ""):match("%S") then
            self:updateNotation()
        end

        -- Restored computer-vs-computer games resume once UCI is ready.
        if self.game:isComputerVsComputer() and self.running then
            self:syncEnginePosition()
            engine.send("isready")
            self:launchNextMove()
        else
            engine.send("isready")
        end

        UIManager:setDirty(self, "ui")
        if self.game and not self.game:isHuman(self.game:turn()) then
            UIManager:nextTick(function() self:launchComputerMove() end)
        end
        -- A human on move with an empty board gets no analysis: the
        -- eval and hints wait for the start of play (see launchAnalysis).
    end)

    engine:on("bestmove", function(move_uci)
        if self.engine ~= engine then return end
        -- Route by which search this go belonged to: analysis searches
        -- only refresh the eval; move searches play the move.
        if self._go_kind == "analysis" then
            self._analysis_active = false
            self._go_kind = nil
            self:commitEval(self._analysis_ply)
            self:commitHints(move_uci)
            return
        end
        self._go_kind = nil
        self.engine_busy = false
        self._search_watchdog = nil
        self:stopThinkingIndicator()
        -- The search evaluated the position as it stood at launch; an
        -- undo since then makes the result stale.
        self:commitEval(self._search_ply)
        if self.game:isHuman(self.game:turn()) then return end

        -- Guarantee a minimum visible pause before the engine's move lands,
        -- so instant replies still read as a deliberate move rather than
        -- an involuntary jump.
        local now = UIManager:getTime()
        local elapsed = now - (self._search_started_at or now)
        local delay = math.max(0, MIN_ENGINE_MOVE_DELAY - elapsed)
        local function apply()
            if self.engine ~= engine then return end
            if self.game:isHuman(self.game:turn()) then return end
            self:applyEngineMove(move_uci)
        end
        if delay > 0.05 then
            UIManager:scheduleIn(delay, apply)
        else
            apply()
        end
    end)

    engine:on("process_error", function(err)
        if self.engine ~= engine then return end
        self.engine_busy = false
        self:markEngineInvalid(err or "Engine process failed.")
    end)

    engine:on("uci_timeout", function(last_output)
        if self.engine ~= engine then return end
        local text = "Timed out waiting for the engine's UCI response."
        if last_output and last_output ~= "" then text = text .. "\n" .. last_output end
        self:markEngineInvalid(text)
    end)

    engine:on("go_timeout", function(last_output)
        if self.engine ~= engine then return end
        self.engine_busy = false
        self._go_kind = nil
        self._analysis_active = false
        self:stopThinkingIndicator()
        local text = "Timed out waiting for the engine's bestmove."
        if last_output and last_output ~= "" then text = text .. "\n" .. last_output end
        self:markEngineInvalid(text)
    end)
end

--- UCI options applied when the engine becomes ready.
function App:applyEngineOptions(engine)
    engine.send("setoption name Hash value 8")
    engine.send("setoption name Threads value 1")
    engine.send("setoption name Skill Level value " .. tostring(self.current_skill or 0))
    engine.send("setoption name Move Overhead value 150")
    engine.send("setoption name Ponder value false")
    engine.send("setoption name Slow Mover value 90")
    engine.send("setoption name MultiPV value 1")
    self.current_skill = self.current_skill or 0
end

function App:shutdownEngine()
    self._pending_launch = nil
    self:stopThinkingIndicator()
    self.engine_busy = false
    self._analysis_active = false
    if self.engine and not self.engine.closed then
        self.engine:quit()
    end
    self.engine = nil
end

function App:stopSearch()
    self._pending_launch = nil
    self:stopThinkingIndicator()
    self.engine_busy = false
    if self.engine and not self.engine.closed and self.engine.state.uciok then
        self.engine:stop()
    end
end

--- Keeps the engine's position in sync with the game history.
function App:syncEnginePosition()
    if not (self.engine and self.engine.state and self.engine.state.uciok) then return end
    self.engine:position({ moves = self.game:uciMoveString() })
end

-- Eval capture --------------------------------------------------------------------

--- Extracts the evaluation from one UCI "info" line (principal variation
--- only), converting it to White's perspective.
function App:captureEval(line)
    local info = Eval.parseInfo(line)
    if not info then return end
    if info.mate ~= nil then
        self.last_mate = Eval.toWhitePerspective(info.mate, self.eval_turn)
        self.last_cp = nil
    elseif info.cp ~= nil then
        self.last_cp = Eval.toWhitePerspective(info.cp, self.eval_turn)
        self.last_mate = nil
    end
end

--- Commits the latest captured eval to the per-ply history at `ply`,
--- provided the game is still at that ply -- an undo (or game reset)
--- during the search makes the result stale and it is dropped.
function App:commitEval(ply)
    if not self.eval_history or not self.game then return end
    if ply ~= #(self.game:sanHistory()) then return end
    if self.last_cp == nil and self.last_mate == nil then return end
    self.eval_history[ply] = { cp = self.last_cp, mate = self.last_mate }
    self:updateNotation()
end

--- Captures per-PV data from "info" lines while the background analysis
--- runs, feeding the Engine Hints line (the top two recommendations).
--- Scores convert to White's perspective exactly like captureEval.
function App:captureHints(line)
    if not self._analysis_active then return end
    if not (self.hints_widget and self:getSetting("show_hints", false)) then return end
    local info = Eval.parsePv(line)
    if not info then return end
    self._hint_pvs = self._hint_pvs or {}
    self._hint_pvs[info.multipv] = {
        move = info.move,
        cp   = info.cp ~= nil and Eval.toWhitePerspective(info.cp, self.eval_turn) or nil,
        mate = info.mate ~= nil and Eval.toWhitePerspective(info.mate, self.eval_turn) or nil,
    }
end

--- Renders the Engine Hints line from the PVs captured during the
--- analysis that just finished: up to the top two moves, each with its
--- eval ("Nf3 +0.35   d4 +0.28"). `bestmove_uci` backs up PV 1 when the
--- engine reported no multipv lines. A stale result -- undo or reset
--- mid-search -- clears the line instead.
function App:commitHints(bestmove_uci)
    local widget = self.hints_widget
    if not widget then return end
    if not self:getSetting("show_hints", false) then return end
    if self._analysis_ply ~= #(self.game:sanHistory()) then
        widget:setText("")
        return
    end
    local pvs = self._hint_pvs or {}
    self._hint_pvs = nil

    local function entry(i)
        local pv = pvs[i]
        local uci = (pv and pv.move) or (i == 1 and bestmove_uci) or nil
        if not uci then return nil end
        local cp, mate = pv and pv.cp or nil, pv and pv.mate or nil
        if i == 1 and cp == nil and mate == nil then
            cp, mate = self.last_cp, self.last_mate
        end
        local san = self:uciToSan(uci)
        local ev = Eval.short{ cp = cp, mate = mate }
        return (ev ~= "") and (san .. " " .. ev) or san
    end

    local parts = {}
    for i = 1, 2 do
        local txt = entry(i)
        if txt then parts[#parts + 1] = txt end
    end
    widget:setText(table.concat(parts, "   "))
    UIManager:setDirty(self, "ui")
end

--- SAN for a UCI token in the current position ("e2e4" -> "Nf3"),
--- matched against the verbose legal-move list, which carries .san.
--- Falls back to the raw token if the position moved on.
function App:uciToSan(uci)
    for _, m in ipairs(self.game:legalMoves({ verbose = true })) do
        if m.from .. m.to .. (m.promotion or "") == uci then return m.san end
    end
    return uci
end

--- Short background search that refreshes the eval without moving.
--- Runs whenever a human is on move; when the computer is thinking, its
--- own search commits the eval as a side effect. Never races the move
--- search: if the engine is busy, the running search commits instead.
function App:launchAnalysis()
    if not (self.engine and self.engine.state and self.engine.state.uciok) then return end
    -- A fresh board gets no eval or suggested moves: they'd imply a
    -- verdict before anyone has played. Play starts the analysis --
    -- onMoveExecuted relaunches it after every ply.
    if #(self.game:sanHistory()) == 0 then return end
    if self.engine_busy or self._analysis_active then return end
    self._analysis_active = true
    self._analysis_ply = #(self.game:sanHistory())
    self.eval_turn = self.game:turn()
    self._hint_pvs = nil
    -- Blank the hints line while a fresh analysis runs: hints from the
    -- previous position would read as current ones.
    if self.hints_widget then self.hints_widget:setText("") end
    local hints = self.hints_widget and self:getSetting("show_hints", false)
    self:syncEnginePosition()
    -- Analysis runs at FULL strength: the skill handicap is a global
    -- engine option, and a 600-ELO analysis both suggests bad hint moves
    -- and reports garbage evals. launchSearch restores the player's
    -- skill before every real move search.
    self.engine.send("setoption name Skill Level value 20")
    -- With Engine Hints on, the analysis doubles as the hint search:
    -- two PVs, deeper than the eval-only pass (time-capped by movetime,
    -- so slow devices reach less depth, never more time).
    if hints then
        self.engine.send("setoption name MultiPV value 2")
    end
    -- Route the bestmove to the analysis handler: chal has no multipv
    -- token, so the bestmove handler keys off this tag, not off flags.
    self._go_kind = "analysis"
    self.engine:go{ depth = hints and 10 or 2, movetime = hints and 1000 or 300 }
end

function App:resetEval()
    self.last_cp = nil
    self.last_mate = nil
    self.eval_turn = nil
    self.eval_history = {}
end

-- Board orientation (derived state) --------------------------------------------------

--- The board faces the side to move in human-vs-human play while the game
--- runs; otherwise it faces the human (white by default).
function App:currentFaceColor()
    local game = self.game
    if game and self.running and game:isHumanVsHuman() then
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
--- Rebuilds the layout because the two player strips trade places (and
--- their rotation), and re-derives the board's flipped grid.
function App:toggleBoardFlip()
    self:setSetting("flip_board", not (self:getSetting("flip_board", false) and true or false))
    self:buildUILayout()
    self:updateBoardOrientation()
    self.board:updateBoard()
    self:updateTimerDisplay()
    self:updateNotation()
    UIManager:setDirty(self, "ui")
end

--- Re-derives orientation from the game and repaints once.
function App:updateBoardOrientation()
    if not (self.board and self.game) then return end
    local hvh = self.game:isHumanVsHuman()
    self.board:setFlipped(self:shouldFlipBoard())
    -- The player strips follow the flip (which side sits at the bottom
    -- is decided in buildUILayout); the clock cards keep their fixed
    -- row order, so each player's own time stays nearest them in both
    -- positions.
    local rotate_pref = self:getSetting("rotate_top_pieces", false) and true or false
    self.board.rotate_top_pieces = (not hvh) and rotate_pref or false
    self.board:setFaceColor(self:currentFaceColor())
end

local function createToolbarButton(icon, w, h, cb)
    return ButtonWidget:new{ icon = icon, width = w, icon_width = w, icon_height = h,
        padding = 0, margin = 0, bordersize = 0, callback = cb }
end

-- Layout -------------------------------------------------------------------------------

function App:buildUILayout()
    local status_bar = self:createStatusBar()
    local status_h   = status_bar:getSize().h

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

    -- Chess clocks (timed games only): two compact cards, one per
    -- player strip. Both cards always paint upright and show both
    -- times; the strip rotates Black's whole bracket (card included)
    -- for the player sitting on Black's side. Positions are fixed to
    -- the board's grid and do not follow its flips.
    self.clock_panels = nil
    local card_h = 0
    if timed then
        local function buildPanel(white_top)
            local panel = ClockPanel:new{
                white     = self.clock:remaining(WHITE),
                black     = self.clock:remaining(BLACK),
                -- Your own time is the one nearest you. White's card
                -- reads upright: White's time at the bottom (near
                -- White). Black's card goes in the flipped strip, so
                -- it's built the other way around: after the strip's
                -- 180° rotation, Black's time is the one nearest Black.
                white_top = white_top,
            }
            panel:update(
                self.clock:remaining(WHITE),
                self.clock:remaining(BLACK),
                self.running and self.clock.turn or nil)
            return panel
        end

        local white_panel = buildPanel(false)
        local black_panel = buildPanel(true)
        card_h = white_panel:getSize().h
        self.clock_panels = {
            white = { panel = white_panel },
            black = { panel = black_panel },
        }
    end

    -- The player strips are part of the board's unit, so their heights
    -- are inputs to the layout (like status_h): the notation block or
    -- the clock card, whichever is taller. The bottom strip grows a
    -- third line when Engine Hints is on -- priced once, only there,
    -- because hints are for the reader nearest the screen.
    local line_h = Layout.logLineHeight(scale_fn)
    local strip_h = math.max(2 * line_h, card_h)
    local bottom_strip_h = self:getSetting("show_hints", false)
        and math.max(3 * line_h, card_h) or strip_h

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
    local notation_w = math.floor(strip_w * 2 / 3)

    -- One notation pair per strip: identical content, updated in tandem
    -- (see updateNotation). Line 1 is the last two plies with each
    -- move's eval; line 2 is the total advantage plus the opening name.
    -- The bottom strip (the one nearest the reader, always upright)
    -- grows a third Engine Hints line when the setting is on. All rows
    -- are pinned to the layout's line height by their containers, so
    -- the strip's height budget stays exact.
    local function buildNotation(with_hints)
        local moves = TextWidget:new{
            text    = "",
            face    = Font:getFace(self.notation_font, self.notation_size),
            padding = 0,
        }
        local total = TextWidget:new{
            text    = "",
            face    = Font:getFace(LOG_FONT, LOG_FONT_SIZE),
            halign  = "left",
            padding = 0,
            width   = notation_w,
        }
        local rows = {
            LeftContainer:new{
                dimen = Geometry:new{ w = notation_w, h = line_h },
                moves,
            },
            LeftContainer:new{
                dimen = Geometry:new{ w = notation_w, h = line_h },
                total,
            },
        }
        local hints
        if with_hints then
            hints = TextWidget:new{
                text    = "",
                face    = Font:getFace(LOG_FONT, LOG_FONT_SIZE),
                padding = 0,
            }
            rows[3] = LeftContainer:new{
                dimen = Geometry:new{ w = notation_w, h = line_h },
                hints,
            }
        end
        local block = VerticalGroup:new{ align = "left", unpack(rows) }
        return moves, total, hints, block
    end

    local white_at_bottom = not self:shouldFlipBoard()
    local w_moves, w_total, w_hints, w_block = buildNotation(white_at_bottom)
    local b_moves, b_total, b_hints, b_block = buildNotation(not white_at_bottom)
    self.notation_moves = { w_moves, b_moves }
    self.notation_totals = { w_total, b_total }
    -- One hints widget: whichever strip sits at the bottom. Rebuilt with
    -- the layout (flip, settings), so the reference is always fresh.
    self.hints_widget = w_hints or b_hints

    -- Which player's strip sits at the bottom (nearest the reader)
    -- follows the board flip: unflipped, White's side is at the bottom;
    -- flipped, Black's. The strip at the top is the rotated one, so
    -- each player still reads their own bracket right side up -- and
    -- each clock card keeps its fixed row order (own time nearest the
    -- reader) in either position.
    local function buildStrip(color, block, card)
        local at_bottom = ((color == WHITE) == white_at_bottom)
        return PlayerStrip:new{
            row_w    = content_w,
            width    = strip_w,
            offset_x = strip_x,
            rotated  = not at_bottom,
            notation = block,
            clock    = card,
        }
    end
    self.white_strip = buildStrip(WHITE, w_block,
        self.clock_panels and self.clock_panels.white.panel or nil)
    self.black_strip = buildStrip(BLACK, b_block,
        self.clock_panels and self.clock_panels.black.panel or nil)

    -- Bottom bar, one row pinned to the BOTTOM line (BottomContainer)
    -- exactly as the icons' ink is pinned to the top line up top: the
    -- prev/next chevrons' ink on the left line (where New Game used to
    -- live -- it moved into the hamburger menu), the player roster's
    -- ink on the right line.
    local player_face = Font:getFace(LOG_FONT, 12)
    self.player_label = TextWidget:new{
        text    = "",
        face    = player_face,
        padding = 0,
    }
    local nav_btn_h = Screen:scaleBySize(16) -- half the old toolbar buttons
    local nav_btn_w = math.floor(content_w / 10)
    local nav_row = HorizontalGroup:new{
        createToolbarButton("chevron.left", nav_btn_w, nav_btn_h,
            function() self:handleUndoMove(false) end),
        createToolbarButton("chevron.right", nav_btn_w, nav_btn_h,
            function() self:handleRedoMove(false) end),
    }
    local third_w = math.floor(content_w / 3)
    local bottom_ink_h = math.max(self.player_label:getSize().h, nav_btn_h)
    local bottom_toolbar = BottomContainer:new{
        dimen = Geometry:new{ w = content_w, h = L.chrome.bottom_h },
        HorizontalGroup:new{
            LeftContainer:new{
                dimen = Geometry:new{ w = third_w, h = bottom_ink_h },
                nav_row,
            },
            RightContainer:new{
                dimen = Geometry:new{ w = content_w - third_w, h = bottom_ink_h },
                self.player_label,
            },
        },
    }

    -- The middle zone is ONE centered unit: [top strip][board][bottom
    -- strip]. The strips are rows of the unit, so they cannot collide
    -- with the board; the leftover slack splits around it. Which strip
    -- is on top follows the flip (see white_at_bottom above).
    local top_strip    = white_at_bottom and self.black_strip or self.white_strip
    local bottom_strip = white_at_bottom and self.white_strip or self.black_strip
    local top_h    = top_strip:getSize().h
    local bottom_h = bottom_strip:getSize().h
    local gap = L.chrome.strip_gap
    local slack = L.board.zone_h - top_h - bottom_h - 2 * gap - L.board.height
    local unit_top = math.floor(slack / 2)
    local middle_zone = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = unit_top },
        top_strip,
        VerticalSpan:new{ width = gap },
        self.board,
        VerticalSpan:new{ width = gap },
        bottom_strip,
        VerticalSpan:new{ width = slack - unit_top },
    }

    self.status_bar = status_bar
    self[1] = VerticalGroup:new{
        align = "center", width = content_w, height = content_h,
        status_bar, middle_zone, bottom_toolbar,
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
end

--- Paints the game, then the move/selection brackets on top.
function App:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    if self.marks then self.marks:paintTo(bb) end
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

function App:createStatusBar()
    local screen = require("device").screen
    return TitleBarWidget:new{
        fullscreen             = true,
        width                  = self.full_width - 2 * FRAME_PAD,
        title                  = "",
        subtitle               = "",
        left_icon              = "slatechess/settings",
        left_icon_size_ratio   = 0.8, -- 20% under the title bar's base size
        right_icon             = "slatechess/menu",
        right_icon_size_ratio  = 0.8,
        -- Frame contract (ui/layout.lua): the icons' ink sits ON the
        -- frame's left/top/right lines. The plugin SVGs render
        -- box == ink, so button_padding 0 pins the ink horizontally to
        -- the bar's edges (= the left/right lines), and zero top
        -- padding pins the ink to the top line. Tap zones still reach
        -- inward (2 icon-widths), so the flush ink costs nothing
        -- ergonomically.
        button_padding         = 0,
        title_h_padding        = FRAME_PAD,
        title_top_padding      = 0,
        bottom_v_padding       = screen:scaleBySize(8),
        left_icon_tap_callback = function()
            self:stopThinkingIndicator()
            SettingsWidget:new{
                engine = self.engine,
                clock  = self.clock,
                game   = self.game,
                parent = self,
                onApply = function()
                    self:stopSearch()
                    local was_timed = self.timed
                    self.timed = self:getSetting("timed", false) and true or false
                    self.clock:reset()
                    if self.timed ~= was_timed then
                        -- The clock cards appear/disappear on the
                        -- board, so the layout (and board size) rebuilds.
                        self:buildUILayout()
                        self:updateBoardOrientation()
                        self.board:updateBoard()
                        self:updateNotation()
                                        end
                    self:updatePlayerDisplay()
                    self:updateTimerDisplay()
                    self:launchComputerMove()
                end,
            }:show()
        end,
        -- Hamburger: game actions, one per row.
        right_icon_tap_callback = function()
            local dialog
            dialog = ButtonDialog:new{
                buttons = {
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
        end,
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
            self:stopThinkingIndicator()
            self:stopClockTicker()
            self.clock:stop()
            self:saveGameState()
            UIManager:close(self, "full")
        end,
    })
end

-- Notation strips ------------------------------------------------------------------
--
-- Both player strips show the same two lines, so every writer below
-- feeds both copies (White's upright pair and Black's mirrored one):
-- line 1 is the last two plies with each move's eval, line 2 the total
-- advantage plus the opening name.

function App:updateNotation()
    local moves_widgets = self.notation_moves
    local total_widgets = self.notation_totals
    if not (moves_widgets and total_widgets) then return end

    local sans = self.game:sanHistory()
    local n = #sans
    local show_eval = self:getSetting("show_eval", true)
    local figurines = self:getSetting("figurine_pgn", false)

    -- The last two plies, each with its own eval from App.eval_history
    -- (committed when the engine finishes searching that position).
    -- White's ply carries the move number; Black's follows bare, so a
    -- full move reads "22. Nf3 Bc4". Figurine mode swaps piece letters
    -- for glyphs (the face falls back to FreeSerif for those glyphs).
    local parts = {}
    for i = math.max(1, n - 1), n do
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
        parts[#parts + 1] = txt
    end
    local moves_txt = table.concat(parts, " ")

    -- Total advantage: the latest position eval plus the opening name.
    -- White's perspective, bare number: the sign says who's better.
    local eval_txt = ""
    if show_eval then
        eval_txt = Eval.short{ cp = self.last_cp, mate = self.last_mate }
    end
    local total_txt = eval_txt
    local opening = self:detectOpening()
    if opening then
        local head = string.format("%s (%s)", opening.name, opening.eco or "?")
        total_txt = (eval_txt ~= "") and (head .. " · " .. eval_txt) or head
    end

    for _, w in ipairs(moves_widgets) do w:setText(moves_txt) end
    for _, w in ipairs(total_widgets) do w:setText(total_txt) end
    UIManager:setDirty(self, "ui")
end

function App:detectOpening()
    if not self.openings then return nil end
    return Openings.match(self.openings, self.game:sanHistory())
end

--- Status bar: clocks when timed, player types always.
function App:updateTimerDisplay()
    local ind = self.running and ((self.game:turn() == WHITE and " < ") or " > ") or " || "
    if self.timed and self.clock_panels then
        local w, b = self.clock:remaining(WHITE), self.clock:remaining(BLACK)
        local active = self.running and self.clock.turn or nil
        for _, entry in pairs(self.clock_panels) do
            entry.panel:update(w, b, active)
            UIManager:setDirty(entry.panel, "ui")
        end
    end
    self.status_bar:setTitle("")
    self:updatePlayerDisplay(ind)
    UIManager:setDirty(self.status_bar, "ui")
end

--- The player roster lives at the bottom right: who plays White / Black,
--- with the turn marker between them (< white to move, > black, || paused).
function App:updatePlayerDisplay(ind)
    local white = "White(" .. (self.game:isHuman(WHITE) and "Human" or "Computer") .. ")"
    local black = "Black(" .. (self.game:isHuman(BLACK) and "Human" or "Computer") .. ")"
    local sep = ind or (self.running and ((self.game:turn() == WHITE and " < ") or " > ") or " || ")
    local text = white .. sep .. black
    if self.player_label then
        if self.player_label.text ~= text then
            self.player_label:setText(text)
            UIManager:setDirty(self, "ui")
        end
    end
end

-- Thinking indicator ---------------------------------------------------------------

function App:startThinkingIndicator()
    self:stopThinkingIndicator()
    if self:getSetting("thinking_indicator", true) == false then return end
    if not self.status_bar then return end
    local token = {}
    self._thinking_token = token
    UIManager:scheduleIn(3, function()
        if self._thinking_token == token then self:showThinkingIndicator() end
    end)
end

function App:showThinkingIndicator()
    if self._thinking_visible or not self.status_bar then return end
    self._thinking_visible = true
    -- NOTE: the loop variable must not be "_" -- it would shadow the
    -- gettext function inside the loop body (crash: "attempt to call
    -- local '_' (a number value)").
    local text = _("Computer thinking...")
    self.status_bar:setSubTitle(text)
    local totals = self.notation_totals or {}
    for i = 1, #totals do totals[i]:setText(text) end
    UIManager:setDirty(self.status_bar, "ui")
    UIManager:setDirty(self, "ui")
end

function App:stopThinkingIndicator()
    local was_visible = self._thinking_visible
    self._thinking_token = nil
    self._thinking_visible = false
    if was_visible and self.status_bar and self.game then
        -- The subtitle is the thinking indicator's only home now (the
        -- player roster moved to the bottom bar), so clear it on stop.
        self.status_bar:setSubTitle("")
        self:updatePlayerDisplay()
        self:updateNotation()
    end
end

-- Clock ticker -----------------------------------------------------------------------

--- A 1-second UI tick while a clock runs: refreshes the display and
--- detects flag-fall. Cancelled by bumping the token.
function App:ensureClockTicker()
    local token = {}
    self._clock_token = token
    local function tick()
        if self._clock_token ~= token then return end
        if not self.clock or not self.clock.running then return end
        self:updateTimerDisplay()
        if self.clock:expired() then
            self:onClockFlag()
            return
        end
        UIManager:scheduleIn(1, tick)
    end
    UIManager:scheduleIn(1, tick)
end

function App:stopClockTicker()
    self._clock_token = nil
end

--- Flag-fall: the side on move ran out of time.
function App:onClockFlag()
    self.clock:stop()
    self:stopClockTicker()
    self:stopSearch()
    self.running = false
    local winner = (self.clock.turn == WHITE) and _("Black") or _("White")
    self:finishGame(string.format(_("%s wins on time."), winner))
end

-- Move flow ------------------------------------------------------------------------

--- Called by the board after any move (human input or promotion).
function App:onMoveExecuted(_)
    self:stopThinkingIndicator()
    self.running = true

    self:updateNotation()
    -- Human vs human: re-derive orientation for the side to move
    -- (board squares stay put; only the piece icons flip).
    self:updateBoardOrientation()

    local status = self.game:status()
    if status.over then
        self:showGameOverDialog(status)
        UIManager:setDirty(self, "ui")
        return
    end

    self:launchNextMove()
    -- When the computer is on move, its search refreshes the eval; when
    -- a human is on move (or the engine is not searching), run the
    -- short background analysis instead.
    self:launchAnalysis()
    UIManager:setDirty(self, "ui")
end

--- Continues the game after a move: clocks, then the engine if it is on move.
function App:launchNextMove()
    if self.timed then
        self.clock:switch(self.game:turn())
        self:ensureClockTicker()
    end
    self:updateTimerDisplay()
    if self.engine and self.engine.state.uciok and not self.game:isHuman(self.game:turn()) then
        self:launchSearch()
    end
end

--- Starts the engine for the side on move right now (game start, resume,
--- settings change).
function App:launchComputerMove()
    if not (self.engine and self.engine.state.uciok and not self.game:isHuman(self.game:turn())) then return end

    self.running = true
    if self.timed then
        self.clock:switch(self.game:turn())
        self:ensureClockTicker()
    end
    self:updateTimerDisplay()
    self:launchSearch()
end

--- Sends the search request to the engine.
function App:launchSearch()
    if not (self.engine and self.engine.state and self.engine.state.uciok) then return end
    if self.engine_busy then return end
    if self._analysis_active then
        -- Let the short analysis finish (its bestmove commits the eval),
        -- then retry -- never send a second `go` while one is running.
        if not self._search_retry then
            self._search_retry = true
            UIManager:scheduleIn(0.3, function()
                self._search_retry = false
                if self.engine then self:launchSearch() end
            end)
        end
        return
    end
    self.engine_busy = true
    self._search_ply = #(self.game:sanHistory())
    self:startThinkingIndicator()
    self._search_started_at = UIManager:getTime()
    self._go_kind = "search"

    self:syncEnginePosition()
    self.eval_turn = self.game:turn()
    -- Move searches run under the player's handicap (and single-PV);
    -- full-strength MultiPV 2 is reserved for the background analysis.
    self.engine.send("setoption name Skill Level value " .. tostring(self.current_skill or 0))
    self.engine.send("setoption name MultiPV value 1")

    local movetime_ms = (self.engine_movetime or 1) * 1000
    local d = tonumber(self.engine_depth) or 0
    local depth_limit = (d >= 1 and d <= 5) and d or nil

    if self.timed then
        self.engine:go{
            wtime    = math.max(100, self.clock:remaining(WHITE) * 1000),
            btime    = math.max(100, self.clock:remaining(BLACK) * 1000),
            winc     = self.clock.increment[WHITE] * 1000,
            binc     = self.clock.increment[BLACK] * 1000,
            movetime = movetime_ms,
            depth    = depth_limit,
        }
    else
        -- Untimed: no clock pressure, just the configured move time / depth.
        self.engine:go{
            movetime = movetime_ms,
            depth    = depth_limit,
        }
    end
    logger.dbg("slatechess: engine > go (move search) movetime", movetime_ms,
        "depth", depth_limit or "none", "fen", self.game:fen())

    -- Watchdog: a healthy search answers well inside its budget. If it
    -- doesn't, send `stop` so the engine emits its best line so far and
    -- the game continues; if even that fails, declare the engine stalled
    -- instead of leaving the app stuck on the thinking indicator.
    local watchdog_token = {}
    self._search_watchdog = watchdog_token
    local budget_s = self.timed and 30 or (movetime_ms / 1000) + 6
    UIManager:scheduleIn(budget_s, function()
        if self._search_watchdog ~= watchdog_token or not self.engine_busy then return end
        logger.warn("slatechess: move search stalled at", self.game:fen(), "-- sending stop")
        if self.engine and not self.engine.closed then self.engine:stop() end
        UIManager:scheduleIn(5, function()
            if self._search_watchdog ~= watchdog_token or not self.engine_busy then return end
            logger.warn("slatechess: engine unresponsive; giving up")
            self:stopSearch()
            self:stopThinkingIndicator()
            self:markEngineInvalid("Engine stalled during its move search.\n"
                .. "Position: " .. self.game:fen() .. "\n"
                .. "Use 'SlateChess: engine diagnostics' to restart it.")
        end)
    end)
end

--- Applies the engine's move (possibly degraded by the Blunder damper).
function App:applyEngineMove(uci_move)
    if not uci_move then return end
    if self.blunderer then
        uci_move = self.blunderer:maybeWeaken(uci_move)
    end
    local move = self.game:playUci(uci_move)
    if move then
        self.board:handleGameMove(move)
    end
end

function App:handleUndoMove(all)
    self:stopSearch()
    if self.timed then self.clock:stop() end
    if all then
        while self.game:undo() do end
    else
        self.game:undo()
    end
    self:updateBoardOrientation()
    self.board:updateBoard()
    self:resetEval()
    self:updateNotation()
    -- Hints described the position that no longer exists.
    if self.hints_widget then self.hints_widget:setText("") end
    UIManager:setDirty(self, "ui")
    if self.timed and self.running then
        self.clock:switch(self.game:turn())
        self:ensureClockTicker()
    end
end

function App:handleRedoMove(all)
    self:stopSearch()
    if self.timed then self.clock:stop() end
    if all then
        while self.game:redo() do end
    else
        self.game:redo()
    end
    self:updateBoardOrientation()
    self.board:updateBoard()
    self:resetEval()
    self:updateNotation()
    if self.hints_widget then self.hints_widget:setText("") end
    UIManager:setDirty(self, "ui")
    if self.timed and self.running then
        self.clock:switch(self.game:turn())
        self:ensureClockTicker()
    end
end

function App:resetGame()
    self:stopSearch()
    self:stopClockTicker()
    self.game:reset()
    self.clock:reset()
    if self.engine then self.engine.send("ucinewgame") end
    self.board:clearValidMoves()
    self.board:clearPreviousMoveHints()
    self.board:clearCheckHint()
    self:setSetting("saved_pgn", "")
    self.running = false
    self:resetEval()
    -- Fresh game: both strips must go blank immediately (no moves made
    -- yet), not keep the previous game's notation until the first move.
    self:updateNotation()
    if self.hints_widget then self.hints_widget:setText("") end
    self:updateBoardOrientation()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
    self.board:updateBoard()
    UIManager:setDirty(self, "ui")
    self:launchComputerMove()
end

-- Game over ------------------------------------------------------------------------

--- Shared game-over flow: stop everything, announce, then start fresh.
function App:finishGame(text)
    self:stopSearch()
    self:stopClockTicker()
    self.clock:stop()
    self.running = false
    self:updateTimerDisplay()

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Continue"),
        cancel_text = nil,
        ok_callback = function()
            self:resetEval()
            self.running = false
            self:resetGame()
            self:updateNotation()
                    self:launchComputerMove()
        end,
    })
end

function App:showGameOverDialog(status)
    self:stopThinkingIndicator()
    local text
    if status.result == "1-0" or status.result == "0-1" then
        local winner = (status.result == "1-0") and _("White") or _("Black")
        text = string.format(_("Checkmate! %s wins."), winner)
    else
        local label = status.reason and _(status.reason) or nil
        text = label and string.format(_("Draw! %s."), label) or _("Draw!")
    end
    self:finishGame(text)
end

-- Persistence -----------------------------------------------------------------------

function App:saveGameState()
    self:setSetting("saved_pgn", self.game:pgn())
    self:setSetting("saved_time_white", self.clock:remaining(WHITE))
    self:setSetting("saved_time_black", self.clock:remaining(BLACK))
    self:setSetting("saved_running", self.running)
end

function App:restoreGameState()
    local pgn = self:getSetting("saved_pgn", "")
    if not pgn or pgn == "" then return end

    local ok = self.game:loadPgn(pgn)
    if not ok then
        self:setSetting("saved_pgn", "")
        return
    end

    if self.timed then
        local tw = self:getSetting("saved_time_white", nil)
        local tb = self:getSetting("saved_time_black", nil)
        if tw then self.clock:setTime(WHITE, tw) end
        if tb then self.clock:setTime(BLACK, tb) end
    end
    self.clock:setTurn(self.game:turn())
    self.running = self:getSetting("saved_running", false)

    self:syncEnginePosition()
    self:updateNotation()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
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

                self:stopSearch()
                self:stopClockTicker()
                self.clock:stop()
                self.game:reset()
                self.game:loadPgn(pgn_data)
                self:resetEval()

                self:updateBoardOrientation()
                self.board:updateBoard()
                self:updateNotation()
                self:updateTimerDisplay()
                self:updatePlayerDisplay()

                if self.engine and self.engine.state.uciok then
                    self.engine.send("ucinewgame")
                    self:syncEnginePosition()
                    self.engine.send("isready")
                end

                UIManager:setDirty(self, "ui")
                if self.timed then
                    self.clock:switch(self.game:turn())
                    self:ensureClockTicker()
                end
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
                local move = self.game:playMove{ from = from, to = to, promotion = char }
                if move then self.board:handleGameMove(move) end
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
