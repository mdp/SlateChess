-- Tests for core.arbiter — the game-flow orchestrator and derived-state owner.
--
-- Driven through the same seam as production: real Game/Clock/Blunder
-- (composed, never injected), a stepped `now`, a scripted `rng`, and manual
-- `scheduled` re-entry. Two assertions per flow: the emitted canonical-ordered
-- effect list, and the projected view model. We never reach for machine
-- internals beyond the public surface (`ar.game`, `ar.clock`, `ar.blunderer`,
-- `ar.cfg`, `ar:view()`, `ar:transition()`).

local Arbiter = require("core.arbiter")

local MIN_ENGINE_MOVE_DELAY = 1

-- Canonical effect order from the contract.
local ORDER = { "persist", "uci", "cancel", "schedule", "repaint", "announce" }
local function rank(kind)
    for i, k in ipairs(ORDER) do
        if k == kind then return i end
    end
    return 99
end

-- Harness: real module, deterministic now + scripted rng.
local function makeHarness(overrides, rng_values)
    local clock_now = 1000.0
    local rng_index = 0
    local cfg = {}
    for k, v in pairs(overrides or {}) do cfg[k] = v end
    local ar = Arbiter:new(cfg, {
        now = function() return clock_now end,
        rng = function()
            rng_index = rng_index + 1
            local v = rng_values and rng_values[rng_index]
            return v ~= nil and v or 0.5
        end,
    })
    return ar, { advance = function(dt) clock_now = clock_now + dt end }
end

-- Effect list helpers.
local function goEffects(fx)
    local out = {}
    for _, e in ipairs(fx) do
        if e.kind == "uci" and e.cmd == "go" then out[#out + 1] = e end
    end
    return out
end

local function firstGo(fx)
    return goEffects(fx)[1]
end

local function uciIndex(fx, cmd)
    for i, e in ipairs(fx) do
        if e.kind == "uci" and e.cmd == cmd then return i end
    end
    return nil
end

local function scheduleWithDelay(fx, delay)
    for _, e in ipairs(fx) do
        if e.kind == "schedule" and e.delay == delay then return e end
    end
    return nil
end

local function repaintTargets(fx)
    local out = {}
    for _, e in ipairs(fx) do
        if e.kind == "repaint" then out[#out + 1] = e.target end
    end
    return out
end

local function hasTarget(fx, target)
    for _, t in ipairs(repaintTargets(fx)) do
        if t == target then return true end
    end
    return false
end

local function announces(fx)
    local out = {}
    for _, e in ipairs(fx) do
        if e.kind == "announce" then out[#out + 1] = e end
    end
    return out
end

local function persists(fx)
    local out = {}
    for _, e in ipairs(fx) do
        if e.kind == "persist" then out[#out + 1] = e end
    end
    return out
end

-- Standard move search: engine_ready, human e2-e4, capture the go, return
-- { go = go, ar = ar, tick = control }.
local function readyHumanOpens(overrides)
    local ar, tick = makeHarness(overrides)
    ar:transition({ kind = "engine_ready" })
    local fx = ar:transition({ kind = "human_move", from = "e2", to = "e4" })
    local go = firstGo(fx)
    assert(type(go) == "table", "expected a go effect after e2-e4")
    return { ar = ar, tick = tick, go = go }
end

describe("Arbiter", function()
    describe("construction", function()
        it("defaults to untimed human-white vs computer-black, starting, not flipped", function()
            local ar = makeHarness()
            local v = ar:view()
            assert.is_nil(v.clock_times)
            assert.equals("starting", v.engine_state)
            assert.is_false(v.running)
            assert.is_false(v.engine_should_move)
            assert.equals("w", v.face_color)
            assert.is_false(v.flipped)
            assert.is_true(v.white_at_bottom)
            assert.is_false(v.can_undo)
            assert.is_false(v.can_redo)
        end)

        it("timed cfg composes a clock at base remaining 900/900", function()
            local ar = makeHarness({ timed = true })
            assert.is_not_nil(ar.clock)
            assert.equals(900, ar.clock:remaining("w"))
            assert.equals(900, ar.clock:remaining("b"))
            assert.same({ white = 900, black = 900 }, ar:view().clock_times)
            assert.equals("w", ar.clock.turn)
        end)

        it("explicit false roles are honored (tight isBool pass-through)", function()
            local ar = makeHarness({ human_white = false, human_black = true, timed = false })
            assert.is_false(ar.game:isHuman("w"))
            assert.is_true(ar.game:isHuman("b"))
            assert.is_false(ar.game:isHumanVsHuman())
            assert.is_true(ar.game:isHumanVsComputer())
            assert.is_nil(ar.clock)
        end)
    end)

    describe("engine readiness", function()
        it("emits no go while a human is to move (history 0)", function()
            local ar = makeHarness()
            local fx = ar:transition({ kind = "engine_ready" })
            assert.equals("ready", ar:view().engine_state)
            assert.equals(0, #(goEffects(fx)))
            assert.equals(0, #(ar.game:sanHistory()))
            assert.is_false(ar:view().engine_should_move)
        end)

        it("computer on move launches position-then-go on engine_ready", function()
            local ar = makeHarness({ human_white = false, human_black = true })
            local fx = ar:transition({ kind = "engine_ready" })
            local go = firstGo(fx)
            assert.is_not_nil(go)
            assert.equals("search", go.go_kind)
            assert.is_not_nil(go.id)
            local pos = uciIndex(fx, "position")
            local goi = uciIndex(fx, "go")
            assert.is_not_nil(pos)
            assert.is_not_nil(goi)
            assert.is_true(pos < goi, "position uci must precede the go effect")
        end)
    end)

    describe("human move hot path", function()
        it("plays e4, emits one search go, repaints board+notation, goes running", function()
            local ar = makeHarness()
            ar:transition({ kind = "engine_ready" })
            local fx = ar:transition({ kind = "human_move", from = "e2", to = "e4" })
            assert.same({ "e4" }, ar.game:sanHistory())
            local gos = goEffects(fx)
            assert.equals(1, #gos)
            assert.equals("search", gos[1].go_kind)
            assert.is_true(ar:view().running)
            assert.is_true(ar:view().engine_should_move)
            assert.is_nil(ar:view().game_over)
            assert.is_true(hasTarget(fx, "board"))
            assert.is_true(hasTarget(fx, "notation"))
            assert.is_false(hasTarget(fx, "layout"))
            assert.is_false(hasTarget(fx, "clocks"))
            -- Effects arrive in canonical order, order preserved within kind.
            local prev = 0
            for _, e in ipairs(fx) do
                local r = rank(e.kind)
                assert.is_true(r >= prev, "effect kinds must be canonical-ordered")
                prev = r
            end
        end)

        it("rejects illegal moves with history 0 and not running", function()
            local ar = makeHarness()
            ar:transition({ kind = "engine_ready" })
            ar:transition({ kind = "human_move", from = "e2", to = "e5" })
            assert.equals(0, #(ar.game:sanHistory()))
            assert.is_false(ar:view().running)
            assert.is_false(ar:view().engine_should_move)
        end)
    end)

    describe("engine reply and eval", function()
        it("applies the engine's move on the MIN_ENGINE_MOVE_DELAY schedule and hands the human an analysis", function()
            local h = readyHumanOpens()
            local ar, tick, go = h.ar, h.tick, h.go
            local fx = ar:transition({ kind = "engine_bestmove", id = go.id, move = "e7e5" })
            -- The move is not applied yet; it waits on the 1.0s pace.
            assert.same({ "e4" }, ar.game:sanHistory())
            assert.is_true(ar:view().engine_should_move)
            local move_tok = scheduleWithDelay(fx, MIN_ENGINE_MOVE_DELAY)
            assert.is_not_nil(move_tok, "expected a 1s move-apply schedule")
            tick.advance(MIN_ENGINE_MOVE_DELAY)
            local fx2 = ar:transition({ kind = "scheduled", token = move_tok.token })
            assert.same({ "e4", "e5" }, ar.game:sanHistory())
            assert.equals("w", ar.game:turn())
            assert.is_true(ar:view().running)
            -- Parity with the pre-arbiter app: the landed engine move
            -- leaves the human to move, so the background analysis
            -- relaunches (onMoveExecuted -> launchAnalysis) -- never
            -- another move search.
            local go2 = firstGo(fx2)
            assert.is_not_nil(go2, "analysis relaunches after the engine's move")
            assert.equals("analysis", go2.go_kind)
        end)

        it("commits the search eva as white-perspective +0.42 with a notation repaint", function()
            local h = readyHumanOpens()
            local ar, go = h.ar, h.go
            ar:transition({ kind = "engine_info",
                line = "info depth 6 multipv 1 score cp -42 pv e7e5" })
            local fx = ar:transition({ kind = "engine_bestmove", id = go.id, move = "e7e5" })
            assert.equals("+0.42", ar:view().eval_text)
            assert.is_true(hasTarget(fx, "notation"))
        end)

        it("feeding engine_info never emits a second go while search is outstanding", function()
            local h = readyHumanOpens()
            local ar = h.ar
            -- Each new info line while the search is outstanding produces
            -- no go (the one-go-at-a-time rule); the engine machinery never
            -- relaunches a like-kind search on its own.
            assert.equals(0, #(goEffects(ar:transition({ kind = "engine_info",
                line = "info depth 5 score cp 12 pv e7e5" }))))
            assert.equals(0, #(goEffects(ar:transition({ kind = "engine_info",
                line = "info depth 6 score cp -8 currmove e7e5" }))))
        end)
    end)

    describe("live-bug regression pins", function()
        it("pgn_loaded with the computer to move launches a search go", function()
            local ar = makeHarness() -- human white, computer black
            ar:transition({ kind = "engine_ready" })
            local fx = ar:transition({ kind = "pgn_loaded", pgn = "1. e4 e5 2. Nf3" })
            assert.same({ "e4", "e5", "Nf3" }, ar.game:sanHistory())
            local go = firstGo(fx)
            assert.is_not_nil(go, "computer to move after PGN load must go")
            assert.equals("search", go.go_kind)
            assert.is_true(ar:view().running)
        end)

        it("pgn_loaded before engine_ready sits pending, drained on ready", function()
            local ar = makeHarness()
            local fx = ar:transition({ kind = "pgn_loaded", pgn = "1. e4 e5 2. Nf3" })
            assert.same({ "e4", "e5", "Nf3" }, ar.game:sanHistory())
            assert.equals(0, #(goEffects(fx)), "no go while the engine handshake is incomplete")
            local fx2 = ar:transition({ kind = "engine_ready" })
            local go = firstGo(fx2)
            assert.is_not_nil(go, "pending launch drains on engine_ready")
            assert.equals("search", go.go_kind)
        end)

        it("roles-only settings preserve clock remaining (no clock wipe)", function()
            local ar, tick = makeHarness({ timed = true })
            assert.is_not_nil(ar.clock)
            ar:transition({ kind = "engine_ready" })
            ar:transition({ kind = "human_move", from = "e2", to = "e4" })
            tick.advance(30)
            assert.equals(870, ar:view().clock_times.black)
            -- Roles-only: both human now; the clock is preserved, not re-based.
            ar:transition({ kind = "settings", changes = { human_black = true } })
            assert.is_not_nil(ar.clock)
            assert.equals(870, ar:view().clock_times.black)
            assert.equals(900, ar:view().clock_times.white)
        end)

        it("difficulty preset mid-game reaches the blunder and persists", function()
            local ar = makeHarness()
            assert.equals(0.20, ar.blunderer.chance)
            local fx = ar:transition({ kind = "settings", changes = { blunder_chance = 1.0 } })
            assert.equals(1.0, ar.blunderer.chance)
            local found = false
            for _, p in ipairs(persists(fx)) do
                if p.key == "blunder_chance" then
                    found = true
                    assert.equals(1.0, p.value)
                end
            end
            assert.is_true(found, "blunder_chance must be persisted")
        end)
    end)

    describe("stale search results", function()
        it("undo drops a late bestmove by id", function()
            local h = readyHumanOpens()
            local ar, go = h.ar, h.go
            ar:transition({ kind = "undo", all = false })
            assert.same({}, ar.game:sanHistory())
            local fx = ar:transition({ kind = "engine_bestmove", id = go.id, move = "e7e5" })
            assert.same({}, ar.game:sanHistory(), "stale bestmove must be dropped")
            assert.equals(0, #(goEffects(fx)), "no go for a stale bestmove")
        end)
    end)

    describe("engine move landing", function()
        it("the computer's landed move hands the human an analysis launch", function()
            local h = readyHumanOpens() -- human white opened, computer black searching
            local ar, go, tick = h.ar, h.go, h.tick
            tick.advance(2) -- long enough that the move lands immediately
            local fx = ar:transition({ kind = "engine_bestmove", id = go.id, move = "e7e5" })
            assert.is_nil(ar.move_pending, "fast reply lands in the same transition")
            assert.same({ "e4", "e5" }, ar.game:sanHistory())
            local go2 = firstGo(fx)
            assert.is_not_nil(go2, "human position after the engine move gets analysis")
            assert.equals("analysis", go2.go_kind)
        end)

        it("a delayed engine move lands via the scheduled token and continues", function()
            local h = readyHumanOpens()
            local ar, go, tick = h.ar, h.go, h.tick
            -- No time advanced: the MIN_ENGINE_MOVE_DELAY pause defers the move.
            local fx = ar:transition({ kind = "engine_bestmove", id = go.id, move = "e7e5" })
            assert.is_not_nil(ar.move_pending)
            assert.same({ "e4" }, ar.game:sanHistory())
            local sched = scheduleWithDelay(fx, 1)
            assert.is_not_nil(sched, "move deferral is a 1s schedule")
            tick.advance(1)
            local fx2 = ar:transition({ kind = "scheduled", token = sched.token })
            assert.is_nil(ar.move_pending)
            assert.same({ "e4", "e5" }, ar.game:sanHistory())
            local go2 = firstGo(fx2)
            assert.is_not_nil(go2, "analysis follows the landed engine move")
            assert.equals("analysis", go2.go_kind)
        end)
    end)

    describe("flag-fall forfeit", function()
        it("black flag-fall finishes with White winning, no relaunch, idempotent", function()
            local ar, tick = makeHarness({
                timed = true,
                time_base_white = 1, time_base_black = 1,
                time_incr_white = 0, time_incr_black = 0,
            })
            ar:transition({ kind = "engine_ready" })
            local hfx = ar:transition({ kind = "human_move", from = "e2", to = "e4" })
            -- In a timed game the human move arms the 1s clock ticker.
            local ticker = scheduleWithDelay(hfx, MIN_ENGINE_MOVE_DELAY)
            assert.is_not_nil(ticker, "timed game must arm the 1s clock ticker")
            tick.advance(2)
            local fx = ar:transition({ kind = "scheduled", token = ticker.token })
            local ann = announces(fx)
            assert.equals(1, #ann)
            assert.equals("game_over", ann[1].announce_kind)
            assert.equals("White wins on time.", ann[1].text)
            assert.is_false(ar:view().running)
            assert.is_false(ar:view().engine_should_move)
            assert.is_truthy(ar:view().game_over)
            -- The machine-over latch prevents the search relaunch and any go.
            assert.equals(0, #(goEffects(fx)))
            -- Re-firing the consumed token is a no-op: no relaunch, no announce.
            local fx2 = ar:transition({ kind = "scheduled", token = ticker.token })
            assert.equals(0, #(announces(fx2)))
            assert.equals(0, #(goEffects(fx2)))
            assert.is_false(ar:view().running)
        end)
    end)

    describe("orientation", function()
        it("computer white / human black renders flipped, black at bottom", function()
            local ar = makeHarness({ human_white = false, human_black = true })
            local v = ar:view()
            assert.is_true(v.flipped)
            assert.is_false(v.white_at_bottom)
        end)

        it("hvh keeps a fixed board: no per-turn face pivot, far pieces angle to their side", function()
            local ar = makeHarness({ human_white = true, human_black = true })
            assert.equals("w", ar:view().face_color) -- never pivots, not even when running
            assert.is_true(ar:view().rotate_top_pieces) -- far pieces face their owner
            ar:transition({ kind = "human_move", from = "e2", to = "e4" })
            assert.equals("w", ar:view().face_color) -- still white after white moved
            assert.is_true(ar:view().rotate_top_pieces)
            ar:transition({ kind = "human_move", from = "e7", to = "e5" })
            assert.equals("w", ar:view().face_color) -- still white after black moved
            assert.is_true(ar:view().rotate_top_pieces)
        end)

        it("angles far pieces toward the far human in hvh, but faces the sole human in one-player", function()
            local hvh = makeHarness({ human_white = true, human_black = true,
                rotate_top_pieces = false })
            assert.is_true(hvh:view().rotate_top_pieces)
            local black_human = makeHarness({ human_white = false, human_black = true,
                rotate_top_pieces = true })
            assert.is_false(black_human:view().rotate_top_pieces)
            local white_human = makeHarness({ rotate_top_pieces = true })
            assert.is_false(white_human:view().rotate_top_pieces)
            local pref_off = makeHarness({ rotate_top_pieces = false })
            assert.is_false(pref_off:view().rotate_top_pieces)
        end)

        it("rebuilds layout when role changes swap the computer HUD", function()
            local ar = makeHarness()
            ar:transition({ kind = "start" })
            local fx = ar:transition({ kind = "settings", changes = {
                human_white = false, human_black = true,
            }})
            local found = false
            for _, effect in ipairs(fx) do
                if effect.kind == "repaint" and effect.target == "layout" then found = true end
            end
            assert.is_true(found)
        end)

        it("flip_pieces_each_turn restores the per-turn whole-board pivot in hvh", function()
            local ar = makeHarness({ human_white = true, human_black = true,
                flip_pieces_each_turn = true })
            assert.equals("w", ar:view().face_color) -- not running yet
            assert.is_false(ar:view().rotate_top_pieces)
            ar:transition({ kind = "human_move", from = "e2", to = "e4" })
            assert.equals("b", ar:view().face_color) -- pivots toward black to move
            assert.is_false(ar:view().rotate_top_pieces)
            ar:transition({ kind = "human_move", from = "e7", to = "e5" })
            assert.equals("w", ar:view().face_color) -- and back toward white
            assert.is_false(ar:view().rotate_top_pieces)
        end)

        it("flip_toggle visually flips a human-vs-human board", function()
            local ar = makeHarness({human_white=true, human_black=true})
            assert.is_false(ar:view().flipped)
            local fx = ar:transition({ kind = "flip_toggle" })
            assert.is_true(ar:view().flipped)
            assert.is_false(ar:view().white_at_bottom)
            local found = false
            for _, p in ipairs(persists(fx)) do
                if p.key == "flip_board" then
                    found = true
                    assert.is_true(p.value)
                end
            end
            assert.is_true(found, "flip_toggle must persist flip_board")
        end)

        it("flip_toggle swaps one-player roles so the bottom seat stays human", function()
            local ar = makeHarness() -- human White at bottom
            assert.is_true(ar.game:isHuman("w"))
            assert.is_false(ar:view().flipped)
            local fx = ar:transition({kind="flip_toggle"})
            assert.is_false(ar.game:isHuman("w"))
            assert.is_true(ar.game:isHuman("b"))
            assert.is_true(ar:view().flipped)
            local saved = {}
            for _, p in ipairs(persists(fx)) do saved[p.key] = p.value end
            assert.is_false(saved.human_white)
            assert.is_true(saved.human_black)
            assert.is_nil(saved.flip_board)
        end)
    end)

    describe("save_requested", function()
        it("emits the four restore persists (pgn, times, running)", function()
            local ar = makeHarness({ timed = true })
            local fx = ar:transition({ kind = "save_requested" })
            local ps = persists(fx)
            assert.equals(4, #ps)
            local keys = {}
            for _, p in ipairs(ps) do keys[#keys + 1] = p.key end
            assert.is_true(keys[1] == "saved_pgn")
            assert.is_true(keys[2] == "saved_time_white")
            assert.is_true(keys[3] == "saved_time_black")
            assert.is_true(keys[4] == "saved_running")
        end)
    end)

    describe("resume and engine restart", function()
        it("reset auto-launches when a computer opens and the engine is ready", function()
            local ar = makeHarness({ human_white = false, human_black = true })
            ar:transition({ kind = "engine_ready" })
            local fx = ar:transition({ kind = "reset" })
            local go = firstGo(fx)
            assert.is_not_nil(go, "computer-to-move after reset launches directly")
            assert.is_true(ar:view().running)
        end)

        it("resume keeps the game live while the engine is still starting", function()
            local ar = makeHarness({ human_white = false, human_black = true })
            -- engine_state stays "starting": no engine_ready fired.
            local fx = ar:transition({ kind = "reset" })
            assert.is_false(ar:view().running)
            assert.equals(0, #(goEffects(fx)), "no go while the handshake is incomplete")
            local fx2 = ar:transition({ kind = "resume" })
            assert.is_true(ar:view().running)
            assert.equals(0, #(goEffects(fx2)), "no go before engine readiness")
            local fx3 = ar:transition({ kind = "engine_ready" })
            local go = firstGo(fx3)
            assert.is_not_nil(go, "pending launch drains on ready")
            assert.equals("search", go.go_kind)
        end)

        it("resume stays inert when a human is on move after reset", function()
            local ar = makeHarness() -- human white
            ar:transition({ kind = "engine_ready" })
            ar:transition({ kind = "reset" })
            local fx2 = ar:transition({ kind = "resume" })
            assert.is_true(ar:view().running, "resume restores the running flag")
            assert.equals(0, #(goEffects(fx2)), "no search when a human is on move")
        end)

        it("engine_restart clears the outstanding search and drops to starting", function()
            local h = readyHumanOpens() -- human white opened, computer black searching
            local ar = h.ar
            assert.equals("search", ar.search.kind)
            ar:transition({ kind = "engine_restart" })
            assert.is_nil(ar.search, "restart must drop the outstanding search")
            assert.equals("starting", ar:view().engine_state)
            -- A fresh uciok re-arms options and relaunches the computer's search.
            local fx2 = ar:transition({ kind = "engine_ready" })
            local go = firstGo(fx2)
            assert.is_not_nil(go, "engine_ready after restart must relaunch play")
            assert.equals("search", go.go_kind)
        end)
    end)
end)
