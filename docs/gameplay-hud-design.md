# Gameplay HUD design language

This is the shared, human- and agent-facing specification for SlateChess and
SlatePuzzle gameplay. `ui/gameplay_design.lua` and its exact-value tests are
the source of truth; this document explains how to apply those executable
tokens.

## Coordinate system and scaling

Geometry is authored against a 1080×1440 framebuffer. `(x, y)` always means a
widget's top-left framebuffer bound, not a text baseline. Scale uniformly with
`k = min(screen_w / 1080, screen_h / 1440)` and round geometry to framebuffer
pixels. Board cells are floored before multiplication so every cell and the
resulting square board remain integral.

| Region | Master rectangle |
|---|---|
| Content frame | `x=32, w=1016` |
| Top HUD | `32, 12, 1016, 164` |
| Board | `32, 184, 1016, 1016`, cell `127` |
| File rail | `32, 1200, 1016, 40` |
| Chess bottom HUD | `32, 1263, 1016, 175` |
| Puzzle footer | `32, 1244, 1016, 196` |

Each HUD owns one 1px board-facing divider. The active-player tab is
`x=336, w=345, h=5` relative to the HUD and straddles that rule by 2px. A top
two-player strip is the same player strip rotated 180°, including its content.

## Columns and top HUD

The text-safe columns are `(8,312)`, `(352,312)`, and `(696,312)`, giving 32px
gutters. The one-third/two-thirds variant uses `(8,312)` and `(352,656)`.
Kickers start at y=12 (14px request, 18px rendered cap); primary values at y=42
(19px, 25px cap). Compact rows start at y=42, 76, and 110 (14px, 19px cap),
with emphasized values at 16px/21px and micro qualifiers at 9px/12px. Final-row
graphics are at most 31px tall. Content ends at y=141, leaving 22px before the
divider.

Puzzle assigns PUZZLE, RATING, and TYPE to the three columns. Computer assigns
identity/rating, recent evaluations, and suggested moves to those same slots.
Paired row values align to the slot's left and right edges.

## Bottom HUDs

Chess content occupies y=16…159. Captures use `(8,312)`, replay `(352,312)`,
and clock `(696,312)`. Replay consists of 40px chevron targets around a 232px
notation field. Far and near clock requests are 19px and 30px, capped by
measured heights of 42px and 64px.

Puzzle places MOVES at `(58,20)` and notation at `(58,48)`, with chevrons at
`(10,40,40,48)` and `(277,40,40,48)`. Status is right-aligned to x=1008 at
y=48 in a maximum 398px region. MOVES, notation, and status use 20/30/28px
requests with 23/35/32px rendered caps. Information glyphs keep at least 16px
clear of the action row.

The action row is y=116, h=58. Its menu slot is `(0,116,72,58)`; PREVIOUS,
NEXT, and HINT are equal 220px controls at x=324, 556, and 788, with 12px gaps
and an 8px trailing inset. Labels share the regular 14px face and 18px cap.
Hiding Hint copy never collapses its rectangle.

## Text and interaction

Dynamic text is measured using actual KOReader glyph bounds inside its named
rectangle. `ui/fitted_text.lua` reduces it from the role target to the scaled
minimum, then truncates at a UTF-8 glyph boundary with an ellipsis if required.
It never paints outside the assigned rectangle. Fixed labels and predefined
statuses assert when they do not fit.

The hamburger ink is 48×30: three 48×6 strokes on a 12px cadence. Standalone
Chess ink begins at `(30,1380)` and uses target `(18,1359,72,72)`. Puzzle
centers the same ink in its menu slot and centers a 72×72 invisible target on
that slot, which may extend beyond the visual action row. A north swipe from
the bottom 12% remains available.

## Allowed variants and no-overlap checklist

Allowed top variants are Puzzle metadata, one-player Computer analysis, and a
rotated two-player strip. Allowed bottoms are the Chess strip and Puzzle action
footer. New variants must reuse named slots or add tokens and exact tests.

Before shipping, verify: integral board cells; complete on-screen composition;
one divider per HUD; no board/HUD intersection; all text contained by its slot;
disjoint columns and controls; at least 16px information/action clearance;
equal action sizes; 72×72 hamburger targets; rotated bounds preserved; and live
resize results validated at every resolution in `e-reader-resolutions.md`, the
1024×1416 emulator, and the height-limited wide viewport.
