-- Luacheck configuration for SlateChess.
std = "luajit"
globals = {
    "logger",
}
line_length = 120
cache = true

-- Vendored third-party rules engine — don't lint.
exclude_files = {
    "chess/src/*.lua",
}

-- The Arbiter-island purity gate: core/*.lua stays host-testable pure
-- Lua. `os`/`io` are banned outright (no wall clock, no IO); `math` may
-- only use the pure arithmetic set — no `math.random`, which must flow
-- through the injected `deps.rng` (its Blunder default is the one
-- luacheck-ignored exception, marked inline in core/blunder.lua). A
-- stray `require("ui/...")` or any require outside the sealed core
-- modules also fails (also enforced by the mechanical Makefile gate,
-- since luacheck does not track require strings).
--
-- The per-file std below is built from luacheck's own luajit standard so
-- this project can't drift from luacheck's real definitions. If luacheck
-- internals are unavailable (older/newer major version), the gate degrades
-- to the plain luajit std and the mechanical Makefile checks still hold.
local builtin_ok, builtin = pcall(require, "luacheck.builtin_standards")
local core_std = "luajit"
if builtin_ok and builtin.luajit then
    local PURE_MATH = {
        abs = true, ceil = true, floor = true, huge = true, max = true, min = true,
    }
    local src = builtin.luajit.read_globals or {}
    local core = { globals = {}, read_globals = {} }
    for name, def in pairs(src) do
        if name ~= "os" and name ~= "io" then
            if name == "math" then
                local fields = {}
                for fname, fdef in pairs(def.fields or {}) do
                    if PURE_MATH[fname] then fields[fname] = fdef end
                end
                core.read_globals[name] = { fields = fields }
            else
                core.read_globals[name] = def
            end
        end
    end
    core_std = core
end

files["core/*.lua"] = {
    std = core_std,
}