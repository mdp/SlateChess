-- Eval: parsing and human-readable formatting of engine evaluations.
--
-- Pure Lua. `parseInfo` reads one UCI "info … score …" line; `format`
-- renders the eval line shown under the move log. Scores passed to
-- `format` are always from White's perspective (positive = White is
-- better); `toWhitePerspective` converts an engine-relative score using
-- the side the engine was searching for.

local Eval = {}

--- Parses a UCI "info" line.
-- Returns `{ multipv = n, cp = n | nil, mate = n | nil }` for the
-- principal variation (multipv 1), nil for anything else.
function Eval.parseInfo(line)
    if type(line) ~= "string" or not line:match("^info ") then return nil end
    local multipv = tonumber(line:match(" multipv (%d+)")) or 1
    if multipv ~= 1 then return nil end
    local cp   = tonumber(line:match(" score cp (-?%d+)"))
    local mate = tonumber(line:match(" score mate (-?%d+)"))
    if not cp and not mate then return nil end
    return { multipv = multipv, cp = cp, mate = mate }
end

--- Parses a UCI "info" line for hint extraction: any PV slot, plus the
-- PV's first move. Returns
-- `{ multipv = n, cp = n | nil, mate = n | nil, move = "e2e4" }`, or nil
-- when the line carries no score or no pv token.
function Eval.parsePv(line)
    if type(line) ~= "string" or not line:match("^info ") then return nil end
    local multipv = tonumber(line:match(" multipv (%d+)"))
    local cp   = tonumber(line:match(" score cp (-?%d+)"))
    local mate = tonumber(line:match(" score mate (-?%d+)"))
    local move = line:match(" pv (%S+)")
    if not (multipv and (cp or mate) and move) then return nil end
    return { multipv = multipv, cp = cp, mate = mate, move = move }
end

-- Figurine glyphs by color: white moves use the outlined set, black the
-- filled set. FreeSerif ships all twelve; the sans fonts ship none, so
-- TextWidget's fallback chain picks them up from FreeSerif.
local FIGURINES = {
    w = { N = "♘", B = "♗", R = "♖", Q = "♕", K = "♔" },
    b = { N = "♞", B = "♝", R = "♜", Q = "♛", K = "♚" },
}

--- Renders a SAN move with figurine piece symbols for `color` ("w"/"b").
-- Leading piece letters and promotion pieces become glyphs; pawn moves,
-- castling and check/mate suffixes are untouched
-- ("Nbd2" -> "♘bd2", "e8=Q+" -> "e8=♕+", "exd5" -> "exd5").
function Eval.figurine(san, color)
    local map = FIGURINES[color] or FIGURINES.w
    san = san:gsub("^%a", function(c) return map[c] or c end)
    san = san:gsub("=([NBKRQ])", function(c) return "=" .. (map[c] or c) end)
    return san
end

--- Converts an engine-relative score to White's perspective.
-- `score` is centipawns or moves-to-mate; `turn` is the side the engine
-- was searching for ("w" or "b"). Returns the signed score.
function Eval.toWhitePerspective(score, turn)
    if score == nil then return nil end
    if turn == "b" then return -tonumber(score) end
    return tonumber(score)
end

local function advantage_tag(value)
    local abs = math.abs(value)
    if abs < 0.20 then
        return "roughly equal"
    end
    local strength
    if abs < 0.50 then
        strength = "slight"
    elseif abs < 1.00 then
        strength = "small"
    elseif abs < 2.00 then
        strength = "clear"
    elseif abs < 4.00 then
        strength = "winning"
    else
        strength = "decisive"
    end
    return string.format("%s advantage for %s", strength, (value > 0) and "White" or "Black")
end

--- Short eval string for a single move (White's perspective): "+0.35",
--- "-1.20", or a mate range like "+M3" / "-M2" ("#" for m=0).
-- Returns "" when neither cp nor mate is present.
function Eval.short(state)
    state = state or {}
    local mate = state.mate
    if mate ~= nil then
        local m = tonumber(mate) or 0
        if m == 0 then return "#" end
        local moves = math.max(1, math.ceil(math.abs(m) / 2))
        return (m > 0 and "+M" or "-M") .. tostring(moves)
    end
    local cp = state.cp
    if cp == nil then return "" end
    return string.format("%+.2f", (tonumber(cp) or 0) / 100.0)
end

--- Formats the eval line from a White-perspective score.
-- `state` = { cp = centipawns | nil, mate = moves-to-mate | nil }.
-- Returns "" when neither is present.
function Eval.format(state)
    state = state or {}
    local mate = state.mate
    if mate ~= nil then
        local m = tonumber(mate) or 0
        if m == 0 then
            return "eval: # (checkmate)"
        end
        local side  = (m > 0) and "White" or "Black"
        local moves = math.max(1, math.ceil(math.abs(m) / 2))
        return string.format("eval: Mate in %d (%s)", moves, side)
    end

    local cp = state.cp
    if cp == nil then return "" end

    local value = (tonumber(cp) or 0) / 100.0
    return string.format("eval: %+.2f (%s)", value, advantage_tag(value))
end

return Eval
