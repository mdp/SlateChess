-- puzzle-stats.lua — research/analysis tool for the Lichess puzzle DB CSV.
--
-- Streams the official `lichess_db_puzzle.csv` (or a piped sample) and prints
-- vocabulary statistics to stdout: distinct theme counts, opening-family
-- counts (first segment before "_"), phase-theme coverage, and rating bands.
-- Useful for grounding the puzzle-type catalog in real data, and for
-- sanity-checking future DB dumps.
--
-- Usage:
--   zstd -dc lichess_db_puzzle.csv.zst | LIMIT=400000 luajit tools/puzzle-stats.lua
--   LIMIT=400000 luajit tools/puzzle-stats.lua /path/to/lichess_db_puzzle.csv
--
-- The Themes column is space-separated; OpeningTags is space-separated
-- underscore-joined names (e.g. "Sicilian_Defense Najdorf_Variation"). Both
-- are parsed leniently so older JSON-array dumps also work.

local LIMIT = tonumber(os.getenv("LIMIT") or "") or 0

-- Same quote-aware CSV parse as convert-puzzles.lua.
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

-- Tokens from a space-separated field, tolerating a JSON-array form too.
local function tags(text)
    local out = {}
    if not text then return out end
    text = text:gsub("^%s*%[", ""):gsub("%]%s*$", "")
    for item in text:gmatch("[^%s,\"]+") do
        out[#out + 1] = item
    end
    return out
end

local infile
for _, arg in ipairs(arg) do
    if arg:match("%.csv$") then infile = arg end
end
local in_fh = infile and io.open(infile, "r") or io.stdin
in_fh:read("*l") -- header

local n = 0
local themes, families = {}, {}
local phases = { opening = 0, middlegame = 0, endgame = 0 }
local no_phase = 0
local bands = { ["_400-1000"] = 0, ["_1001-1500"] = 0, ["_1501-2000"] = 0, ["_2001-3000"] = 0 }
-- Human-vetting census (the converter's MIN_PLAYS/MIN_POPULARITY gates).
local pop_buckets = { ["<0"] = 0, ["0-30"] = 0, ["31-60"] = 0, ["61-100"] = 0 }
local plays_buckets = { ["0-9"] = 0, ["10-19"] = 0, ["20-99"] = 0, ["100+"] = 0 }
local missing_plays, missing_pop = 0, 0
local survives_default_gate = 0

for line in in_fh:lines() do
    if LIMIT > 0 and n >= LIMIT then break end
    n = n + 1
    local f = parseCsvRow(line)
    if #f >= 10 then
        local rating = tonumber(f[4]) or 0
        if rating <= 1000 then bands["_400-1000"] = bands["_400-1000"] + 1
        elseif rating <= 1500 then bands["_1001-1500"] = bands["_1001-1500"] + 1
        elseif rating <= 2000 then bands["_1501-2000"] = bands["_1501-2000"] + 1
        else bands["_2001-3000"] = bands["_2001-3000"] + 1 end
        local has_phase = false
        for _, t in ipairs(tags(f[8])) do
            themes[t] = (themes[t] or 0) + 1
            if phases[t] then phases[t] = phases[t] + 1; has_phase = true end
        end
        for _, t in ipairs(tags(f[10])) do
            local fam = t:match("^([^_]+)") or t
            families[fam] = (families[fam] or 0) + 1
        end
        if not has_phase then no_phase = no_phase + 1 end

        local pop, plays = tonumber(f[6]), tonumber(f[7])
        if pop then
            if pop < 0 then pop_buckets["<0"] = pop_buckets["<0"] + 1
            elseif pop <= 30 then pop_buckets["0-30"] = pop_buckets["0-30"] + 1
            elseif pop <= 60 then pop_buckets["31-60"] = pop_buckets["31-60"] + 1
            else pop_buckets["61-100"] = pop_buckets["61-100"] + 1 end
        else missing_pop = missing_pop + 1 end
        if plays then
            if plays < 10 then plays_buckets["0-9"] = plays_buckets["0-9"] + 1
            elseif plays < 20 then plays_buckets["10-19"] = plays_buckets["10-19"] + 1
            elseif plays < 100 then plays_buckets["20-99"] = plays_buckets["20-99"] + 1
            else plays_buckets["100+"] = plays_buckets["100+"] + 1 end
        else missing_plays = missing_plays + 1 end
        if (not plays or plays >= 20) and (not pop or pop >= 0) then
            survives_default_gate = survives_default_gate + 1
        end
    end
end

io.write(("rows            %d\n"):format(n))
io.write(("no phase theme  %d (%.2f%%)\n"):format(no_phase, n > 0 and 100 * no_phase / n or 0))
for _, b in ipairs({ "_400-1000", "_1001-1500", "_1501-2000", "_2001-3000" }) do
    io.write(("rating %-14s%d\n"):format(b, bands[b]))
end

io.write("\n-- phases --\n")
for _, k in ipairs({ "opening", "middlegame", "endgame" }) do
    io.write(("%-12s%d\n"):format(k, phases[k]))
end

local function sortByCount(tbl)
    local sorted = {}
    for k, v in pairs(tbl) do sorted[#sorted + 1] = { k, v } end
    table.sort(sorted, function(a, b) return a[2] > b[2] end)
    return sorted
end

io.write("\n-- themes (top 45) --\n")
local t_sorted = sortByCount(themes)
for i = 1, math.min(45, #t_sorted) do
    io.write(("%-20s%d\n"):format(t_sorted[i][1], t_sorted[i][2]))
end

io.write("\n-- opening families (top 35) --\n")
local f_sorted = sortByCount(families)
for i = 1, math.min(35, #f_sorted) do
    io.write(("%-28s%d\n"):format(f_sorted[i][1], f_sorted[i][2]))
end

io.write("\n-- human-vetting census --\n")
io.write(("survives default gate (plays>=20, pop>=0)  %d (%.2f%%)\n")
    :format(survives_default_gate, n > 0 and 100 * survives_default_gate / n or 0))
io.write(("missing plays       %d,  missing popularity %d\n"):format(missing_plays, missing_pop))
io.write("popularity:  ")
for _, k in ipairs({ "<0", "0-30", "31-60", "61-100" }) do
    io.write(("  %s=%d"):format(k, pop_buckets[k]))
end
io.write("\nplays:        ")
for _, k in ipairs({ "0-9", "10-19", "20-99", "100+" }) do
    io.write(("  %s=%d"):format(k, plays_buckets[k]))
end
io.write("\n")

if infile then in_fh:close() end