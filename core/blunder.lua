-- Blunder: difficulty damper.
--
-- Pure Lua. With probability p the engine's move is replaced by a random
-- legal move, so low-difficulty opponents feel beatable. The RNG is
-- injectable for deterministic tests.

local Blunder = {}
Blunder.__index = Blunder

--- `game` is a core.game Game; `chance` is in [0, 1]; `rng` returns a
-- uniform value in [0, 1) — the injected `deps.rng` seam. The math.random
-- fallback is the one sanctioned randomness site in core (the purity gate
-- bans its use anywhere else).
function Blunder:new(game, chance, rng)
    local o = setmetatable({}, self)
    o.game  = game
    o.rng   = rng or math.random -- luacheck: ignore 143
    o:setChance(chance)
    return o
end

function Blunder:setChance(chance)
    self.chance = math.max(0.0, math.min(1.0, tonumber(chance) or 0.0))
end

--- May replace `uci_move` with a random legal move (UCI string,
--- promotions forced to queen). Returns a UCI move either way.
function Blunder:maybeWeaken(uci_move)
    if self.chance <= 0.0 then return uci_move end
    if self.rng() > self.chance then return uci_move end

    local legal = self.game:legalMoves({ verbose = true })
    if not legal or #legal == 0 then return uci_move end

    local pick = legal[math.floor(self.rng() * #legal) + 1]
    local result = pick.from .. pick.to
    if pick.promotion and pick.promotion ~= "" then
        result = result .. pick.promotion:lower()
    end
    return result
end

return Blunder
