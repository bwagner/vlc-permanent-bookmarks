-- Convert legacy bookmark files to the JSON format.
--
-- The legacy format is a Lua chunk, so reading it means loading it - which is
-- exactly the hazard this migration removes. That is acceptable here and only
-- here: this runs once, locally, over the user's own files, by explicit
-- request. The extension itself never loads them again.
--
-- Each `<hash>` file becomes `<hash>.json`, and the original is renamed to
-- `<hash>.legacy` rather than deleted. An existing `<hash>.json` is never
-- overwritten.
--
-- Every converted file is verified by reading it back with jq - an independent
-- parser - and comparing every field against the source table. A file that
-- fails verification is removed again and the original is left alone.
--
-- Usage: lua scripts/migrate_bookmarks_to_json.lua [--apply] [bookmarks-dir]
--        Without --apply it is a dry run and writes nothing.
-- Exits 1 if any file failed, 2 on a usage or environment error.

local BOOKMARK_FORMAT_VERSION = 1
local JSON_EXT = ".json"
local LEGACY_EXT = ".legacy"
local INDENT = "  "
-- The hash is 16 hex digits. Anything else in the directory is left alone.
local LEGACY_NAME_PATTERN = "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
local DEFAULT_DIR = "/Library/Application Support/org.videolan.vlc/lua/extensions/userdata/bookmarks"
local EXIT_FAILURE = 1
local EXIT_USAGE = 2

-- JSON string escaping. Short forms where JSON defines them, \u00XX for the
-- remaining control characters, so the output matches jq's own @json encoding
-- and the verification below compares like with like.
local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t"
}

local function jsonString(s)
    local out = string.gsub(s, '[%z\1-\31"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. out .. '"'
end

local function jsonNumber(n)
    -- Microsecond timestamps are whole numbers; %d keeps them out of
    -- exponent notation, which JSON allows but nothing here should produce.
    if n == math.floor(n) then
        return string.format("%d", n)
    end
    return string.format("%.14g", n)
end

-- Key order matches the extension's JSON_KEY_ORDER (verified against dkjson's
-- own output). The indentation differs slightly from dkjson's, which is
-- cosmetic and disappears the first time the extension rewrites the file.
local function encodeBookmarks(bookmarks)
    local parts = {}
    parts[#parts + 1] = "{"
    parts[#parts + 1] = INDENT .. '"version":' .. jsonNumber(BOOKMARK_FORMAT_VERSION) .. ","
    parts[#parts + 1] = INDENT .. '"bookmarks":['
    for i, b in ipairs(bookmarks) do
        local sep = (i < #bookmarks) and "," or ""
        parts[#parts + 1] = INDENT .. INDENT .. "{"
        parts[#parts + 1] = INDENT .. INDENT .. INDENT .. '"time":' .. jsonNumber(b.time) .. ","
        parts[#parts + 1] = INDENT .. INDENT .. INDENT .. '"formattedTime":' .. jsonString(b.formattedTime) .. ","
        parts[#parts + 1] = INDENT .. INDENT .. INDENT .. '"label":' .. jsonString(b.label)
        parts[#parts + 1] = INDENT .. INDENT .. "}" .. sep
    end
    parts[#parts + 1] = INDENT .. "]"
    parts[#parts + 1] = "}"
    return table.concat(parts, "\n") .. "\n"
end

-- Mirrors table_load() from the pre-JSON extension, index-linking pass included.
local function loadLegacy(path)
    local chunk, err = loadfile(path)
    if not chunk then
        return nil, "cannot load: " .. tostring(err)
    end
    local ok, tables = pcall(chunk)
    if not ok or type(tables) ~= "table" then
        return nil, "not a bookmark table"
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
    if type(tables[1]) ~= "table" then
        return nil, "empty bookmark table"
    end
    return tables[1]
end

local function validate(bookmarks)
    for i, b in ipairs(bookmarks) do
        if type(b) ~= "table" then
            return "entry " .. i .. " is not a table"
        end
        if type(b.time) ~= "number" then
            return "entry " .. i .. " has no numeric time"
        end
        if type(b.label) ~= "string" then
            return "entry " .. i .. " has no string label"
        end
        if type(b.formattedTime) ~= "string" then
            return "entry " .. i .. " has no string formattedTime"
        end
    end
    return nil
end

local function plural(n)
    return n .. " bookmark" .. (n == 1 and "" or "s")
end

local function shellQuote(path)
    return "'" .. string.gsub(path, "'", "'\\''") .. "'"
end

local function capture(command)
    local pipe = io.popen(command, "r")
    if not pipe then
        return nil
    end
    local out = pipe:read("*a")
    local ok = pipe:close()
    if not ok then
        return nil, out
    end
    return out
end

-- One line per bookmark, values JSON-encoded, so the comparison is exact and
-- cannot be confused by a tab or a quote inside a label.
local function expectedDigest(bookmarks)
    local lines = {}
    for _, b in ipairs(bookmarks) do
        lines[#lines + 1] = jsonNumber(b.time) .. "\t" .. jsonString(b.formattedTime) .. "\t" .. jsonString(b.label)
    end
    return table.concat(lines, "\n")
end

local JQ_DIGEST = [[jq -r '.bookmarks[] | "\(.time)\t\(.formattedTime|@json)\t\(.label|@json)"' ]]
local JQ_VERSION = [[jq -er '.version' ]]

local function verify(path, bookmarks)
    local version = capture(JQ_VERSION .. shellQuote(path))
    if not version then
        return "jq could not read the file"
    end
    if tonumber(version) ~= BOOKMARK_FORMAT_VERSION then
        return "version is " .. tostring(version and version:gsub("%s+$", "")) .. ", expected " ..
                   BOOKMARK_FORMAT_VERSION
    end
    local digest = capture(JQ_DIGEST .. shellQuote(path))
    if not digest then
        return "jq could not read the bookmarks array"
    end
    digest = string.gsub(digest, "\n$", "")
    local expected = expectedDigest(bookmarks)
    if digest ~= expected then
        return "content mismatch\n    jq:       " .. string.gsub(digest, "\n", "\n              ") ..
                   "\n    expected: " .. string.gsub(expected, "\n", "\n              ")
    end
    return nil
end

local function fileExists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function listDir(dir)
    local out = capture("ls -1 " .. shellQuote(dir) .. " 2>/dev/null")
    if not out then
        return nil
    end
    local names = {}
    for name in string.gmatch(out, "[^\n]+") do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

-- Arguments
local apply = false
local dir = nil
for _, a in ipairs(arg) do
    if a == "--apply" then
        apply = true
    elseif a == "-h" or a == "--help" then
        print("usage: lua migrate_bookmarks_to_json.lua [--apply] [bookmarks-dir]")
        os.exit(0)
    elseif string.sub(a, 1, 1) == "-" then
        io.stderr:write("unknown option: " .. a .. "\n")
        os.exit(EXIT_USAGE)
    else
        dir = a
    end
end
if not dir then
    local home = os.getenv("HOME")
    if not home then
        io.stderr:write("HOME is not set and no directory was given\n")
        os.exit(EXIT_USAGE)
    end
    dir = home .. DEFAULT_DIR
end

if not capture("command -v jq") then
    io.stderr:write("jq is required for verification and was not found\n")
    os.exit(EXIT_USAGE)
end

local names = listDir(dir)
if not names then
    io.stderr:write("cannot list " .. dir .. "\n")
    os.exit(EXIT_USAGE)
end

print((apply and "Converting" or "Dry run - nothing will be written") .. " in " .. dir)
print("")

local converted, skipped, failed = 0, 0, 0

for _, name in ipairs(names) do
    local path = dir .. "/" .. name
    if not string.match(name, LEGACY_NAME_PATTERN) then
        -- .json, .legacy, .DS_Store, anything else: not ours to touch
        print("skip     " .. name .. " (not a legacy bookmark file)")
        skipped = skipped + 1
    else
        local target = path .. JSON_EXT
        local backup = path .. LEGACY_EXT
        if fileExists(target) then
            print("skip     " .. name .. " (" .. name .. JSON_EXT .. " already exists)")
            skipped = skipped + 1
        elseif fileExists(backup) then
            print("skip     " .. name .. " (" .. name .. LEGACY_EXT .. " already exists)")
            skipped = skipped + 1
        else
            local bookmarks, err = loadLegacy(path)
            if not bookmarks then
                print("FAIL     " .. name .. ": " .. err)
                failed = failed + 1
            else
                local invalid = validate(bookmarks)
                if invalid then
                    print("FAIL     " .. name .. ": " .. invalid)
                    failed = failed + 1
                elseif not apply then
                    print("would convert " .. name .. " -> " .. name .. JSON_EXT .. " (" .. plural(#bookmarks) ..
                              "), and rename the original to " .. name .. LEGACY_EXT)
                    converted = converted + 1
                else
                    local file, openErr = io.open(target, "wb")
                    if not file then
                        print("FAIL     " .. name .. ": cannot write " .. target .. ": " .. tostring(openErr))
                        failed = failed + 1
                    else
                        file:write(encodeBookmarks(bookmarks))
                        local closed, closeErr = file:close()
                        if not closed then
                            print("FAIL     " .. name .. ": " .. tostring(closeErr))
                            failed = failed + 1
                        else
                            local bad = verify(target, bookmarks)
                            if bad then
                                os.remove(target)
                                print("FAIL     " .. name .. ": verification failed, " .. target ..
                                          " removed and the original left alone\n    " .. bad)
                                failed = failed + 1
                            else
                                local renamed, renameErr = os.rename(path, backup)
                                if not renamed then
                                    print("FAIL     " .. name .. ": converted but could not rename the original: " ..
                                              tostring(renameErr))
                                    failed = failed + 1
                                else
                                    print("ok       " .. name .. " -> " .. name .. JSON_EXT ..
                                              " (" .. plural(#bookmarks) .. ", verified), original kept as " ..
                                              name .. LEGACY_EXT)
                                    converted = converted + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

print("")
print(string.format("%d converted, %d skipped, %d failed", converted, skipped, failed))
if not apply and converted > 0 then
    print("Re-run with --apply to write.")
end
os.exit(failed > 0 and EXIT_FAILURE or 0)
