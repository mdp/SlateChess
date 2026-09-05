--[[--
SlatePuzzle — emulator end-to-end test pass.

Installed by tools/emu-test-puzzle.sh into <emulator>/patches/2-slatepuzzle-emu.lua
and executed as a "late" (priority 2) userpatch: once KOReader's UIManager
is up.

It boots the puzzle plugin the way KOReader would (PuzzleApp:new +
startSession), then drives a scripted solving session through the App's
public surface and the machine's transition seam: bank load, a settings
re-filter into a known type + difficulty, the correct move + the
automatically scheduled opponent reply, a wrong move, prev/next navigation,
restart, solving to completion, an empty filter, and exit -> resume into a
fresh App instance.

The long-handled line is GONE: this driver works against *any* puzzle the
machine draws by reading the expected ply from the machine's public
`remainingSolution()` (the solver-first alternating list — the player moves
on the odd positions of that list, the auto-reply fills the even ones), so
it runs against the real stratified bank too.

Results go to <emulator>/EMU_TEST_PUZZLE_RESULT.txt; the process then exits
0 (all green) or 1 (failures), so tools/emu-test-puzzle.sh can report.
--]]--

local UIManager = require("ui/uimanager")
local logger    = require("logger")
local lfs       = require("libs/libkoreader-lfs")

local EMU_ROOT    = lfs.currentdir()
local RESULT_FILE = EMU_ROOT .. "/EMU_TEST_PUZZLE_RESULT.txt"
local PLUGIN_ROOT = EMU_ROOT .. "/plugins/slatepuzzle.koplugin"
local POLL        = 0.25
local DEADLINE    = os.time() + 6 * 60  -- hard bail if wedged

local function log(fmt, ...)
    logger.warn("SLATEPUZZLE-EMU " .. string.format(fmt, ...))
end

--------------------------------------------------------------------------------
-- Tiny step harness (identical shape to the chess driver).
--------------------------------------------------------------------------------
local app
local steps = {}
local results = {}
local idx = 1

local function addStep(name, fn)
    steps[#steps + 1] = { name = name, fn = fn }
end

local function finish(ok, why)
    local passed, failed = 0, 0
    for _, r in ipairs(results) do
        if r:find("PASS") then passed = passed + 1 else failed = failed + 1 end
    end
    if why then results[#results + 1] = "ABORT: " .. why end
    local out = { table.concat(results, "\n") }
    out[1] = out[1] .. "\nRESULT: " .. (ok and "PASS" or "FAIL")
    out[1] = out[1] .. ("\nSUMMARY: %d passed, %d failed"):format(passed, failed)
    log(out[1])
    local fh = io.open(RESULT_FILE, "w")
    if fh then fh:write(out[1], "\n"); fh:close() end
    if app and app.settings then pcall(function() app.settings:flush() end) end
    UIManager:scheduleIn(0.2, function() os.exit(ok and 0 or 1) end)
end

local function stepLoop()
    if idx > #steps then finish(true); return end
    if os.time() > DEADLINE then
        log("FAIL %s :: global deadline", steps[idx].name)
        finish(false, ("deadline while running %s"):format(steps[idx].name))
        return
    end
    local step = steps[idx]
    local ok, res = pcall(step.fn)
    if not ok then
        results[#results + 1] = step.name .. ": FAIL " .. tostring(res)
        log("FAIL %s :: %s", step.name, tostring(res))
        finish(false)
        return
    end
    if res == true then
        results[#results + 1] = step.name .. ": PASS"
        log("PASS %s", step.name)
        idx = idx + 1
        UIManager:scheduleIn(0, stepLoop)
    else
        UIManager:scheduleIn(POLL, stepLoop)
    end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function view()
    return app and app.plan and app.plan:view() or nil
end

local function waitFor(cond, timeoutS, label)
    local t0 = os.time()
    return function()
        if cond() then return true end
        if os.time() - t0 > timeoutS then
            error(("timed out waiting for %s"):format(label), 2)
        end
        return false
    end
end

local function once(flag, fn)
    if not flag.v then flag.v = true; fn() end
end

-- The expected *player* ply right now (the machine is on the player's turn
-- whenever `consumed` is even: odd entries in the solution are the
-- player's own plies).
local function nextPlayerPly()
    local sol = app.plan and app.plan:remainingSolution()
    return sol and sol[1] or nil
end

local function playPly(uci)
    assert(type(uci) == "string" and #uci >= 4, "bad uci ply " .. tostring(uci))
    app:onMoveExecuted{
        from      = uci:sub(1, 2),
        to        = uci:sub(3, 4),
        promotion = (#uci > 4) and uci:sub(5) or nil,
    }
end

local function settings(changes)
    if changes.difficulty then app:setSetting("puzzle_difficulty",changes.difficulty) end
    if changes.type then app:setSetting("puzzle_type",changes.type) end
    app:dispatch(app.plan:transition{ kind = "settings", changes = changes })
end

--------------------------------------------------------------------------------
-- Step 1 — boot: bank loads, the first puzzle renders, widgets built
--------------------------------------------------------------------------------
addStep("boot: bank loads, first puzzle rendered", function()
    if not app then
        package.path = string.format("%s/?.lua;%s", PLUGIN_ROOT, package.path)
        local AppMod = dofile(PLUGIN_ROOT .. "/main.lua")
        app = AppMod:new{ ui = { menu = { registerToMainMenu = function() end } } }
        app:startSession()
    end
    local v = view()
    if not v then return false end
    if not app.board then return false end

    app.bank = app.bank or {}
    assert(#app.bank >= 100,
        "the real stratified bank must load (got " .. #app.bank .. ")")
    assert(v.status == "solving", "session must start solving")
    assert(v.puzzle_id and v.puzzle_id ~= "", "a puzzle is loaded")
    assert(v.total >= 1, "a non-empty filtered slice")
    assert(app.board.game == app.game, "board mirrors the machine's game")
    assert(app.top_hud and app.bottom_hud, "both puzzle HUDs must be built")
    assert(app.board.rotate_top_pieces == false, "puzzles never rotate pieces")
    return true
end)

--------------------------------------------------------------------------------
-- Step 2 — a correct move, then the auto-played opponent reply
--------------------------------------------------------------------------------
local g2 = { v = false }
addStep("correct move schedules + auto-plays the opponent reply", function()
    -- Force a type/difficulty whose every puzzle has ≥ 3 plies, so a reply
    -- is guaranteed after the first player move.
    once(g2, function()
        settings{ difficulty = "easy", type = "mateIn2" }
        playPly(nextPlayerPly())
    end)
    local v = view()
    if v.status == "empty" then
        error("no easy mate-in-2 puzzles in the bank")
    end
    -- The first player move consumes 1 ply; the auto-reply lands after.
    local wait_reply = waitFor(function()
            local vv = view()
            return vv and vv.consumed >= 2
        end, 15, "the auto-played reply to the first move")
    if not wait_reply() then return false end

    v = view()
    assert(v.consumed == 2, "two plies consumed (player + reply), got " .. v.consumed)
    assert(v.to_move == v.player_side, "board back to the player after the reply")
    assert(v.status == "solving", "still solving after the reply")
    return true
end)

addStep("footer action geometry and deterministic move replay", function()
    local buttons={app.prev_btn,app.next_btn,app.hint_btn}
    local A=require("ui.layout").puzzleActions(app.bottom_hud.width,app.bottom_hud.height)
    for _,b in ipairs(buttons) do
        assert(b and b.height==A.h,"action buttons must share the specified height")
        assert(b.text_font_face=="cfont" and b.text_font_size==buttons[1].text_font_size,
            "action labels must share typography")
        assert(b.bordersize>0,"action buttons must be visibly outlined")
    end
    assert(buttons[1].width==A.previous.w and buttons[2].width==A.next.w
        and buttons[3].width==A.hint.w,
        "action widths must match the footer specification")
    assert(buttons[1].overlap_offset[1]==A.previous.x
        and buttons[2].overlap_offset[1]==A.next.x
        and buttons[3].overlap_offset[1]==A.hint.x,"actions must use specified x positions")
    assert(app.replay_back_btn and app.replay_forward_btn,
        "move-history chevrons must be present")
    assert(app.replay_back_btn.icon_width==18 and app.replay_back_btn.icon_height==31,
        "chevron glyph must remain a physical 18x31px")
    local before=view()
    assert(before.can_replay_back and not before.can_replay_forward,
        "stable progress enables only replay back")
    app:dispatch(app.plan:transition{kind="replay",direction=-1})
    local review=view()
    assert(review.reviewing and review.replay_cursor==before.consumed-1,
        "back chevron enters one-ply review")
    app:dispatch(app.plan:transition{kind="replay",direction=1})
    assert(not view().reviewing and view().replay_cursor==view().consumed,
        "forward chevron returns to live play")
    return true
end)

--------------------------------------------------------------------------------
-- Step 3 — wrong move is rejected, session continues
--------------------------------------------------------------------------------
addStep("wrong move is rejected, position untouched", function()
    local expected = nextPlayerPly()
    assert(expected, "a player ply must be next")
    -- A guaranteed-different (and board-nonsensical is fine) move: the
    -- machine rejects anything that does not match the expected UCI.
    local wrong = expected:sub(1, 2) .. (expected:sub(3, 4) == "h8" and "a8" or "h8")
    local before = app.game:fen()
    app:onMoveExecuted{ from = wrong:sub(1, 2), to = wrong:sub(3, 4) }
    local v = view()
    assert(v.wrong_attempts >= 1, "wrong move must be counted")
    assert(v.status == "solving", "still solving after a wrong move")
    assert(app.game:fen() == before, "position untouched by the rejection")
    assert(v.consumed == 2, "consumed count unchanged by the rejection")
    return true
end)

--------------------------------------------------------------------------------
-- Step 4 — next / prev navigate (any slice), restart resets
--------------------------------------------------------------------------------
addStep("next/prev navigate; restart resets the current puzzle", function()
    settings{ difficulty = "any", type = "any" }
    local id0 = view().puzzle_id
    app:navPuzzle(1) -- next
    local vid = view().puzzle_id
    assert(vid ~= id0, "next must land on a different puzzle in the any slice")
    app:navPuzzle(-1) -- prev back
    assert(view().puzzle_id == id0, "prev returns to the starting puzzle")
    app:dispatch(app.plan:transition{ kind = "restart" })
    local v = view()
    assert(v.consumed == 0 and v.wrong_attempts == 0, "restart resets progress")
    assert(v.status == "solving", "restart returns to solving")
    return true
end)

--------------------------------------------------------------------------------
-- Step 5 — solve a mate-in-2 puzzle to completion
--------------------------------------------------------------------------------
local g5 = { applied = false }
addStep("solve a mate-in-2 puzzle to completion", function()
    once(g5, function()
        settings{ difficulty = "easy", type = "mateIn2" }
    end)
    local v = view()
    if v.status == "empty" then error("no easy mate-in-2 puzzles") end
    if v.status == "solved" then return true end
    -- On the player's turn? (odd consumed = the auto-reply is mid-flight)
    if v.consumed % 2 ~= 0 then return false end
    playPly(nextPlayerPly())
    return false
end)

--------------------------------------------------------------------------------
-- Step 6 — unknown type empties the set; recovering re-fills it
--------------------------------------------------------------------------------
addStep("unknown type empties the set, recovery re-fills it", function()
    settings{ type = "noSuchType" }
    assert(view().status == "empty", "a bogus type must empty the slice")
    settings{ difficulty = "any", type = "any" }
    assert(view().status == "solving" and view().puzzle_id, "back to solving")
    return true
end)

--------------------------------------------------------------------------------
-- Step 7 — exit persists the resume point; a fresh instance resumes it
--------------------------------------------------------------------------------
addStep("resume: last puzzle survives a fresh session", function()
    app:persistResume()
    local last_id = app:getSetting("last_puzzle", nil)
    assert(last_id, "persistResume must record the current puzzle")

    local AppMod = dofile(PLUGIN_ROOT .. "/main.lua")
    local app2 = AppMod:new{ ui = { menu = { registerToMainMenu = function() end } } }
    app2:startSession()
    local v2 = app2.plan and app2.plan:view()
    assert(v2 and v2.puzzle_id == last_id,
        "fresh instance resumes the same puzzle (got "
        .. tostring(v2 and v2.puzzle_id) .. ", want " .. tostring(last_id) .. ")")
    app2:persistResume()
    return true
end)

stepLoop()
