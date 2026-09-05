-- UCI go-command builder.
--
-- The command line is the contract between the app and the engine:
-- every field omitted or present changes how long the engine searches.
-- Kept as a pure, dependency-free module so it can be unit-tested
-- without dragging KOReader's widget tree in (engine.uci pulls that in
-- via engine.process).
--
-- The engine stall this pins down: clock-mode engines compute their
-- budget from remaining time (our_time/20), so a go that accidentally
-- OMITS movetime lets a timed game search for ~26s per move. These
-- specs guarantee an explicitly budgeted move always says so on the
-- wire.

local UciCommand = {}

--- Builds a UCI "go" command from opts. Fields emit in a fixed order,
--- nil fields are omitted, boolean flags emit bare.
function UciCommand.buildGoCommand(opts)
    opts = opts or {}
    local cmd = "go"
    local order = {
        "searchmoves", "ponder",
        "wtime", "btime", "winc", "binc", "movestogo",
        "depth", "nodes", "mate", "movetime",
        "infinite",
    }
    for _, k in ipairs(order) do
        local v = opts[k]
        if v ~= nil then
            if type(v) == "boolean" then
                if v then cmd = cmd .. " " .. k end
            else
                cmd = cmd .. " " .. k .. " " .. tostring(v)
            end
        end
    end
    return cmd
end

return UciCommand
