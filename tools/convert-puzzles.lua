-- convert-puzzles.lua — Lichess puzzle database CSV → compact JSON bank,
-- with catalog-aware stratified sampling.
--
-- Input: the official `lichess_db_puzzle.csv`, format:
--   PuzzleId,FEN,Moves,Rating,RatingDeviation,Popularity,NbPlays,Themes,GameUrl,OpeningTags
--   The `Moves` column is the FULL recorded line, space-separated UCI.
--   Per Lichess's own semantics (checked against lichess.org/api/puzzle/<id>)
--   the FEN is the position BEFORE the opponent's decisive move, and the
--   line is [opponent's lead-in blunder] + the solver's winning sequence.
--   Real rows therefore have an EVEN ply count: the solver is the side
--   OPPOSITE the FEN's active color, the first token is the opponent's
--   blunder, and the solver's winning plies are the even tokens.
--   Themes is a SPACE-SEPARATED list ("fork middlegame"), and OpeningTags a
--   space-separated list of underscore-joined opening names
--   ("Sicilian_Defense Sicilian_Defense_Najdorf"). Older dumps encoded one
--   or both as JSON arrays — both forms are parsed.
--
-- Output: a compact JSON array on stdout (or a file), one record per line:
--   [
--     { "id":"AbC…", "fen":"rnbq… w KQkq - 2 4",
--       "moves":"g1f3 d8h4 …", "r":1359, "p":77, "pl":250,
--       "t":["fork","middlegame"] }
--   ]
--
-- Stratified sampling: the bank is not a blind prefix of the stream. The
-- curated catalog (core/puzzle_types.lua) drives quotas — every catalog
-- type is guaranteed `build_quota` (× QUOTA_SCALE) records in the bank,
-- so rare types (underPromotion, smothered mates, …) stay covered. One
-- record can fill several types' deficits at once and is stored once.
-- Records matching nothing — or everything, once the typed quotas are full
-- — go to the fallback pool, which absorbs rows until LIMIT is met, so the
-- bank is exactly `LIMIT` records (quality-filtered) when the stream allows.
--
-- Quality gates beyond legality/outcome:
--   * MIN_PLAYS      — skip puzzles played fewer times (Lichess's own
--                      NbPlays is a fine proxy for human vetting; default 20)
--   * MIN_POPULARITY — skip puzzles voted below this (default 0; the CSV's
--                      Popularity is 100*(up-down)/(up+down), weighted by
--                      solver strength and solve success).
--   * MAX_RD         — skip puzzles with rating deviation above this
--                      (unstable / barely-tested ratings).
--
-- Usage:
--   zstd -dc lichess_db_puzzle.csv.zst | luajit tools/convert-puzzles.lua > data/puzzles.json
--   luajit tools/convert-puzzles.lua input.csv data/puzzles.json
--
-- Env knobs: RATING_MIN / RATING_MAX (default 0..99999), LIMIT (max records
-- written; 0 = unlimited), QUOTA_SCALE (multiplier for the catalog quotas),
-- MIN_PLAYS (default 20), MIN_POPULARITY (default 0), MAX_RD (default 99999),
-- SCAN_LIMIT (max CSV rows consumed before giving up on unfilled quotas),
-- TYPES_FILE (path to the catalog; defaults to ../core/puzzle_types.lua).
--
-- Pure Lua, no external modules: runs on luajit and stock lua alike.

-- Quote-aware CSV row parser: handles quoted fields (commas, quote
-- escaping by doubling) as older OpeningTags dumps require.
local function parseCsvRow(line)
    local fields, field, i, n = {}, {}, 1, #line
    local in_quotes = false
    while i <= n do
        local c = line:sub(i, i)
        if in_quotes then
            if c == '"' then
                local next = line:sub(i + 1, i + 1)
                if next == '"' then
                    field[#field + 1] = '"'
                    i = i + 2
                else
                    in_quotes = false
                    i = i + 1
                end
            else
                field[#field + 1] = c
                i = i + 1
            end
        else
            if c == '"' then
                in_quotes = true
                i = i + 1
            elseif c == ',' then
                fields[#fields + 1] = table.concat(field)
                field = {}
                i = i + 1
            else
                field[#field + 1] = c
                i = i + 1
            end
        end
    end
    fields[#fields + 1] = table.concat(field)
    return fields
end

-- Tokens from a tag field. Two real-world encodings exist:
--   "fork middlegame"        — space-separated (current dump)
--   ["fork","middlegame"]    — JSON array (older dumps)
local function tagTokens(text)
    if not text or text == "" then return {} end
    local tokens = {}
    if text:find('"', 1, true) then
        for item in text:gmatch('"([^"]*)"') do
            item = item:gsub('\\"', '"')
            tokens[#tokens + 1] = item
        end
    else
        for item in text:gmatch("[^%s,]+") do
            tokens[#tokens + 1] = item
        end
    end
    return tokens
end

-- Themes ∪ OpeningTags, de-duplicated, first-seen order.
local function mergeTags(themes_field, openings_field)
    local out, seen = {}, {}
    for _, f in ipairs({ themes_field, openings_field }) do
        for _, token in ipairs(tagTokens(f)) do
            if not seen[token] then
                seen[token] = true
                out[#out + 1] = token
            end
        end
    end
    return out
end

-- JSON string escaping (control chars + quote + backslash).
local function jsonEscape(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
    return s
end

local function jsonArray(items)
    local parts = {}
    for _, item in ipairs(items) do
        parts[#parts + 1] = '"' .. jsonEscape(item) .. '"'
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- Filter / sampling knobs via env (fetch scripts set them).
local RATING_MIN  = tonumber(os.getenv("RATING_MIN") or "") or 0
local RATING_MAX  = tonumber(os.getenv("RATING_MAX") or "") or 99999
local LIMIT       = tonumber(os.getenv("LIMIT") or "") or 0
local QUOTA_SCALE = tonumber(os.getenv("QUOTA_SCALE") or "") or 1
local MIN_PLAYS   = tonumber(os.getenv("MIN_PLAYS") or "") or 20
local MIN_POPULARITY = tonumber(os.getenv("MIN_POPULARITY") or "") or 0
local MAX_RD      = tonumber(os.getenv("MAX_RD") or "") or 99999
local SCAN_LIMIT  = tonumber(os.getenv("SCAN_LIMIT") or "") or 6000000
local TYPES_FILE = os.getenv("TYPES_FILE")

-- Resolve the catalog path relative to this script when possible.
if not TYPES_FILE then
    local script_dir = (arg and arg[0] and arg[0]:match("^(.*[/\\])")) or "./"
    TYPES_FILE = script_dir .. "../core/puzzle_types.lua"
end

local infile, outfile
for _, a in ipairs(arg or {}) do
    if a:match("%.csv$") then infile = a end
end
for i = #(arg or {}), 1, -1 do
    if not arg[i]:match("%.csv$") then
        outfile = arg[i]
        break
    end
end

local ok_types, Types = pcall(dofile, TYPES_FILE)
if not ok_types or type(Types) ~= "table" then
    io.stderr:write(("convert-puzzles: cannot load catalog %s (%s)\n")
        :format(TYPES_FILE, tostring(Types)))
    os.exit(1)
end

-- Bring in the shared pure core for the quality gate below: the engine
-- (core.game) replays each candidate line, and we drop rows whose recorded
-- line ends with the SOLVER clearly worse — those would make the app
-- announce "Solved!" after a loss.
local script_dir = (arg and arg[0] and arg[0]:match("^(.*[/\\])")) or "./"
package.path = (script_dir .. "../?.lua;") .. package.path
local ok_pz, Puzzles = pcall(require, "core.puzzles")
local ok_gm, Game     = pcall(require, "core.game")
if not ok_pz or not ok_gm or type(Puzzles) ~= "table" or type(Game) ~= "table" then
    io.stderr:write("convert-puzzles: core.puzzles / core.game unavailable for the quality gate\n")
    os.exit(1)
end

local PIECE_VALUES = { p = 1, n = 3, b = 3, r = 5, q = 9, k = 0 }
local function materialDiff(game, color)
    local diff = 0
    for _, row in ipairs(game:board() or {}) do
        for _, sq in ipairs(row) do
            if sq and sq.type and sq.color then
                local v = PIECE_VALUES[sq.type] or 0
                diff = diff + (sq.color == color and v or -v)
            end
        end
    end
    return diff
end

--- The line's outcome from the solver's view. Solver = opposite of the FEN
-- active color on blunder-layout rows (even ply count); otherwise the FEN
-- side. False → drop the row.
local function outcomeOk(rec)
    local game = Game:new{ fen = rec.fen }
    if not game then return false end
    local fen_side = game:turn()
    local solver = Puzzles.blunder(rec)
        and (fen_side == "w" and "b" or "w")
        or fen_side
    for _, u in ipairs(Puzzles.tokens(rec)) do
        if not game:playUci(u) then return false end
    end
    local st = game:status()
    if st.over then
        if st.result == "1/2-1/2" then return false end
        local white_won = st.result == "1-0"
        return (solver == "w" and white_won) or (solver == "b" and not white_won)
    end
    return materialDiff(game, solver) >= -1
end

-- Build the deficits (unfilled quotas) from the catalog. The fallback
-- "__random" pool absorbs rows until LIMIT is reached, so the bank is
-- exactly LIMIT records once the typed quotas are satisfied (or the
-- stream/scan cap cuts in).
local deficit = {}
for _, t in ipairs(Types.LIST) do
    if t.kind ~= "any" and t.build_quota and t.build_quota > 0 then
        local q = math.floor(t.build_quota * QUOTA_SCALE)
        if q > 0 then deficit[t.id] = q end
    end
end
if LIMIT and LIMIT > 0 then
    deficit["__random"] = LIMIT
else
    deficit["__random"] = math.floor(Types.RANDOM_QUOTA * QUOTA_SCALE)
end

-- All typed quoting done ("__random" excluded: it is a device to CAP the total,
-- not a guarantee).
local function typedDone()
    for id, v in pairs(deficit) do
        if id ~= "__random" and v > 0 then return false end
    end
    return true
end

local in_fh = infile and io.open(infile, "r") or io.stdin
local out_fh = outfile and io.open(outfile, "w") or io.stdout

-- Skip the header row.
in_fh:read("*l")

local bank, seen = {}, {}
local rows_seen = 0

-- Process one parsed row: decide claimability up front (tag-only, cheap),
-- then run the engine quality gate only for rows that would actually be
-- stored — the gate's replay dominates the runtime, so it must not run on
-- the ~500k rows the quotas skip anyway.
local function considerRow(f, rating)
    local popularity = tonumber(f[6])
    local nplays     = tonumber(f[7])
    local rd         = tonumber(f[5])
    -- Human-vetting/tuning gates: skip puzzles nobody has played, that
    -- players voted down, or whose rating hasn't stabilized.
    if nplays and nplays < MIN_PLAYS then return end
    if popularity and popularity < MIN_POPULARITY then return end
    if rd and rd > MAX_RD then return end

    local tags = mergeTags(f[8], f[10] or "")
    local rec = {
        id    = f[1],
        fen   = f[2],
        moves = f[3],
        r     = rating,
        p     = popularity,
        pl    = nplays,
        t     = tags,
    }
    if seen[rec.id] then return end

    -- Which quota slots would this row fill? (No engine yet.)
    local claims = {}
    for _, t in ipairs(Types.LIST) do
        if t.kind ~= "any" and deficit[t.id] and deficit[t.id] > 0
            and Types.matches(t, rec) then
            claims[#claims + 1] = t.id
        end
    end
    -- The fallback pool is only touched once every typed quota is full —
    -- otherwise a big LIMIT would swallow common themes and starve the rare
    -- types this sampler exists to cover.
    if #claims == 0 then
        if typedDone() and deficit["__random"] > 0 then
            claims[#claims + 1] = "__random"
        else
            return
        end
    end

    -- Quality gate: only ship rows whose line leaves the solver winning.
    if not outcomeOk(rec) then return end

    seen[rec.id] = true
    bank[#bank + 1] = rec
    for _, id in ipairs(claims) do
        deficit[id] = deficit[id] - 1
    end
end

for line in in_fh:lines() do
    rows_seen = rows_seen + 1
    -- A small LIMIT is a dev/budget cap: stop as soon as it's hit. On a full
    -- build the typed quotas must finish first (they are the whole point of
    -- the sampler); the random pool then tops the bank up toward LIMIT.
    if LIMIT > 0 and #bank >= LIMIT and (LIMIT <= 1500 or typedDone()) then break end
    if LIMIT <= 0 and typedDone() then break end
    if rows_seen > SCAN_LIMIT then
        io.stderr:write(("scan_cap reached after %d rows"):format(SCAN_LIMIT) .. "\n")
        break
    end
    local f = parseCsvRow(line)
    if #f >= 10 then
        local rating = tonumber(f[4]) or 0
        if rating >= RATING_MIN and rating <= RATING_MAX then
            considerRow(f, rating)
        end
    end
end

if infile then in_fh:close() end

-- Report unfilled quotas (types the stream ran out of before filling).
local unfilled = {}
for id, v in pairs(deficit) do
    if v > 0 and id ~= "__random" then
        local label = (Types.byId and Types.byId(id).label) or id
        unfilled[#unfilled + 1] = label .. " (still need " .. v .. ")"
    end
end
table.sort(unfilled)
if #unfilled > 0 then
    io.stderr:write(("unfilled quotas: %s"):format(table.concat(unfilled, ", ")) .. "\n")
end

-- Compact output: one record per line; deterministic (kept stream order).
out_fh:write("[")
for i, rec in ipairs(bank) do
    if i > 1 then out_fh:write(",") end
    out_fh:write("\n")
    out_fh:write(string.format(
        '{"id":"%s","fen":"%s","moves":"%s","r":%d,"p":%s,"pl":%s,"t":%s}',
        jsonEscape(rec.id), jsonEscape(rec.fen), jsonEscape(rec.moves),
        rec.r,
        rec.p and string.format("%d", rec.p) or "null",
        rec.pl and string.format("%d", rec.pl) or "null",
        jsonArray(rec.t)))
end
out_fh:write("\n]\n")
if outfile then out_fh:close() end

io.stderr:write(("puzzles: %d records written (%d rows scanned)"):format(#bank, rows_seen) .. "\n")