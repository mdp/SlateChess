-- Tests for core.puzzle_types — the curated puzzle-type catalog + matchers.
--
-- Pure facts: entry shape, exact/prefix matching, one-pass counts, and the
-- "random matches nothing" rule that keeps filter("any") the *only* path to
-- a mixed slice. Records mirror the real Lichess tag vocabulary.

local Types = require("core.puzzle_types")

local function rec(...)
    return { t = { ... } }
end

describe("PuzzleTypes catalog", function()
    it("provides spoiler-safe phases and a principal motif", function()
        assert.equals("Middlegame", Types.phase({"fork","middlegame"}))
        assert.equals("Fork", Types.principal({"fork","middlegame"}))
        assert.equals("Random", Types.phase({"fork"}))
    end)
    it("has a stable id -> entry lookup and display labels", function()
        local fork = Types.byId("fork")
        assert.is_not_nil(fork)
        assert.are.equal("Fork", fork.label)
        assert.is_not_nil(Types.byId("random"))
        assert.is_not_nil(Types.byId("openSicilian"))
        assert.is_nil(Types.byId("nonexistent"))
        assert.are.equal("nonexistent", Types.label("nonexistent")) -- falls back
    end)

    it("covers the goals, lengths and named-mate vocabulary", function()
        -- Goals
        assert.is_not_nil(Types.byId("equality"))
        assert.is_not_nil(Types.byId("advantage"))
        assert.is_not_nil(Types.byId("crushing"))
        assert.is_not_nil(Types.byId("mate"))
        -- Lengths
        assert.is_not_nil(Types.byId("oneMove"))
        assert.is_not_nil(Types.byId("short"))
        assert.is_not_nil(Types.byId("long"))
        assert.is_not_nil(Types.byId("veryLong"))
        -- Representative named mate patterns
        assert.is_not_nil(Types.byId("balestra"))
        assert.is_not_nil(Types.byId("killBox"))
        assert.is_not_nil(Types.byId("vukovic"))
        assert.is_not_nil(Types.byId("swallowtail"))
    end)

    it("every entry carries a one-line description", function()
        for _, e in ipairs(Types.LIST) do
            assert.is_string(e.desc, "desc missing for " .. e.id)
            assert.is_true(#e.desc > 10, "desc too short for " .. e.id)
        end
        assert.is_nil(Types.desc("nonexistent"))
        assert.is_string(Types.desc("fork"))
    end)

    it("is ordered with Random first and only groups referencing real ids", function()
        assert.are.equal("random", Types.LIST[1].id)
        local group_ids = {}
        for _, g in ipairs(Types.GROUPS) do group_ids[g.id] = true end
        local total_quota = 0
        for _, e in ipairs(Types.LIST) do
            if e.id ~= "random" then
                assert.is_true(group_ids[e.group], "group must exist for " .. e.id)
                if e.build_quota then total_quota = total_quota + e.build_quota end
                assert.is_string(e.label)
            end
        end
        assert.is_true(total_quota > 0, "the build quotas must sum to something")
    end)
end)

describe("PuzzleTypes.matches", function()
    it("anyTheme matches when any listed theme is present", function()
        local fork = Types.byId("fork")
        assert.is_true(Types.matches(fork, rec("fork", "middlegame", "short")))
        assert.is_false(Types.matches(fork, rec("pin", "middlegame")))
    end)

    it("combines theme groups (e.g. discovered attack)", function()
        local disc = Types.byId("discovered")
        assert.is_true(Types.matches(disc, rec("discoveredAttack", "long")))
        assert.is_true(Types.matches(disc, rec("discoveredCheck")))
        assert.is_false(Types.matches(disc, rec("attraction")))
    end)

    it("prefix matches openings by family, respecting the _ boundary", function()
        local sicilian = Types.byId("openSicilian")
        assert.is_true(Types.matches(sicilian, rec("Sicilian_Defense")))
        assert.is_true(Types.matches(sicilian, rec("Sicilian_Defense_Najdorf")))
        assert.is_false(Types.matches(sicilian, rec("Italian_Game")))
        -- a same-initial-token non-family must not slip through
        assert.is_false(Types.matches(Types.byId("openItalian"), rec("Sicilian_Game")))
        -- hyphenated names (Caro-Kann legacy spelling)
        assert.is_true(Types.matches(Types.byId("openCaroKann"), rec("Caro-Kann_Defense")))
    end)

    it("random matches nothing (it is the no-filter default, not a matcher)", function()
        local random = Types.byId("random")
        assert.is_false(Types.matches(random, rec("fork", "endgame")))
        assert.is_false(Types.matches(random, rec()))
    end)

    it("is safe on nil/odd records", function()
        assert.is_false(Types.matches(Types.byId("fork"), nil))
        assert.is_false(Types.matches(Types.byId("fork"), {}))
        assert.is_false(Types.matches(nil, rec("fork")))
    end)
end)

describe("PuzzleTypes.counts", function()
    local bank = {
        rec("fork", "middlegame"),
        rec("fork"),
        rec("pin", "endgame"),
        rec("Sicilian_Defense", "opening"),
        rec("Sicilian_Defense_Najdorf"),
    }

    it("counts per-type in one pass, Random = whole bank", function()
        local c = Types.counts(bank)
        assert.are.equal(2, c.fork)
        assert.are.equal(1, c.pin)
        assert.are.equal(2, c.openSicilian)
        assert.are.equal(1, c.opening)          -- theme "opening" on the 4th
        assert.are.equal(5, c.random)
        assert.is_nil(c.nonexistent)
    end)
end)
