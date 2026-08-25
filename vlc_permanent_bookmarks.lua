-------------- Global variables ---------------------------------------
local mediaFile = {}
local input = nil
local Bookmarks = {}
local selectedBookmarkId = nil
-- The rows armed for deletion, sorted ascending, or nil. Separate from
-- selectedBookmarkId: a pending rename and a pending removal do not disturb
-- each other, since a rename does not shift any index.
local pendingRemoval = nil
local bookmarkFilePath = nil
-- System, set by check_config()
local slash = nil
local bookmarksDir = nil
-- Finder integration (macOS): reveal the bookmark file, or open its folder
local FINDER_REVEAL_CMD = "open -R "
local FINDER_OPEN_CMD = "open "
-- Bookmark file format. The file is JSON data, decoded with the dkjson module
-- that VLC bundles, and is never executed. The previous format was a Lua chunk
-- read with loadfile(), so any bookmark file arriving from elsewhere could run
-- arbitrary shell commands as the user - VLC's Lua state has os.execute.
local JSON_MODULE = "dkjson"
local BOOKMARK_FILE_EXT = ".json"
local BOOKMARK_FORMAT_VERSION = 1
-- Fixed key order, so a rewritten file diffs cleanly against the previous one.
local JSON_KEY_ORDER = {"version", "filename", "bookmarks", "time", "formattedTime", "label"}
local JSON_INDENT = true
local json = nil
-- Set when a file exists on disk but could not be trusted. Blocks saving, so a
-- failed read can never be turned into an overwrite.
local bookmarksReadOnly = false
local legacyBookmarkFilePath = nil
local pendingFooterMessage = nil
-- Footer messages
local MSG_JSON_MISSING = "Bookmarks unavailable - the dkjson module is missing"
local MSG_LOAD_FAILED = "Existing bookmarks could not be read - not saving over them"
local MSG_LEGACY_FOUND = "Bookmarks are in the old format - run the migration script"
local MSG_SAVE_BLOCKED = "Not saving - the existing bookmarks were not read"
local MSG_SAVE_FAILED = "Bookmarks could not be saved"
-- Two messages, not one: the first describes the state the dialog is sitting
-- in, the second answers a click. Sharing a string made Add look dead - the
-- footer already said it before the button was pressed.
local MSG_NO_MEDIA = "No media playing"
local MSG_ADD_NO_MEDIA = "Nothing to bookmark - no media is playing"
-- A third state hides behind the same nil input: a medium that is playing but
-- that getFileHash() could not hash, a stream yielding no data. Saying nothing
-- is playing would be untrue there, so it gets its own wording.
local MSG_ADD_NO_HASH = "Nothing to bookmark - this medium cannot be identified"
-- Rename is two-step: Rename loads the label, Confirm commits it. Add never
-- renames, so a pending rename cannot be committed by accident.
local MSG_RENAME_PENDING = "Renaming #%d - click Confirm to commit"
local MSG_RENAME_NOT_PENDING = "Click Rename first to load a bookmark's name"
local MSG_RENAME_SELECTION_CHANGED = "Selection changed - reselect #%d to confirm"
-- Remove is two-step as well, but its commit sits on a button of its own:
-- a confirmation that one button's double-click can satisfy is not one.
local MSG_REMOVE_PENDING_ONE = "Removing 1 bookmark - click Delete to commit"
local MSG_REMOVE_PENDING_MANY = "Removing %d bookmarks - click Delete to commit"
local MSG_REMOVE_NOT_PENDING = "Click Remove first to choose what to delete"
local MSG_REMOVE_SELECTION_CHANGED = "Selection changed - reselect to delete"
-- Show in Finder falls back to the folder whenever there is no bookmark file to
-- reveal, which is equally the state with nothing playing at all - hence two
-- wordings for the one branch.
local MSG_FINDER_NO_FILE = "No bookmarks saved yet for this video - showing the folder"
local MSG_FINDER_NO_MEDIA = "No media playing - showing the bookmarks folder"
local MSG_FINDER_NO_DIR = "Bookmarks folder is unknown"
local MSG_FINDER_FAILED = "Could not open Finder"
-- Time formats. The stored form keeps milliseconds and is also what the
-- duplicate check compares, so it must not lose precision. The list drops
-- them: millisecond precision is noise for seeking, and the four-column
-- layout pins the dialog width, so every character costs label room.
local TIME_FORMAT_STORED = "%02d:%02d:%02d.%03d"
local TIME_FORMAT_DISPLAY = "%02d:%02d:%02d"
-- UI
local dialog_UI = nil
local bookmarks_dialog = {}
local dialog_title = "VLC Permanent Bookmarks"
------------------------------------------------------------------------

-- VLC defined callback functions --------------------------------------
-- Script descriptor, called when the extensions are scanned
function descriptor()
    return {
        title = dialog_title,
        version = "1.0.1",
        author = "Bucchio",
        url = 'https://github.com/JacopoBucchioni/vlc-permanents-bookmarks',
        shortdesc = "Bookmarks",
        description = "Save bookmarks for your media files and store them permanently.",
        -- No "menu" capability: VLC's Cocoa provider never calls menu() and
        -- never builds a submenu for an extension, so menu() and trigger_menu()
        -- were dead code here (measured on 3.0.23, 2026-08-25). The flat
        -- Extensions entry, which is what a macOS App Shortcut binds to, is
        -- unaffected by dropping this.
        capabilities = {"input-listener"}
    }
end

-- First function to be called when the extension is activated
function activate()
    vlc.msg.dbg("[Activate extension] Welcome! Start saving your bookmarks!")
    local ok, err = pcall(check_config)
    if not ok then
        vlc.msg.err(err)
        return false
    end
    loadJsonModule()
    show_gui()
end

-- Called when the extension dialog is closed
function close()
    vlc.deactivate()
end

-- Called when the extension is deactivated
function deactivate()
    vlc.msg.dbg("[Deactivate extension] Bye bye!")
    if dialog_UI then
        dialog_UI:hide()
    end
end

-- related to capabilities={"input-listener"} in descriptor()
-- triggered by Start/Stop media input event
function input_changed() -- ~ !important: deve essere qualcosa di veloce
    vlc.msg.dbg("[Input changed]")
    if not dialog_UI then
        return
    end
    -- Measured on VLC 3.0.23: a track change fires this twice, and both calls
    -- already see the NEW item - there is no call that still reports the old
    -- one. The uri is therefore what separates a real change from the
    -- duplicate, and without this test every track change would hash 128 KB
    -- and parse the bookmark file twice. It is also the whole cost of the
    -- fast path, which is what the comment above asks for.
    local item = vlc.input.item()
    local uri = nil
    if item then
        uri = item:uri()
    end
    if uri == mediaFile.uri then
        return
    end
    reloadCurrentMedium()
end

-- triggered by available media input meta data?
function meta_changed()
    -- return
end
-- End VLC defined callback functions ----------------------------------

-- // Bookmarks init function
function load_bookmarks()
    -- mediaFile.metaTitle = vlc.input.item():name()
    mediaFile.uri = vlc.input.item():uri()
    if mediaFile.uri then
        local filePath = vlc.strings.make_path(mediaFile.uri)
        if not filePath then
            filePath = vlc.strings.decode_uri(mediaFile.uri)
            local match = string.match(filePath, "^.*[" .. slash .. "]([^" .. slash .. "]-).?[%a%d]*$")
            if match then
                filePath = match
            end
        else
            mediaFile.dir, mediaFile.name = string.match(filePath,
                "^(.*[" .. slash .. "])([^" .. slash .. "]-).?[%a%d]*$")
            mediaFile.baseName = getBaseName(filePath)
        end
        if not mediaFile.name then
            mediaFile.name = filePath
        end
        -- vlc.msg.dbg("Video Meta Title: " .. mediaFile.metaTitle)
        vlc.msg.dbg("Video URI: " .. mediaFile.uri)
        vlc.msg.dbg("fileName: " .. mediaFile.name)
        vlc.msg.dbg("fileDir: " .. tostring(mediaFile.dir))

        getFileHash()
        if mediaFile.hash then
            bookmarkFilePath = bookmarksDir .. slash .. mediaFile.hash .. BOOKMARK_FILE_EXT
            legacyBookmarkFilePath = bookmarksDir .. slash .. mediaFile.hash
            readBookmarks()
            input = vlc.object.input()
        end
    end
    collectgarbage()
end

-- // The medium's file name with its extension. mediaFile.name cannot serve
-- here: the pattern above yields the stem, dropping the extension. Returns nil
-- when there is no name to take, and the bookmark file then carries no
-- filename field at all rather than a placeholder.
function getBaseName(filePath)
    if type(filePath) ~= "string" then
        return nil
    end
    return string.match(filePath, "([^" .. slash .. "]+)$")
end

function getFileHash()
    -- Calculate media hash
    local data_start
    local data_end
    local size
    local chunk_size = 65536
    local ok
    local err

    -- Get data for hash calculation
    vlc.msg.dbg("init read hash data from stream")
    local stream = vlc.stream(mediaFile.uri)
    if not stream then
        vlc.msg.warn("Failed to open stream for: " .. mediaFile.uri)
        return false
    end

    data_start = stream:read(chunk_size)
    if not data_start or #data_start == 0 then
        vlc.msg.warn("Failed to read data from start of stream")
        return false
    end

    ok, size = pcall(stream.getsize, stream)
    if not ok or not size or size <= 0 then
        vlc.msg.warn("Failed to get stream size: " .. tostring(size))
        return false
    end
    mediaFile.bytesize = size
    vlc.msg.dbg("File bytesize: " .. mediaFile.bytesize)

    -- For small files, don't try to seek to the end
    if size <= chunk_size then
        data_end = ""
    else
        ok, err = pcall(stream.seek, stream, size - chunk_size)
        if not ok then
            vlc.msg.warn("Failed to seek the stream: " .. tostring(err))
            return false
        end
        data_end = stream:read(chunk_size)
        if not data_end then
            data_end = ""
        end
    end
    vlc.msg.dbg("finish Read hash data from stream")

    -- Hash calculation
    -- local lo = mediaFile.bytesize
    local lo = size
    local hi = 0
    local a, b, c, d, e, f, g, h
    local hash_data = data_start .. data_end
    local max_size = 4294967296
    local overflow

    for i = 1, #hash_data, 8 do
        a, b, c, d, e, f, g, h = hash_data:byte(i, i + 7)
        a, b, c, d = a or 0, b or 0, c or 0, d or 0
        e, f, g, h = e or 0, f or 0, g or 0, h or 0

        lo = lo + a + b * 256 + c * 65536 + d * 16777216
        hi = hi + e + f * 256 + g * 65536 + h * 16777216

        if lo > max_size then
            overflow = math.floor(lo / max_size)
            lo = lo - (overflow * max_size)
            hi = hi + overflow
        end

        if hi > max_size then
            overflow = math.floor(hi / max_size)
            hi = hi - (overflow * max_size)
        end
    end

    mediaFile.hash = string.format("%08x%08x", hi, lo)
    vlc.msg.dbg("File hash: " .. mediaFile.hash)
    collectgarbage()
    return true
end

function getLastBookmarkIndex()
    local bm_count = #Bookmarks
    local last_bookmark = nil
    if bm_count > 0 then
        -- the last bookmark by position; pairs() promises no order
        last_bookmark = Bookmarks[bm_count].label
    end

    local last_index = nil
    if last_bookmark ~= nil then
        for k in string.gmatch(last_bookmark, "%((%d+)%)") do
            last_index = tonumber(k)
        end
    end

    if last_index == nil then
        return bm_count
    end
    return last_index
end

-- // system check and extension config
function check_config()
    slash = package.config:sub(1, 1)

    bookmarksDir = vlc.config.userdatadir()
    local res, err = vlc.io.mkdir(bookmarksDir, "0700")
    if res ~= 0 and err ~= vlc.errno.EEXIST then
        vlc.msg.warn("Failed to create " .. bookmarksDir)
        return false
    end
    local subdirs = {"lua", "extensions", "userdata", "bookmarks"}
    for _, dir in ipairs(subdirs) do
        res, err = vlc.io.mkdir(bookmarksDir .. slash .. dir, "0700")
        if res ~= 0 and err ~= vlc.errno.EEXIST then
            vlc.msg.warn("Failed to create " .. bookmarksDir .. slash .. dir)
            return false
        end
        bookmarksDir = bookmarksDir .. slash .. dir
    end

    if bookmarksDir then
        vlc.msg.dbg("Bookmarks directory: " .. bookmarksDir)
    end

    collectgarbage()
    return true
end

-- // Load the JSON module VLC bundles. Without it the extension can neither
-- read nor write, so the failure is reported instead of silently degrading.
function loadJsonModule()
    local ok, module = pcall(require, JSON_MODULE)
    if ok and type(module) == "table" and type(module.encode) == "function" and type(module.decode) == "function" then
        json = module
        return true
    end
    json = nil
    vlc.msg.err("Failed to load the " .. JSON_MODULE .. " module: " .. tostring(module))
    return false
end

-- // Footer text. Silently ignored before the dialog exists, so the load path
-- can raise a message before there is anywhere to put it.
function setFooter(text)
    if bookmarks_dialog['footer_message'] then
        bookmarks_dialog['footer_message']:set_text(setMessageStyle(text))
    end
end

-- // Read a bookmark file. The content is decoded as data and never executed.
-- Returns the bookmark list, or nil plus an error message.
function loadBookmarksFile(filePath)
    local file, openErr = io.open(filePath, "rb")
    if not file then
        return nil, openErr or "open failed"
    end
    local content = file:read("*a")
    file:close()
    if not content then
        return nil, "read failed"
    end

    local decoded, _, decodeErr = json.decode(content)
    if type(decoded) ~= "table" then
        return nil, decodeErr or "not a JSON object"
    end
    if type(decoded.bookmarks) ~= "table" then
        return nil, "no bookmarks array"
    end

    -- The file is untrusted input, so entries are checked before the UI
    -- concatenates them. A malformed entry is dropped rather than fatal.
    local bookmarks = {}
    for _, entry in ipairs(decoded.bookmarks) do
        if type(entry) == "table" and type(entry.time) == "number" and type(entry.label) == "string" then
            local formatted = entry.formattedTime
            if type(formatted) ~= "string" then
                formatted = getFormattedTime(entry.time)
            end
            table.insert(bookmarks, {
                time = entry.time,
                label = entry.label,
                formattedTime = formatted
            })
        else
            vlc.msg.warn("Skipping a malformed bookmark entry in " .. tostring(filePath))
        end
    end
    return bookmarks
end

-- // Populate Bookmarks for the current medium
function readBookmarks()
    Bookmarks = {}
    bookmarksReadOnly = false
    pendingFooterMessage = nil

    if not json then
        bookmarksReadOnly = true
        pendingFooterMessage = MSG_JSON_MISSING
        return
    end

    if not fileExists(bookmarkFilePath) then
        -- An old-format file is left exactly as it is and never executed. Until
        -- the migration script converts it this medium stays read-only, so an
        -- Add cannot strand the old bookmarks behind a new file.
        if legacyBookmarkFilePath and fileExists(legacyBookmarkFilePath) then
            bookmarksReadOnly = true
            pendingFooterMessage = MSG_LEGACY_FOUND
            vlc.msg.warn("Old-format bookmark file found: " .. tostring(legacyBookmarkFilePath))
        end
        return
    end

    local bookmarks, err = loadBookmarksFile(bookmarkFilePath)
    if not bookmarks then
        bookmarksReadOnly = true
        pendingFooterMessage = MSG_LOAD_FAILED
        vlc.msg.err("Failed to read bookmarks from " .. tostring(bookmarkFilePath) .. ": " .. tostring(err))
        return
    end
    Bookmarks = bookmarks
end

-- // Persist Bookmarks, reporting a write failure instead of losing it
function saveBookmarks()
    if bookmarksReadOnly then
        vlc.msg.err("Refusing to save over bookmarks that were not read: " .. tostring(bookmarkFilePath))
        setFooter(pendingFooterMessage or MSG_SAVE_BLOCKED)
        return false
    end
    local err = saveBookmarksFile(Bookmarks, bookmarkFilePath, mediaFile.baseName)
    if not err then
        return true
    end
    vlc.msg.err("Failed to save bookmarks to " .. tostring(bookmarkFilePath) .. ": " .. tostring(err))
    setFooter(MSG_SAVE_FAILED)
    return false
end

-- // The Save Function. Encodes once and writes once, so a failing disk has a
-- single point to report, and both write() and close() are checked.
-- fileName is meta-information only - the hash stays the sole key and nothing
-- reads the field back - so a nil simply leaves it out of the constructor, and
-- out of the file.
function saveBookmarksFile(bookmarks, filePath, fileName)
    if not json then
        return "the " .. JSON_MODULE .. " module is missing"
    end
    local payload = {
        version = BOOKMARK_FORMAT_VERSION,
        filename = fileName,
        bookmarks = bookmarks
    }
    local ok, encoded = pcall(json.encode, payload, {
        indent = JSON_INDENT,
        keyorder = JSON_KEY_ORDER
    })
    if not ok or type(encoded) ~= "string" then
        return tostring(encoded)
    end

    local file, openErr = io.open(filePath, "wb")
    if not file then
        return openErr or "open failed"
    end
    local written, writeErr = file:write(encoded)
    if not written then
        file:close()
        return writeErr or "write failed"
    end
    -- close() flushes, so it is the second place a full disk shows up
    local closed, closeErr = file:close()
    if not closed then
        return closeErr or "close failed"
    end
end

-- // The Binary Insert Function
function table_binInsert(t, value, fcomp)
    local fcomp_default = function(a, b)
        return a < b
    end
    -- Initialise compare function
    fcomp = fcomp or fcomp_default
    --  Initialise numbers
    local iStart, iEnd, iMid, iState = 1, #t, 1, 0
    -- Get insert position
    while iStart <= iEnd do
        -- calculate middle
        iMid = math.floor((iStart + iEnd) / 2)
        -- compare
        if fcomp(value, t[iMid]) then
            iEnd, iState = iMid - 1, 0
        else
            iStart, iState = iMid + 1, 1
        end
    end
    -- table.insert( t,(iMid+iState),value )
    return (iMid + iState)
end

function table_length(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- // a label of only whitespace is not a label, and padding is not part of one
local function trimLabel(text)
    return string.match(text, "^%s*(.-)%s*$")
end

-- // put the next default name back in the input, after a bookmark is written
local function resetLabelInput()
    local next_index = tostring(getLastBookmarkIndex() + 1)
    bookmarks_dialog['text_input']:set_text('Bookmark (' .. next_index .. ')')
end

-- // split a time in microseconds into hours, minutes, seconds and milliseconds
local function splitTime(micros)
    local millis = math.floor(micros / 1000)
    return math.floor((millis / 3600000) % 24),
           math.floor((millis / 60000) % 60),
           math.floor((millis / 1000) % 60),
           math.floor(millis % 1000)
end

-- // get number rappresenting time in microseconds and return a string with formatted time hh:mm:ss.millis
function getFormattedTime(micros)
    local hours, minutes, seconds, millis = splitTime(micros)
    return string.format(TIME_FORMAT_STORED, hours, minutes, seconds, millis)
end

-- // same time as hh:mm:ss, for the bookmark list only. Never stored, and
-- never compared - getFormattedTime stays the canonical form.
function getDisplayTime(micros)
    local hours, minutes, seconds = splitTime(micros)
    return string.format(TIME_FORMAT_DISPLAY, hours, minutes, seconds)
end

-- GUI Setup and buttons callbacks ----------------------------------------
-- Create the main bookmarks dialog
function main_dialog()
    vlc.msg.dbg("Creating main dialog")
    -- Gui positional args: col, row, col_span, row_span, width, height
    dialog_UI = vlc.dialog(dialog_title)

    -- ~ !important: Add button must be the first item that is created
    dialog_UI:add_button("Add", addBookmark, 4, 1, 1, 1)
    -- bookmarks labels input box
    local new_index = tostring(getLastBookmarkIndex() + 1)
    bookmarks_dialog['text_input'] = dialog_UI:add_text_input('Bookmark (' .. new_index .. ')', 1, 1, 3, 1)

    -- bookmarks list
    bookmarks_dialog['bookmarks_list'] = dialog_UI:add_list(1, 2, 4, 1)

    -- buttons
    dialog_UI:add_button("Go", goToBookmark, 1, 3, 1, 1)
    dialog_UI:add_button("Rename", editBookmark, 2, 3, 1, 1)
    dialog_UI:add_button("Remove", removeBookmark, 3, 3, 1, 1)
    dialog_UI:add_button("Close", vlc.deactivate, 4, 3, 1, 1)
    -- dialog_UI:add_button("Import", show_import_gui, 1, 10, 1, 1)
    -- dialog_UI:add_button("Export", show_export_gui, 1, 11, 1, 1)

    -- Directly under Rename, so it reads as that button's second step. Column 2
    -- is already sized by "Rename", so this costs no width.
    dialog_UI:add_button("Confirm", confirmRename, 2, 4, 1, 1)
    -- Directly under Remove, for the same reason. Column 3 is already sized by
    -- "Remove", so this costs no width either.
    dialog_UI:add_button("Delete", confirmRemoval, 3, 4, 1, 1)
    dialog_UI:add_button("Show in Finder", showInFinder, 4, 4, 1, 1)

    -- footer message_label, its own full-width row so long messages have room
    bookmarks_dialog['footer_message'] = dialog_UI:add_label('', 1, 5, 4, 1)

    showBookmarks()
    if pendingFooterMessage then
        setFooter(pendingFooterMessage)
    end
    dialog_UI:show()
end

function showBookmarks()
    if bookmarks_dialog['bookmarks_list'] then
        bookmarks_dialog['bookmarks_list']:clear()
        for idx, b in pairs(Bookmarks) do
            local text = '#' .. idx .. ' - ' .. getDisplayTime(b.time) .. ' - ' .. b.label
            bookmarks_dialog['bookmarks_list']:add_value(text, idx)
        end
    end
end

-- // Swap the dialog's contents to the medium playing now, without rebuilding
-- the window. Keeping the same dialog is the point: a rebuild would drop it
-- back at the default position, raise it over the video and replay the
-- open-flicker on every track change. Defined here rather than beside
-- input_changed() because resetLabelInput() is a local declared further up.
function reloadCurrentMedium()
    input = nil
    mediaFile = {}
    Bookmarks = {}
    selectedBookmarkId = nil
    pendingRemoval = nil
    bookmarkFilePath = nil
    legacyBookmarkFilePath = nil
    pendingFooterMessage = nil
    bookmarksReadOnly = false

    -- The no-input dialog has none of the widgets below, so there is nothing
    -- to refresh in place - build the real one instead.
    if not bookmarks_dialog['text_input'] then
        show_gui()
        return
    end

    if vlc.input.item() then
        load_bookmarks()
    end
    showBookmarks()
    resetLabelInput()
    dlt_footer()
    if pendingFooterMessage then
        setFooter(pendingFooterMessage)
    elseif not vlc.input.item() then
        setFooter(MSG_NO_MEDIA)
    end
    collectgarbage()
end

-- Buttons callbacks -------------------------------------------------------------

-- // Leave the remove cycle. Every button other than Delete calls this, because
-- every callback clears the footer first: without it the arming would outlive
-- the message announcing it and a later Delete would commit a removal the user
-- had already walked away from.
--
-- The selection is deliberately not cleared here, because it cannot be: the
-- dialog API has no deselect call, and rebuilding the list with clear() plus
-- add_value() leaves the selected row selected (measured - see the XFAIL in
-- scripts/smoke-test.sh). Rename could not use it anyway: confirmRename()
-- refuses unless the loaded row is still the selected one.
function disarmRemoval()
    pendingRemoval = nil
end

function addBookmark()
    dlt_footer()
    -- Reachable since the dialog stays open across a track change: with nothing
    -- playing there is no position to read, and vlc.var.get() on a nil input
    -- raises. A button cannot be greyed out, so it refuses in the footer.
    if not input then
        if vlc.input.item() then
            setFooter(MSG_ADD_NO_HASH)
        else
            setFooter(MSG_ADD_NO_MEDIA)
        end
        return
    end
    -- An add shifts every index after the insertion point, so a rename loaded
    -- or a removal armed before it would land on the wrong row. Adding cancels
    -- both.
    selectedBookmarkId = nil
    disarmRemoval()
    if bookmarks_dialog['text_input'] then
        local label = trimLabel(bookmarks_dialog['text_input']:get_text())
        if string.len(label) > 0 then
            local bookmark = {}
            bookmark.time = vlc.var.get(input, "time")
            bookmark.label = label
            bookmark.formattedTime = getFormattedTime(bookmark.time)
            local i = table_binInsert(Bookmarks, bookmark, function(a, b)
                return a.time <= b.time
            end)
            -- bookmark with same time already present
            if Bookmarks[i] then
                if Bookmarks[i].formattedTime == bookmark.formattedTime then
                    setFooter("Bookmark already added")
                    return
                end
            end
            table.insert(Bookmarks, i, bookmark)
            saveBookmarks()
            showBookmarks()
            resetLabelInput()
        else
            setFooter("Please enter your bookmark title")
        end
    end
end

-- // Commit a rename loaded by editBookmark(), from the Confirm button. Refuses unless the selection is
-- still the row whose label was loaded, so an edited label can never land on a
-- bookmark the user did not open.
function confirmRename()
    dlt_footer()
    disarmRemoval()
    if not (bookmarks_dialog['text_input'] and bookmarks_dialog['bookmarks_list']) then
        return
    end
    if selectedBookmarkId == nil then
        setFooter(MSG_RENAME_NOT_PENDING)
        return
    end
    local selection = bookmarks_dialog['bookmarks_list']:get_selection()
    if not selection or not selection[selectedBookmarkId] or table_length(selection) ~= 1 then
        -- The pending rename is kept, so reselecting that row and clicking
        -- Save again works without loading the label a second time.
        setFooter(string.format(MSG_RENAME_SELECTION_CHANGED, selectedBookmarkId))
        return
    end
    local label = trimLabel(bookmarks_dialog['text_input']:get_text())
    if string.len(label) == 0 then
        setFooter("Please enter your bookmark title")
        return
    end
    Bookmarks[selectedBookmarkId].label = label
    selectedBookmarkId = nil
    saveBookmarks()
    showBookmarks()
    resetLabelInput()
end

function goToBookmark()
    dlt_footer()
    disarmRemoval()
    if bookmarks_dialog['bookmarks_list'] then
        local selection = bookmarks_dialog['bookmarks_list']:get_selection()
        selectedBookmarkId = nil
        if next(selection) then
            if table_length(selection) == 1 then
                for idx, _ in pairs(selection) do
                    vlc.var.set(input, "time", Bookmarks[idx].time)
                    break
                end
            else
                bookmarks_dialog['footer_message']:set_text(setMessageStyle("Please select only one item"))
            end
        else
            bookmarks_dialog['footer_message']:set_text(setMessageStyle("Please select a item"))
        end
    end
end

function editBookmark()
    dlt_footer()
    disarmRemoval()
    if bookmarks_dialog['bookmarks_list'] then
        local selection = bookmarks_dialog['bookmarks_list']:get_selection()
        selectedBookmarkId = nil
        if next(selection) then
            if table_length(selection) == 1 then
                for idx, _ in pairs(selection) do
                    bookmarks_dialog['text_input']:set_text(Bookmarks[idx].label)
                    selectedBookmarkId = idx
                    setFooter(string.format(MSG_RENAME_PENDING, idx))
                    return
                end
            else
                bookmarks_dialog['footer_message']:set_text(setMessageStyle("Please select only one item"))
            end
        else
            bookmarks_dialog['footer_message']:set_text(setMessageStyle("Please select a item"))
        end
    end
end

-- // Arm a removal. This writes nothing: it records which rows are selected and
-- says so in the footer. confirmRemoval(), on the Delete button, does the
-- deleting. Two clicks on two different buttons, so a stray double-click on one
-- of them cannot delete a bookmark.
function removeBookmark()
    dlt_footer()
    if not bookmarks_dialog['bookmarks_list'] then
        return
    end
    local selection = bookmarks_dialog['bookmarks_list']:get_selection()
    if not next(selection) then
        pendingRemoval = nil
        setFooter("Please select items you want remove")
        return
    end
    -- Sorted here rather than at commit time: the offset arithmetic in
    -- confirmRemoval() is only correct while the ids ascend.
    local ids = {}
    for id in pairs(selection) do
        table.insert(ids, id)
    end
    table.sort(ids)
    pendingRemoval = ids
    if #ids == 1 then
        setFooter(MSG_REMOVE_PENDING_ONE)
    else
        setFooter(string.format(MSG_REMOVE_PENDING_MANY, #ids))
    end
end

-- // Commit a removal armed by removeBookmark(), from the Delete button.
-- Refuses unless the selection is still exactly the armed rows, so a bookmark
-- selected after arming can never be the one that gets deleted. The refusal
-- keeps the arming, so reselecting and clicking Delete again works.
function confirmRemoval()
    dlt_footer()
    if not bookmarks_dialog['bookmarks_list'] then
        return
    end
    if not pendingRemoval then
        setFooter(MSG_REMOVE_NOT_PENDING)
        return
    end
    local selection = bookmarks_dialog['bookmarks_list']:get_selection()
    if not selection or table_length(selection) ~= #pendingRemoval then
        setFooter(MSG_REMOVE_SELECTION_CHANGED)
        return
    end
    for _, id in ipairs(pendingRemoval) do
        if not selection[id] then
            setFooter(MSG_REMOVE_SELECTION_CHANGED)
            return
        end
    end

    -- A deletion shifts every index after it, so a rename loaded before it
    -- would commit to the wrong row.
    selectedBookmarkId = nil
    local count = 0
    -- ipairs, not pairs: the idx - count offset below is only correct while
    -- the sorted ids are walked in order
    for _, idx in ipairs(pendingRemoval) do
        table.remove(Bookmarks, idx - count)
        count = count + 1
    end
    pendingRemoval = nil
    saveBookmarks()
    showBookmarks()
end
-- Quote a path for the shell: single quotes, with any embedded one escaped
function shellQuote(path)
    return "'" .. string.gsub(path, "'", "'\\''") .. "'"
end

function fileExists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- Reveal this medium's bookmark file in Finder. Nothing is written until the
-- first bookmark is saved, so fall back to the folder the file will live in -
-- and with no medium loaded there is no "this video" to name in the message.
function showInFinder()
    dlt_footer()
    disarmRemoval()
    local command
    if bookmarkFilePath and fileExists(bookmarkFilePath) then
        command = FINDER_REVEAL_CMD .. shellQuote(bookmarkFilePath)
    elseif bookmarksDir then
        command = FINDER_OPEN_CMD .. shellQuote(bookmarksDir)
        local message = MSG_FINDER_NO_FILE
        if not vlc.input.item() then
            message = MSG_FINDER_NO_MEDIA
        end
        bookmarks_dialog['footer_message']:set_text(setMessageStyle(message))
    else
        bookmarks_dialog['footer_message']:set_text(setMessageStyle(MSG_FINDER_NO_DIR))
        return
    end
    if os.execute(command) ~= 0 then
        vlc.msg.err("Failed to reveal bookmarks in Finder: " .. command)
        bookmarks_dialog['footer_message']:set_text(setMessageStyle(MSG_FINDER_FAILED))
    end
end

-- End buttons callbacks -------------------------------------------------

function setMessageStyle(str)
    return "<p style='font-size: 12px; margin-left: 4px;'>" .. str .. "</p>"
end

function dlt_footer()
    if bookmarks_dialog['footer_message'] then
        bookmarks_dialog['footer_message']:set_text('')
    end
end

function close_dlg()
    vlc.msg.dbg("Closing dialog")
    if dialog_UI ~= nil then
        -- dialog_UI:delete() -- Throw an error
        dialog_UI:hide()
    end
    dialog_UI = nil
    bookmarks_dialog = nil
    bookmarks_dialog = {}
    collectgarbage() -- ~ !important
end

function show_gui()
    close_dlg()
    if vlc.input.item() then
        if not input then
            load_bookmarks()
        end
        main_dialog()
    else
        noinput_dialog()
    end
    collectgarbage() -- ~ !important
end

function noinput_dialog()
    vlc.msg.dbg("Creating noinput dialog")
    dialog_UI = vlc.dialog(dialog_title)
    dialog_UI:add_label(
        "<p style='font-size: 12px; text-align: center;'>Please open a media file before running this extension</p>")
    -- dialog_UI:show()
end
