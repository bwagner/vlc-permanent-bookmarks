-------------- Global variables ---------------------------------------
local mediaFile = {}
local input = nil
local Bookmarks = {}
local selectedBookmarkId = nil
local bookmarkFilePath = nil
-- System, set by check_config()
local slash = nil
local bookmarksDir = nil
-- UI
local dialog_UI = nil
local bookmarks_dialog = {}
local dialog_title = "VLC Permanents Bookmarks"
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
        capabilities = {"menu", "input-listener"}
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

-- Called on mouseover on the extension in View menu
function menu()
    return {"Show dialog"}
end

-- trigger function on menu() function call
function trigger_menu(dlg_id)
    show_gui()
end

-- related to capabilities={"input-listener"} in descriptor()
-- triggered by Start/Stop media input event
function input_changed() -- ~ !important: deve essere qualcosa di veloce
    vlc.msg.dbg("[Input changed]")
    if dialog_UI then
        dialog_UI:hide()

        input = nil
        mediaFile = nil
        mediaFile = {}
        Bookmarks = nil
        Bookmarks = {}
        selectedBookmarkId = nil
        bookmarkFilePath = nil
    end
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
            bookmarkFilePath = bookmarksDir .. slash .. mediaFile.hash
            Bookmarks = table_load(bookmarkFilePath)
            input = vlc.object.input()
        end
    end
    collectgarbage()
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

-- // Persist Bookmarks, reporting a write failure instead of losing it
function saveBookmarks()
    local err = table_save(Bookmarks, bookmarkFilePath)
    if not err then
        return true
    end
    vlc.msg.err("Failed to save bookmarks to " .. tostring(bookmarkFilePath) .. ": " .. tostring(err))
    if bookmarks_dialog['footer_message'] then
        bookmarks_dialog['footer_message']:set_text(setMessageStyle("Bookmarks could not be saved"))
    end
    return false
end

-- // The Save Function
function table_save(t, filePath)
    local function exportstring(s)
        return string.format("%q", s)
    end

    local charS, charE = "   ", "\n"
    local file, err = io.open(filePath, "wb")
    if err then
        return err
    end

    -- Buffer the whole table and write it once, so a failing disk has a
    -- single point to report instead of eleven unchecked writes.
    local out = {}
    local function w(str)
        out[#out + 1] = str
    end

    -- initiate variables for save procedure
    local tables, lookup = {t}, {
        [t] = 1
    }
    w("return {" .. charE)

    for idx, t in ipairs(tables) do
        w("-- Table: {" .. idx .. "}" .. charE)
        w("{" .. charE)
        local thandled = {}

        for i, v in ipairs(t) do
            thandled[i] = true
            local stype = type(v)
            -- only handle value
            if stype == "table" then
                if not lookup[v] then
                    table.insert(tables, v)
                    lookup[v] = #tables
                end
                w(charS .. "{" .. lookup[v] .. "}," .. charE)
            elseif stype == "string" then
                w(charS .. exportstring(v) .. "," .. charE)
            elseif stype == "number" then
                w(charS .. tostring(v) .. "," .. charE)
            end
        end

        for i, v in pairs(t) do
            -- escape handled values
            if (not thandled[i]) then

                local str = ""
                local stype = type(i)
                -- handle index
                if stype == "table" then
                    if not lookup[i] then
                        table.insert(tables, i)
                        lookup[i] = #tables
                    end
                    str = charS .. "[{" .. lookup[i] .. "}]="
                elseif stype == "string" then
                    str = charS .. "[" .. exportstring(i) .. "]="
                elseif stype == "number" then
                    str = charS .. "[" .. tostring(i) .. "]="
                end

                if str ~= "" then
                    stype = type(v)
                    -- handle value
                    if stype == "table" then
                        if not lookup[v] then
                            table.insert(tables, v)
                            lookup[v] = #tables
                        end
                        w(str .. "{" .. lookup[v] .. "}," .. charE)
                    elseif stype == "string" then
                        w(str .. exportstring(v) .. "," .. charE)
                    elseif stype == "number" then
                        w(str .. tostring(v) .. "," .. charE)
                    end
                end
            end
        end
        w("}," .. charE)
    end
    w("}")

    local ok, werr = file:write(table.concat(out))
    if not ok then
        file:close()
        return werr or "write failed"
    end
    -- close() flushes, so it is the second place a full disk shows up
    local closed, cerr = file:close()
    if not closed then
        return cerr or "close failed"
    end
end

-- // The Load Function
function table_load(filePath)
    local ftables, err = loadfile(filePath)
    if err then
        return {}, err
    end
    local tables = ftables()
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
        -- link indices
        for _, v in ipairs(tolinki) do
            tables[idx][v[2]], tables[idx][v[1]] = tables[idx][v[1]], nil
        end
    end
    return tables[1]
end

-- // The Binary Insert Function
function table_binInsert(t, value, fcomp)
    local fcomp_default = function(a, b)
        return a < b
    end
    -- Initialise compare function
    local fcomp = fcomp or fcomp_default
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

-- // get number rappresenting time in microseconds and return a string with formatted time hh:mm:ss.millis
function getFormattedTime(micros)
    local millis = math.floor(micros / 1000)
    local seconds = math.floor((millis / 1000) % 60)
    local minutes = math.floor((millis / 60000) % 60)
    local hours = math.floor((millis / 3600000) % 24)
    millis = math.floor(millis % 1000)
    return string.format("%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
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

    -- footer message_label
    bookmarks_dialog['footer_message'] = dialog_UI:add_label('', 1, 4, 4, 1)

    showBookmarks()
    dialog_UI:show()
end

function showBookmarks()
    if bookmarks_dialog['bookmarks_list'] then
        bookmarks_dialog['bookmarks_list']:clear()
        for idx, b in pairs(Bookmarks) do
            local text = '#' .. idx .. ' - ' .. b.formattedTime .. ' - ' .. b.label
            bookmarks_dialog['bookmarks_list']:add_value(text, idx)
        end
    end
end

-- Buttons callbacks -------------------------------------------------------------
function addBookmark()
    dlt_footer()
    if bookmarks_dialog['text_input'] then
        local label = bookmarks_dialog['text_input']:get_text()
        -- a label of only whitespace is not a label
        label = string.match(label, "^%s*(.-)%s*$")
        if string.len(label) > 0 then
            if selectedBookmarkId ~= nil then
                -- rename an existing bookmark
                Bookmarks[selectedBookmarkId].label = label
                selectedBookmarkId = nil
            else
                -- add a new bookmark
                local b = {}
                b.time = vlc.var.get(input, "time")
                b.label = label
                b.formattedTime = getFormattedTime(b.time)
                local i = table_binInsert(Bookmarks, b, function(a, b)
                    return a.time <= b.time
                end)
                -- bookmark with same time already present
                if Bookmarks[i] then
                    if Bookmarks[i].formattedTime == b.formattedTime then
                        bookmarks_dialog['footer_message']:set_text(setMessageStyle("Bookmark already added"))
                        return
                    end
                end
                table.insert(Bookmarks, i, b)
            end
            saveBookmarks()
            showBookmarks()
            local next_index = tostring(getLastBookmarkIndex() + 1)
            bookmarks_dialog['text_input']:set_text('Bookmark (' .. next_index .. ')')
        else
            bookmarks_dialog['footer_message']:set_text(setMessageStyle("Please enter your bookmark title"))
        end
    end
end

function goToBookmark()
    dlt_footer()
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
    if bookmarks_dialog['bookmarks_list'] then
        local selection = bookmarks_dialog['bookmarks_list']:get_selection()
        selectedBookmarkId = nil
        if next(selection) then
            if table_length(selection) == 1 then
                for idx, _ in pairs(selection) do
                    bookmarks_dialog['text_input']:set_text(Bookmarks[idx].label)
                    selectedBookmarkId = idx
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

function removeBookmark()
    dlt_footer()
    if bookmarks_dialog['bookmarks_list'] then
        local selection = bookmarks_dialog['bookmarks_list']:get_selection()
        selectedBookmarkId = nil
        if next(selection) then
            local count = 0
            -- sort selection by ids
            local selectionSorted = {}
            for id in pairs(selection) do
                table.insert(selectionSorted, id)
            end
            table.sort(selectionSorted)

            -- ipairs, not pairs: the idx - count offset below is only
            -- correct while the sorted selection is walked in order
            for _, idx in ipairs(selectionSorted) do
                table.remove(Bookmarks, idx - count)
                count = count + 1
            end
            saveBookmarks()
            showBookmarks()
        else
            bookmarks_dialog['footer_message']:set_text(setMessageStyle("Please select items you want remove"))
        end
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
