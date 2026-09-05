-- Puzzle: the SlatePuzzle state machine — the puzzle-session equivalent of
-- the chess Arbiter.
--
-- Pure Lua (zero KOReader / io / os dependencies) — host-testable like the
-- whole core/ surface. Owns the session: which puzzle is loaded, whose side
-- controls the board, the move-by-move validation against the Lichess
-- solution line (player plies = the odd solution entries, the opponent's
-- auto-played replies = the even ones), wrong-move handling, restart and
-- step navigation, and the settings re-filter.
--
-- Composed, never injected: a real `core.game` Game per puzzle, built from
-- the record's FEN. The only injected impurity is `deps.rng` (used to pick
-- the opening puzzle of a session), matching ADR-0002's Clock/Blunder seam.
--
-- Same contract shape as the Arbiter — one verb, one read, a canonical
-- effect list:
--
--   local p = Puzzle:new(cfg, deps)
--   local fx = p:transition(event)   -- reducer: adopt new state, emit effects
--   local v  = p:view()              -- pure projection
--
-- Wrong-move policy: a wrong move is rejected (counted, exposed in view,
-- position untouched) and the session continues. The FIRST wrong move puts
-- the round into lichess-style try-mode: counted as a miss, the round is no
-- longer rated, but you keep solving (✓/✗ feedback). A single `reveal`
-- event reveals the next expected move as a from→to arrow and also makes
-- the round unrated.

local Game = require("core.game")
local Puzzles = require("core.puzzles")

-- How long before the opponent's auto-reply lands (seconds; passed through
-- to UIManager:scheduleIn, same unit as the Arbiter's delay effects).
local REPLY_DELAY = 1.0

local Puzzle = {}
Puzzle.__index = Puzzle

Puzzle.IDLE    = "idle"
Puzzle.SOLVING = "solving"
Puzzle.SOLVED  = "solved"
Puzzle.EMPTY   = "empty"

function Puzzle:new(cfg, deps)
    cfg = cfg or {}
    deps = deps or {}
    local o = setmetatable({}, self)
    o.bank       = type(cfg.bank) == "table" and cfg.bank or {}
    o.difficulty = cfg.difficulty or nil      -- nil/"any" = no rating filter
    o.adaptive_rating = Puzzles.clampAdaptiveRating(cfg.adaptive_rating)
    o.type       = cfg.type or nil            -- nil/"any"/"random" = no type filter
    o.theme      = cfg.theme or nil           -- nil/"any" = no theme filter (legacy)
    o.resume     = cfg.resume or nil          -- { id = … } | nil
    o.deps = {
        rng = type(deps.rng) == "function" and deps.rng
            or math.random -- luacheck: ignore 143
    }
    o.slice      = {}
    o.index      = 0
    o.record     = nil
    o.game       = nil
    o.solution   = {}
    o.consumed   = 0
    o.replay_cursor = 0
    o.status     = Puzzle.IDLE
    o.side       = Game.WHITE
    o.wrong_attempts = 0
    o.hint_level  = 0
    o.hint_used   = false
    o.missed_first = false
    o.last_wrong = nil
    o.last_san   = nil
    o.last_mover = nil
    o.reply_token = nil
    o.rating_recorded = false
    return o
end

--- Rebuilds the filtered slice from the current difficulty/type/theme.
function Puzzle:applyFilter()
    local lo, hi
    if self.difficulty == "adaptive" then
        lo, hi = Puzzles.adaptiveRange(self.adaptive_rating)
    else
        lo, hi = Puzzles.bandRange(self.difficulty)
    end
    self.slice = Puzzles.filter(self.bank, {
        rating_min = lo,
        rating_max = hi,
        type       = self.type,
        theme      = self.theme,
    })
end

--- Absolute material balance on `game` from `color`'s point of view.
local PIECE_VALUES = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 0 }

local function materialDiff(game, color)
    local diff = 0
    for _, row in ipairs(game:board() or {}) do
        for _, sq in ipairs(row) do
            if sq and sq.type and sq.color then
                local v = PIECE_VALUES[sq.type] or 0
                diff = diff + (sq.color == color and v or -v)
            end
        end
    end
    return diff
end

local function recentPlies(rec, sans)
    local active, fullmove = (rec.fen or ""):match("^%S+%s+(%a)%s+%S+%s+%S+%s+%S+%s+(%d+)")
    fullmove = tonumber(fullmove) or 1
    local out, first = {}, math.max(1, #sans-1)
    for i=first,#sans do
        local white = (active=="w" and i%2==1) or (active=="b" and i%2==0)
        local n = active=="w" and (fullmove+math.floor((i-1)/2))
            or (fullmove+math.floor(i/2))
        out[#out+1] = n .. (white and ". " or "... ") .. sans[i]
    end
    return table.concat(out,"  ")
end

--- False when replaying the recorded line leaves the SOLVER clearly worse
-- (checkmated, drawing, or down ≥ 2 pawns). Such corrupt/reversed rows
-- would otherwise make the app announce "Solved!" after a loss, so they
-- are skipped exactly like illegal lines.
local function outcomeOk(probe, solver)
    local st = probe:status()
    if st.over then
        if st.result == "1/2-1/2" then return false end
        local white_won = st.result == "1-0"
        return (solver == Game.WHITE and white_won)
            or (solver == Game.BLACK and not white_won)
    end
    return materialDiff(probe, solver) >= -1
end

--- Builds a playable Game at a record's initial position, validates the
--- full recorded line against the rules engine, sets the roles (the puzzle's
--- SOLVER — the side opposite the FEN's active color on real DB rows — is
--- the human), and returns `game, solution`. Returns nil when the FEN, any
--- move, or the line's outcome is bad (a corrupt/dropped-in record —
--- skipped, never fatal).
--
-- Real Lichess rows: `moves` = [opponent's lead-in blunder] + the solver's
-- winning sequence. The lead-in blunder is applied when the game is built
-- so the board starts exactly where the puzzle starts on lichess.org
-- (after the opponent's losing move, solver to move). The returned
-- `solution` is the interactive alternating list (solver first).
local function buildGame(rec)
    local tokens = Puzzles.tokens(rec)
    if #tokens == 0 then return nil end

    local ok_probe, probe = pcall(function()
        return Game:new{ fen = rec.fen }
    end)
    if not ok_probe or not probe then return nil end
    local fen_side = probe:turn()

    -- Determine the layout + the solver from the recorded line.
    local blunder, solution, solver
    local candidate_blunder = Puzzles.blunder(rec)
    if candidate_blunder and probe:playUci(candidate_blunder) then
        blunder  = candidate_blunder
        solution = Puzzles.solution(rec)
        solver   = fen_side == Game.WHITE and Game.BLACK or Game.WHITE
    else
        blunder  = nil
        solution = Puzzles.solution(rec)
        solver   = fen_side
    end
    if #solution == 0 then return nil end

    -- Replay the full recorded line for legality and outcome.
    local ok_full, full = pcall(function()
        return Game:new{ fen = rec.fen }
    end)
    if not ok_full or not full then return nil end
    for _, uci in ipairs(tokens) do
        if not full:playUci(uci) then return nil end
    end
    if not outcomeOk(full, solver) then return nil end

    -- The live game for the app: start after the lead-in blunder if any.
    local ok_fresh, fresh = pcall(function()
        return Game:new{ fen = rec.fen }
    end)
    if not ok_fresh or not fresh then return nil end
    if blunder then
        if not fresh:playUci(blunder) then return nil end
    end
    fresh:setHuman(solver, true)
    fresh:setHuman(solver == Game.WHITE and Game.BLACK or Game.WHITE, false)
    return fresh, solution
end

--- Loads slice[index] as the current puzzle (fresh, consumed = 0).
-- Returns false when the record can't build a game or the slice is empty;
-- the session then skips past it (the App/spec decides what to do).
function Puzzle:_loadAt(index)
    if index < 1 or index > #self.slice then return false end
    local rec = self.slice[index]
    local game, solution = buildGame(rec)
    if not game then return false end
    self.index       = index
    self.record      = rec
    self.game        = game
    self.solution    = solution
    self.consumed    = 0
    self.replay_cursor = 0
    self.status      = Puzzle.SOLVING
    self.side        = game:turn()
    self.wrong_attempts = 0
    self.hint_level  = 0
    self.hint_used   = false
    self.missed_first = false
    self.last_wrong  = nil
    self.last_san    = nil
    self.last_mover  = nil
    self.reply_token = nil
    self.rating_recorded = false
    return true
end

--- Score an adaptive round exactly once. A clean solve is a win; solving
-- after a mistake/hint (or abandoning with Next/Previous) is a loss.
-- Persistence stays an App effect so the pure state machine never does I/O.
function Puzzle:_recordAdaptive(score)
    if self.difficulty ~= "adaptive" or self.rating_recorded or not self.record then
        return nil
    end
    self.rating_recorded = true
    self.adaptive_rating = Puzzles.updateAdaptiveRating(
        self.adaptive_rating, self.record.r, score)
    return { kind = "persist", key = "puzzle_adaptive_rating",
        value = self.adaptive_rating }
end

function Puzzle:_completeEffects()
    self.status = Puzzle.SOLVED
    self.reply_token = nil
    local fx = {
        { kind = "repaint", target = "board" },
        { kind = "repaint", target = "status" },
    }
    local rating = self:_recordAdaptive(
        (not self.hint_used and not self.missed_first) and 1 or 0)
    if rating then fx[#fx + 1] = rating end
    fx[#fx + 1] = { kind = "announce", announce_kind = "solved" }
    return fx
end

--- Invalidates any pending reply timer (the token the App holds) and, when
--- `pump`, emits the cancel effect for it. Returns the leading effect list.
function Puzzle:_killPendingReply(pump)
    local fx = {}
    if self.reply_token then
        if pump then
            fx[#fx + 1] = { kind = "cancel", token = self.reply_token }
        end
        self.reply_token = nil
    end
    return fx
end

-- SAN of the most recently played move, from the game's own history.
function Puzzle:_snapLastMove()
    local sans = self.game:sanHistory()
    return sans[#sans]
end

--- The side that just moved was the previous turn.
function Puzzle:recordLastMove()
    self.last_san   = self:_snapLastMove()
    self.last_mover = self.game:turn()
end

-- Events --------------------------------------------------------------------

function Puzzle:transition(event)
    event = event or {}
    local kind = event.kind
    if kind == "start" then
        return self:onStart()
    elseif kind == "select" then
        return self:onSelect(event.index)
    elseif kind == "next" then
        return self:onStep(1)
    elseif kind == "prev" then
        return self:onStep(-1)
    elseif kind == "human_move" then
        return self:onHumanMove(event)
    elseif kind == "hint" or kind == "reveal" then
        return self:onHint()
    elseif kind == "replay" then
        return self:onReplay(event.direction)
    elseif kind == "scheduled" then
        return self:onScheduled(event.token)
    elseif kind == "restart" then
        return self:onRestart()
    elseif kind == "settings" then
        return self:onSettings(event.changes)
    end
    return {}
end

function Puzzle:onStart()
    self:applyFilter()
    local fx = {}
    if #self.slice == 0 then
        self.status = Puzzle.EMPTY
        self.record, self.game, self.index = nil, nil, 0
        fx[#fx + 1] = { kind = "announce", announce_kind = "error",
            text = "No puzzles match these settings." }
        fx[#fx + 1] = { kind = "repaint", target = "all" }
        return fx
    end
    -- Resume the last puzzle when it's still in the slice; else a uniform
    -- fresh draw.
    local idx
    if self.resume and self.resume.id then
        for i, rec in ipairs(self.slice) do
            if rec.id == self.resume.id then idx = i; break end
        end
    end
    if not idx then
        idx = math.floor(self.deps.rng() * #self.slice) + 1
    end
    if self:_loadAt(idx) then
        fx[#fx + 1] = { kind = "repaint", target = "all" }
    else
        -- The drawn record failed to build: walk forward to the first good one.
        for offset = 1, #self.slice do
            local i = ((idx - 1 + offset - 1) % #self.slice) + 1
            if self:_loadAt(i) then
                fx[#fx + 1] = { kind = "repaint", target = "all" }
                break
            end
        end
        if not self.record then
            self.status = Puzzle.EMPTY
            self.game   = nil
            fx[#fx + 1] = { kind = "announce", announce_kind = "error",
                text = "No playable puzzles in this set." }
            fx[#fx + 1] = { kind = "repaint", target = "all" }
        end
    end
    return fx
end

function Puzzle:onSelect(index)
    if not index or index < 1 or index > #self.slice then return {} end
    local fx = self:_killPendingReply(true)
    if self:_loadAt(index) then
        fx[#fx + 1] = { kind = "repaint", target = "all" }
    end
    return fx
end

function Puzzle:onStep(dir)
    local n = #self.slice
    if n == 0 then return {} end
    local fx = self:_killPendingReply(true)
    if self.status == Puzzle.SOLVING then
        local rating = self:_recordAdaptive(0)
        if rating then fx[#fx + 1] = rating end
    end
    if self.difficulty == "adaptive" then self:applyFilter() end
    local idx = ((self.index - 1 + dir) % n) + 1
    if self:_loadAt(idx) then
        fx[#fx + 1] = { kind = "repaint", target = "all" }
    end
    return fx
end

--- Reveal the next expected move. One-shot per puzzle: the round stops
-- being rated the moment the solver asks. The App renders the from→to
-- arrow from the view and may auto-play the move on a second tap.
function Puzzle:onHint()
    if self.status ~= Puzzle.SOLVING or self.reply_token
            or self.replay_cursor ~= self.consumed then return {} end
    local expected = self.solution[self.consumed + 1]
    if not expected then return {} end
    self.hint_used = true
    local rating = self:_recordAdaptive(0)
    if self.hint_level > 0 then
        self.hint_level = 0
        return self:onHumanMove{
            from=expected:sub(1,2), to=expected:sub(3,4),
            promotion=expected:sub(5),
        }
    end
    self.hint_level = 1
    local fx = {
        { kind = "repaint", target = "board" },
        { kind = "repaint", target = "status" },
    }
    if rating then fx[#fx + 1] = rating end
    return fx
end

function Puzzle:onHumanMove(event)
    if self.status ~= Puzzle.SOLVING
            or self.replay_cursor ~= self.consumed then return {} end
    local expected = self.solution[self.consumed + 1]
    if not expected then
        -- Invariant guard: solving with nothing more to play means solved.
        return self:_completeEffects()
    end

    local candidate = event.from .. event.to .. (event.promotion or "")
    local side_before = self.game:turn()
    local played
    if candidate == expected then
        played = self.game:playUci(expected)
    end
    if not played then
        -- Wrong move (or an unplayable one): rejected, session continues.
        -- Lichess behaviour on the FIRST ply: the round is no longer rated
        -- (try-mode — count the miss, keep solving for feedback).
        self.wrong_attempts = self.wrong_attempts + 1
        self.missed_first = true
        self.hint_level = 0
        self.last_wrong   = { from = event.from, to = event.to, expected = expected }
        local fx = { { kind = "repaint", target = "status" } }
        local rating = self:_recordAdaptive(0)
        if rating then fx[#fx + 1] = rating end
        return fx
    end

    self.consumed = self.consumed + 1
    self.replay_cursor = self.consumed
    self.hint_level = 0
    self.last_wrong = nil
    self.last_san   = self:_snapLastMove()
    self.last_mover = side_before

    if self.consumed >= #self.solution then
        return self:_completeEffects()
    end

    -- The opponent answers automatically: schedule the reply, then hand the
    -- board back to the player.
    local token = tostring(self:newId())
    self.reply_token = token
    return {
        { kind = "schedule", token = token, delay = REPLY_DELAY },
        { kind = "repaint", target = "board" },
        { kind = "repaint", target = "status" },
    }
end

function Puzzle:onScheduled(token)
    if token ~= self.reply_token then return {} end
    self.reply_token = nil
    if self.status ~= Puzzle.SOLVING then return {} end
    local reply = self.solution[self.consumed + 1]
    if not reply then return {} end
    local side_before = self.game:turn()
    if not self.game:playUci(reply) then
        -- Bank corruption mid-line: can't continue this puzzle.
        self.status = Puzzle.SOLVED
        local fx = {{ kind="announce", announce_kind="error",
            text="This puzzle's solution is broken — skipping." }}
        for _, e in ipairs(self:onStep(1)) do fx[#fx+1] = e end
        return fx
    end
    self.consumed = self.consumed + 1
    self.replay_cursor = self.consumed
    self.last_san   = self:_snapLastMove()
    self.last_mover = side_before
    if self.consumed >= #self.solution then
        return self:_completeEffects()
    end
    return {
        { kind = "repaint", target = "board" },
        { kind = "repaint", target = "status" },
    }
end

--- Read-only navigation through completed solution plies. The lead-in
-- blunder is the cursor-zero baseline and is never undone.
function Puzzle:onReplay(direction)
    if not self.game or self.reply_token then return {} end
    direction = tonumber(direction) or 0
    if direction < 0 then
        if self.replay_cursor <= 0 or not self.game:undo() then return {} end
        self.replay_cursor = self.replay_cursor - 1
    elseif direction > 0 then
        if self.replay_cursor >= self.consumed or not self.game:redo() then return {} end
        self.replay_cursor = self.replay_cursor + 1
    else
        return {}
    end
    self.hint_level = 0
    return {
        { kind="repaint", target="board" },
        { kind="repaint", target="status" },
    }
end

function Puzzle:onRestart()
    if not self.record then return {} end
    local fx = self:_killPendingReply(true)
    if self:_loadAt(self.index) then
        fx[#fx + 1] = { kind = "repaint", target = "all" }
    end
    return fx
end

function Puzzle:onSettings(changes)
    changes = changes or {}
    local filter_changed = false
    if changes.difficulty and changes.difficulty ~= (self.difficulty or "any") then
        self.difficulty = changes.difficulty
        filter_changed = true
    end
    if changes.type and changes.type ~= (self.type or "any") then
        self.type = changes.type
        filter_changed = true
    end
    if changes.theme and changes.theme ~= (self.theme or "any") then
        self.theme = changes.theme
        filter_changed = true
    end
    self:applyFilter()
    local fx = self:_killPendingReply(true)
    if #self.slice == 0 then
        self.status = Puzzle.EMPTY
        self.record, self.game, self.index = nil, nil, 0
        fx[#fx + 1] = { kind = "repaint", target = "all" }
        fx[#fx + 1] = { kind = "announce", announce_kind = "error",
            text = "No puzzles match these settings." }
        return fx
    end
    if filter_changed then
        -- A filter axis changed: draw a fresh random puzzle from the new
        -- slice (so picking a type drops you straight into that type).
        local idx = math.floor(self.deps.rng() * #self.slice) + 1
        for offset = 0, #self.slice - 1 do
            local i = ((idx - 1 + offset) % #self.slice) + 1
            if self:_loadAt(i) then
                fx[#fx + 1] = { kind = "repaint", target = "all" }
                return fx
            end
        end
        self.status = Puzzle.EMPTY
        self.record, self.game, self.index = nil, nil, 0
        fx[#fx + 1] = { kind = "repaint", target = "all" }
        return fx
    end
    -- No filter axis changed: keep the current puzzle if it still matches
    -- the filter (fresh), else jump to the first.
    if self.record then
        for i, rec in ipairs(self.slice) do
            if rec.id == self.record.id then
                if self:_loadAt(i) then
                    fx[#fx + 1] = { kind = "repaint", target = "all" }
                    return fx
                end
                break
            end
        end
    end
    for offset = 1, #self.slice do
        local i = ((1 - 1 + offset - 1) % #self.slice) + 1
        if self:_loadAt(i) then
            fx[#fx + 1] = { kind = "repaint", target = "all" }
            return fx
        end
    end
    return fx
end

-- Tokens ----------------------------------------------------------------

Puzzle._next_token = 0
function Puzzle.newId()
    Puzzle._next_token = Puzzle._next_token + 1
    return Puzzle._next_token
end

-- View --------------------------------------------------------------------

--- Pure projection: everything the App renders, mapped from state fresh on
--- every call.
function Puzzle:view()
    local rec = self.record
    local v = {
        status = self.status,
        index  = self.index,
        total  = #self.slice,
    }
    if rec and self.game then
        v.puzzle_id     = rec.id
        v.rating        = rec.r
        v.themes        = rec.t
        v.difficulty    = self.difficulty
        v.adaptive_rating = self.adaptive_rating
        v.type          = self.type
        v.type_label    = self.type and Puzzles.types().label(self.type) or nil
        v.theme         = self.theme
        -- The side the puzzle faces (fixed for the duration of the puzzle:
        -- the player sits at the bottom, lichess-style).
        v.player_side   = self.side
        v.flipped       = self.side == Game.BLACK
        v.to_move       = self.game:turn()
        v.consumed      = self.consumed
        v.replay_cursor = self.replay_cursor
        v.reviewing     = self.replay_cursor ~= self.consumed
        v.can_replay_back = self.reply_token == nil and self.replay_cursor > 0
        v.can_replay_forward = self.reply_token == nil
            and self.replay_cursor < self.consumed
        v.solution_length = #self.solution
        v.wrong_attempts  = self.wrong_attempts
        v.hint_level      = self.hint_level
        v.hint_used       = self.hint_used
        v.revealed        = self.hint_level > 0
        v.missed_first    = self.missed_first
        v.rated           = not self.hint_used and not self.missed_first
        v.input_enabled   = self.status == Puzzle.SOLVING
            and self.reply_token == nil and not v.reviewing
            and self.game:turn() == self.side
        if v.reviewing then v.feedback = "review"
        elseif self.status == Puzzle.SOLVED then v.feedback = "solved"
        elseif self.last_wrong then v.feedback = "try_again"
        elseif self.reply_token then v.feedback = "best_move"
        else v.feedback = "your_move" end
        v.last_wrong      = self.last_wrong
        v.last_san        = self.last_san
        v.last_mover      = self.last_mover
        v.san             = self.game:sanHistory()
        v.recent_plies    = recentPlies(rec, v.san)
        v.fen             = self.game:fen()
        v.game            = self.game
        -- The pending SOLVER move: UCI, plus from/to squares for the reveal
        -- highlight. Only exposed when the solver is actually to move —
        -- never during the opponent's pending reply (the revealed hint must
        -- always point at the solver's own piece).
        local expected = self.solution[self.consumed + 1]
        if expected and v.input_enabled then
            v.expected = expected
            v.hint = {
                from = expected:sub(1, 2),
                to   = expected:sub(3, 4),
                promotion = expected:sub(5),
            }
        end
        local Types = Puzzles.types()
        local random = not self.type or self.type == "any" or self.type == "random"
        if random then
            v.type_label = self.status == Puzzle.SOLVED
                and Types.principal(rec.t) or Types.phase(rec.t)
        else
            v.type_label = Types.label(self.type)
        end
    end
    return v
end

--- The current puzzle's id (nil when none) — used by the App to persist
--- the resume position.
function Puzzle:currentId()
    return self.record and self.record.id or nil
end

--- The solution tokens not yet consumed (public, for reveal later).
function Puzzle:remainingSolution()
    local out = {}
    for i = self.consumed + 1, #self.solution do
        out[#out + 1] = self.solution[i]
    end
    return out
end

return Puzzle
