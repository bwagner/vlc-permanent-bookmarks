-- VLC 3.0.x embeds Lua 5.1.5 (confirmed from liblua_plugin.dylib: the
-- version string, plus lua_setfenv/lua_getfenv, which are 5.1 only).
std = "lua51"

-- The host injects the whole VLC API as one global table.
read_globals = {"vlc"}

-- Every function in this file is a top-level global calling other
-- top-level globals. That is the file's structure, not a mistake.
-- Globals assigned inside a function body still warn, which is the
-- check actually worth having here.
allow_defined_top = true

-- 131 is "unused global". VLC calls these eight by name, so nothing in
-- the file reads them. Scoped per name rather than disabled outright, so
-- a genuinely dead helper still gets reported.
ignore = {
    "131/descriptor",
    "131/activate",
    "131/deactivate",
    "131/close",
    "131/menu",
    "131/trigger_menu",
    "131/input_changed",
    "131/meta_changed",
}

-- trigger_menu(dlg_id) must keep VLC's signature even though the
-- single-entry menu ignores the argument.
unused_args = false
