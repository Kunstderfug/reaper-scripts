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

local function main()
    local proj = 0
    log("=== GPhil MIDI Solo Cue Export ===")
    log("(stub)")
end

main()
