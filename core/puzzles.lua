-- Puzzles: loading and filtering the puzzle bank.
--
-- Pure Lua (zero KOReader / io / os dependencies) — part of the test
-- surface. The bank is the compact JSON produced by tools/convert-puzzles.lua
-- from the Lichess puzzle database:
--
--   [ { "id":"AbC…", "fen":"rnbq… w KQkq - 2 4",
--       "moves":"g1f3 d8h4 …", "r":1359, "p":77, "pl":250,
--       "t":["fork","middlegame"] } ]
--
--   * `moves` — the FULL recorded line, space-separated UCI. Per Lichess's
--     own API semantics (confirmed against lichess.org/api/puzzle/<id>):
--     the FEN is the position BEFORE the opponent's decisive move, and the
--     line is [opponent's losing move] + the solver's winning sequence,
--     solver/replies alternating. So real rows have an EVEN ply count: the
--     first token is the opponent's pre-blunder, and the solver's winning
--     plies are the EVEN tokens (Puzzles.solution returns them as an
--     alternating solver-first list; Puzzles.blunder returns the lead-in).
--     Old hand-written rows (odd ply count) are treated as plain solver-first
--     lines with no blunder.
--   * `r` — puzzle rating. `p` — popularity (-100..100, optional). `pl` —
--     times played (optional). `t` — themes.

local Puzzles = {}
local Types = require("core.puzzle_types")

-- Difficulty bands (the settings vocabulary). `any` == no filter.
Puzzles.BANDS = {
    easy   = { 400, 1000 },
    normal = { 1001, 1500 },
    hard   = { 1501, 2000 },
    expert = { 2001, 3000 },
}

Puzzles.ADAPTIVE_DEFAULT = 1200
Puzzles.ADAPTIVE_MIN = 400
Puzzles.ADAPTIVE_MAX = 3000
Puzzles.ADAPTIVE_WINDOW = 150
Puzzles.ADAPTIVE_K = 40

--- Clamp a persisted player rating to the supported puzzle-bank range.
function Puzzles.clampAdaptiveRating(rating)
    rating = math.floor((tonumber(rating) or Puzzles.ADAPTIVE_DEFAULT) + 0.5)
    return math.max(Puzzles.ADAPTIVE_MIN, math.min(Puzzles.ADAPTIVE_MAX, rating))
end

--- Rating window used by adaptive mode. A narrow local pool prevents the
-- full-bank jumps produced by "Any" while retaining enough puzzle variety.
function Puzzles.adaptiveRange(rating)
    rating = Puzzles.clampAdaptiveRating(rating)
    return math.max(Puzzles.ADAPTIVE_MIN, rating - Puzzles.ADAPTIVE_WINDOW),
        math.min(Puzzles.ADAPTIVE_MAX, rating + Puzzles.ADAPTIVE_WINDOW)
end

--- One standard Elo update against a puzzle's published rating.
function Puzzles.updateAdaptiveRating(player_rating, puzzle_rating, score)
    local player = Puzzles.clampAdaptiveRating(player_rating)
    local opponent = tonumber(puzzle_rating) or player
    local expected = 1 / (1 + 10 ^ ((opponent - player) / 400))
    local updated = player + Puzzles.ADAPTIVE_K * ((tonumber(score) or 0) - expected)
    return Puzzles.clampAdaptiveRating(updated)
end

--- The rating range for a band name, or nil for "any"/unknown.
function Puzzles.bandRange(band)
    local range = Puzzles.BANDS[band]
    if not range then return nil end
    return range[1], range[2]
end

--- Ordered band names for the settings dialog (after "any").
function Puzzles.bandList()
    return { "easy", "normal", "hard", "expert" }
end

--- True when a record is syntactically usable.
function Puzzles.valid(record)
    if type(record) ~= "table" then return false end
    if type(record.id) ~= "string" or record.id == "" then return false end
    if type(record.fen) ~= "string" or record.fen == "" then return false end
    if type(record.moves) ~= "string" or record.moves == "" then return false end
    if type(record.r) ~= "number" then return false end
    -- Every token must look like a UCI move ("e2e4", "e7e8q").
    for token in record.moves:gmatch("%S+") do
        if not token:match("^[a-h][1-8][a-h][1-8][qrbn]?$") then return false end
    end
    return true
end

--- All UCI tokens of the recorded line, in order.
function Puzzles.tokens(record)
    if not Puzzles.valid(record) then return {} end
    local out = {}
    for token in record.moves:gmatch("%S+") do
        out[#out + 1] = token
    end
    return out
end

--- The opponent's lead-in blunder: the first stored token when the record
-- follows Lichess's "line = blunder + solution" layout (an EVEN ply count,
-- which every real DB row has). nil for plain odd-ply lines.
function Puzzles.blunder(record)
    local t = Puzzles.tokens(record)
    if #t % 2 == 0 and #t > 0 then return t[1] end
    return nil
end

--- The interactive solution as an alternating list, SOLVER first:
--   [solver1, opponent1, solver2, opponent2, …, solverLast].
-- For blunder-layout rows this drops the lead-in blunder (so the solver's
-- winning plies show up at the odd positions, exactly what the machine
-- expects). For plain lines it is the whole token list.
function Puzzles.solution(record)
    local t = Puzzles.tokens(record)
    if #t % 2 == 0 and #t > 0 then
        local out = {}
        for i = 2, #t do out[#out + 1] = t[i] end
        return out
    end
    return t
end

--- Parses bank content (JSON) into an array of records, tolerating stray
-- trailing commas. `decode` is the JSON decoder; when omitted KOReader's
-- bundled json module is used (tests inject a stub). Malformed content and
-- syntactically-bad records yield a smaller bank, never an error.
function Puzzles.load(content, decode)
    if not decode then
        local ok_json, json = pcall(require, "json")
        if not ok_json then return {} end
        decode = json.decode
    end
    if type(content) ~= "string" or content == "" then return {} end
    content = content:gsub(",%s*([%]%}])", "%1")
    local ok, data = pcall(decode, content)
    if not ok or type(data) ~= "table" then return {} end
    local bank = {}
    for _, rec in ipairs(data) do
        if Puzzles.valid(rec) then
            bank[#bank + 1] = {
                id    = rec.id,
                fen   = rec.fen,
                moves = rec.moves,
                r     = tonumber(rec.r) or 0,
                -- Quality metadata is optional (older banks lack it); the
                -- converter writes it as "p"/"pl", kept as integers.
                p     = (type(rec.p) == "number") and math.floor(rec.p) or nil,
                pl    = (type(rec.pl) == "number") and math.floor(rec.pl) or nil,
                t     = (type(rec.t) == "table") and rec.t or {},
            }
        end
    end
    return bank
end

--- The puzzle-type catalog module (the picker vocabulary + matchers).
function Puzzles.types()
    return Types
end

--- Filters the bank. opts may carry `rating_min`, `rating_max` (numbers),
-- `type` (nil/"any"/"random" matches everything; otherwise a catalog type
-- id, matched against the record's tags — unknown ids match nothing) and
-- `theme` (nil/"any" = everything; otherwise exact match against the
-- record's theme list; only used when `type` is not a recognized id).
-- Returns a new array.
function Puzzles.filter(bank, opts)
    opts = opts or {}
    local lo = tonumber(opts.rating_min) or 0
    local hi = tonumber(opts.rating_max) or math.huge
    local want_type = opts.type
    if want_type == "any" or want_type == "random" then want_type = nil end
    local type_entry = want_type and Types.byId(want_type) or nil
    local theme = opts.theme
    if theme == "any" then theme = nil end
    local out = {}
    for _, rec in ipairs(bank) do
        if rec.r >= lo and rec.r <= hi then
            if type_entry then
                if Types.matches(type_entry, rec) then
                    out[#out + 1] = rec
                end
            elseif theme then
                for _, t in ipairs(rec.t) do
                    if t == theme then
                        out[#out + 1] = rec
                        break
                    end
                end
            elseif not want_type then
                -- Unknown/nonexistent type ids match nothing (empty slice);
                -- otherwise with no theme and no type: the whole bank.
                out[#out + 1] = rec
            end
        end
    end
    return out
end

--- The distinct theme vocabulary of a bank (sorted), for the settings
-- dialog.
function Puzzles.themes(bank)
    local seen, out = {}, {}
    for _, rec in ipairs(bank) do
        for _, t in ipairs(rec.t) do
            if not seen[t] then
                seen[t] = true
                out[#out + 1] = t
            end
        end
    end
    table.sort(out)
    return out
end

--- Human-vetting metadata for a record: popularity (-100..100) and plays.
-- Returns nil,nil when the bank predates the quality fields. Handy for
-- the census tool and for culling low-quality slices.
function Puzzles.quality(record)
    if type(record) ~= "table" then return nil, nil end
    return record.p, record.pl
end

return Puzzles
