-- Game: the chess rules facade.
--
-- Pure Lua (no KOReader dependencies) — this is the primary test surface.
-- Wraps the vendored rules engine (chess/src/chess.lua) behind a small,
-- explicit interface:
--
--   * roles          — which colors are played by humans
--   * move play      — SAN strings or {from,to,promotion} tables
--   * undo / redo    — with a redo stack cleared on every new move
--   * UCI move list  — the full history as "e2e4 e7e5 …" for engine sync
--   * status         — terminal state (checkmate / draws) as one query
--   * PGN            — export and import of full games
--
-- Note: the rules engine's public functions are closures called with dot
-- syntax (e.g. `self.engine.moves({...})`), not method calls.

local chess = require("chess/src/chess")

local Game = {}
Game.__index = Game

-- Color constants, forwarded from the rules engine ("w" / "b").
Game.WHITE = chess.WHITE
Game.BLACK = chess.BLACK
Game.PAWN = chess.PAWN
Game.KNIGHT = chess.KNIGHT
Game.BISHOP = chess.BISHOP
Game.ROOK = chess.ROOK
Game.QUEEN = chess.QUEEN
Game.KING = chess.KING

local function is_color(color)
    return color == chess.WHITE or color == chess.BLACK
end

--- Creates a Game. `opts.fen` optionally loads a position; when the FEN
-- cannot be parsed the constructor returns nil (no silent fallback to the
-- start position, which would make a corrupt record "playable").
function Game:new(opts)
    opts = opts or {}
    local o = setmetatable({}, self)
    o.engine = chess()
    if opts.fen then
        -- chess.load throws on some garbage but SILENTLY IGNORES other
        -- unparseable FENs (keeping the start position), so the position
        -- must be verified by round-tripping it back out of the engine:
        -- the placement / active-color / castling fields have to match.
        local ok = pcall(function() o.engine.load(opts.fen) end)
        if not ok then return nil end
        local want_p, want_a, want_c = opts.fen:match("^(%S+)%s+(%S+)%s+(%S+)")
        local got = o.engine.fen() or ""
        local got_p, got_a, got_c = got:match("^(%S+)%s+(%S+)%s+(%S+)")
        if not want_p or got_p ~= want_p or got_a ~= want_a or got_c ~= want_c then
            return nil
        end
    end
    o.redo_stack = {}
    o._replaying_redo = false
    o.human = {
        [chess.WHITE] = true,
        [chess.BLACK] = false,
    }
    return o
end

-- Roles -------------------------------------------------------------------

function Game:setHuman(color, is_human)
    assert(is_color(color), "invalid color: " .. tostring(color))
    self.human[color] = is_human and true or false
end

function Game:isHuman(color)
    assert(is_color(color), "invalid color: " .. tostring(color))
    return self.human[color]
end

function Game:isHumanVsHuman()
    return self:isHuman(chess.WHITE) and self:isHuman(chess.BLACK)
end

function Game:isHumanVsComputer()
    return self:isHuman(chess.WHITE) ~= self:isHuman(chess.BLACK)
end

function Game:isComputerVsComputer()
    return not self:isHuman(chess.WHITE) and not self:isHuman(chess.BLACK)
end

-- Position queries ----------------------------------------------------------

function Game:turn()
    return self.engine.turn()
end

function Game:fen()
    return self.engine.fen()
end

function Game:board()
    return self.engine.board()
end

--- The piece at an algebraic square ("e4") or nil.
function Game:pieceAt(square)
    return self.engine.get(square)
end

function Game:inCheck()
    return self.engine.in_check() and true or false
end

--- Legal moves. `opts.verbose` returns pretty move tables instead of SAN
-- strings. See the rules engine for the pretty-move shape.
function Game:legalMoves(opts)
    return self.engine.moves(opts)
end

--- Terminal state: `{ over, result, reason }`.
-- `result` is "1-0", "0-1", or "1/2-1/2" when over.
function Game:status()
    local over, result, reason = self.engine.game_over()
    return {
        over   = over and true or false,
        result = over and result or nil,
        reason = over and reason or nil,
    }
end

-- History -------------------------------------------------------------------

--- SAN strings of every move played, e.g. {"e4", "e5", "Nf3"}.
function Game:sanHistory()
    return self.engine.history()
end

--- The full move history as a UCI token list ("e2e4", "e7e5", …),
-- suitable for `position … moves` and engine sync.
function Game:uciMoveList()
    local tokens = {}
    for _, m in ipairs(self.engine.history({ verbose = true })) do
        tokens[#tokens + 1] = m.from .. m.to .. (m.promotion or "")
    end
    return tokens
end

--- Concatenated UCI move list ("e2e4 e7e5 …"); "" when no moves played.
function Game:uciMoveString()
    return table.concat(self:uciMoveList(), " ")
end

--- The last move played (pretty move table with from/to), or nil.
function Game:lastMove()
    local history = self.engine.history({ verbose = true })
    return history[#history]
end

--- The full move history as pretty move tables (color, from, to,
-- piece, captured, promotion). The captured-pieces display replays
-- this; see core.eval.
function Game:moveHistory()
    return self.engine.history({ verbose = true })
end

-- Playing moves --------------------------------------------------------------

--- Plays a move. `move` is either a SAN string ("Nf3", with or without
-- check/annotation suffixes) or a table `{ from = "e2", to = "e4",
-- promotion = "q"|nil }`. Returns the pretty move table on success,
-- nil if the move is illegal.
function Game:playMove(move)
    local played
    if type(move) == "string" then
        played = self.engine.move(move, { sloppy = true })
    else
        played = self.engine.move(move)
    end
    if played and not self._replaying_redo then
        self.redo_stack = {}
    end
    return played
end

--- Convenience: play a UCI move ("e2e4", "e7e8q").
function Game:playUci(uci)
    if type(uci) ~= "string" or #uci < 4 then return nil end
    return self:playMove({
        from      = uci:sub(1, 2),
        to        = uci:sub(3, 4),
        promotion = #uci >= 5 and uci:sub(5, 5) or nil,
    })
end

--- Takes back the last move. Returns the pretty move, or nil.
function Game:undo()
    local move = self.engine.undo()
    if move then
        self.redo_stack[#self.redo_stack + 1] = move
    end
    return move
end

--- Replays the last undone move. Returns the pretty move, or nil.
function Game:redo()
    local move = table.remove(self.redo_stack)
    if not move then return nil end
    self._replaying_redo = true
    local ok, result = pcall(function() return self:playMove(move) end)
    self._replaying_redo = false
    if not ok then return nil end
    return result
end

--- Clears the board to the initial position and forgets the history.
function Game:reset()
    self.redo_stack = {}
    self.engine.reset()
end

-- PGN ------------------------------------------------------------------------

--- The full game as PGN (headers included when set).
function Game:pgn()
    return self.engine.pgn()
end

--- Loads a PGN string, replacing the current game.
-- Returns true on success; false + message on failure.
function Game:loadPgn(text)
    local ok, result = pcall(self.engine.load_pgn, text)
    if not ok then
        return false, tostring(result)
    end
    self.redo_stack = {}
    return true
end

return Game
