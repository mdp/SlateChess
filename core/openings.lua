-- Openings: matching played moves against the opening book.
--
-- Pure Lua. The book is `data/aperturas.json` — an array of ECO entries
-- `{ eco, name, moves }` where `moves` is a space-separated SAN sequence.
-- The loader tolerates the book's non-standard trailing commas and takes
-- its JSON decoder as a parameter (KOReader bundles one; tests inject a
-- stub or a real one).

local Openings = {}

--- Removes check/mate/annotation suffixes from a SAN token ("Nf3+" → "Nf3").
function Openings.stripSan(san)
    return (tostring(san):gsub("[+#?!]", ""))
end

--- Parses book content (a JSON string) into an array of entries.
-- `decode` is a function(json_string) → table; when omitted, KOReader's
-- bundled json module is used. Malformed content yields an empty book.
function Openings.load(content, decode)
    if not decode then
        local ok_json, json = pcall(require, "json")
        if not ok_json then return {} end
        decode = json.decode
    end
    if type(content) ~= "string" then return {} end
    -- The book historically contains trailing commas inside the array;
    -- strip them so strict JSON decoders accept it.
    content = content:gsub(",%s*([%]%}])", "%1")
    local ok, data = pcall(decode, content)
    if not ok or type(data) ~= "table" then return {} end
    local book = {}
    for _, entry in ipairs(data) do
        if type(entry) == "table" and type(entry.moves) == "string" and entry.moves ~= "" then
            book[#book + 1] = {
                eco   = entry.eco,
                name  = entry.name,
                moves = entry.moves,
            }
        end
    end
    return book
end

--- Matches played SAN moves (array of strings) against the book.
-- Returns the longest book line that the played moves begin with
-- (a `{ eco, name, moves }` entry), or nil.
function Openings.match(book, san_moves)
    if type(book) ~= "table" or type(san_moves) ~= "table" then return nil end

    local played = {}
    for _, san in ipairs(san_moves) do
        if type(san) == "string" and san ~= "" then
            played[#played + 1] = Openings.stripSan(san)
        end
    end
    if #played == 0 then return nil end

    local line = table.concat(played, " ")
    local best = nil
    for _, entry in ipairs(book) do
        if line:find(entry.moves, 1, true) == 1 then
            if not best or #entry.moves > #best.moves then
                best = entry
            end
        end
    end
    return best
end

return Openings
