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
