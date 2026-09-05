-- Arbiter: the game-flow orchestrator and derived-state owner.
--
-- Design A + grafts (see docs/arbiter-design.md). Pure Lua, zero KOReader
-- requires — the transition funnel lives here, host-testable, instead of
-- being hand-rolled across >=10 app.lua sequences.
--
-- State vs View, React-style:
--   * state   — ground truth only (Game, Clock, roles, running, the active
--               search, pending launches, engine readiness, settings snapshot)
--   * view()  — pure projection state -> view model, fresh every call
--   * effects — transition() returns one canonical-ordered effect list the
--               App performs; repaint targets come from diffing projections.

local Game     = require("core.game")
local Clock    = require("core.clock")
local Blunder  = require("core.blunder")
local Eval     = require("core.eval")
local Openings = require("core.openings")

local Arbiter = {}
Arbiter.__index = Arbiter

local WHITE = Game.WHITE
local BLACK = Game.BLACK

-- Machine constants (transcribed from current app.lua behavior).
local MIN_ENGINE_MOVE_DELAY   = 1       -- app.lua:64
local SEARCH_RETRY_DELAY      = 0.3     -- app.lua:1525
local THINKING_REVEAL_DELAY   = 3       -- app.lua:1399
local CLOCK_TICKER_DELAY      = 1       -- app.lua:1444
local ANALYSIS_PLY_DEPTH      = 2
local ANALYSIS_HINTS_DEPTH    = 10
local ANALYSIS_MOVETIME       = 300
local ANALYSIS_HINTS_MOVETIME = 1000
local WATCHDOG_GIVEUP_DELAY   = 5

-- Validation helpers -------------------------------------------------------

local function normalDepth(d, fallback)
    d = tonumber(d)
    if d == 0 or (d >= 1 and d <= 5) then return d end
    return fallback
end

local function clamp(v, lo, hi, fallback)
    v = tonumber(v)
    if v == nil then return fallback end
    return math.max(lo, math.min(hi, v))
end

local function isBool(v) return v == true end
-- (true → true, false → false, garbage → false: a strict boolean pass-through.)

-- Settings schema (owned once — the source of truth for every key).
local SETTINGS = {
    { key = "human_white",         default = true,   coerce = isBool },
    { key = "human_black",         default = false,  coerce = isBool },
    { key = "timed",               default = false,  coerce = isBool },
    { key = "time_base_white",     default = 900,    coerce = function(v) return clamp(v, 0, 86400, 900) end },
    { key = "time_base_black",     default = 900,    coerce = function(v) return clamp(v, 0, 86400, 900) end },
    { key = "time_incr_white",     default = 10,     coerce = function(v) return clamp(v, 0, 3600, 10) end },
    { key = "time_incr_black",     default = 10,     coerce = function(v) return clamp(v, 0, 3600, 10) end },
    { key = "skill_level",         default = 0,      coerce = function(v) return clamp(v, 0, 20, 0) end },
    { key = "engine_depth",        default = 2,      coerce = function(v) return normalDepth(v, 2) end },
    { key = "engine_movetime",     default = 1,      coerce = function(v) return clamp(v, 1, 10, 1) end },
    { key = "blunder_chance",      default = 0.20,   coerce = function(v) return clamp(v, 0, 1, 0.20) end },
    { key = "flip_board",          default = false,  coerce = isBool },
    { key = "rotate_top_pieces",   default = false,  coerce = isBool },
    -- Human-vs-human only: rotate the entire board toward the side to
    -- move on every turn (the classic two-headed behavior). Off (default):
    -- the board stays fixed and each side's far pieces angle toward their
    -- own player instead.
    { key = "flip_pieces_each_turn", default = false, coerce = isBool },
    { key = "show_eval",           default = true,   coerce = isBool },
    { key = "show_hints",          default = false,  coerce = isBool },
    { key = "figurine_pgn",        default = false,  coerce = isBool },
    { key = "thinking_indicator",  default = true,   coerce = isBool },
    { key = "learning_mode",       default = false,  coerce = isBool },
    { key = "show_selected",       default = true,   coerce = isBool },
    { key = "previous_move_hints", default = true,   coerce = isBool },
    { key = "opponent_hints",      default = false,  coerce = isBool },
    { key = "check_hints",         default = false,  coerce = isBool },
    { key = "saved_pgn",           default = "",     coerce = tostring },
    { key = "saved_time_white",    default = nil,
      coerce = function(v) if v == nil then return nil end return clamp(v, 0, 86400, nil) end },
    { key = "saved_time_black",    default = nil,
      coerce = function(v) if v == nil then return nil end return clamp(v, 0, 86400, nil) end },
    { key = "saved_running",       default = false,  coerce = isBool },
}

-- Constructor --------------------------------------------------------------

--- `cfg` is the settings snapshot; may carry `.openings` (parsed book).
-- `deps` is { now = fn() -> seconds, rng = fn() -> [0,1) }. `now` is
-- mandatory: the machine never reads the wall clock itself (the core purity
-- gate bans os.*), and host tests always inject it.
function Arbiter:new(cfg, deps)
    deps = deps or {}
    assert(type(deps.now) == "function",
        "arbiter: deps.now is required (host-testable time source)")
    local o = setmetatable({}, self)
    o.deps = deps
    o.cfg = {}
    for _, s in ipairs(SETTINGS) do
        local raw = cfg and cfg[s.key]
        local value
        if raw == nil then
            value = s.default
        elseif s.coerce then
            value = s.coerce(raw)
        else
            value = raw
        end
        o.cfg[s.key] = value
    end

    o.game = Game:new()
    o.game:setHuman(WHITE, o:cfgbool("human_white"))
    o.game:setHuman(BLACK, o:cfgbool("human_black"))
    o.clock = nil
    if o:cfgbool("timed") then
        o.clock = Clock:new({
            base      = { w = o.cfg.time_base_white,   b = o.cfg.time_base_black },
            increment = { w = o.cfg.time_incr_white,   b = o.cfg.time_incr_black },
        }, { now = deps.now })
    end
    o.blunderer = Blunder:new(o.game, o.cfg.blunder_chance or 0.0, deps.rng)
    o.openings = (cfg and cfg.openings) or nil

    o.running         = false
    o._over           = false            -- machine-decided game end (flag-fall)
    o.engine_state    = "starting"       -- "starting" | "ready" | "failed"
    o.search          = nil              -- {id, kind, ply, started_at}
    o.move_pending    = nil              -- {move, token}
    o.pending_launch  = nil              -- "search" while engine not ready
    o.thinking        = false
    o._go_id          = 0
    o._next_token     = 0
    o._timers         = {}               -- token -> fn
    o._tick_token     = nil
    o._retry_token    = nil
    o._prev_view      = nil
    o._prev_layout    = nil

    o._pending        = nil              -- {cp, mate}
    o._pending_turn   = nil
    o._current_cp     = nil
    o._current_mate   = nil
    o._hint_pvs       = nil              -- multipv -> {move, cp, mate}
    o.eval_history    = {}               -- ply -> {cp, mate}
    return o
end

function Arbiter:cfgbool(key)
    return self.cfg[key] == true
end

function Arbiter:_now()
    return self.deps.now()
end

-- Effects ---------------------------------------------------------------

function Arbiter:_newEffects()
    self._effects = {
        persist  = {},
        uci      = {},
        cancel   = {},
        schedule = {},
        repaint  = {},
        announce = {},
    }
end

function Arbiter:_emit(kind, fx)
    self._effects[kind][#self._effects[kind] + 1] = fx
end

-- Timers ----------------------------------------------------------------

function Arbiter:_mint()
    self._next_token = self._next_token + 1
    return self._next_token
end

function Arbiter:_schedule(delay, fn)
    local token = self:_mint()
    self._timers[token] = fn
    self:_emit("schedule", { kind = "schedule", token = token, delay = delay })
    return token
end

function Arbiter:_cancel(token)
    if not token or not self._timers[token] then return end
    self._timers[token] = nil
    self:_emit("cancel", { kind = "cancel", token = token })
end

-- Deep equality for view diff ---------------------------------------------

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- View projection ----------------------------------------------------------

--- The single derived-truth projection. Pure; computed fresh every call.
function Arbiter:view()
    local game   = self.game
    local clock  = self.clock
    local status = game:status()
    local hvh    = game:isHumanVsHuman()
    local turn   = game:turn()
    local sans   = game:sanHistory()
    local n      = #sans

    -- Piece orientation. "Flip pieces to player on each turn" (hvh only):
    -- on = the classic per-turn whole-board pivot — face_color follows the
    -- side to move, far-side angling off, so the whole board rotates 180°
    -- toward whoever is about to play. Off (default) = the fixed board:
    -- face_color stays white and each side's far pieces angle toward their
    -- own player.
    local face_color = WHITE
    if self.running and hvh and self:cfgbool("flip_pieces_each_turn") then
        face_color = turn
    end
    local rotate_top_pieces = false
    if hvh then
        rotate_top_pieces = not self:cfgbool("flip_pieces_each_turn")
    end

    local derived_flip = game:isHuman(BLACK) and not game:isHuman(WHITE)
    local flipped = (derived_flip and true or false) ~= self:cfgbool("flip_board")

    local clock_times, whose_clock, clock_active_color
    if clock then
        clock_times        = { white = clock:remaining(WHITE), black = clock:remaining(BLACK) }
        whose_clock        = self.running and clock.turn or nil
        clock_active_color = (self.running and clock.running) and clock.turn or nil
    end

    local over = status.over and true or false
    local engine_should_move = self.running
        and (not over)
        and (not game:isHuman(turn))

    -- Notation.
    local show_eval    = self:cfgbool("show_eval")
    local figurine_pgn = self:cfgbool("figurine_pgn")

    local function ply_text(i)
        local move_no  = math.floor((i - 1) / 2) + 1
        local prefix   = (i % 2 == 1) and (move_no .. ". ") or ""
        local move_txt = sans[i]
        if figurine_pgn then
            move_txt = Eval.figurine(move_txt, (i % 2 == 1) and "w" or "b")
        end
        local txt = prefix .. tostring(move_txt)
        if show_eval then
            local ev = Eval.short(self.eval_history[i])
            if ev ~= "" then txt = txt .. "  " .. ev end
        end
        return txt
    end

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

    local caps = Eval.capturedPieces(game:moveHistory())

    local total_txt = ""
    if show_eval then
        local eval_txt = Eval.short{ cp = self._current_cp, mate = self._current_mate }
        total_txt = eval_txt
        if self.openings then
            local opening = Openings.match(self.openings, sans)
            if opening then
                local head = string.format("%s (%s)", opening.name, opening.eco or "?")
                total_txt = (eval_txt ~= "") and (head .. " · " .. eval_txt) or head
            end
        end
    end

    local hints_txt = ""
    if self:cfgbool("show_hints") and self._hint_pvs then
        local function entry(i)
            local pv = self._hint_pvs[i]
            local uci = (pv and pv.move) or nil
            if not uci then return nil end
            local cp, mate = pv and pv.cp, pv and pv.mate
            if i == 1 and cp == nil and mate == nil then
                cp, mate = self._current_cp, self._current_mate
            end
            local san = self:_uciToSan(uci)
            local ev = Eval.short{ cp = cp, mate = mate }
            return (ev ~= "") and (san .. " " .. ev) or san
        end
        local parts = {}
        for i = 1, 2 do
            local txt = entry(i)
            if txt then parts[#parts + 1] = txt end
        end
        hints_txt = table.concat(parts, "   ")
    end

    return {
        face_color         = face_color,
        flipped            = flipped,
        white_at_bottom    = not flipped,
        rotate_top_pieces  = rotate_top_pieces,
        running            = self.running,
        whose_clock        = whose_clock,
        clock_active_color = clock_active_color,
        clock_times        = clock_times,
        engine_should_move = engine_should_move,
        engine_state       = self.engine_state,
        thinking           = (self.thinking and self.search ~= nil) and true or false,
        game_over          = (over and status) or (self._over and { over = true }) or nil,
        notation_lines     = lines,
        eval_text          = total_txt,
        hints_text         = hints_txt,
        captured           = { white = caps.w, black = caps.b },
        can_undo           = n > 0,
        can_redo           = (game.redo_stack and #game.redo_stack > 0) and true or false,
    }
end

function Arbiter:_uciToSan(uci)
    for _, m in ipairs(self.game:legalMoves({ verbose = true })) do
        if m.from .. m.to .. (m.promotion or "") == uci then return m.san end
    end
    return uci
end
-- Reconciliation ------------------------------------------------------------

local function layoutSignature(cfg)
    return {
        human_white       = cfg.human_white,
        human_black       = cfg.human_black,
        timed             = cfg.timed,
        flip_board        = cfg.flip_board,
        show_eval         = cfg.show_eval,
        show_hints        = cfg.show_hints,
        figurine_pgn      = cfg.figurine_pgn,
        rotate_top_pieces = cfg.rotate_top_pieces,
    }
end

function Arbiter:_finalizeEffects()
    local fen   = self.game:fen()
    local v     = self:view()
    local prev  = self._prev_view
    local repaints = {}

    local layout_changed = false
    if prev == nil then
        layout_changed = true
    else
        local sig = layoutSignature(self.cfg)
        local prev_sig = self._prev_layout
        if prev_sig then
            for k, val in pairs(sig) do
                if prev_sig[k] ~= val then layout_changed = true break end
            end
        else
            layout_changed = true
        end
        if not layout_changed then
            if self._prev_fen ~= fen
                or v.face_color ~= prev.face_color
                or v.flipped ~= prev.flipped
                or v.rotate_top_pieces ~= prev.rotate_top_pieces then
                repaints[#repaints + 1] = { kind = "repaint", target = "board" }
            end
            if not deepEqual(v.clock_times, prev.clock_times)
                or v.whose_clock ~= prev.whose_clock
                or v.clock_active_color ~= prev.clock_active_color then
                repaints[#repaints + 1] = { kind = "repaint", target = "clocks" }
            end
            if not deepEqual(v.notation_lines, prev.notation_lines)
                or v.eval_text ~= prev.eval_text
                or v.hints_text ~= prev.hints_text
                or v.thinking ~= prev.thinking
                or not deepEqual(v.captured, prev.captured)
                or v.game_over ~= prev.game_over then
                repaints[#repaints + 1] = { kind = "repaint", target = "notation" }
            end
        end
    end

    if layout_changed then
        repaints[#repaints + 1] = { kind = "repaint", target = "layout" }
    end

    -- Canonical order: persist, uci, cancel, schedule, repaint, announce.
    local out = {}
    local order = { "persist", "uci", "cancel", "schedule", "repaint", "announce" }
    for _, kind in ipairs(order) do
        for _, fx in ipairs(self._effects[kind]) do
            out[#out + 1] = fx
        end
    end
    for _, fx in ipairs(repaints) do
        out[#out + 1] = fx
    end

    self._prev_view = v
    self._prev_layout = layoutSignature(self.cfg)
    self._prev_fen = fen
    return out
end

-- Eval capture helpers ------------------------------------------------------

function Arbiter:_resetEval()
    self._pending = nil
    self._pending_turn = nil
    self._current_cp = nil
    self._current_mate = nil
    self._hint_pvs = nil
    self.eval_history = {}
end

function Arbiter:_commitEval(ply)
    local game = self.game
    if ply ~= #(game:sanHistory()) then
        self._pending = nil
        return
    end
    if self._pending then
        self.eval_history[ply] = { cp = self._pending.cp, mate = self._pending.mate }
        self._current_cp = self._pending.cp
        self._current_mate = self._pending.mate
        self._pending = nil
    end
end

-- Machine helpers -----------------------------------------------------------

function Arbiter:_engineWantsMove()
    local game = self.game
    local status = game:status()
    return (not self._over)
        and (not status.over)
        and (not game:isHuman(game:turn()))
end

function Arbiter:_stopSearch()
    local s = self.search
    if s then
        if self.engine_state == "ready" then
            self:_emit("uci", { kind = "uci", cmd = "stop" })
        end
        self.search = nil
    end
    self:_cancel(self._search_wd)
    self._search_wd = nil
    self:_cancel(self._think_r)
    self._think_r = nil
    self:_cancel(self._search_giveup)
    self._search_giveup = nil
    self:_cancel(self._retry_token)
    self._retry_token = nil
    if self.move_pending then
        self:_cancel(self.move_pending.token)
        self.move_pending = nil
    end
    self.thinking = false
end

function Arbiter:_ensureClockTicker()
    if not (self.clock and self.clock.running) then return end
    self:_cancel(self._tick_token)
    self._tick_token = self:_schedule(CLOCK_TICKER_DELAY, function()
        self:_clockTick()
    end)
end

function Arbiter:_clockTick()
    if not (self.clock and self.clock.running) then return end
    if not self.running then return end
    if self.clock:expired() then
        -- Flag-fall: the side on move ran out of time; the game ends and
        -- the opponent wins on time. `clock.turn` is still the flagging
        -- side (stop() banks but keeps turn).
        local loser = self.clock.turn
        local winner = (loser == WHITE) and "Black" or "White"
        self:_finishGame(string.format("%s wins on time.", winner))
        return
    end
    self._tick_token = self:_schedule(CLOCK_TICKER_DELAY, function()
        self:_clockTick()
    end)
end

function Arbiter:_launchSearch(kind)
    if self.engine_state ~= "ready" then
        if kind == "search" then self.pending_launch = "search" end
        return
    end
    if self.search then return end

    local game = self.game
    local cfg = self.cfg
    local id = self._go_id + 1
    self._go_id = id
    local turn = game:turn()
    local ply = #(game:sanHistory())

    if kind == "search" then
        self:_emit("uci", { kind = "uci", cmd = "setoption", name = "Skill Level",
                            value = tostring(cfg.skill_level or 0) })
        self:_emit("uci", { kind = "uci", cmd = "setoption", name = "MultiPV", value = "1" })
    else
        self:_emit("uci", { kind = "uci", cmd = "setoption", name = "Skill Level", value = "20" })
        self:_emit("uci", { kind = "uci", cmd = "setoption", name = "MultiPV",
                            value = self:cfgbool("show_hints") and "2" or "1" })
    end

    self:_emit("uci", { kind = "uci", cmd = "position", moves = game:uciMoveString() })

    local movetime_ms = (cfg.engine_movetime or 1) * 1000
    local d = tonumber(cfg.engine_depth) or 0
    local depth_limit = (d >= 1 and d <= 5) and d or nil

    local spec
    if kind == "search" then
        if self:cfgbool("timed") and self.clock then
            spec = {
                wtime    = math.max(100, self.clock:remaining(WHITE) * 1000),
                btime    = math.max(100, self.clock:remaining(BLACK) * 1000),
                winc     = (self.clock.increment[WHITE] or 0) * 1000,
                binc     = (self.clock.increment[BLACK] or 0) * 1000,
                movetime = movetime_ms,
                depth    = depth_limit,
            }
        else
            spec = { movetime = movetime_ms, depth = depth_limit }
        end
    else
        local hints = self:cfgbool("show_hints")
        spec = {
            depth    = hints and ANALYSIS_HINTS_DEPTH or ANALYSIS_PLY_DEPTH,
            movetime = hints and ANALYSIS_HINTS_MOVETIME or ANALYSIS_MOVETIME,
        }
    end

    self:_emit("uci", { kind = "uci", cmd = "go", id = id, go_kind = kind, spec = spec })

    self.search = { id = id, kind = kind, ply = ply, started_at = self:_now() }
    self._pending = nil
    self._pending_turn = turn

    if kind == "search" then
        self.running = true
        -- Arm the clock only if the mover didn't already: a double
        -- clock:switch() banks the side's Fischer increment for ~0 elapsed
        -- (a free +increment on every move).
        if self.clock and not self.clock.running then
            self.clock:switch(game:turn())
            self:_ensureClockTicker()
        end
        self.pending_launch = nil
        local budget_s = self:cfgbool("timed") and 30 or (movetime_ms / 1000) + 6
        self._search_wd = self:_schedule(budget_s, function()
            self:_onSearchWatchdog(id)
        end)
        if self:cfgbool("thinking_indicator") then
            self._think_r = self:_schedule(THINKING_REVEAL_DELAY, function()
                self.thinking = true
            end)
        end
    else
        self._hint_pvs = nil
        -- Analysis: not the "thinking" indicator; no watchdog, no clock.
    end
end

function Arbiter:_scheduleRetry()
    if self._retry_token then return end
    self._retry_token = self:_schedule(SEARCH_RETRY_DELAY, function()
        self._retry_token = nil
        if self.engine_state ~= "ready" then return end
        if self.move_pending then return end
        if self:_engineWantsMove() then
            if self.search == nil then
                self:_launchSearch("search")
            elseif self.search.kind == "analysis" then
                self:_scheduleRetry()
            end
        end
    end)
end

function Arbiter:_onSearchWatchdog(id)
    local s = self.search
    if not s or s.id ~= id or s.kind ~= "search" then return end
    if self.engine_state ~= "ready" then return end
    self:_emit("uci", { kind = "uci", cmd = "stop" })
    self._search_giveup = self:_schedule(WATCHDOG_GIVEUP_DELAY, function()
        if self.search and self.search.id == id then
            self:_onEngineFailed("Engine stalled during its move search.")
        end
    end)
end

function Arbiter:_applyPendingMove(move_uci)
    if self.game:status().over then return end
    if self.game:isHuman(self.game:turn()) then return end
    local uci = move_uci
    if self.blunderer then uci = self.blunderer:maybeWeaken(move_uci) end
    local played = self.game:playUci(uci)
    if not played then return end

    if self.clock then
        self.clock:switch(self.game:turn())
        self:_ensureClockTicker()
    end
    local status = self.game:status()
    if status.over then
        self:_finishGame(self:_gameOverText(status))
        return
    end
    -- Continue play (CvC self-play) or run the eval/hints analysis for
    -- the human's new position -- same as the pre-arbiter onMoveExecuted
    -- relaunching launchAnalysis after every landed ply.
    self:_afterState(true)
end

function Arbiter:_gameOverText(status) -- luacheck: ignore 212
    if status.result == "1-0" then return "Checkmate! White wins." end
    if status.result == "0-1" then return "Checkmate! Black wins." end
    if status.reason then return "Draw! " .. status.reason .. "." end
    return "Draw!"
end

function Arbiter:_finishGame(text)
    self:_stopSearch()
    if self.clock then self.clock:stop() end
    self:_cancel(self._tick_token)
    self._tick_token = nil
    self.running = false
    self._over   = true
    self.thinking = false
    self.pending_launch = nil
    self:_emit("announce", { kind = "announce", announce_kind = "game_over", text = text })
end

-- Post-transition derivation ------------------------------------------------

function Arbiter:_afterState(allow_analysis)
    if self._over then return end
    local status = self.game:status()
    if status.over then return end
    if self.move_pending then return end

    if not self:_engineWantsMove() then
        if allow_analysis
            and self.running
            and self.engine_state == "ready"
            and self.search == nil
            and #(self.game:sanHistory()) > 0 then
            self:_launchSearch("analysis")
        end
        return
    end

    if self.engine_state == "ready" then
        if self.search == nil then
            self:_launchSearch("search")
        elseif self.search.kind == "analysis" then
            self:_scheduleRetry()
        end
    else
        self.pending_launch = "search"
    end
end

-- Event handlers -------------------------------------------------------------

function Arbiter:_onStart(event)
    self.running = false
    self._over = false
    self.thinking = false
    self:_resetEval()
    local restore = event and event.restore
    if restore and type(restore) == "table" and restore.pgn and restore.pgn ~= "" then
        local ok = self.game:loadPgn(restore.pgn)
        if ok then
            if self.clock then
                if restore.t_w ~= nil then self.clock:setTime(WHITE, restore.t_w) end
                if restore.t_b ~= nil then self.clock:setTime(BLACK, restore.t_b) end
                self.clock:setTurn(self.game:turn())
            end
            self.running = restore.running and true or false
        else
            self:_emit("persist", { kind = "persist", key = "saved_pgn", value = "" })
        end
    end
end

function Arbiter:_onResume()
    -- "Continue" after a reset/game-over: put the machine back in play.
    -- _afterState launches the search when a computer is on move.
    if self._over then return end
    self.running = true
    if self.clock then
        self.clock:switch(self.game:turn())
        self:_ensureClockTicker()
    end
end

function Arbiter:_onReset()
    self:_stopSearch()
    self.game:reset()
    if self.clock then self.clock:reset() end
    self:_emit("uci", { kind = "uci", cmd = "ucinewgame" })
    self:_emit("persist", { kind = "persist", key = "saved_pgn", value = "" })
    self.running = false
    self._over = false
    self.thinking = false
    self.pending_launch = nil
    self:_resetEval()
end

function Arbiter:_onHumanMove(event)
    local played = self.game:playMove({
        from      = event.from,
        to        = event.to,
        promotion = event.promotion,
    })
    if not played then return false end

    if self.move_pending then
        self:_cancel(self.move_pending.token)
        self.move_pending = nil
    end
    self._hint_pvs = nil

    self.running = true
    if self.clock then
        self.clock:switch(self.game:turn())
        self:_ensureClockTicker()
    end
    local status = self.game:status()
    if status.over then
        self:_finishGame(self:_gameOverText(status))
    end
    return true
end

function Arbiter:_onPgnLoaded(event)
    self:_stopSearch()
    if self.clock then self.clock:stop() end
    self._over = false
    local pgn = event and event.pgn
    local prev_pgn = self.game:pgn()
    self.game:reset()
    local ok, err = self.game:loadPgn(pgn)
    if not ok then
        self.game:reset()
        if prev_pgn and prev_pgn ~= "" then self.game:loadPgn(prev_pgn) end
        self:_emit("announce", { kind = "announce", announce_kind = "error",
                                 text = err or "Could not load PGN." })
        return
    end
    self:_resetEval()
    if self.clock then
        self.clock:setTurn(self.game:turn())
        self.clock:switch(self.game:turn())
        self:_ensureClockTicker()
    end
    self.running = true
end

function Arbiter:_onUndoRedo(is_undo, event)
    self:_stopSearch()
    self._over = false
    if self.clock then self.clock:stop() end
    local all = event and event.all
    if is_undo then
        if all then while self.game:undo() do end else self.game:undo() end
    else
        if all then while self.game:redo() do end else self.game:redo() end
    end
    self:_resetEval()
    if self.clock and self.running then
        self.clock:switch(self.game:turn())
        self:_ensureClockTicker()
    end
end

function Arbiter:_onSettings(changes)
    self:_stopSearch()
    if type(changes) ~= "table" then return end
    local cfg = self.cfg
    local roles_changed = false
    local control_changed = false

    for _, entry in ipairs(SETTINGS) do
        local k = entry.key
        if changes[k] ~= nil then
            local newv = entry.coerce and entry.coerce(changes[k]) or changes[k]
            if newv ~= cfg[k] then
                cfg[k] = newv
                self:_emit("persist", { kind = "persist", key = k, value = newv })
                if k == "human_white" or k == "human_black" then
                    roles_changed = true
                elseif k:match("^time_") then
                    control_changed = true
                elseif k == "blunder_chance" then
                    self.blunderer:setChance(newv)
                elseif k == "skill_level" then
                    if self.engine_state == "ready" then
                        self:_emit("uci", { kind = "uci", cmd = "setoption",
                                            name = "Skill Level", value = tostring(newv) })
                    end
                end
            end
        end
    end

    if roles_changed then
        self.game:setHuman(WHITE, self:cfgbool("human_white"))
        self.game:setHuman(BLACK, self:cfgbool("human_black"))
    end

    if self:cfgbool("timed") then
        if not self.clock or control_changed then
            self.clock = Clock:new({
                base      = { w = cfg.time_base_white,   b = cfg.time_base_black },
                increment = { w = cfg.time_incr_white,   b = cfg.time_incr_black },
            }, { now = function() return self:_now() end })
        end
    elseif self.clock then
        self.clock = nil
    end
end

function Arbiter:_onFlipToggle()
    local white_human = self.game:isHuman(WHITE)
    local black_human = self.game:isHuman(BLACK)
    if white_human ~= black_human then
        -- In one-player mode the bottom seat belongs to the human. Flipping
        -- therefore swaps roles/colors as well as the derived board view;
        -- changing flip_board too would cancel that derived flip.
        self:_stopSearch()
        self.cfg.human_white, self.cfg.human_black = black_human, white_human
        self.game:setHuman(WHITE, black_human)
        self.game:setHuman(BLACK, white_human)
        self:_emit("persist", { kind="persist", key="human_white", value=black_human })
        self:_emit("persist", { kind="persist", key="human_black", value=white_human })
        if self:cfgbool("flip_board") then
            self.cfg.flip_board = false
            self:_emit("persist", {kind="persist", key="flip_board", value=false})
        end
        return
    end
    self.cfg.flip_board = not self:cfgbool("flip_board")
    self:_emit("persist", { kind = "persist", key = "flip_board",
                            value = self:cfgbool("flip_board") })
end

function Arbiter:_onEngineRestart()
    -- Diagnostics "Restart engine": the subprocess is being torn down and
    -- respawned. Clear the outstanding search (the old process can no
    -- longer answer it) and drop back to "starting"; the next uciok
    -- re-arms options and drains any pending launch.
    self:_stopSearch()
    self.engine_state = "starting"
    self.pending_launch = nil
    self.thinking = false
end

function Arbiter:_onEngineReady()
    self.engine_state = "ready"
    local options = {
        { name = "Hash", value = "8" },
        { name = "Threads", value = "1" },
        { name = "Skill Level", value = tostring(self.cfg.skill_level or 0) },
        { name = "Move Overhead", value = "150" },
        { name = "Ponder", value = "false" },
        { name = "Slow Mover", value = "90" },
        { name = "MultiPV", value = "1" },
    }
    for _, opt in ipairs(options) do
        self:_emit("uci", { kind = "uci", cmd = "setoption", name = opt.name, value = opt.value })
    end
    self:_emit("uci", { kind = "uci", cmd = "ucinewgame" })
    self.pending_launch = nil
end

function Arbiter:_onEngineInfo(line)
    local info = Eval.parseInfo(line)
    if info then
        local turn = self._pending_turn or self.game:turn()
        if info.mate ~= nil then
            self._pending = { cp = nil, mate = Eval.toWhitePerspective(info.mate, turn) }
        else
            self._pending = { cp = Eval.toWhitePerspective(info.cp, turn), mate = nil }
        end
    end
    if self:cfgbool("show_hints") and self.search and self.search.kind == "analysis" then
        local pv = Eval.parsePv(line)
        if pv then
            local turn = self._pending_turn or self.game:turn()
            self._hint_pvs = self._hint_pvs or {}
            self._hint_pvs[pv.multipv] = {
                move = pv.move,
                cp   = pv.cp ~= nil and Eval.toWhitePerspective(pv.cp, turn) or nil,
                mate = pv.mate ~= nil and Eval.toWhitePerspective(pv.mate, turn) or nil,
            }
        end
    end
end

function Arbiter:_onEngineBestmove(id, move_uci)
    local s = self.search
    if not s or s.id ~= id then return end

    self:_cancel(self._search_wd)
    self._search_wd = nil
    self:_cancel(self._think_r)
    self._think_r = nil
    self:_cancel(self._search_giveup)
    self._search_giveup = nil

    if s.kind == "analysis" then
        if s.ply ~= #(self.game:sanHistory()) then self._hint_pvs = nil end
        self:_commitEval(s.ply)
        self.search = nil
        self.thinking = false
        return
    end

    self:_commitEval(s.ply)
    self.search = nil
    self.thinking = false
    self._pending_turn = nil

    local elapsed = self:_now() - s.started_at
    local delay = math.max(0, MIN_ENGINE_MOVE_DELAY - elapsed)
    if delay > 0.05 then
        local token = self:_schedule(delay, function()
            self.move_pending = nil
            self:_applyPendingMove(move_uci)
        end)
        self.move_pending = { move = move_uci, token = token }
    else
        self.move_pending = nil
        self:_applyPendingMove(move_uci)
    end
end

function Arbiter:_onEngineFailed(reason)
    self:_stopSearch()
    self.engine_state = "failed"
    self.running = false
    self.thinking = false
    self.pending_launch = nil
    if self.clock then self.clock:stop() end
    self:_emit("announce", { kind = "announce", announce_kind = "engine_failed",
                             text = reason or "Engine process failed." })
end

function Arbiter:_onScheduled(token)
    local fn = self._timers[token]
    if not fn then return end
    self._timers[token] = nil
    fn()
end

function Arbiter:_onSaveRequested()
    self:_emit("persist", { kind = "persist", key = "saved_pgn", value = self.game:pgn() })
    if self.clock then
        self:_emit("persist", { kind = "persist", key = "saved_time_white",
                                value = self.clock:remaining(WHITE) })
        self:_emit("persist", { kind = "persist", key = "saved_time_black",
                                value = self.clock:remaining(BLACK) })
    end
    self:_emit("persist", { kind = "persist", key = "saved_running", value = self.running })
end

-- Transition dispatch --------------------------------------------------------

--- The transition funnel. Every flow funnels through here.
-- Returns the canonical-ordered effect list the App performs.
function Arbiter:transition(event)
    assert(type(event) == "table", "arbiter: transition needs an event table")
    self:_newEffects()
    local kind = event.kind

    if kind == "start" then
        self:_onStart(event)
    elseif kind == "resume" then
        self:_onResume()
    elseif kind == "reset" then
        self:_onReset()
    elseif kind == "human_move" then
        if not self:_onHumanMove(event) then
            return self:_finalizeEffects()
        end
    elseif kind == "pgn_loaded" then
        self:_onPgnLoaded(event)
    elseif kind == "undo" then
        self:_onUndoRedo(true, event)
    elseif kind == "redo" then
        self:_onUndoRedo(false, event)
    elseif kind == "settings" then
        self:_onSettings(event.changes)
    elseif kind == "flip_toggle" then
        self:_onFlipToggle()
    elseif kind == "engine_ready" then
        self:_onEngineReady()
    elseif kind == "engine_restart" then
        self:_onEngineRestart()
    elseif kind == "engine_info" then
        self:_onEngineInfo(event.line)
    elseif kind == "engine_bestmove" then
        self:_onEngineBestmove(event.id, event.move)
    elseif kind == "engine_failed" then
        self:_onEngineFailed(event.reason)
    elseif kind == "search_timeout" then
        self:_onEngineFailed(event.detail)
    elseif kind == "scheduled" then
        self:_onScheduled(event.token)
    elseif kind == "save_requested" then
        self:_onSaveRequested()
    else
        error("arbiter: unknown event kind " .. tostring(kind))
    end

    -- Analysis relaunches only when a position was just created with a
    -- human to move (a new ply), never after an analysis commit —
    -- otherwise the engine would loop analysis searches forever.
    local allow_analysis = (kind == "human_move" or kind == "pgn_loaded"
        or kind == "undo" or kind == "redo") and true or false
    self:_afterState(allow_analysis)
    local out = self:_finalizeEffects()
    self._effects = nil
    return out
end

return Arbiter
