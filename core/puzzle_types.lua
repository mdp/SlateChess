-- PuzzleTypes: the curated "puzzle type" catalog shared by the SlatePuzzle
-- app and the bank builder.
--
-- Pure Lua, zero KOReader / io / os dependencies — one source of truth for
-- what a "puzzle type" means, grounded in the Lichess puzzle theme and
-- opening vocabularies:
--
--   * Themes       — space-separated tokens in the DB (themes like "fork",
--                    "mateIn2", "endgame"). See Lichess puzzleTheme.xml.
--   * OpeningTags  — space-separated underscore-joined opening names in the
--                    DB (e.g. "Sicilian_Defense", "Sicilian_Defense_Najdorf").
--
-- Each entry in Types.LIST is:
--   id          — the persisted settings value ("any"/nil = no type filter)
--   label       — human-readable name
--   group       — section id when shown in the type picker
--   desc        — one-line explanation shown under the label in the picker
--   kind        — matcher kind:
--                   "any"       — matches everything (the Random entry)
--                   "anyTheme"  — the record has ≥1 of `themes`
--                   "matchAll"  — the record has all of `themes`
--                   "prefix"    — some record tag starts with one of
--                                 `prefixes` (opening-family matching)
--   themes/prefixes — the match lists
--   build_quota — default per-type target count when building the embedded
--                 bank (tools/convert-puzzles.lua); ignored by the app.
--
-- Type matching ignores record rating and any other field: it is purely
-- tag-based, so the app and the builder agree exactly.
--
-- NOTES ON REAL DATA (checked 2026-08):
--   * phases (opening/middlegame/endgame) cover ~100% of puzzles;
--   * opening tags use apostrophe-free names ("Kings_Pawn_Game",
--     "Queens_Gambit_Declined"); Caro-Kann appears as "Kann_Defense";
--   * there is no "stalemate" theme; enPassant is rare (~0.13%);
--   * goals (equality/advantage/crushing/mate) and lengths
--     (oneMove/short/long/veryLong) are 1:1 with the theme vocab — only the
--     "mate" theme overlaps the mateInN types (double-counting is fine);
--   * the named mate patterns are the full visible mate-theme family
--     (balestra/blindSwine/corner/doubleBishop/dovetail/epaulette/hook/
--     killBox/pillsbury/morphy/swallowtail/triangle/vukovic).

local Types = {}

-- Section labels for the picker, in display order.
Types.GROUPS = {
    { id = "mates",    label = "Mates" },
    { id = "tactics",  label = "Tactics" },
    { id = "patterns", label = "Mating patterns" },
    { id = "endgames", label = "Endgames" },
    { id = "pawns",    label = "Pawn play" },
    { id = "phases",   label = "Phases" },
    { id = "goals",    label = "Goals" },
    { id = "lengths",  label = "Lengths" },
    { id = "openings", label = "Openings by name" },
}

Types.LIST = {
    -- The default: a completely mixed draw from the whole bank.
    { id = "random", label = "Random", group = nil, kind = "any",
      desc = "A mix of everything — be ready for anything!" },

    -- --- Mates ---------------------------------------------------------
    { id = "mateIn1",    label = "Mate in 1",  group = "mates",
      kind = "anyTheme", themes = { "mateIn1" }, build_quota = 250,
      desc = "Deliver checkmate in one move." },
    { id = "mateIn2",    label = "Mate in 2",  group = "mates",
      kind = "anyTheme", themes = { "mateIn2" }, build_quota = 350,
      desc = "Deliver checkmate in two moves." },
    { id = "mateIn3",    label = "Mate in 3",  group = "mates",
      kind = "anyTheme", themes = { "mateIn3" }, build_quota = 250,
      desc = "Deliver checkmate in three moves." },
    { id = "mateIn4plus", label = "Mate in 4+", group = "mates",
      kind = "anyTheme", themes = { "mateIn4", "mateIn5", "veryLong" }, build_quota = 200,
      desc = "Figure out a long forced mating sequence." },

    -- --- Core tactics --------------------------------------------------
    { id = "fork",       label = "Fork",  group = "tactics",
      kind = "anyTheme", themes = { "fork" }, build_quota = 300,
      desc = "The moved piece attacks two opponent pieces at once." },
    { id = "pin",        label = "Pin",   group = "tactics",
      kind = "anyTheme", themes = { "pin" }, build_quota = 280,
      desc = "A piece cannot move without revealing an attack on a higher-value piece." },
    { id = "skewer",     label = "Skewer", group = "tactics",
      kind = "anyTheme", themes = { "skewer" }, build_quota = 250,
      desc = "Attack a high-value piece so it moves and a weaker piece behind is captured." },
    { id = "discovered", label = "Discovered attack", group = "tactics",
      kind = "anyTheme", themes = { "discoveredAttack", "discoveredCheck" }, build_quota = 280,
      desc = "Move a piece to unveil an attack from a long-range piece behind it." },
    { id = "deflection", label = "Deflection", group = "tactics",
      kind = "anyTheme", themes = { "deflection" }, build_quota = 250,
      desc = "Distract an enemy piece from a duty it performs (also 'overloading')." },
    { id = "attraction", label = "Attraction", group = "tactics",
      kind = "anyTheme", themes = { "attraction" }, build_quota = 250,
      desc = "Sacrifice to lure an enemy piece onto a square that allows a follow-up." },
    { id = "sacrifice",  label = "Sacrifice", group = "tactics",
      kind = "anyTheme", themes = { "sacrifice" }, build_quota = 280,
      desc = "Give up material short-term to gain a decisive advantage later." },
    { id = "trapped",    label = "Trapped piece", group = "tactics",
      kind = "anyTheme", themes = { "trappedPiece" }, build_quota = 200,
      desc = "A piece is unable to escape capture because it has few moves." },
    { id = "hanging",    label = "Hanging piece", group = "tactics",
      kind = "anyTheme", themes = { "hangingPiece" }, build_quota = 200,
      desc = "Capture an opponent piece that is undefended or under-defended." },
    { id = "interference", label = "Interference", group = "tactics",
      kind = "anyTheme", themes = { "interference" }, build_quota = 120,
      desc = "Put a piece between two enemy pieces to cut their defense." },
    { id = "zugzwang",   label = "Zugzwang", group = "tactics",
      kind = "anyTheme", themes = { "zugzwang" }, build_quota = 120,
      desc = "Every move the opponent makes worsens their position." },
    { id = "intermezzo", label = "Intermezzo", group = "tactics",
      kind = "anyTheme", themes = { "intermezzo" }, build_quota = 150,
      desc = "Interpose a move with an immediate threat before playing the expected one." },
    { id = "quiet",      label = "Quiet move", group = "tactics",
      kind = "anyTheme", themes = { "quietMove" }, build_quota = 200,
      desc = "A non-check, non-capture move that prepares a hidden threat." },
    { id = "clearance",  label = "Clearance", group = "tactics",
      kind = "anyTheme", themes = { "clearance" }, build_quota = 150,
      desc = "Clear a square, file or diagonal to make room for a follow-up." },
    { id = "xray",       label = "X-ray attack", group = "tactics",
      kind = "anyTheme", themes = { "xRayAttack" }, build_quota = 120,
      desc = "A piece attacks or defends a square through an enemy piece." },
    { id = "enpassant",  label = "En passant", group = "tactics",
      kind = "anyTheme", themes = { "enPassant" }, build_quota = 100,
      desc = "Use the en passant rule to win material." },
    { id = "captureDefender", label = "Capture the defender", group = "tactics",
      kind = "anyTheme", themes = { "capturingDefender" }, build_quota = 150,
      desc = "Remove the defender so a now-undefended piece can be captured next." },
    { id = "doublecheck", label = "Double check", group = "tactics",
      kind = "anyTheme", themes = { "doubleCheck" }, build_quota = 150,
      desc = "Check with two pieces at once — the king must move." },
    { id = "exposedKing", label = "Exposed king", group = "tactics",
      kind = "anyTheme", themes = { "exposedKing" }, build_quota = 200,
      desc = "A king with few defenders, often leading to checkmate." },
    { id = "kingsideAttack", label = "Kingside attack", group = "tactics",
      kind = "anyTheme", themes = { "kingsideAttack" }, build_quota = 200,
      desc = "Attack the king after it castled towards the kingside." },
    { id = "attackingF2F7", label = "Attack on f2/f7", group = "tactics",
      kind = "anyTheme", themes = { "attackingF2F7" }, build_quota = 120,
      desc = "Focus the attack on the weakest starting pawn, f2 or f7." },

    -- --- Mating patterns ------------------------------------------------
    { id = "backRank",   label = "Back rank mate", group = "patterns",
      kind = "anyTheme", themes = { "backRankMate" }, build_quota = 200,
      desc = "Mate on the home rank, the king trapped by its own pawns." },
    { id = "smothered",  label = "Smothered mate", group = "patterns",
      kind = "anyTheme", themes = { "smotheredMate" }, build_quota = 120,
      desc = "A knight mates a king smothered by its own pieces." },
    { id = "anastasia",  label = "Anastasia's mate", group = "patterns",
      kind = "anyTheme", themes = { "anastasiaMate" }, build_quota = 100,
      desc = "A knight and rook/queen trap the king against the board edge." },
    { id = "arabian",    label = "Arabian mate", group = "patterns",
      kind = "anyTheme", themes = { "arabianMate" }, build_quota = 100,
      desc = "A knight and rook trap the king in a corner." },
    { id = "boden",      label = "Boden's mate", group = "patterns",
      kind = "anyTheme", themes = { "bodenMate" }, build_quota = 80,
      desc = "Two bishops on criss-crossing diagonals deliver mate." },
    { id = "opera",      label = "Opera mate", group = "patterns",
      kind = "anyTheme", themes = { "operaMate" }, build_quota = 120,
      desc = "A rook checks the king while a bishop defends it." },
    { id = "balestra",   label = "Balestra mate", group = "patterns",
      kind = "anyTheme", themes = { "balestraMate" }, build_quota = 60,
      desc = "A bishop mates while a queen blocks the remaining escapes." },
    { id = "blindSwine", label = "Blind swine mate", group = "patterns",
      kind = "anyTheme", themes = { "blindSwineMate" }, build_quota = 60,
      desc = "Two rooks team up to mate within a 2×2 area." },
    { id = "cornerMate", label = "Corner mate", group = "patterns",
      kind = "anyTheme", themes = { "cornerMate" }, build_quota = 80,
      desc = "A rook or queen and a knight confine the king to the corner." },
    { id = "doubleBishop", label = "Double bishop mate", group = "patterns",
      kind = "anyTheme", themes = { "doubleBishopMate" }, build_quota = 60,
      desc = "Two bishops on adjacent diagonals deliver mate." },
    { id = "dovetail",   label = "Dovetail mate", group = "patterns",
      kind = "anyTheme", themes = { "dovetailMate" }, build_quota = 60,
      desc = "A queen mates an adjacent king whose escapes are blocked." },
    { id = "epaulette",  label = "Epaulette mate", group = "patterns",
      kind = "anyTheme", themes = { "epauletteMate" }, build_quota = 70,
      desc = "The king's two escapes are occupied by its own pieces." },
    { id = "hook",       label = "Hook mate", group = "patterns",
      kind = "anyTheme", themes = { "hookMate" }, build_quota = 60,
      desc = "Rook, knight and pawn mate, an enemy pawn limiting the king." },
    { id = "killBox",    label = "Kill box mate", group = "patterns",
      kind = "anyTheme", themes = { "killBoxMate" }, build_quota = 50,
      desc = "A rook next to the king, backed by a queen, in a 3×3 box." },
    { id = "pillsbury",  label = "Pillsbury's mate", group = "patterns",
      kind = "anyTheme", themes = { "pillsburysMate" }, build_quota = 70,
      desc = "A rook delivers mate while a bishop confines the king." },
    { id = "morphy",     label = "Morphy's mate", group = "patterns",
      kind = "anyTheme", themes = { "morphysMate" }, build_quota = 60,
      desc = "A bishop checks while a rook confines the king." },
    { id = "swallowtail", label = "Swallow's tail mate", group = "patterns",
      kind = "anyTheme", themes = { "swallowstailMate" }, build_quota = 60,
      desc = "A mate resembling a swallow's tail — escapes blocked by own pieces." },
    { id = "triangle",   label = "Triangle mate", group = "patterns",
      kind = "anyTheme", themes = { "triangleMate" }, build_quota = 60,
      desc = "Queen and rook on a line form a triangle around the king." },
    { id = "vukovic",    label = "Vuković mate", group = "patterns",
      kind = "anyTheme", themes = { "vukovicMate" }, build_quota = 50,
      desc = "A rook mates backed by a third piece, a knight blocking escapes." },

    -- --- Endgames --------------------------------------------------------
    { id = "endgame",      label = "Endgame", group = "endgames",
      kind = "anyTheme", themes = { "endgame" }, build_quota = 400,
      desc = "A tactic during the last phase of the game." },
    { id = "pawnEndgame",  label = "Pawn endgame", group = "endgames",
      kind = "anyTheme", themes = { "pawnEndgame" }, build_quota = 200,
      desc = "An endgame with only pawns (and kings)." },
    { id = "rookEndgame",  label = "Rook endgame", group = "endgames",
      kind = "anyTheme", themes = { "rookEndgame" }, build_quota = 250,
      desc = "An endgame with only rooks and pawns." },
    { id = "knightEndgame", label = "Knight endgame", group = "endgames",
      kind = "anyTheme", themes = { "knightEndgame" }, build_quota = 150,
      desc = "An endgame with only knights and pawns." },
    { id = "bishopEndgame", label = "Bishop endgame", group = "endgames",
      kind = "anyTheme", themes = { "bishopEndgame" }, build_quota = 150,
      desc = "An endgame with only bishops and pawns." },
    { id = "queenEndgame", label = "Queen endgame", group = "endgames",
      kind = "anyTheme", themes = { "queenEndgame" }, build_quota = 150,
      desc = "An endgame with only queens and pawns." },
    { id = "queenRookEndgame", label = "Queen + rook endgame", group = "endgames",
      kind = "anyTheme", themes = { "queenRookEndgame" }, build_quota = 100,
      desc = "An endgame with only queens, rooks and pawns." },

    -- --- Pawn play --------------------------------------------------------
    { id = "promotion",     label = "Promotion", group = "pawns",
      kind = "anyTheme", themes = { "promotion" }, build_quota = 200,
      desc = "Promote a pawn to a queen or a lesser piece." },
    { id = "underPromotion", label = "Underpromotion", group = "pawns",
      kind = "anyTheme", themes = { "underPromotion" }, build_quota = 100,
      desc = "Promotion to a knight, bishop or rook — not a queen." },
    { id = "advancedPawn",  label = "Advanced pawn", group = "pawns",
      kind = "anyTheme", themes = { "advancedPawn" }, build_quota = 150,
      desc = "A pawn deep in the opponent's position, threatening to promote." },

    -- --- Phases ------------------------------------------------------------
    { id = "opening",    label = "Opening", group = "phases",
      kind = "anyTheme", themes = { "opening" }, build_quota = 400,
      desc = "A tactic during the first phase of the game." },
    { id = "middlegame", label = "Middlegame", group = "phases",
      kind = "anyTheme", themes = { "middlegame" }, build_quota = 500,
      desc = "A tactic during the second phase of the game." },

    -- --- Goals ----------------------------------------------------------
    { id = "equality",  label = "Equality", group = "goals",
      kind = "anyTheme", themes = { "equality" }, build_quota = 150,
      desc = "Come back from a losing position to a draw or balance." },
    { id = "advantage", label = "Advantage", group = "goals",
      kind = "anyTheme", themes = { "advantage" }, build_quota = 220,
      desc = "Seize a decisive advantage, ~200–600cp." },
    { id = "crushing",  label = "Crushing", group = "goals",
      kind = "anyTheme", themes = { "crushing" }, build_quota = 220,
      desc = "Punish a blunder into a crushing advantage, ~600cp+." },
    { id = "mate",      label = "Checkmate", group = "goals",
      kind = "anyTheme", themes = { "mate" }, build_quota = 180,
      desc = "Win the game with style." },

    -- --- Lengths -----------------------------------------------------------
    { id = "oneMove",   label = "One move", group = "lengths",
      kind = "anyTheme", themes = { "oneMove" }, build_quota = 180,
      desc = "A puzzle that is only one move long." },
    { id = "short",     label = "Short", group = "lengths",
      kind = "anyTheme", themes = { "short" }, build_quota = 200,
      desc = "Two moves to win." },
    { id = "long",      label = "Long", group = "lengths",
      kind = "anyTheme", themes = { "long" }, build_quota = 160,
      desc = "Three moves to win." },
    { id = "veryLong",  label = "Very long", group = "lengths",
      kind = "anyTheme", themes = { "veryLong" }, build_quota = 160,
      desc = "Four moves or more to win." },

    -- --- Openings by name (prefix match on opening tags) -------------------
    { id = "openSicilian",    label = "Sicilian Defense",  group = "openings",
      kind = "prefix", prefixes = { "Sicilian_Defense" }, build_quota = 300,
      desc = "Puzzles that arose out of the Sicilian Defense." },
    { id = "openFrench",      label = "French Defense",    group = "openings",
      kind = "prefix", prefixes = { "French_Defense" }, build_quota = 200,
      desc = "Puzzles that arose out of the French Defense." },
    { id = "openCaroKann",    label = "Caro-Kann Defense", group = "openings",
      kind = "prefix", prefixes = { "Kann_Defense", "Caro-Kann_Defense" }, build_quota = 200,
      desc = "Puzzles that arose out of the Caro-Kann Defense." },
    { id = "openKingsPawn",   label = "King's Pawn Game",  group = "openings",
      kind = "prefix", prefixes = { "Kings_Pawn_Game" }, build_quota = 200,
      desc = "Puzzles from games that began with 1.e4 (unclassified)." },
    { id = "openQueensPawn",  label = "Queen's Pawn Game", group = "openings",
      kind = "prefix", prefixes = { "Queens_Pawn_Game" }, build_quota = 200,
      desc = "Puzzles from games that began with 1.d4." },
    { id = "openQueensGambit", label = "Queen's Gambit",   group = "openings",
      kind = "prefix", prefixes = { "Queens_Gambit" }, build_quota = 150,
      desc = "Puzzles from games in the Queen's Gambit family." },
    { id = "openKingsIndian", label = "King's Indian",     group = "openings",
      kind = "prefix", prefixes = { "Kings_Indian_Defense" }, build_quota = 150,
      desc = "Puzzles from games in the King's Indian family." },
    { id = "openKingsGambit", label = "King's Gambit",     group = "openings",
      kind = "prefix", prefixes = { "Kings_Gambit" }, build_quota = 120,
      desc = "Puzzles from games in the King's Gambit." },
    { id = "openItalian",     label = "Italian Game",      group = "openings",
      kind = "prefix", prefixes = { "Italian_Game" }, build_quota = 200,
      desc = "Puzzles that arose out of the Italian Game." },
    { id = "openRuyLopez",    label = "Ruy Lopez",         group = "openings",
      kind = "prefix", prefixes = { "Ruy_Lopez" }, build_quota = 150,
      desc = "Puzzles that arose out of the Ruy Lopez." },
    { id = "openScotch",      label = "Scotch Game",       group = "openings",
      kind = "prefix", prefixes = { "Scotch_Game" }, build_quota = 150,
      desc = "Puzzles that arose out of the Scotch Game." },
    { id = "openEnglish",     label = "English Opening",   group = "openings",
      kind = "prefix", prefixes = { "English_Opening" }, build_quota = 150,
      desc = "Puzzles that arose out of the English Opening." },
    { id = "openScandinavian", label = "Scandinavian Defense", group = "openings",
      kind = "prefix", prefixes = { "Scandinavian_Defense" }, build_quota = 150,
      desc = "Puzzles that arose out of the Scandinavian Defense." },
    { id = "openFourKnights", label = "Four Knights Game", group = "openings",
      kind = "prefix", prefixes = { "Four_Knights_Game" }, build_quota = 120,
      desc = "Puzzles that arose out of the Four Knights Game." },
    { id = "openVienna",      label = "Vienna Game",       group = "openings",
      kind = "prefix", prefixes = { "Vienna_Game" }, build_quota = 120,
      desc = "Puzzles that arose out of the Vienna Game." },
    { id = "openPhilidor",    label = "Philidor Defense",  group = "openings",
      kind = "prefix", prefixes = { "Philidor_Defense" }, build_quota = 120,
      desc = "Puzzles that arose out of the Philidor Defense." },
    { id = "openNimzoIndian", label = "Nimzo-Indian Defense", group = "openings",
      kind = "prefix", prefixes = { "Nimzo-Indian_Defense" }, build_quota = 120,
      desc = "Puzzles that arose out of the Nimzo-Indian Defense." },
}

-- Quota for records that match no catalog type (the builder's fallback pool;
-- tiny in practice because phases cover ~100% of puzzles). With an explicit
-- LIMIT the converter replaces this with the LIMIT-sized fallback pool.
Types.RANDOM_QUOTA = 200

--- Lookup helpers -------------------------------------------------

Types._by_id = nil

--- Look up a type entry by id (nil when unknown).
function Types.byId(id)
    if not Types._by_id then
        local idx = {}
        for _, t in ipairs(Types.LIST) do idx[t.id] = t end
        Types._by_id = idx
    end
    return Types._by_id[id]
end

--- The display label for a type id (falls back to the id itself).
function Types.label(id)
    local entry = Types.byId(id)
    return entry and entry.label or id
end

--- The one-line description for a type id (nil when unknown).
function Types.desc(id)
    local entry = Types.byId(id)
    return entry and entry.desc or nil
end

--- True when the catalog has an entry for `id`.
function Types.known(id)
    return Types.byId(id) ~= nil
end

--- Whether `rec` (a bank record with a `.t` tag list) belongs to `entry`.
-- "random"/any matches nothing here — it is the "no filter" default, not a
-- matcher. Unknown ids match nothing, which is how an empty slice arises.
function Types.matches(entry, rec)
    if not entry then return false end
    if entry.kind == "any" then return false end
    local tags = rec and rec.t
    if type(tags) ~= "table" then return false end

    if entry.themes then
        if entry.kind == "matchAll" then
            local missing = #entry.themes
            for _, t in ipairs(tags) do
                for _, want in ipairs(entry.themes) do
                    if t == want then missing = missing - 1 break end
                end
            end
            if missing == 0 then return true end
        else -- anyTheme
            for _, t in ipairs(tags) do
                for _, want in ipairs(entry.themes) do
                    if t == want then return true end
                end
            end
        end
    end

    if entry.prefixes then
        for _, t in ipairs(tags) do
            for _, p in ipairs(entry.prefixes) do
                -- Full open_name, or open_name_Variation, exactly.
                if t == p or t:sub(1, #p + 1) == p .. "_" then return true end
            end
        end
    end
    return false
end

--- One-pass counts of how many bank records match each type id.
-- (Random = the whole bank.) Handy for the picker's per-type counts.
function Types.counts(bank)
    local out = {}
    for _, t in ipairs(Types.LIST) do
        out[t.id] = 0
        if t.group == nil then out[t.id] = #(bank or {}) end
    end
    for _, rec in ipairs(bank or {}) do
        for _, t in ipairs(Types.LIST) do
            if Types.matches(t, rec) then out[t.id] = out[t.id] + 1 end
        end
    end
    return out
end

function Types.phase(tags)
    for _, want in ipairs({"opening", "middlegame", "endgame"}) do
        for _, tag in ipairs(tags or {}) do
            if tag == want then return Types.label(want) end
        end
    end
    return "Random"
end

function Types.principal(tags)
    local rec = { t=tags or {} }
    for _, entry in ipairs(Types.LIST) do
        if entry.group == "mates" or entry.group == "tactics"
                or entry.group == "patterns" or entry.group == "pawns" then
            if Types.matches(entry, rec) then return entry.label end
        end
    end
    return Types.phase(tags)
end

return Types
