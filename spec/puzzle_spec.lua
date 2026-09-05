-- Tests for core.puzzle — the SlatePuzzle session state machine.
--
-- Driven through the same seam as the Arbiter: real Game (composed from
-- the record FEN), a scripted `rng`, and manual `scheduled` re-entry with
-- the exact token the transition emitted. Assertions on the effect list
-- and the projected view model; tests never reach for internals.
--
-- The bank here is deliberately tiny and hand-verified against the rules
-- engine (see spec commentary): a back-rank mate-in-1 for white, the same
-- for black (flipped layout), a 3-ply opening line (reply + second player
-- move), and a promotion line.

local Puzzle = require("core.puzzle")

local BANK = {
    { id = "mate-w", fen = "6k1/5ppp/8/8/8/8/R7/4K3 w - - 0 1",
      moves = "a2a8", r = 1200, t = { "backRankMate" } },
    { id = "mate-b", fen = "1r4k1/8/8/8/8/8/5PPP/7K b - - 0 1",
      moves = "b8b1", r = 1100, t = { "backRankMate" } },
    { id = "flow", fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
      moves = "e2e4 e7e5 g1f3", r = 1000, t = { "opening" } },
    { id = "promo", fen = "4k3/3P4/8/8/8/8/8/4K3 w - - 0 1",
      moves = "d7d8q", r = 2000, t = { "promotion" } },
}

-- rng draws are uniform [0,1): 0 → first puzzle, 0.75 → fourth, etc.
local function mk(cfg, rng)
    return Puzzle:new(cfg or {}, { rng = rng or function() return 0 end })
end

local function rngAt(rate)
    return function() return rate end
end

local function kinds(fx)
    local out = {}
    for _, e in ipairs(fx or {}) do out[#out + 1] = e.kind end
    return out
end

local function find(fx, kind)
    for _, e in ipairs(fx or {}) do
        if e.kind == kind then return e end
    end
    return nil
end

describe("core.puzzle start", function()
    it("answers error announce + repaint when the bank is empty", function()
        local p = mk({ bank = {} }, function() return 0 end)
        local fx = p:transition{ kind = "start" }
        assert.are.equal(Puzzle.EMPTY, p:view().status)
        assert.are.equal("error", find(fx, "announce").announce_kind)
        assert.is_not_nil(find(fx, "repaint"))
    end)

    it("picks the first puzzle with a deterministic rng of 0", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        local fx = p:transition{ kind = "start" }
        local v = p:view()
        assert.are.equal(Puzzle.SOLVING, v.status)
        assert.are.equal(1, v.index)
        assert.are.equal(4, v.total)
        assert.are.equal("mate-w", v.puzzle_id)
        assert.are.equal(1200, v.rating)
        assert.are.same({ "backRankMate" }, v.themes)
        assert.are.same({ "repaint" }, kinds(fx))
        -- The puzzle's side to move (white) is human, opponent computer.
        assert.is_true(v.game:isHuman("w"))
        assert.is_false(v.game:isHuman("b"))
    end)

    it("flips the board for a black-to-move puzzle", function()
        local p = mk({ bank = BANK }, rngAt(0.25)) -- → index 2
        p:transition{ kind = "start" }
        local v = p:view()
        assert.are.equal("mate-b", v.puzzle_id)
        assert.are.equal("b", v.player_side)
        assert.is_true(v.flipped)
        assert.is_true(v.game:isHuman("b"))
    end)

    it("resumes the last puzzle when it is in the slice", function()
        local p = mk({ bank = BANK, resume = { id = "flow" } }, function() return 0 end)
        p:transition{ kind = "start" }
        assert.are.equal("flow", p:view().puzzle_id)
        assert.are.equal(3, p:view().index)
    end)

    it("skips past a corrupt record to the first playable one", function()
        local bank = {
            { id = "broken", fen = "gibberish", moves = "e2e4", r = 1, t = {} },
            { id = "mate-w", fen = BANK[1].fen,  moves = BANK[1].moves, r = BANK[1].r, t = {} },
        }
        local p = mk({ bank = bank }, function() return 0 end)
        p:transition{ kind = "start" }
        assert.are.equal("mate-w", p:view().puzzle_id)
    end)
end)

describe("core.puzzle human_move", function()
    it("numbers the pre-applied blunder from the source FEN", function()
        local bank={{id="blunder",fen="6Qk/p1p3pp/4N3/1p6/2q1r1n1/2B5/PP4PP/3R1R1K b - - 0 28",
            moves="h8g8 f1f8",r=1200,t={"mate"}}}
        local p=mk({bank=bank},function()return 0 end); p:transition{kind="start"}
        assert.matches("28%.%.%.",p:view().recent_plies)
    end)
    it("rejects a wrong move: counted, position untouched, session continues", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        local before = p:view().fen
        local fx = p:transition{ kind = "human_move", from = "a2", to = "a4" }
        local v = p:view()
        assert.are.equal(1, v.wrong_attempts)
        assert.are.same({ from = "a2", to = "a4", expected = "a2a8" }, v.last_wrong)
        assert.are.equal(before, v.fen) -- position untouched
        assert.are.equal(Puzzle.SOLVING, v.status)
        assert.are.same({ "repaint" }, kinds(fx))
        assert.are.equal("status", find(fx, "repaint").target)
    end)

    it("plays the exact solution move, schedules the reply, hands board to opponent", function()
        local p = mk({ bank = BANK }, rngAt(0.5)) -- index 3 = "flow"
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "human_move", from = "e2", to = "e4" }
        local v = p:view()
        assert.are.equal(1, v.consumed)
        assert.are.equal(3, v.solution_length)
        assert.are.equal("w", v.last_mover)
        assert.are.equal("e4", v.last_san)
        assert.are.equal("b", v.to_move) -- opponent to reply
        assert.are.same({ "schedule", "repaint", "repaint" }, kinds(fx))
        assert.are.equal(Puzzle.SOLVING, v.status)
        return fx
    end)

    it("auto-plays the scheduled reply, then solves on the final player move", function()
        local p = mk({ bank = BANK }, rngAt(0.5))
        p:transition{ kind = "start" }
        local fx1 = p:transition{ kind = "human_move", from = "e2", to = "e4" }
        local token = find(fx1, "schedule").token
        local fx2 = p:transition{ kind = "scheduled", token = token }
        local v = p:view()
        assert.are.equal(2, v.consumed)
        assert.are.equal("e5", v.last_san)
        assert.are.equal("b", v.last_mover)
        assert.are.equal("w", v.to_move)
        assert.are.same({ "repaint", "repaint" }, kinds(fx2))
        -- The third ply is the player's: solve.
        local fx3 = p:transition{ kind = "human_move", from = "g1", to = "f3" }
        v = p:view()
        assert.are.equal(Puzzle.SOLVED, v.status)
        assert.are.equal(3, v.consumed)
        assert.are.equal("solved", find(fx3, "announce").announce_kind)
    end)

    it("ignores a stale scheduled fire after stepping away", function()
        local p = mk({ bank = BANK }, rngAt(0.5))
        p:transition{ kind = "start" }
        local fx1 = p:transition{ kind = "human_move", from = "e2", to = "e4" }
        local token = find(fx1, "schedule").token
        p:transition{ kind = "next" } -- cancels + reloads (index 3 → 4 = "promo")
        local fx = p:transition{ kind = "scheduled", token = token } -- stale
        assert.are.same({}, kinds(fx))
        local v = p:view()
        assert.are.equal("promo", v.puzzle_id)
        assert.are.equal(0, v.consumed) -- the new puzzle was not disturbed
    end)

    it("solves a one-ply mate-in-1 with an announce", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "human_move", from = "a2", to = "a8" }
        local v = p:view()
        assert.are.equal(Puzzle.SOLVED, v.status)
        assert.are.equal("solved", find(fx, "announce").announce_kind)
        assert.are.same({ "repaint", "repaint", "announce" }, kinds(fx))
    end)

    it("rejects a wrong promotion piece, accepts the exact one", function()
        local p = mk({ bank = BANK }, rngAt(0.75)) -- index 4 = "promo"
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "human_move", from = "d7", to = "d8", promotion = "n" }
        assert.are.equal("status", find(fx, "repaint").target)
        assert.are.equal(1, p:view().wrong_attempts)
        local fx2 = p:transition{ kind = "human_move", from = "d7", to = "d8", promotion = "q" }
        assert.are.equal("solved", find(fx2, "announce").announce_kind)
        assert.are.equal(1, p:view().consumed)
    end)

    it("is a no-op after solved", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        p:transition{ kind = "human_move", from = "a2", to = "a8" }
        local fx = p:transition{ kind = "human_move", from = "a8", to = "h8" }
        assert.are.same({}, kinds(fx))
    end)
end)

describe("core.puzzle navigation", function()
    it("advances, cancelling a pending reply first", function()
        local p = mk({ bank = BANK }, rngAt(0.5)) -- index 3 = "flow"
        p:transition{ kind = "start" }
        local fx1 = p:transition{ kind = "human_move", from = "e2", to = "e4" }
        local token = find(fx1, "schedule").token
        local fx = p:transition{ kind = "next" }
        assert.are.same({ "cancel", "repaint" }, kinds(fx))
        assert.are.equal(token, find(fx, "cancel").token)
        assert.are.equal(4, p:view().index) -- 3 → 4
    end)

    it("wraps around at both ends", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        p:transition{ kind = "prev" }
        assert.are.equal(4, p:view().index) -- wrap backward
        p:transition{ kind = "prev" }
        assert.are.equal(3, p:view().index)
        p:transition{ kind = "next" }
        assert.are.equal(4, p:view().index)
        p:transition{ kind = "next" }
        assert.are.equal(1, p:view().index) -- wrap forward
    end)

    it("restart resets the current puzzle, cancelling a still-pending reply", function()
        local p = mk({ bank = BANK }, rngAt(0.5))
        p:transition{ kind = "start" }
        p:transition{ kind = "human_move", from = "e2", to = "e4" } -- correct → reply scheduled
        p:transition{ kind = "human_move", from = "g1", to = "f3" } -- wrong on purpose
        local v0 = p:view()
        assert.are.equal(1, v0.wrong_attempts)
        local fx = p:transition{ kind = "restart" }
        assert.are.same({ "cancel", "repaint" }, kinds(fx)) -- the pending reply is cancelled
        local v = p:view()
        assert.are.equal(0, v.consumed)
        assert.are.equal(0, v.wrong_attempts)
        assert.are.equal(Puzzle.SOLVING, v.status)
    end)

    it("restart during a pending reply cancels it", function()
        local p = mk({ bank = BANK }, rngAt(0.5))
        p:transition{ kind = "start" }
        local fx1 = p:transition{ kind = "human_move", from = "e2", to = "e4" }
        local token = find(fx1, "schedule").token
        local fx = p:transition{ kind = "restart" }
        assert.are.same({ "cancel", "repaint" }, kinds(fx))
        assert.are.equal(token, find(fx, "cancel").token)
        -- the old fire is a no-op
        assert.are.same({}, kinds(p:transition{ kind = "scheduled", token = token }))
    end)
end)

describe("core.puzzle adaptive difficulty", function()
    it("filters to the player's local rating window", function()
        local p = mk({ bank = BANK, difficulty = "adaptive", adaptive_rating = 1200 }, function() return 0 end)
        p:transition{ kind = "start" }
        local v = p:view()
        assert.are.equal(2, v.total) -- 1100 and 1200; 1000 and 2000 are outside ±150
        assert.are.equal(1200, v.adaptive_rating)
    end)

    it("raises the persisted rating after a clean solve exactly once", function()
        local p = mk({ bank = BANK, difficulty = "adaptive", adaptive_rating = 1200 }, function() return 0 end)
        p:transition{ kind = "start" } -- mate-w, rated 1200
        local fx = p:transition{ kind = "human_move", from = "a2", to = "a8" }
        local persist = find(fx, "persist")
        assert.are.equal("puzzle_adaptive_rating", persist.key)
        assert.are.equal(1220, persist.value)
        assert.are.equal(1220, p:view().adaptive_rating)
        assert.is_nil(find(p:transition{ kind = "next" }, "persist"))
    end)

    it("lowers the rating on the first mistake and does not score twice", function()
        local p = mk({ bank = BANK, difficulty = "adaptive", adaptive_rating = 1200 }, function() return 0 end)
        p:transition{ kind = "start" }
        local miss = p:transition{ kind = "human_move", from = "a2", to = "a4" }
        assert.are.equal(1180, find(miss, "persist").value)
        local solved = p:transition{ kind = "human_move", from = "a2", to = "a8" }
        assert.is_nil(find(solved, "persist"))
    end)

    it("counts skipping an unfinished puzzle as a miss", function()
        local p = mk({ bank = BANK, difficulty = "adaptive", adaptive_rating = 1200 }, function() return 0 end)
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "next" }
        assert.are.equal(1180, find(fx, "persist").value)
        assert.are.equal(1180, p:view().adaptive_rating)
    end)
end)

describe("core.puzzle settings", function()
    it("re-filters the bank by difficulty and reloads fresh", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        p:transition{ kind = "human_move", from = "a2", to = "a8" } -- solved mate-w
        p:transition{ kind = "human_move", from = "a2", to = "a4" } -- ignored (solved)
        local fx = p:transition{ kind = "settings", changes = { difficulty = "easy" } }
        local v = p:view()
        -- easy = ≤1000 → only "flow" (1000) from the bank
        assert.are.equal(1, v.total)
        assert.are.equal("flow", v.puzzle_id)
        assert.are.equal(0, v.consumed)
        assert.are.same({ "repaint" }, kinds(fx))
    end)

    it("still honors a legacy exact theme", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "settings", changes = { theme = "backRankMate" } }
        local v = p:view()
        assert.are.equal(2, v.total)
        assert.are.equal("mate-w", v.puzzle_id) -- fresh draw, rng 0 → first
        assert.is_not_nil(find(fx, "repaint"))
    end)

    it("answers error when a filter empties the bank", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "settings", changes = { type = "nonexistent" } }
        assert.are.equal(Puzzle.EMPTY, p:view().status)
        assert.is_not_nil(find(fx, "announce"))
    end)

    it("filters by a catalog type and exposes it in the view", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "settings", changes = { type = "backRank" } }
        local v = p:view()
        -- both mate-w and mate-b carry the backRankMate theme → slice of 2
        assert.are.equal(2, v.total)
        assert.are.equal("backRank", v.type)
        assert.are.equal("Back rank mate", v.type_label)
        -- one-slice types draw a fresh (consumed = 0) puzzle
        assert.are.equal(0, v.consumed)
        assert.is_not_nil(find(fx, "repaint"))
    end)

    it("re-draws a fresh random puzzle when a filter axis changes", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        p:transition{ kind = "human_move", from = "a2", to = "a8" } -- solve mate-w
        assert.are.equal(Puzzle.SOLVED, p:view().status)
        local fx = p:transition{ kind = "settings", changes = { type = "backRank" } }
        local v = p:view()
        assert.are.equal(Puzzle.SOLVING, v.status)
        assert.are.equal(0, v.consumed)   -- freshly loaded, not re-solved state
        assert.is_not_nil(find(fx, "repaint"))
    end)

    it("keeps the current puzzle when the same filters are applied again", function()
        local p = mk({ bank = BANK, type = "backRank" }, function() return 0 end)
        p:transition{ kind = "start" }
        local id0 = p:view().puzzle_id
        p:transition{ kind = "settings", changes = { type = "backRank" } }
        -- no axis changed → preserve, but reloaded fresh
        assert.are.equal(id0, p:view().puzzle_id)
        assert.are.equal(0, p:view().consumed)
    end)
end)

describe("core.puzzle blunder-layout records (real Lichess rows)", function()
    -- Real DB semantics (verified against lichess.org/api/puzzle/<id>): the
    -- FEN is BEFORE the opponent's decisive blunder, and moves =
    -- [opponent blunder] + solver's winning plies. The solver is the side
    -- OPPOSITE the FEN active color. These two are real mate-in-1 rows
    -- lifted from the shipped bank (lines engine-verified: both end with
    -- the solver mating).
    local BL = {
        -- FEN turn = b → solver white; blunder h8g8; white mates with f1f8.
        { id = "bm-w", fen = "6Qk/p1p3pp/4N3/1p6/2q1r1n1/2B5/PP4PP/3R1R1K b - - 0 28",
          moves = "h8g8 f1f8", r = 1200, t = { "mate", "mateIn1", "oneMove" } },
        -- FEN turn = w → solver black; blunder d4e6; black mates with d6h2.
        { id = "bm-b", fen = "2kr1b1r/p1p2pp1/2pqb3/7p/3N2n1/2NPB3/PPP2PPP/R2Q1RK1 w - - 2 13",
          moves = "d4e6 d6h2", r = 1100, t = { "mate", "mateIn1", "oneMove" } },
    }

    it("lets the solver (opposite the FEN turn) move, with the blunder already applied", function()
        local p = mk({ bank = BL }, function() return 0 end)
        p:transition{ kind = "start" }
        local v = p:view()
        assert.are.equal("bm-w", v.puzzle_id)
        assert.are.equal("w", v.player_side) -- solver = white (FEN says black)
        assert.is_false(v.flipped)
        assert.is_true(v.game:isHuman("w"))
        assert.is_false(v.game:isHuman("b"))
        -- the lead-in blunder has been applied, so the solver is to move
        assert.are.equal("w", v.game:turn())
        assert.are.equal("Kxg8", v.san[1]) -- h8g8 = Kxg8 (blunder)
        assert.are.equal(1, v.solution_length) -- just the one winning ply
    end)

    it("solves the blunder-layout mate in one with the solver's ply", function()
        local p = mk({ bank = BL }, function() return 0 end)
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "human_move", from = "f1", to = "f8" }
        assert.are.equal(Puzzle.SOLVED, p:view().status)
        assert.are.equal("solved", find(fx, "announce").announce_kind)
        -- solver won: the recorded line really ends in mate for the solver
        local st = p:view().game:status()
        assert.is_true(st.over)
        assert.are.equal("1-0", st.result)
    end)

    it("flips the board for a black solver", function()
        local p = mk({ bank = BL }, rngAt(0.75)) -- → index 2 = bm-b
        p:transition{ kind = "start" }
        local v = p:view()
        assert.are.equal("bm-b", v.puzzle_id)
        assert.are.equal("b", v.player_side)
        assert.is_true(v.flipped)
        assert.is_true(v.game:isHuman("b"))
    end)

    it("skips a reversed line whose solver actually loses", function()
        local junk = {
            -- a real-looking row whose recording is inverted (solver white
            -- would have to make black's move): unplayable → skipped
            { id = "bad", fen = BL[1].fen, moves = "f1f8 h8g8", r = 1, t = {} },
            { id = "bm-w", fen = BL[1].fen, moves = BL[1].moves, r = 1200, t = { "mate" } },
        }
        local p = mk({ bank = junk }, function() return 0 end)
        p:transition{ kind = "start" }
        -- the bad record is skipped; the good one loads
        assert.are.equal("bm-w", p:view().puzzle_id)
    end)
end)

describe("core.puzzle reveal + try-mode", function()
    it("uses a two-stage hint and auto-plays on the second tap", function()
        local p=mk({bank=BANK},function()return 0 end)
        p:transition{kind="start"}; p:transition{kind="hint"}
        assert.equals(1,p:view().hint_level)
        assert.is_true(p:view().hint_used)
        local fx=p:transition{kind="hint"}
        assert.equals(Puzzle.SOLVED,p:view().status)
        assert.is_not_nil(find(fx,"announce"))
    end)

    it("clears hint state after a wrong move and allows another try", function()
        local p=mk({bank=BANK},function()return 0 end)
        p:transition{kind="start"}; p:transition{kind="hint"}
        p:transition{kind="human_move",from="a2",to="a4"}
        local v=p:view()
        assert.equals(0,v.hint_level)
        assert.equals("try_again",v.feedback)
        assert.is_true(v.input_enabled)
        assert.is_false(v.rated)
    end)

    it("gates input and reports best move until the scripted reply", function()
        local p=mk({bank=BANK},rngAt(.5)); p:transition{kind="start"}
        local fx=p:transition{kind="human_move",from="e2",to="e4"}
        assert.is_false(p:view().input_enabled)
        assert.equals("best_move",p:view().feedback)
        p:transition{kind="scheduled",token=find(fx,"schedule").token}
        assert.is_true(p:view().input_enabled)
        assert.equals("your_move",p:view().feedback)
    end)
    it("exposes the pending expected move + hint squares while solving", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        local v = p:view()
        assert.are.equal("a2a8", v.expected)
        assert.are.equal("a2", v.hint.from)
        assert.are.equal("a8", v.hint.to)
        assert.is_true(v.rated)
        assert.is_false(v.revealed)
        assert.is_false(v.missed_first)
    end)

    it("reveal marks the round unrated and exposes hint squares", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        local fx = p:transition{ kind = "reveal" }
        local v = p:view()
        assert.are.same({ "repaint", "repaint" }, kinds(fx))
        assert.is_true(v.revealed)
        assert.is_false(v.rated)
        assert.are.equal("a2", v.hint.from)
        assert.are.equal("a8", v.hint.to)
    end)

    it("the revealed move is still the expected player ply (auto-play works)", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        p:transition{ kind = "reveal" }
        -- The App can play the hinted move through the normal human_move seam.
        local fx = p:transition{ kind = "human_move", from = "a2", to = "a8" }
        assert.are.equal("solved", find(fx, "announce").announce_kind)
        assert.is_false(p:view().rated)
    end)

    it("reveal is a no-op once solved, and does not clear try-mode", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        p:transition{ kind = "human_move", from = "a2", to = "a4" } -- wrong first
        assert.is_true(p:view().missed_first)
        assert.is_false(p:view().rated)
        p:transition{ kind = "human_move", from = "a2", to = "a8" } -- solve
        assert.are.same({}, kinds(p:transition{ kind = "reveal" }))
        assert.are.equal(nil, p:view().hint)
    end)

    it("does not expose the hint during the opponent's pending reply", function()
        local p = mk({ bank = BANK }, rngAt(0.5)) -- index 3 = "flow"
        p:transition{ kind = "start" }
        local fx1 = p:transition{ kind = "human_move", from = "e2", to = "e4" }
        -- Opponent is due to reply: the solver is NOT to move, so there is
        -- no hint/expected even though we are still SOLVING.
        local v = p:view()
        assert.are.equal("b", v.game:turn())
        assert.are.equal(nil, v.hint)
        assert.are.equal(nil, v.expected)
        local token = find(fx1, "schedule").token
        p:transition{ kind = "scheduled", token = token }
        -- After the reply it is the solver's move again: hint returns.
        v = p:view()
        assert.are.equal("g1f3", v.expected)
        assert.are.equal("g1", v.hint.from)
    end)

    it("a wrong first move un-rates the round (try-mode), solving in try-mode keeps it unrated", function()
        local p = mk({ bank = BANK }, function() return 0 end)
        p:transition{ kind = "start" }
        local v = p:view()
        assert.is_true(v.rated)
        -- First wrong move → miss, try-mode.
        p:transition{ kind = "human_move", from = "a2", to = "a4" }
        v = p:view()
        assert.is_true(v.missed_first)
        assert.is_false(v.rated)
        -- Solving afterwards still counts, but the round stays unrated.
        p:transition{ kind = "human_move", from = "a2", to = "a8" }
        assert.are.equal(Puzzle.SOLVED, p:view().status)
        assert.is_false(p:view().rated)
    end)
end)

describe("core.puzzle view", function()
    it("exposes the SAN history and fen of the live game", function()
        local p = mk({ bank = BANK }, rngAt(0.5))
        p:transition{ kind = "start" }
        p:transition{ kind = "human_move", from = "e2", to = "e4" }
        local v = p:view()
        assert.are.same({ "e4" }, v.san)
        assert.is_string(v.fen)
        assert.are.equal("e4", v.last_san)
        assert.are.equal(nil, v.last_wrong)
    end)

    it("keeps the puzzle's fixed facing across the reply", function()
        local p = mk({ bank = BANK }, rngAt(0.5))
        p:transition{ kind = "start" }
        local fx1 = p:transition{ kind = "human_move", from = "e2", to = "e4" }
        local token = find(fx1, "schedule").token
        p:transition{ kind = "scheduled", token = token }
        local v = p:view()
        assert.is_false(v.flipped) -- white puzzle stays white-facing
        assert.are.equal("w", v.player_side)
    end)
end)

describe("core.puzzle move replay", function()
    local function advanced()
        local p=mk({bank=BANK},rngAt(.5)); p:transition{kind="start"}
        local fx=p:transition{kind="human_move",from="e2",to="e4"}
        return p,fx
    end

    it("is disabled while a scripted reply is pending", function()
        local p=advanced()
        assert.is_false(p:view().can_replay_back)
        assert.same({},p:transition{kind="replay",direction=-1})
        assert.equals(1,p:view().replay_cursor)
    end)

    it("steps through each completed ply without changing progress", function()
        local p,fx=advanced()
        p:transition{kind="scheduled",token=find(fx,"schedule").token}
        assert.equals(2,p:view().replay_cursor)
        assert.is_true(p:view().can_replay_back)
        p:transition{kind="replay",direction=-1}
        local v=p:view()
        assert.equals(2,v.consumed)
        assert.equals(1,v.replay_cursor)
        assert.is_true(v.reviewing)
        assert.equals("review",v.feedback)
        assert.is_false(v.input_enabled)
        assert.equals(1,#v.san)
        p:transition{kind="replay",direction=-1}
        assert.equals(0,p:view().replay_cursor)
        assert.same({},p:transition{kind="replay",direction=-1})
        p:transition{kind="replay",direction=1}
        p:transition{kind="replay",direction=1}
        v=p:view()
        assert.equals(2,v.replay_cursor)
        assert.is_false(v.reviewing)
        assert.is_true(v.input_enabled)
        assert.is_false(v.can_replay_forward)
    end)

    it("clears the active hint stage but preserves unrated status", function()
        local p,fx=advanced(); p:transition{kind="scheduled",token=find(fx,"schedule").token}
        p:transition{kind="hint"}
        assert.equals(1,p:view().hint_level)
        p:transition{kind="replay",direction=-1}
        assert.equals(0,p:view().hint_level)
        assert.is_true(p:view().hint_used)
        assert.is_false(p:view().rated)
    end)

    it("replays a solved position and resets on puzzle navigation", function()
        local p=mk({bank=BANK},function()return 0 end); p:transition{kind="start"}
        p:transition{kind="human_move",from="a2",to="a8"}
        assert.equals("solved",p:view().feedback)
        p:transition{kind="replay",direction=-1}
        assert.equals("review",p:view().feedback)
        p:transition{kind="replay",direction=1}
        assert.equals("solved",p:view().feedback)
        p:transition{kind="next"}
        assert.equals(0,p:view().replay_cursor)
        assert.is_false(p:view().reviewing)
    end)
end)
