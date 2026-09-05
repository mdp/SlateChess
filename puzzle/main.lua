-- SlatePuzzle — chess puzzles for KOReader.
--
-- This file is the plugin entry point; the App widget (controller + view)
-- lives in puzzle_app.lua (renamed from app.lua so the module name can't
-- collide with SlateChess's `require("app")` inside one KOReader process).
-- The plugin uses the same board and rules engine as SlateChess (staged
-- copies); see the repo README and docs for the split.

local PuzzleApp = require("puzzle_app")

return PuzzleApp