-- Tests for core.openings — book loading and prefix matching.

local Openings = require("core.openings")

local BOOK = {
    { eco = "C20", name = "King Pawn Game", moves = "e4" },
    { eco = "C60", name = "Ruy Lopez", moves = "e4 e5 Nf3 Nc6 Bb5" },
    { eco = "B01", name = "Scandinavian", moves = "e4 d5" },
}

describe("Openings.stripSan", function()
    it("removes annotation suffixes", function()
        assert.equals("Nf3", Openings.stripSan("Nf3+"))
        assert.equals("Qh4", Openings.stripSan("Qh4#"))
        assert.equals("e4", Openings.stripSan("e4!?"))
        assert.equals("d5", Openings.stripSan("d5"))
    end)
end)

describe("Openings.match", function()
    it("returns the exact matched line", function()
        local entry = Openings.match(BOOK, { "e4", "e5", "Nf3+", "Nc6", "Bb5" })
        assert.equals("Ruy Lopez", entry.name)
        assert.equals("C60", entry.eco)
    end)

    it("prefers the longest match", function()
        local entry = Openings.match(BOOK, { "e4", "e5", "Nf3", "Nc6" })
        assert.equals("King Pawn Game", entry.name) -- Ruy Lopez needs Bb5
        entry = Openings.match(BOOK, { "e4", "d5" })
        assert.equals("Scandinavian", entry.name)
    end)

    it("returns nil when nothing matches", function()
        assert.is_nil(Openings.match(BOOK, { "d4", "Nf6" }))
    end)

    it("returns nil for an empty history", function()
        assert.is_nil(Openings.match(BOOK, {}))
        assert.is_nil(Openings.match(BOOK, nil))
        assert.is_nil(Openings.match(nil, { "e4" }))
    end)
end)

describe("Openings.load", function()
    it("uses the injected decoder", function()
        local book = Openings.load('[{"eco":"A00","name":"X","moves":"e4"}]', function(s)
            assert.is_string(s)
            return { { eco = "A00", name = "X", moves = "e4" } }
        end)
        assert.equals(1, #book)
        assert.equals("X", book[1].name)
    end)

    it("strips trailing commas for strict JSON decoders", function()
        Openings.load('[{"eco":"A00","moves":"e4"},]', function(s)
            assert.falsy(s:find(",%s*%]"))
            return {}
        end)
    end)

    it("yields an empty book on bad input", function()
        assert.same({}, Openings.load("not json", function() error("boom") end))
        assert.same({}, Openings.load(nil))
        assert.same({}, Openings.load('[{"moves":""}]', function() return { { moves = "" } } end))
    end)
end)
