-- Tests for core.blunder — the difficulty damper.

local Game = require("core.game")
local Blunder = require("core.blunder")

-- RNG stub returning canned values in sequence.
local function seqRng(values)
    local i = 0
    return function()
        i = i + 1
        return values[((i - 1) % #values) + 1]
    end
end

describe("Blunder", function()
    it("passes the move through at zero chance", function()
        local game = Game:new()
        game:playMove("e4")
        local blunder = Blunder:new(game, 0.0, seqRng({ 0.0 }))
        assert.equals("e7e5", blunder:maybeWeaken("e7e5"))
    end)

    it("passes the move through when the roll exceeds the chance", function()
        local game = Game:new()
        game:playMove("e4")
        local blunder = Blunder:new(game, 0.5, seqRng({ 0.7 }))
        assert.equals("e7e5", blunder:maybeWeaken("e7e5"))
    end)

    it("substitutes a legal UCI move when the roll hits", function()
        local game = Game:new()
        local blunder = Blunder:new(game, 1.0, seqRng({ 0.0 }))
        local move = blunder:maybeWeaken("e2e4")
        -- Every legal reply here is a plain 4-char UCI move; the bug this
        -- guards against is an appended promotion letter ("e7e5q").
        assert.equals(4, #move)
        local legal = {}
        for _, m in ipairs(game:legalMoves({ verbose = true })) do
            legal[m.from .. m.to] = true
        end
        assert.is_truthy(legal[move])
    end)

    it("clamps chance into [0, 1]", function()
        local game = Game:new()
        local roll = seqRng({ 0.5 })
        local blunder = Blunder:new(game, 5, roll)
        assert.equals(1, blunder.chance)
        blunder:setChance(-3)
        assert.equals(0, blunder.chance)
        blunder:setChance(nil)
        assert.equals(0, blunder.chance)
    end)

    it("keeps the engine's promotion when not weakening", function()
        local game = Game:new()
        game:playMove("e4")
        local blunder = Blunder:new(game, 0.0, seqRng({ 0.0 }))
        assert.equals("a7a8q", blunder:maybeWeaken("a7a8q"))
    end)
end)
