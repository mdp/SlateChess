-- Tests for core.eval — UCI info-line parsing and eval formatting.

local Eval = require("core.eval")

describe("Eval.parseInfo", function()
    it("parses a centipawn score", function()
        local info = Eval.parseInfo(
            "info depth 12 seldepth 15 multipv 1 score cp 42 nodes 1000 nps 50000 "
                .. "hashfull 0 tbhits 0 time 20 pv e2e4 e7e5")
        assert.same({ multipv = 1, cp = 42, mate = nil }, info)
    end)

    it("parses negative centipawn scores", function()
        local info = Eval.parseInfo("info depth 8 multipv 1 score cp -123 pv d2d4")
        assert.equals(-123, info.cp)
    end)

    it("parses mate scores", function()
        local info = Eval.parseInfo("info depth 5 multipv 1 score mate 3 pv f6f7")
        assert.equals(3, info.mate)
        assert.is_nil(info.cp)
    end)

    it("ignores non-principal-variation lines", function()
        assert.is_nil(Eval.parseInfo("info depth 5 multipv 2 score cp 10 pv a2a3"))
    end)

    it("ignores lines without a score", function()
        assert.is_nil(Eval.parseInfo("info depth 5 multipv 1 nodes 100"))
        assert.is_nil(Eval.parseInfo("bestmove e2e4"))
        assert.is_nil(Eval.parseInfo(nil))
        assert.is_nil(Eval.parseInfo("uciok"))
    end)
end)

describe("Eval.toWhitePerspective", function()
    it("keeps white-search scores as-is", function()
        assert.equals(42, Eval.toWhitePerspective(42, "w"))
    end)

    it("negates black-search scores", function()
        assert.equals(-42, Eval.toWhitePerspective(42, "b"))
        assert.equals(42, Eval.toWhitePerspective(-42, "b"))
    end)

    it("handles nil", function()
        assert.is_nil(Eval.toWhitePerspective(nil, "w"))
    end)
end)

describe("Eval.format", function()
    it("renders centipawn evals with an advantage tag", function()
        assert.equals("eval: +0.00 (roughly equal)", Eval.format({ cp = 0 }))
        assert.equals("eval: -0.30 (slight advantage for Black)", Eval.format({ cp = -30 }))
        assert.equals("eval: +0.80 (small advantage for White)", Eval.format({ cp = 80 }))
        assert.equals("eval: -1.50 (clear advantage for Black)", Eval.format({ cp = -150 }))
        assert.equals("eval: +3.00 (winning advantage for White)", Eval.format({ cp = 300 }))
        assert.equals("eval: -5.00 (decisive advantage for Black)", Eval.format({ cp = -500 }))
    end)

    it("renders mate scores", function()
        assert.equals("eval: Mate in 2 (White)", Eval.format({ mate = 4 }))
        assert.equals("eval: Mate in 3 (Black)", Eval.format({ mate = -5 }))
        assert.equals("eval: # (checkmate)", Eval.format({ mate = 0 }))
    end)

    it("renders nothing without a score", function()
        assert.equals("", Eval.format({}))
        assert.equals("", Eval.format(nil))
    end)
end)

describe("Eval.short", function()
    it("renders centipawn evals as signed pawns", function()
        assert.equals("+0.35", Eval.short({ cp = 35 }))
        assert.equals("-1.20", Eval.short({ cp = -120 }))
        assert.equals("+0.00", Eval.short({ cp = 0 }))
    end)

    it("renders mate scores compactly", function()
        assert.equals("+M2", Eval.short({ mate = 4 }))
        assert.equals("-M3", Eval.short({ mate = -5 }))
        assert.equals("#", Eval.short({ mate = 0 }))
    end)

    it("renders nothing without a score", function()
        assert.equals("", Eval.short({}))
        assert.equals("", Eval.short(nil))
    end)
end)

describe("Eval.parsePv", function()
    it("parses the principal variation with its first move", function()
        local info = Eval.parsePv(
            "info depth 8 seldepth 10 multipv 1 score cp 35 nodes 5000 "
                .. "nps 250000 time 20 pv e2e4 e7e5 g1f3")
        assert.same({ multipv = 1, cp = 35, mate = nil, move = "e2e4" }, info)
    end)

    it("parses second-PV lines, which parseInfo rejects", function()
        local info = Eval.parsePv("info depth 8 multipv 2 score cp 21 pv d2d4 d7d5")
        assert.same({ multipv = 2, cp = 21, mate = nil, move = "d2d4" }, info)
    end)

    it("parses mate scores and promotion heads", function()
        local info = Eval.parsePv("info depth 6 multipv 1 score mate 3 pv f6f7")
        assert.equals(3, info.mate)
        assert.equals("f6f7", info.move)
        local promo = Eval.parsePv("info depth 9 multipv 2 score cp 900 pv e7e8q")
        assert.equals("e7e8q", promo.move)
    end)

    it("ignores score-only lines and non-info lines", function()
        -- Score-only info lines carry no pv token.
        assert.is_nil(Eval.parsePv("info depth 2 score cp 40"))
        assert.is_nil(Eval.parsePv("bestmove e2e4"))
        assert.is_nil(Eval.parsePv("info depth 5 multipv 1 nodes 100"))
    end)
end)

describe("Eval.figurine", function()
    it("replaces leading piece letters per color", function()
        assert.equals("♘f3", Eval.figurine("Nf3", "w"))
        assert.equals("♞f6", Eval.figurine("Nf6", "b"))
        assert.equals("♗xc6", Eval.figurine("Bxc6", "w"))
        assert.equals("♕h5#", Eval.figurine("Qh5#", "w"))
    end)

    it("keeps disambiguation and pawn moves intact", function()
        assert.equals("♘bd2", Eval.figurine("Nbd2", "w"))
        assert.equals("♖1e2", Eval.figurine("R1e2", "w"))
        assert.equals("exd5", Eval.figurine("exd5", "b"))
        assert.equals("e4", Eval.figurine("e4", "w"))
    end)

    it("renders promotions and leaves castling alone", function()
        assert.equals("e8=♕+", Eval.figurine("e8=Q+", "w"))
        assert.equals("e8=♞", Eval.figurine("e8=N", "b"))
        assert.equals("O-O", Eval.figurine("O-O", "w"))
        assert.equals("O-O-O", Eval.figurine("O-O-O", "b"))
    end)
end)

describe("Eval.parseInfo with chal-style lines", function()
    -- Chal omits the multipv token entirely (single PV); parseInfo must
    -- still accept its lines, and parsePv must reject them so the hints
    -- line falls back to bestmove + last score.
    local line = "info depth 16 score cp 24 nodes 692843 time 567 nps 1221 pv c1f4 g8f6"

    it("parses an info line without a multipv token", function()
        local info = Eval.parseInfo(line)
        assert.same({ multipv = 1, cp = 24, mate = nil }, info)
    end)

    it("does not treat a chal line as a hint PV (no multipv)", function()
        assert.is_nil(Eval.parsePv(line))
    end)
end)
