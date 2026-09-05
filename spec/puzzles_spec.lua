-- Tests for core.puzzles — the bank loader, filter, and band math.
--
-- Same seam as the rest of the suite: real records, an injected fake
-- decoder for the load tolerance cases, and the pure functions exercised
-- directly (the module has no state).

local Puzzles = require("core.puzzles")

local FAKE_DECODE = function() end -- never reached in most tests

local function bank(n)
    local out = {}
    for i = 1, n do
        out[i] = {
            id    = "p" .. i,
            fen   = "8/8/8/8/8/8/8/8 w - - 0 1",
            moves = "a1a2",
            r     = 1000 + i * 100,
            t     = { "fork" },
        }
    end
    return out
end

describe("Puzzles.load", function()
    it("parses a JSON array into usable records", function()
        local content = '[{"id":"x","fen":"y w - - 0 1","moves":"e2e4","r":1200,"t":["fork"]}]'
        local out = Puzzles.load(content, function(s)
            assert(s:find("[", 1, true), "array expected")
            return { { id = "x", fen = "y w - - 0 1", moves = "e2e4", r = 1200, t = { "fork" } } }
        end)
        assert.are.equal(1, #out)
        assert.are.equal("x", out[1].id)
        assert.are.equal(1200, out[1].r)
        assert.are.same({ "fork" }, out[1].t)
    end)

    it("carries through the optional quality fields (p/pl)", function()
        local out = Puzzles.load("irrelevant", function()
            return { {
                id = "q", fen = "8/8/8/8/8/8/8/8 w - - 0 1", moves = "a1a2",
                r = 1500, p = 77, pl = 250, t = {},
            } }
        end)
        assert.are.equal(77, out[1].p)
        assert.are.equal(250, out[1].pl)
        assert.are.equal(77, (Puzzles.quality(out[1])))
        assert.are.equal(250, (select(2, Puzzles.quality(out[1]))))
    end)

    it("tolerates banks without the quality fields", function()
        local out = Puzzles.load("irrelevant", function()
            return { {
                id = "q", fen = "8/8/8/8/8/8/8/8 w - - 0 1", moves = "a1a2",
                r = 1500, t = {},
            } }
        end)
        assert.is_nil(out[1].p)
        assert.is_nil(out[1].pl)
        assert.is_nil(Puzzles.quality(out[1]))
        assert.is_nil((select(2, Puzzles.quality(out[1]))))
    end)

    it("strips stray trailing commas before the strict decoder sees them", function()
        local content = '[{"id":"x","fen":"f w - - 0 1","moves":"b1c3","r":1100,"t":[]},]'
        local seen
        local out = Puzzles.load(content, function(s)
            seen = s
            return { { id = "x", fen = "f w - - 0 1", moves = "b1c3", r = 1100, t = {} } }
        end)
        assert.are.equal(1, #out)
        -- The decoder must never receive the ",]" that strict JSON rejects.
        assert.is_nil(seen:find(",%s*%]"))
    end)

    it("returns an empty bank on malformed content instead of raising", function()
        assert.are.same({}, Puzzles.load(nil, FAKE_DECODE))
        assert.are.same({}, Puzzles.load("", FAKE_DECODE))
        assert.are.same({}, Puzzles.load("not json at all", function() error("boom") end))
        assert.are.same({}, Puzzles.load("{}", FAKE_DECODE)) -- not an array
    end)

    it("drops syntactically invalid records", function()
        local raw = {
            { id = "ok",   fen = "8/8/8/8/8/8/8/8 w - - 0 1", moves = "e2e4", r = 1200, t = {} },
            { id = "bad1", fen = "", moves = "e2e4", r = 1200, t = {} },
            { id = "bad2", fen = "x", moves = "zz99",   r = 1200, t = {} },
            { id = "bad3", fen = "x", moves = "e2e4", r = "oops", t = {} },
            { id = "bad4", fen = "x", moves = "",  r = 1200, t = {} },
            { id = "bad5", fen = 42, moves = "e2e4", r = 1200, t = {} },
        }
        local out = Puzzles.load("irrelevant", function() return raw end)
        assert.are.equal(1, #out)
        assert.are.equal("ok", out[1].id)
    end)
end)

describe("Puzzles.valid / Puzzles.solution", function()
    it("accepts real UCI tokens incl. promotion, rejects garbage", function()
        assert.is_true(Puzzles.valid({ id = "i", fen = "f w - - 0 1", moves = "e2e4 e7e5 g1f3", r = 1, t = {} }))
        assert.is_true(Puzzles.valid({ id = "i", fen = "f w - - 0 1", moves = "e7e8q", r = 1, t = {} }))
        assert.is_false(Puzzles.valid({ id = "i", fen = "f w - - 0 1", moves = "e2e4 e9e5", r = 1, t = {} }))
        assert.is_false(Puzzles.valid({ id = "i", fen = "f w - - 0 1", moves = "e2", r = 1, t = {} }))
        assert.is_false(Puzzles.valid({}))
    end)

    it("splits the solution into UCI tokens", function()
        local rec = { id = "i", fen = "f w - - 0 1", moves = "e2e4 e7e5 g1f3", r = 1, t = {} }
        assert.are.same({ "e2e4", "e7e5", "g1f3" }, Puzzles.solution(rec))
        assert.are.same({}, Puzzles.solution({}))
    end)

    it("treats odd-ply (classic) lines as solver-first with no blunder", function()
        local rec = { id = "i", fen = "f w - - 0 1", moves = "e2e4 e7e5 g1f3", r = 1, t = {} }
        assert.are.same({ "e2e4", "e7e5", "g1f3" }, Puzzles.tokens(rec))
        assert.is_nil(Puzzles.blunder(rec))
        assert.are.same({ "e2e4", "e7e5", "g1f3" }, Puzzles.solution(rec))
    end)

    it("understands Lichess blunder lines (even layout)", function()
        -- Real DB rows: line = [opponent's lead-in blunder] + solver line.
        local rec = { id = "i", fen = "f b - - 0 1", moves = "d7d5 e2e4 g8f6 e4e5", r = 1, t = {} }
        assert.are.same({ "d7d5", "e2e4", "g8f6", "e4e5" }, Puzzles.tokens(rec))
        assert.are.equal("d7d5", Puzzles.blunder(rec))
        -- the solution drops the blunder; "solver first, alternating"
        assert.are.same({ "e2e4", "g8f6", "e4e5" }, Puzzles.solution(rec))
    end)
end)

describe("Puzzles.filter", function()
    local src = bank(5) -- ratings 1100,1200,1300,1400,1500

    it("filters by rating range", function()
        local out = Puzzles.filter(src, { rating_min = 1200, rating_max = 1400 })
        assert.are.equal(3, #out)
        assert.are.equal("p2", out[1].id)
        assert.are.equal("p4", out[#out].id)
    end)

    it("honors a theme", function()
        local themed = Puzzles.filter(src, { theme = "fork" })
        assert.are.equal(5, #themed)
        assert.are.equal(0, #Puzzles.filter(src, { theme = "pin" }))
    end)

    it("'any' and nil themes mean no filter", function()
        assert.are.equal(5, #Puzzles.filter(src, { theme = "any" }))
        assert.are.equal(5, #Puzzles.filter(src, {}))
    end)

    it("filters by a catalog type id", function()
        assert.are.equal(5, #Puzzles.filter(src, { type = "fork" }))
        assert.are.equal(0, #Puzzles.filter(src, { type = "pin" }))
        -- unknown type ids match nothing (how an empty slice arises)
        assert.are.equal(0, #Puzzles.filter(src, { type = "nonexistent" }))
        -- 'any'/'random'/nil all mean the whole bank
        assert.are.equal(5, #Puzzles.filter(src, { type = "any" }))
        assert.are.equal(5, #Puzzles.filter(src, { type = "random" }))
        assert.are.equal(5, #Puzzles.filter(src, {}))
    end)

    it("combines rating bounds with a type", function()
        local mixed = {
            { id = "m1", fen = "8/8/8/8/8/8/8/8 w - - 0 1", moves = "a1a2", r = 900,  t = { "fork" } },
            { id = "m2", fen = "8/8/8/8/8/8/8/8 w - - 0 1", moves = "a1a2", r = 1500, t = { "fork", "pin" } },
            { id = "m3", fen = "8/8/8/8/8/8/8/8 w - - 0 1", moves = "a1a2", r = 1600, t = { "pin" } },
        }
        assert.are.equal(1, #Puzzles.filter(mixed, { type = "fork", rating_max = 1000 }))
        assert.are.equal(2, #Puzzles.filter(mixed, { type = "pin" }))
    end)

    it("exposes the type catalog module", function()
        assert.is_table(Puzzles.types())
        assert.is_not_nil(Puzzles.types().byId("mateIn2"))
    end)
end)

describe("Puzzles.bandRange / bands", function()
    it("maps the four bands to inclusive rating ranges", function()
        local lo, hi = Puzzles.bandRange("easy")
        assert.is_true(lo <= 1000 and hi >= 1000 and hi < 1100)
        local lo2, hi2 = Puzzles.bandRange("normal")
        assert.are.equal(1001, lo2)
        assert.are.equal(1500, hi2)
    end)

    it("returns nil for 'any' and unknown bands", function()
        assert.is_nil(Puzzles.bandRange("any"))
        assert.is_nil(Puzzles.bandRange("wizard"))
    end)
end)

describe("Puzzles adaptive rating", function()
    it("uses a narrow, clamped window around the player", function()
        assert.are.same({ 1050, 1350 }, { Puzzles.adaptiveRange(1200) })
        assert.are.same({ 400, 550 }, { Puzzles.adaptiveRange(400) })
        assert.are.same({ 2850, 3000 }, { Puzzles.adaptiveRange(3000) })
    end)

    it("raises clean solves and lowers misses using Elo expectations", function()
        assert.are.equal(1220, Puzzles.updateAdaptiveRating(1200, 1200, 1))
        assert.are.equal(1180, Puzzles.updateAdaptiveRating(1200, 1200, 0))
        assert.is_true(Puzzles.updateAdaptiveRating(1200, 1400, 1) > 1220)
    end)

    it("clamps corrupt and extreme persisted values", function()
        assert.are.equal(1200, Puzzles.clampAdaptiveRating("bad"))
        assert.are.equal(400, Puzzles.clampAdaptiveRating(-99))
        assert.are.equal(3000, Puzzles.clampAdaptiveRating(9000))
    end)
end)
