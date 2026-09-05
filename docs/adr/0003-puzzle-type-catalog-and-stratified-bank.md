# ADR-0003: puzzle types — one shared catalog, stratified bank

Status: accepted, 2026-08-31

## Context

SlatePuzzle needed a real, offline puzzle bank and a way to pick what kind
of puzzle you practice. The Lichess puzzle DB (CC0, `database.lichess.org`)
is free and open; its rows carry space-separated Themes
(`fork middlegame`) and OpeningTags (`Sicilian_Defense Najdorf …`). Two
naive approaches were rejected:

- **Raw exploding-themes UI**: enumerating every distinct Lichess theme
  (~70 tokens, many overlapping or obscure — `morphysMate` vs `operaMate`)
  is a poor dropdown.
- **Blind prefix sample**: taking the first N rows of the DB leaves rare
  but fun types (underpromotion, smothered mates, en passant) with almost
  nothing, so selecting them shows an empty set.

## Decision

- One **curated catalog** (`core/puzzle_types.lua`, pure Lua) is the single
  source of truth for both the app UI and the bank builder. Each type has
  an `id` (the persisted setting), a `label`, a matcher (`anyTheme`,
  `prefix` for opening families), and a `build_quota`.
- The bank is **stratified**: `tools/convert-puzzles.lua` partitions the DB
  by catalog type with per-type quotas, so every type is guaranteed a
  usable count in the embedded `data/puzzles.json`. A record can satisfy
  several types at once (a `fork` in the `middlegame` trains both) and is
  stored once.
- Tag matching (and therefore type filtering at runtime) is **pure and
  shared**: `Puzzles.filter` and the builder both use
  `PuzzleTypes.matches`. "Random" is not a matcher — it is the absence of a
  type filter.
- The build curve: `fetch-puzzles.sh` → `convert-puzzles.lua` (env knobs
  `RATING_MIN/MAX`, `LIMIT`, `QUOTA_SCALE`) → `data/puzzles.json`.

## Consequences

- Rare types stay solveable offline (guaranteed ≥ quota records each) and
  "No puzzles match" is practically unreachable on release banks.
- The type vocabulary is curated and stable; growing it means editing one
  pure module + regenerating the bank.
- Themes parsed from the DB must match the catalog's real vocabulary (the
  parser handles both the current space-separated encoding and the older
  JSON-array encoding; opening prefixes are matched at a `_` boundary).
- The bank is ~8k records / ~1.6 MB — trivially small for KOReader and
  regenerable in seconds from a local `.zst`.