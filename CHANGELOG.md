# Changelog

All notable changes to SlateChess. The format is Keep a Changelog-ish;
newest first. SlateChess is a fork of Casual Chess for KOReader — see
LICENSE for the full attribution history.

## 1.0.0 — 2026-08-31

First SlateChess release. The plugin was renamed from PlyChess and now
lives at https://github.com/mdp/SlateChess; history before this point
(Casual Chess and its ancestors) is squashed and credited in LICENSE.

### Renamed to SlateChess
- New name everywhere: plugin metadata, menus, dispatcher action, settings
  file (`slatechess.lua`), icon paths, packaging and CI.
- One-time migrations on first launch: settings are copied from
  `plychess.lua`, and the old icon cache dir is removed.

### About dialog
- New "About SlateChess" entry in the hamburger menu: version, the most
  recent changelog entries, and a GitHub link (opens in the browser on
  devices that support it).

### Board markers
- Corner-bracket marks: └ ┐ on the last-move squares, four corners on the
  selected square; the old solid ring and dashed from/to outlines are gone.
- Fixed a regression where the marker overlay swallowed all board input.
- E-ink ghosting on moved squares is cleared with a scheduled refresh.

### Clock and layout
- Untimed games no longer show a running clock; timer font is a notch bigger.
- Larger coordinates, clock card sizing fixes, per-move evals in the
  notation strips, and Flip Board in the menu.
- Analysis lines wait until the computer has moved.

### Under the hood
- Chal engine with `go movetime` and `ucinewgame` TT-clear patches; a
  hardened search lifecycle (watchdog, stalled-search recovery).
- Layered core/engine/ui architecture with a busted test suite and
  luacheck-clean sources.
