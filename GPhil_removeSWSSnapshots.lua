-- Separate SWS cleanup: create a project copy; never optimize MIDI or overwrite input.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local function quote(s)
    assert(not s:find('[\r\n]'), 'Paths may not contain newlines')
    return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end
local ok, err = xpcall(function()
    local project, filename = reaper.EnumProjects(-1, '')
    assert(filename ~= '', 'Save the project once before creating a cleaned copy.')
    assert(reaper.GetPlayStateEx(project) & 4 == 0, 'Stop recording first.')
    local binary = root .. 'bin/rpp-curve-opt'
    assert(reaper.file_exists(binary), 'CC optimizer binary is missing.')
    local stem = filename:gsub('%.[Rr][Pp][Pp]$', '') .. '_NO_SWS_' .. os.date('%Y%m%d_%H%M%S')
    local output, n = stem .. '.RPP', 1
    while reaper.file_exists(output) do n=n+1;output=stem .. '_' .. n .. '.RPP' end
    local input = output .. '.input.RPP'
    assert(not reaper.file_exists(input), 'Temporary input path already exists.')
    local dirty = reaper.IsProjectDirty(project) ~= 0
    reaper.Main_SaveProjectEx(project, input, 0)
    if dirty then reaper.MarkProjectDirty(project) end
    assert(reaper.file_exists(input), 'Could not snapshot the current project.')
    local response = reaper.ExecProcess(quote(binary)..' '..quote(input)..' '..quote(output)..' --snapshots-only',0)
    assert(response and response:match('^0\r?\n'), 'SWS cleanup failed; snapshot retained at '..input..'\n'..(response or ''))
    os.remove(input)
    reaper.Main_OnCommand(40859,0);reaper.Main_openProject(output)
    reaper.ShowConsoleMsg('SWS snapshots removed in copy: '..output..'\n'..response..'\n')
end, debug.traceback)
if not ok then reaper.ShowMessageBox(tostring(err),'Remove SWS snapshots — create copy',0) end
