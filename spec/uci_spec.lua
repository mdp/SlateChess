-- Tests for engine.uci's go-command builder.
--
-- The command line is the contract between the app and the engine:
-- every field omitted or present here changes how long the engine
-- searches. The chal stall (clock mode computing a ~45s budget because
-- a missing movetime looked like "no limit") is exactly the failure
-- mode these assertions pin down: an explicit movetime must ALWAYS
-- appear when the app sends one.

local UciCommand = require("engine.uci_command")

describe("UCI.buildGoCommand", function()
    it("emits movetime when the app budgets a move", function()
        assert.equals("go movetime 1000", UciCommand.buildGoCommand{ movetime = 1000 })
    end)

    it("emits depth and movetime together, in UCI order", function()
        local cmd = UciCommand.buildGoCommand{ movetime = 1000, depth = 2 }
        assert.equals("go depth 2 movetime 1000", cmd)
    end)

    it("emits clock fields for timed games", function()
        local cmd = UciCommand.buildGoCommand{
            wtime = 900000, btime = 900000,
            winc = 10000, binc = 10000,
            movetime = 1000, depth = 2,
        }
        assert.equals("go wtime 900000 btime 900000 winc 10000 binc 10000 "
            .. "depth 2 movetime 1000", cmd)
    end)

    it("omits nil fields instead of sending 'nil'", function()
        local cmd = UciCommand.buildGoCommand{ depth = nil, movetime = 300 }
        assert.equals("go movetime 300", cmd)
        assert.equals("go", UciCommand.buildGoCommand{})
    end)

    it("emits boolean flags bare", function()
        assert.equals("go infinite", UciCommand.buildGoCommand{ infinite = true })
        assert.equals("go", UciCommand.buildGoCommand{ infinite = false })
    end)
end)
