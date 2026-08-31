-- Resolve "slatechess/<name>" icon names to absolute file paths inside this
-- plugin's icons/ directory. KOReader's IconWidget only searches its own data
-- dir and bundled resources for named icons; loading via `file=` always works
-- regardless of where the plugin is installed.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local PLUGIN_ICONS_DIR
do
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    local dir = src:match("^(.*[/\\])") or "./"
    -- This file lives in <plugin>/ui/, so step back up to the plugin root
    -- before appending "icons".
    dir = dir:gsub("[/\\]ui[/\\]$", "")
    PLUGIN_ICONS_DIR = dir .. "/icons"
end

local icons = {}

--- Resolves a "slatechess/<name>" icon name to a plugin-local .svg path.
-- Returns nil if the name isn't one of ours or the file doesn't exist.
function icons.resolve(name)
    if type(name) ~= "string" then return nil end
    local base = name:match("^slatechess/(.+)$")
    if not base or base:find("/", 1, true) then return nil end
    local path = PLUGIN_ICONS_DIR .. "/" .. base .. ".svg"
    if lfs.attributes(path, "mode") == "file" then return path end
    logger.warn("slatechess: plugin-local icon not found for", name, "->", path)
    return nil
end

return icons
