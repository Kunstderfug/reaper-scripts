-- Staged replacement for GPhilDeck single Tempo Set re-renders: the run manifest,
-- the swap into place with rollback, and pruning of old
-- <render root>/.gphildeck-rerender/<run> folders.
-- Data-only: the REAPER API and the file operations are passed in.
--
-- Manifest lines (tab separated): "created <time>", "stage <rel>", "previous <rel>"
-- and, written last, one final marker: "done <time>" after a fully successful run,
-- or "discardable <time>" after a stopped run that left nothing in previous/
-- (no file was backed up, or every backup was moved back into place).
-- A "previous" line is written BEFORE the old file is moved, so an interrupted
-- or failed run never hides a recovery copy. Only runs whose LAST manifest line
-- is a marker are pruned; a run never reuses an existing run folder.
local M = {}

local function slash(path)
    return (path:gsub("\\", "/"))
end

local function parent(path)
    return path:match("^(.*)[/\\][^/\\]+$")
end

M.slash, M.parent = slash, parent

-- fs: { rename, remove, open } with os/io semantics. Entries are read at call
-- time, so callers may replace them (tests inject failures this way).
function M.new(fs)
    local S = {}

    -- Relative tails of every target under root; nil + message when any target is outside it.
    function S.relative(root, targets, work_folder)
        local prefix = slash(root):gsub("/+$", "") .. "/"
        local reserved = work_folder .. "/"
        local rels, seen = {}, {}
        for _, target in ipairs(targets) do
            local normalized = slash(target)
            if normalized:sub(1, #prefix) ~= prefix then
                return nil, "A render output is outside the render folder: " .. target
            end
            local rel = normalized:sub(#prefix + 1)
            if rel == "" or seen[rel] or rel:sub(1, #reserved) == reserved then
                return nil, "Render outputs are not unique: " .. target
            end
            seen[rel] = true
            rels[#rels + 1] = rel
        end
        return rels
    end

    local function write_line(path, mode, kind, value)
        local file = fs.open(path, mode)
        if not file then return nil end
        local written = file:write(kind, "\t", value, "\n")
        local closed = file:close()
        return written and closed and true or nil
    end

    -- True when anything already exists at run_dir (folder, manifest or contents).
    function S.exists(api, run_dir, manifest)
        if api.file_exists(manifest) then return true end
        if fs.exists and fs.exists(run_dir) then return true end
        for _, enumerate in ipairs({ api.EnumerateFiles, api.EnumerateSubdirectories }) do
            if enumerate then
                pcall(enumerate, run_dir, -1)
                local called, name = pcall(enumerate, run_dir, 0)
                if called and name then return true end
            end
        end
        return false
    end

    -- Creates a NEW run folder and its manifest. An existing folder (for example
    -- the same run arriving again) is refused: its manifest could carry an old
    -- marker. Call once per run folder. Returns true, or nil + message.
    function S.create(api, run_dir, manifest, now)
        if S.exists(api, run_dir, manifest) then
            return nil, "A re-render folder for this run already exists, so nothing was rendered or moved: "
                .. run_dir .. ". Start a new re-render from GPhilDeck."
        end
        api.RecursiveCreateDirectory(run_dir, 0)
        if not write_line(manifest, "w", "created", tostring(now)) then
            return nil, "Could not create the re-render folder " .. run_dir
        end
        return true
    end

    -- Appends one manifest line. Returns true, or nil + message; never raises on I/O failure.
    function S.manifest(path, kind, value)
        if not write_line(path, "a", kind, value) then
            return nil, "Could not write the re-render manifest " .. path
        end
        return true
    end

    -- Moves canonical files to previous/ and staged files into place; rolls back on
    -- any failure, including an unexpected error. Returns true, or
    -- false + message + rollback_incomplete. After a full rollback no entry is
    -- left marked backed_up.
    function S.swap(api, entries, manifest)
        local done, current = {}, nil
        local function undo()
            local errors = {}
            for i = #done, 1, -1 do
                local step = done[i]
                local called, ok, message = pcall(fs.rename, step.to, step.from)
                if called and ok then
                    if step.backup then step.backup.backed_up = nil end
                else
                    errors[#errors + 1] = tostring(called and message or ok)
                end
            end
            return errors
        end
        local function attempt()
            for _, entry in ipairs(entries) do
                current = entry
                if api.file_exists(entry.canonical) then
                    if api.file_exists(entry.previous) then
                        return nil, "A previous copy already exists: " .. entry.previous
                    end
                    local noted, note_error = S.manifest(manifest, "previous", entry.rel)
                    if not noted then return nil, note_error end
                    api.RecursiveCreateDirectory(parent(entry.previous), 0)
                    local moved, move_error = fs.rename(entry.canonical, entry.previous)
                    if not moved then return nil, move_error end
                    entry.backed_up = true
                    done[#done + 1] = { from = entry.canonical, to = entry.previous, backup = entry }
                end
                api.RecursiveCreateDirectory(parent(entry.canonical), 0)
                local moved, move_error = fs.rename(entry.staged, entry.canonical)
                if not moved then return nil, move_error end
                done[#done + 1] = { from = entry.staged, to = entry.canonical }
            end
            return true
        end
        local called, ok, message = pcall(attempt)
        if called and ok then return true end
        if not called then message = ok end
        local errors = undo()
        local text = "Could not swap in " .. (current and current.rel or "the outputs") .. ": " .. tostring(message)
        if #errors > 0 then
            text = text .. ". Rollback was incomplete; inspect the staging and previous folders. Rollback problems: "
                .. table.concat(errors, "; ")
        else
            text = text .. ". The pass was rolled back; the old outputs are in place."
        end
        return false, text, #errors > 0
    end

    local function list_subdirectories(api, path)
        local names = {}
        if not api.EnumerateSubdirectories then return names end
        pcall(api.EnumerateSubdirectories, path, -1)
        local i = 0
        while true do
            local name = api.EnumerateSubdirectories(path, i)
            if not name then break end
            names[#names + 1] = name
            i = i + 1
        end
        return names
    end

    -- The run's final marker ("done" or "discardable"), only when it is the
    -- manifest's last line and that line is complete; nil otherwise.
    function S.marker(text)
        local last = ("\n" .. text):match("\n([^\n]*)\n$")
        return last and (last:match("^(done)\t%d+$") or last:match("^(discardable)\t%d+$")) or nil
    end

    -- Keeps the newest `keep` other marked runs; deletes only manifest-listed files.
    -- Unmarked runs (interrupted, rollback incomplete, stopped with a backup left
    -- in previous/, a line after the marker, or made before markers existed) may
    -- hold the only copy of an old output, so they are never pruned.
    function S.prune(api, work, current_run, keep)
        local runs = {}
        for _, name in ipairs(list_subdirectories(api, work)) do
            if name ~= current_run and name:match("^%x+$") then
                local manifest = work .. "/" .. name .. "/manifest.txt"
                local file = fs.open(manifest, "r")
                if file then
                    local text = file:read("a") or ""
                    file:close()
                    if S.marker(text) then
                        runs[#runs + 1] = { name = name, manifest = manifest, text = text,
                            created = tonumber(text:match("^created\t(%d+)")) or 0 }
                    end
                end
            end
        end
        table.sort(runs, function(a, b)
            if a.created ~= b.created then return a.created > b.created end
            return a.name > b.name
        end)
        for i = keep + 1, #runs do
            local run = runs[i]
            local base = work .. "/" .. run.name
            local folders = {}
            for kind, rel in run.text:gmatch("(%a+)\t([^\n]+)") do
                if (kind == "stage" or kind == "previous") and not rel:find("%.%.") then
                    fs.remove(base .. "/" .. kind .. "/" .. rel)
                    local dir = parent(kind .. "/" .. rel)
                    while dir do
                        folders[dir] = true
                        dir = parent(dir)
                    end
                end
            end
            fs.remove(run.manifest)
            local ordered = {}
            for dir in pairs(folders) do ordered[#ordered + 1] = dir end
            table.sort(ordered, function(a, b) return #a > #b end)
            for _, dir in ipairs(ordered) do fs.remove(base .. "/" .. dir) end -- empty folders only
            fs.remove(base)
        end
    end

    return S
end

return M
