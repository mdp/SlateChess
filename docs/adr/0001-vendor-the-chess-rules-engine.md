# ADR-0001: Vendor the chess rules engine

Status: accepted, 2026-08-30

## Context

The rules engine (`chess/src/chess.lua`, a Lua port of chess.js) was declared
as a git submodule pointing at `github.com/arizati/chess.lua`, but the
checkout already contained plain tracked files — the submodule was never
actually used as one. CI still assumed submodules, and the Makefile hinted
at `git submodule update` in an error message.

## Decision

Vendor the rules engine: track `chess/src/*.lua` as ordinary files, delete
`.gitmodules`, and drop all submodule assumptions from CI and the Makefile.

## Consequences

- The engine is pinned to our copy; upstream fixes must be pulled manually.
- Never edit `chess/src/` casually — all our code reaches it through the
  Game facade (`core/game.lua`), which is the seam if we ever swap engines.
