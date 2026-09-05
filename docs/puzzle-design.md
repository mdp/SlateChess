# SlatePuzzle data & types

How real Lichess puzzles get into SlatePuzzle, and how the "puzzle type"
dropdown is built. Ground rules: everything here is **pure Lua** where it
runs on the device, and the **catalog in `core/puzzle_types.lua` is the
single source of truth** for both the app UI and the bank builder.

## The data source

Lichess publishes the whole puzzle database for download (CC0):

- `https://database.lichess.org/lichess_db_puzzle.csv.zst` (~300 MB
  compressed, ~7 GB as text, ~4M puzzles)
- It is **sorted by puzzle id**, which is effectively a random shuffle for
  sampling purposes.

Real CSV shape (verified against a 2026-08 dump):

```
PuzzleId,FEN,Moves,Rating,RatingDeviation,Popularity,NbPlays,Themes,GameUrl,OpeningTags,DailyDate
00008,r6k/…7K b - - 0 24,f2g3 e6e7 …,1939,77,95,10000,crushing hangingPiece long middlegame,https://lichess.org/787zsVup/black#48,,
```

- `Moves` — the FULL recorded line, space-separated UCI, with Lichess's
  own semantics (confirmed against `lichess.org/api/puzzle/<id>`): the FEN
  is the position **BEFORE the opponent's decisive move**, and the line is
  **[opponent's lead-in blunder] + the solver's winning sequence**,
  alternating solver/reply. Real rows therefore have an even ply count. The
  solver is the side **opposite** the FEN's active color (the player is the
  one who makes the winning moves). `Puzzles.blunder` returns the lead-in
  (applied when the puzzle is loaded) and `Puzzles.solution` returns the
  solver-first interactive line (`[solver1, opponent1, solver2, …]`), so
  after the pre-blunder the player is always at the bottom facing the
  opponent, exactly as on lichess.org. The converter's quality gate keeps
  only rows whose replay leaves the solver winning (mates or clearly
  better), dropping the handful of corrupt/reversed rows.
- `Themes` — **space-separated** tag tokens (`fork middlegame`). Older
  dumps encoded a JSON array; the parser handles both.
- `OpeningTags` — **space-separated** underscore-joined opening names
  (`Sicilian_Defense`, `Sicilian_Defense_Najdorf`). Older dumps used JSON
  arrays too.
- `Popularity` — `100 * (upvotes - downvotes)/(upvotes + downvotes)`,
  weighted by solver strength and solve success: the human-quality signal
  (a negative value means players vote the puzzle down as bad/cheaty).
- `NbPlays` — how many times the puzzle has been solved. Combined with
  `Popularity` this is the "has this puzzle been human-vetted" gate.
- `RatingDeviation` — Glicko-2 RD; a high value means the rating hasn't
  stabilized (few plays).
- Every puzzle carries a phase theme — `opening`/`middlegame`/`endgame`
  cover ~100% of rows (checked: 0 missing in 500k). Goals
  (`equality`/`advantage`/`crushing`/`mate`) and lengths
  (`oneMove`/`short`/`long`/`veryLong`) are full themes too.

Observed vocabulary decisions worth knowing:

- There is **no `stalemate` theme** (0 hits in 500k).
- Apostrophes are dropped in opening tags: `Kings_Pawn_Game`,
  `Queens_Gambit_Declined`, `Kings_Indian_Defense`.
- Caro-Kann is published as `Kann_Defense` (recent lila rename); the
  catalog matches both `Kann_Defense` and legacy `Caro-Kann_Defense`.
- Even rare themes are plentiful: `enPassant` ≈ 0.14%, `underPromotion`
  ≈ 0.02% (~700 in the whole DB), `bodenMate` ≈ 0.07%.

## The catalog (`core/puzzle_types.lua`)

A curated, ordered list of types, each with:

- `id` — persisted settings value (`any`/`random` = no type filter)
- `label` — the human name in the picker
- `desc` — a one-line explanation shown under the label in the picker
- `group` — picker section (`mates`, `tactics`, `patterns`, `endgames`,
  `pawns`, `phases`, `goals`, `lengths`, `openings`)
- `kind` + match lists:
  - `anyTheme` — record has ≥1 of these Lichess themes
  - `prefix` — a record tag starts with one of these opening-family
    prefixes at a `_` boundary (so `Sicilian_Defense` matches
    `Sicilian_Defense_Najdorf` but not `Sicilian_Game`)
- `build_quota` — guaranteed records per type when building the bank

Beyond the classic tactics/phases, the catalog now mirrors Lichess's full
vocabulary:

- **Goals** — `equality`, `advantage`, `crushing`, `mate` (a free
  difficulty/completion-axis; `mate` overlaps the `mateInN` types, which is
  fine — a record can match several types at once).
- **Lengths** — `oneMove`, `short`, `long`, `veryLong` (a free
  session-length axis).
- **Named mate patterns** — the whole visible mate-theme family:
  `balestra`, `blindSwine`, `cornerMate`, `doubleBishop`, `dovetail`,
  `epaulette`, `hook`, `killBox`, `pillsbury`, `morphy`, `swallowtail`,
  `triangle`, `vukovic`.

**`Random` is not a matcher.** It is the UI/constraint meaning "no type
filter" (`Puzzles.filter` with `type="any"`), i.e. the whole bank.

## The pipeline

```
zstd -dc lichess_db_puzzle.csv.zst
  └─ tools/convert-puzzles.lua  (RATING_MIN/MAX, LIMIT, QUOTA_SCALE,
   │                             MIN_PLAYS, MIN_POPULARITY, MAX_RD)
       └─ data/puzzles.json     (one compact record per line)
            └─ staged into slatepuzzle.koplugin/data/puzzles.json
```

`tools/puzzle-stats.lua` is a vocabulary/census tool for researching future
dumps (theme counts, opening families, phase coverage, ratings).

Usage:

```sh
# from a local .zst (avoids re-downloading the 300 MB file)
sh tools/fetch-puzzles.sh /path/to/lichess_db_puzzle.csv.zst

# skinnier bank: halve every type's quota
QUOTA_SCALE=0.5 sh tools/fetch-puzzles.sh ...

# tighter quality: only puzzles played ≥100 times, voted ≥+30
MIN_PLAYS=100 MIN_POPULARITY=30 sh tools/fetch-puzzles.sh ...

# or skip the CSV materialization entirely for a one-off rebuild
zstd -dc lichess_db_puzzle.csv.zst | luajit tools/convert-puzzles.lua \
  > data/puzzles.json
```

The converter keeps the human-vetting metadata (popularity `p`, plays `pl`,
dropping only the RD from the stored record) and, beyond the legality/outcome
gate, skips records nobody has solved (`MIN_PLAYS < 20` by default), that are
downturned (`popularity < 0`), or whose rating hasn't stabilized
(`MAX_RD`). Sampling is stratified: every catalog type's `build_quota` is
met first, then a fallback pool tops the bank up toward `LIMIT`, so a big
bank never starves the rare mate patterns.

The current release bank is **12,000 records / ~2.5 MB** (all quotas met),
which loads in well under a second on device.

## Runtime filtering & the picker

- `Puzzles.filter(bank, { type = "fork", rating_min, rating_max })` —
  pure, linear, and identical to what the bank builder used, so a
  regenerated bank can never drift from the UI's vocabulary.
- The machine (`core/puzzle.lua`) stores the type id; changing a filter
  axis on the `settings` transition **re-draws a fresh random puzzle** of
  the new type (previous behavior preserved the current puzzle — unhelpful
  when you pick "Sicilian").
- The picker (`puzzle/ui/type_picker.lua`) is a KOReader `Menu`:
  Random + one submenu per group, `✓` on the current selection, and live
  per-type counts from `PuzzleTypes.counts(bank)`.
- Persisted settings: `puzzle_type`, `puzzle_difficulty`, and
  `puzzle_adaptive_rating`, stored in
  `slatepuzzle.lua`.

## Coverage beats and the emulator driver

Because the driver asserts on *any* machine-drawn puzzle (it reads the
expected ply from `Puzzle:remainingSolution()` and plays it), it runs on
the real bank. Step 5 forces `easy` + `mateIn2` (guaranteed ≥3 plies) so
the auto-reply path is exercised deterministically; step 6 uses a bogus
type id to force the empty-announce path.
