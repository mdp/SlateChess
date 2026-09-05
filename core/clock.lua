-- Clock: pure chess-clock accounting.
--
-- No scheduling and no I/O: the App feeds a time source (`now`, seconds)
-- and drives start/stop/switch at game transitions. Stopping a player's
-- clock banks their Fischer increment. `remaining()` clamps at zero, and
-- `expired()` reports flag-fall for the side on move.
--
-- Colors are the rules engine's constants: "w" (white) and "b" (black).

local Clock = {}
Clock.__index = Clock

--- `control` = { base = {w=seconds, b=seconds}, increment = {w=secs, b=secs} }
-- `opts.now` is mandatory — the time source in seconds (the pure module
-- never reads the wall clock; the core purity gate bans os.*).
function Clock:new(control, opts)
    opts = opts or {}
    assert(type(opts.now) == "function",
        "clock: opts.now is required (host-testable time source)")
    control = control or {}
    local base      = control.base or {}
    local increment = control.increment or {}
    local o = setmetatable({}, self)
    o.now       = opts.now
    o.base      = { w = tonumber(base.w) or 0, b = tonumber(base.b) or 0 }
    o.increment = { w = tonumber(increment.w) or 0, b = tonumber(increment.b) or 0 }
    o.time      = { w = o.base.w, b = o.base.b }
    o.turn      = "w"
    o.running   = false
    o.anchor    = nil
    return o
end

function Clock:_bankElapsed()
    if not self.running then return end
    local elapsed = self.now() - self.anchor
    local c = self.turn
    self.time[c] = math.max(0, self.time[c] - elapsed + self.increment[c])
    self.running = false
    self.anchor = nil
end

--- Starts (or restarts) the clock for the current player.
function Clock:start()
    if self.running then return end
    self.anchor = self.now()
    self.running = true
end

--- Stops the clock, banking the elapsed time for the current player.
function Clock:stop()
    self:_bankElapsed()
end

--- Stops the current player's clock (banking their increment) and hands
-- the clock to `color` (defaults to the opponent), starting it immediately.
function Clock:switch(color)
    self:_bankElapsed()
    if color == "w" or color == "b" then
        self.turn = color
    else
        self.turn = (self.turn == "w") and "b" or "w"
    end
    self:start()
end

--- Sets which color is on the clock without banking time. Used on
--- restore, where the banked times were persisted as-is.
function Clock:setTurn(color)
    if self.running then self:stop() end
    if color == "w" or color == "b" then self.turn = color end
end

--- Resets both clocks to their base times; the clock is stopped, White is
--- on move.
function Clock:reset()
    self.time    = { w = self.base.w, b = self.base.b }
    self.turn    = "w"
    self.running = false
    self.anchor  = nil
end

--- Directly sets a player's banked remaining time (used on restore).
function Clock:setTime(color, seconds)
    self.time[color] = math.max(0, tonumber(seconds) or 0)
end

--- Remaining seconds for a color. For the running player this includes
--- time elapsed since their clock was started (clamped at zero).
function Clock:remaining(color)
    if self.running and color == self.turn then
        local elapsed = math.max(0, self.now() - self.anchor)
        return math.max(0, self.time[color] - elapsed)
    end
    return self.time[color]
end

--- True while the game is running and the side on move has no time left.
function Clock:expired()
    return self.running and self:remaining(self.turn) <= 0
end

--- Formats seconds as "hh:mm:ss".
function Clock.format(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours   = math.floor(seconds / 3600)
    local minutes = math.floor(seconds / 60) % 60
    local secs    = seconds % 60
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

return Clock
