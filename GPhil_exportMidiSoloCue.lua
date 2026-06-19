-- Export selected MIDI items to region/tempo-aware .mid files
-- with the project's tempo and time-signature map embedded.
-- Output path: AUDIO/SOLO_CUE/<region>/<project>_<region>_SOLO_CUE_<tempo>.mid

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local DIR_ROOT_REL = "AUDIO/SOLO_CUE"
local DIR_SEP = package.config:sub(1, 1) -- "/" on macOS/Windows Lua

local function log(msg)
    reaper.ShowConsoleMsg(tostring(msg) .. "\n")
end

-- Round to nearest integer; half rounds up. Used to kill float noise
-- like 59.999999 -> 60 in the filename tempo suffix.
local function round_tempo(tempo)
    return math.floor((tempo or 0) + 0.5)
end

-- Strip path and extension from a project filename.
local function get_project_stem(proj)
    local name = ""
    if reaper.GetProjectName then
        local ok, value = pcall(reaper.GetProjectName, proj, "")
        if ok and value then
            name = value
        end
    end

    name = name:match("([^/\\]+)$") or name
    name = name:gsub("%.[Rr][Pp][Pp]%-?[Bb]?[Aa]?[Kk]?$", "")
    name = name:gsub("%.[^%.]+$", "")
    if name == "" then
        name = "untitled"
    end
    return name
end

-- Replace characters illegal on macOS/Windows with _, collapse runs, trim ends.
local function sanitize_name_part(name)
    local text = name or ""
    text = text:gsub("[\t\r\n]", " ")
    text = text:gsub('[/\\:*?"<>|]', "_")
    text = text:gsub("%s+", " ")
    text = text:gsub("_+", "_")
    text = text:gsub("^[_%s]+", "")
    text = text:gsub("[_%s]+$", "")
    return text
end

-- Enumerate every region in the project as {pos, rgnend, name}.
local function collect_regions(proj)
    local regions = {}
    local idx = 0
    while true do
        local retval, is_region, pos, rgnend, name = reaper.EnumProjectMarkers3(proj, idx)
        if retval == 0 then
            break
        end
        if is_region then
            regions[#regions + 1] = {
                pos = pos,
                rgnend = rgnend,
                name = name or ""
            }
        end
        idx = idx + 1
    end
    return regions
end

-- Return the region whose [pos, rgnend] contains item_pos.
-- On overlap, the region with the smallest pos wins.
local function find_containing_region(regions, item_pos)
    local best
    for i = 1, #regions do
        local r = regions[i]
        if item_pos >= r.pos and item_pos <= r.rgnend then
            if not best or r.pos < best.pos then
                best = r
            end
        end
    end
    return best
end

-- Region's start BPM, read-only. Returns nil on failure.
local function region_start_bpm(proj, region)
    if not region then
        return nil
    end
    local bpm = reaper.TimeMap2_GetDividedBpmAtTime(proj, region.pos)
    if not bpm or bpm <= 0 then
        return nil
    end
    return bpm
end

-- Extract the take's MIDI events into a list of
-- { ppq = absolute_ppq, msg = bytes_string, flags = int }.
-- Meta events (status 0xFF) are preserved as-is; they will be filtered
-- out before writing so only our injected tempo/timesig meta events remain.
local function extract_midi_events(take)
    local ok, midi_str = reaper.MIDI_GetAllEvts(take, "")
    if not ok then
        return nil
    end

    local events = {}
    local len = midi_str:len()
    local pos = 1
    local ppq = 0
    local unpack = string.unpack

    while pos <= len do
        local offset, flags, msg, next_pos = unpack("i4Bs4", midi_str, pos)
        ppq = ppq + offset
        events[#events + 1] = {
            ppq = ppq,
            flags = flags,
            msg = msg,
            is_meta = (msg:byte(1) == 0xFF)
        }
        pos = next_pos
    end

    return events
end

local function main()
    local proj = 0
    log("=== GPhil MIDI Solo Cue Export ===")
    log("(stub)")
end

main()
