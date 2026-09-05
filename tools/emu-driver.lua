--[[--
SlateChess — emulator end-to-end test pass.

Installed by tools/emu-test.sh into <emulator>/patches/2-slatechess-emu.lua
and executed as a "late" (priority 2) userpatch: once KOReader's UIManager
is up.

It boots the plugin the way KOReader would (App:new + startGame), then drives
a scripted session through the App's public surface — human moves, engine
replies, the eval pipeline, undo/redo, flip, a real settings apply (roles-only
preserving the clock), a PGN load with the computer to move, human-vs-human
(no per-turn piece flip), a flag-fell finish, and a save→re-boot restore —
asserting the arbiter view model and the rendered widgets at every step.

Results go to <emulator>/EMU_TEST_RESULT.txt; the process then exits 0 (all
green) or 1 (failures), so tools/emu-test.sh can report and clean up.
--]]--

local UIManager = require("ui/uimanager")
local logger    = require("logger")
local lfs       = require("libs/libkoreader-lfs")

local EMU_ROOT    = lfs.currentdir()
local RESULT_FILE = EMU_ROOT .. "/EMU_TEST_RESULT.txt"
local PLUGIN_ROOT = EMU_ROOT .. "/plugins/slatechess.koplugin"
local POLL        = 0.25
local DEADLINE    = os.time() + 6 * 60  -- hard bail if wedged

local function log(fmt, ...)
    logger.warn("SLATECHESS-EMU " .. string.format(fmt, ...))
end

--------------------------------------------------------------------------------
-- Tiny step harness: each step fn returns `true` (done, PASS) or `false`
-- (poll again) or raises (fail, abort the run). Steps run strictly in order.
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
    return app and app.arbiter and app.arbiter:view() or nil
end

local function game()
    return app and app.arbiter and app.arbiter.game or nil
end

--- Poll wrapper: keep returning false until cond() is true, RAISE on timeout.
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

--- Fire one-shot guarded action so a re-polled step never re-dispatches it.
local function once(flag, fn)
    if not flag.v then flag.v = true; fn() end
end

--- The Arbiter `settings` event with the exact payload the dialog's onApply
--- closure builds (ui/settings_dialog.lua applyAndClose -> app.lua onApply).
local function applySettings(changes)
    app:dispatch(app.arbiter:transition{ kind = "settings", changes = changes })
end

--------------------------------------------------------------------------------
-- Boot-time settings so every run starts identically.
--------------------------------------------------------------------------------
local PREF = {
    human_white = true, human_black = false,
    timed = true,
    time_base_white = 60, time_base_black = 60,
    time_incr_white = 5,  time_incr_black = 5,
    skill_level = 0, engine_depth = 2, engine_movetime = 1, blunder_chance = 0.2,
    flip_board = false, rotate_top_pieces = false, flip_pieces_each_turn = false,
    show_eval = true, show_hints = false, figurine_pgn = false,
    thinking_indicator = true,
    learning_mode = false, show_selected = true,
    previous_move_hints = true, opponent_hints = false, check_hints = false,
    saved_pgn = "",
}

--------------------------------------------------------------------------------
-- Step 1 — boot
--------------------------------------------------------------------------------
addStep("boot: fresh timed game, engine handshakes, widgets built", function()
    if not app then
        package.path = string.format("%s/?.lua;%s", PLUGIN_ROOT, package.path)
        local AppMod = dofile(PLUGIN_ROOT .. "/main.lua")
        app = AppMod:new{ ui = { menu = { registerToMainMenu = function() end } } }
        for k, v in pairs(PREF) do app:setSetting(k, v) end
        app:startGame()
    end
    local v = view()
    if not v then return false end
    if v.engine_state == "failed" then
        error("engine failed to start: " .. tostring(app:getEngineStatusText()), 2)
    end
    if v.engine_state ~= "ready" then return false end

    -- The strips are keyed by the chess color constants ('w'/'b').
    local wrow = app.notation_history and app.notation_history["w"]
    assert(app.board, "board widget must be built")
    assert((wrow and wrow[1] and wrow[2]) or app.computer_hud,
        "a player strip or computer HUD must be built")
    assert(app.board.game == game(), "board must mirror the arbiter's game")
    assert(math.abs(v.clock_times.white - 60) < 0.01, "white clock at base 60")
    assert(math.abs(v.clock_times.black - 60) < 0.01, "black clock at base 60")
    assert(v.running == false, "a fresh game does not auto-run")
    assert(v.can_undo == false and v.can_redo == false, "fresh game has no history")
    assert(v.game_over == nil, "fresh game: nothing over")
    assert(#v.notation_lines == 2, "two notation rows projected")
    return true
end)

--------------------------------------------------------------------------------
-- Step 2 — human opens e4, engine replies
--------------------------------------------------------------------------------
local g2 = { v = false }
addStep("human opens e4, engine replies, strips + board render it", function()
    once(g2, function()
        app:onMoveExecuted{ from = "e2", to = "e4" }
    end)
    local wait = waitFor(function()
        return #(game():sanHistory()) >= 2
    end, 30, "the engine's reply to 1. e4")
    if not wait() then return false end

    local sans = game():sanHistory()
    assert(sans[1] == "e4", "first ply rendered as e4, got " .. tostring(sans[1]))
    assert(type(sans[2]) == "string" and #sans[2] >= 2,
        "engine replied with a uci move")
    local v = view()
    assert(v.running == true, "game runs after the opening move")
    assert(v.game_over == nil, "no game over after one exchange")
    assert(v.whose_clock == "w" or v.whose_clock == "b", "a clock is live")
    assert(v.can_undo == true, "history is undoable")
    -- The strip widgets rendered the projected lines.
    local lines=v.notation_lines or {}
    assert(table.concat(lines," "):find("e4",1,true),"e4 projected into notation")
    -- Clock accounting: both clocks are live and sane after the exchange —
    -- each remaining is within [base-5, base+increment] (increments may
    -- have banked at the switches; neither clock has been wiped or freed).
    assert(v.clock_times.white > 58 and v.clock_times.white <= 65,
        ("white clock out of band: %.2f (base 60, incr 5)")
        :format(v.clock_times.white))
    assert(v.clock_times.black > 55 and v.clock_times.black <= 65,
        ("black clock out of band: %.2f (base 60, incr 5)")
        :format(v.clock_times.black))
    return true
end)

--------------------------------------------------------------------------------
-- Step 3 — the eval pipeline reaches the eval row
--------------------------------------------------------------------------------
addStep("eval pipeline feeds the eval row", function()
    -- The move search's info commits `_current_cp`, so the eval row fills in
    -- shortly after the reply lands (analysis may re-run after it too).
    local wait = waitFor(function()
        local v = view()
        return v.eval_text and v.eval_text ~= ""
    end, 20, "a committed eval for the current position")
    if not wait() then return false end
    local v = view()
    local total = app.notation_totals and app.notation_totals["w"]
    assert(total or app.computer_hud, "eval row or computer HUD exists")
    assert(v.eval_text:find("%d"), "eval text carries a number: " .. v.eval_text)
    return true
end)

--------------------------------------------------------------------------------
-- Step 4 — undo-all and redo-all
--------------------------------------------------------------------------------
local g4 = { v = false }
addStep("undo-all restores the book, redo-all replays it", function()
    once(g4, function()
        app:handleUndoMove(true)
        app:handleRedoMove(true)
    end)
    local wait = waitFor(function()
        return #(game():sanHistory()) >= 2
    end, 20, "redo to replay the undone plies")
    if not wait() then return false end

    local sans = game():sanHistory()
    assert(sans[1] == "e4" and sans[2], "redone position matches the opening")
    local v = view()
    assert(v.can_undo == true, "replayed game is undoable again")
    assert(v.can_redo == false, "redo stack exhausted after redo-all")
    assert(v.game_over == nil, "still a live game after redo")
    -- The strip still renders the replays.
    local text = table.concat(v.notation_lines or {}, " ")
    assert(text:find("e4", 1, true), "notations stay rendered after redo")
    return true
end)

--------------------------------------------------------------------------------
-- Step 5 — flip preference toggles orientation
--------------------------------------------------------------------------------
local g5a = { v = false }
local g5b = { v = false }
addStep("flip preference toggles the board orientation", function()
    local v0 = view()
    once(g5a, function()
        app:toggleBoardFlip()
    end)
    local wait = waitFor(function()
        return view().flipped ~= v0.flipped
    end, 10, "the flip to reach the view")
    if not wait() then return false end
    assert(view().flipped == true, "flipped reads true after one toggle")
    assert(view().white_at_bottom == false, "white no longer at the bottom")

    once(g5b, function()
        app:toggleBoardFlip()  -- and back
    end)
    local wait2 = waitFor(function()
        return view().flipped == false
    end, 10, "the un-flip to reach the view")
    if not wait2() then return false end
    assert(view().white_at_bottom == true, "white at the bottom again")
    return true
end)

--------------------------------------------------------------------------------
-- Step 6 — play on, then a roles-only settings apply preserves the clocks
--------------------------------------------------------------------------------
local g6a = { v = false }
local g6b = { v = false }
addStep("roles-only settings apply keeps clock remaining (live-bug #2)", function()
    once(g6a, function()
        -- Human (white) continues: play d4, let the engine answer.
        app:onMoveExecuted{ from = "d2", to = "d4" }
    end)
    local wait = waitFor(function()
        return #(game():sanHistory()) >= 4
    end, 30, "the engine's reply to 1.e4 ... 2.d4")
    if not wait() then return false end

    local before = view()
    local w0, b0 = before.clock_times.white, before.clock_times.black
    assert(w0 > 0 and b0 > 0, "both clocks are live before the apply")
    assert(w0 < 120 and b0 < 120, "clocks are within a sane band")

    once(g6b, function()
        -- Roles-only: black becomes human, white computer. Time control and
        -- the clock itself are untouched.
        applySettings{
            human_white = false, human_black = true,
        }
    end)
    local wait2 = waitFor(function()
        return view().flipped == true
    end, 10, "black-at-bottom after the roles flip")
    if not wait2() then return false end

    local after = view()
    assert(after.clock_times, "clock survives a roles-only apply")
    assert(math.abs(after.clock_times.white - w0) < 3,
        ("white clock preserved (was %.1f, now %.1f)"):format(w0, after.clock_times.white))
    assert(math.abs(after.clock_times.black - b0) < 3,
        ("black clock preserved (was %.1f, now %.1f)"):format(b0, after.clock_times.black))
    assert(after.engine_should_move == true,
        "computer (now white) is on move and must think")
    return true
end)

--------------------------------------------------------------------------------
-- Step 7 — PGN load with the computer to move launches a search (live-bug #1)
--------------------------------------------------------------------------------
local g7 = { v = false }
addStep("pgn_loaded with the computer to move launches a search", function()
    once(g7, function()
        -- White is the computer now; "1. e4 e5 2. Nf3 Nc6" leaves white to
        -- move, so the arbiter must go — never sit dead.
        app:dispatch(app.arbiter:transition{ kind = "pgn_loaded",
            pgn = "1. e4 e5 2. Nf3 Nc6" })
    end)
    local wait = waitFor(function()
        return #(game():sanHistory()) >= 5
    end, 30, "the computer's reply after the PGN load")
    if not wait() then return false end

    local sans = game():sanHistory()
    assert(#sans >= 5, "hs=" .. tostring(#sans) .. " ["
        .. table.concat(sans, " ") .. "]")
    if sans[5] then
        assert(#sans[5] >= 2, "the reply is a uci move")
    end
    local v = view()
    assert(v.running == true, "a loaded computer-to-move game runs")
    assert(v.game_over == nil, "no game over after the PGN load")
    return true
end)

--------------------------------------------------------------------------------
-- Step 8 — human-vs-human keeps a fixed board (no per-turn piece flip)
--------------------------------------------------------------------------------
local g8a = { v = false }
local g8b = { v = false }
local g8c = { v = false }
local g8d = { v = false }
local g8e = { v = false }
addStep("hvh keeps a fixed board, far pieces angle to their side", function()
    once(g8a, function()
        -- Roles-only apply: both sides human. With "Flip pieces to player
        -- on each turn" off (the default) the board must NOT pivot toward
        -- the mover; each side's far pieces angle toward their own player
        -- instead (rotate_top_pieces is always true in hvh).
        applySettings{
            human_white = true, human_black = true,
        }
    end)
    local wait = waitFor(function()
        local g = game()
        local v = view()
        return g and g:isHumanVsHuman()
            and v.rotate_top_pieces == true and v.face_color == "w"
    end, 10, "the hvh fixed-orientation apply to land")
    if not wait() then return false end

    local pre
    once(g8b, function()
        -- Both sides human: play the side to move's first legal move.
        -- No engine involved, so it lands without a search.
        local g = game()
        pre = #(g:sanHistory())
        local gbm = {}
        for _, m in ipairs(g:legalMoves{ verbose = true }) do
            if not m.promotion then gbm[#gbm + 1] = m end
        end
        assert(#gbm > 0, "a legal non-promotion move exists in hvh")
        local m = gbm[1]
        app:onMoveExecuted{ from = m.from, to = m.to }
    end)
    local wait2 = waitFor(function()
        return #(game():sanHistory()) >= pre + 1
    end, 10, "the human-vs-human move to land")
    if not wait2() then return false end

    local v = view()
    assert(v.face_color == "w",
        "the board never pivots toward the mover (face="
            .. tostring(v.face_color) .. ")")
    assert(v.rotate_top_pieces == true, "far pieces keep facing their side")
    if app.board then
        assert(app.board.face_color == "w",
            "board widget's face color stays parked at white")
        assert(app.board.rotate_top_pieces == true,
            "board widget angles the far side's pieces")
    end

    -- "Flip pieces to player on each turn" turns the old pivot back on:
    -- after the next move the whole board must follow the side to move.
    once(g8c, function()
        applySettings{ flip_pieces_each_turn = true }
    end)
    local pre2
    once(g8d, function()
        local g = game()
        pre2 = #(g:sanHistory())
        local gbm = {}
        for _, m in ipairs(g:legalMoves{ verbose = true }) do
            if not m.promotion then gbm[#gbm + 1] = m end
        end
        assert(#gbm > 0, "a legal non-promotion move exists to pivot over")
        local m = gbm[1]
        app:onMoveExecuted{ from = m.from, to = m.to }
    end)
    -- White is on move here (black played the first hvh ply), so after
    -- white's reply the side to move is black and the face must go black.
    local wait3 = waitFor(function()
        return #(game():sanHistory()) >= pre2 + 1
            and view().face_color == "b"
            and view().rotate_top_pieces == false
    end, 10, "the per-turn face pivot to turn back on")
    if not wait3() then return false end
    assert(view().rotate_top_pieces == false, "far-side angling yields to the pivot")

    -- And back off: fixed board, far pieces facing their owner again.
    once(g8e, function()
        applySettings{ flip_pieces_each_turn = false }
    end)
    local wait4 = waitFor(function()
        return view().face_color == "w" and view().rotate_top_pieces == true
    end, 10, "the fixed board to return")
    if not wait4() then return false end
    return true
end)

--------------------------------------------------------------------------------
-- Step 9 — a flag-fell finishes the game on time
--------------------------------------------------------------------------------
local g9a = { v = false }
local g9b = { v = false }
addStep("flag-fell finishes the game on time", function()
    once(g9a, function()
        -- Tight time control: 10s base, no increment.
        applySettings{
            human_white = false, human_black = true,
            timed = true,
            time_base_white = 10, time_base_black = 10,
            time_incr_white = 0, time_incr_black = 0,
        }
    end)
    -- The hvh step left either side near its time; wait until the human
    -- (black) is on move under the tight control — the computer (white)
    -- may need to answer the previous ply first. Then play a legal
    -- non-promotion move and let the tight clock run out.
    local wait = waitFor(function()
        local g = game()
        return g and g:isHuman(g:turn()) and view().engine_state == "ready"
    end, 30, "the human side to be on move under the tight clock")
    if not wait() then return false end

    once(g9b, function()
        local g = game()
        local gbm = {}
        for _, m in ipairs(g:legalMoves{ verbose = true }) do
            if not m.promotion then gbm[#gbm + 1] = m end
        end
        assert(#gbm > 0, "a legal non-promotion move exists to play")
        local m = gbm[1]
        app:onMoveExecuted{ from = m.from, to = m.to }
    end)
    local wait2 = waitFor(function()
        return view().game_over ~= nil
    end, 45, "the flagged side to lose on time")
    if not wait2() then return false end

    local v = view()
    assert(v.game_over.over == true, "game_over carries the over flag")
    assert(v.running == false, "the clock stops at flag-fell")
    -- The verdict text ("... wins on time.") is pinned by the unit spec
    -- (spec/arbiter_spec.lua flag-fall test); here we assert the state
    -- transition itself: the game is over and the machine stopped.
    assert(v.whose_clock == nil, "no clock is live after the finish")
    return true
end)

--------------------------------------------------------------------------------
-- Step 10 — the save survives and a re-boot restores the game
--------------------------------------------------------------------------------
local g10a = { v = false }
local g10b = { v = false }
local n10
addStep("save persists; a re-boot restores the position", function()
    once(g10a, function()
        app:dispatch(app.arbiter:transition{ kind = "save_requested" })
        n10 = #(game():sanHistory())
    end)
    local saved_pgn = app:getSetting("saved_pgn", "")
    if saved_pgn == "" then
        return false  -- persist effect has to land first
    end
    assert(n10 and n10 > 0, "the saved game has plies")

    once(g10b, function()
        app:startGame()  -- simulate KOReader relaunching the game
    end)
    local wait = waitFor(function()
        local v = view()
        return v and v.engine_state == "ready"
    end, 30, "the engine handshake after re-boot")
    if not wait() then return false end

    local sans = game():sanHistory()
    assert(#sans == n10,
        ("restored position has %d plies (saved %d)"):format(#sans, n10))
    local v = view()
    assert(v.running == false, "restored game does not auto-run (saved stopped)")
    assert(app.board.game == game(), "board mirrors the restored game")
    return true
end)

--------------------------------------------------------------------------------
-- Go
--------------------------------------------------------------------------------
UIManager:nextTick(function()
    UIManager:scheduleIn(0.5, stepLoop)
end)
