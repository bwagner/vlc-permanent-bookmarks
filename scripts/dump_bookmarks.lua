-- Dump a saved bookmark file as TSV: index, time (us), formattedTime, label.
--
-- The files written by table_save() in vlc_permanents_bookmarks.lua are plain
-- Lua table constructors, so they can be loaded directly. This mirrors
-- table_load(), including the index-linking pass, so the dumper cannot drift
-- from the format the extension actually writes.
--
-- Usage: lua dump_bookmarks.lua <bookmark-file>
-- Exits 2 if the file cannot be loaded.

local path = arg[1]
if not path then
    io.stderr:write("usage: dump_bookmarks.lua <bookmark-file>\n")
    os.exit(2)
end

local ftables, err = loadfile(path)
if not ftables then
    io.stderr:write("cannot load " .. path .. ": " .. tostring(err) .. "\n")
    os.exit(2)
end

local ok, tables = pcall(ftables)
if not ok or type(tables) ~= "table" then
    io.stderr:write("not a bookmark table: " .. path .. "\n")
    os.exit(2)
end

for idx = 1, #tables do
    local tolinki = {}
    for i, v in pairs(tables[idx]) do
        if type(v) == "table" then
            tables[idx][i] = tables[v[1]]
        end
        if type(i) == "table" and tables[i[1]] then
            table.insert(tolinki, {i, tables[i[1]]})
        end
    end
    for _, v in ipairs(tolinki) do
        tables[idx][v[2]], tables[idx][v[1]] = tables[idx][v[1]], nil
    end
end

local bookmarks = tables[1]
if type(bookmarks) ~= "table" then
    io.stderr:write("empty bookmark table: " .. path .. "\n")
    os.exit(2)
end

for i, b in ipairs(bookmarks) do
    io.write(string.format("%d\t%s\t%s\t%s\n", i, tostring(b.time), tostring(b.formattedTime), tostring(b.label)))
end
