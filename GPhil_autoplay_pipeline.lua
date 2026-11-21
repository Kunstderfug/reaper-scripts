-- @description GPhil AUTOPLAY: rebuild, check and upload click JSON
-- @version 1.0
-- The Python worker runs outside REAPER; the native bridge stays responsive.
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local value = f:read('*a'); f:close(); return value
end
local function quoted(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
local repository = read(here .. 'autoplay_pipeline.repo')
repository = repository and repository:match('^([^\r\n]+)') or here:gsub('[/\\]$', '')
if not read(repository .. '/tools/autoplay.py') then
    reaper.MB('Install the AUTOPLAY pipeline checkout path in autoplay_pipeline.repo beside this action.', 'GPhil AUTOPLAY', 0)
    return
end
local last = reaper.GetExtState('GPhil_AutoplayPipeline', 'manifest')
local ok, manifest = reaper.GetUserFileNameForRead(last, 'Choose AUTOPLAY timing manifest', '.json')
if not ok then return end
local folder = assert(manifest:match('^(.*[/\\])'))
gfx.init('GPhil AUTOPLAY', 0, 0)
local choice = gfx.showmenu('Build project|Build and check clicks|Build, check and preview upload|Build, check and upload')
gfx.quit()
if choice == 0 then return end
reaper.SetExtState('GPhil_AutoplayPipeline', 'manifest', manifest, true)
-- Idempotent bridge startup in this process, never another REAPER instance.
if choice > 1 then dofile(here .. 'GPhil_nativeBridge_start.lua') end
local output = folder .. 'BUILD'
reaper.RecursiveCreateDirectory(output, 0)
local id = reaper.genGuid():gsub('[^%w]', '')
local log, done = output .. '/run-' .. id .. '.log', output .. '/run-' .. id .. '.exit'
local mode = ({'build', 'evaluate', 'run', 'run'})[choice]
local python = read(here .. 'autoplay_pipeline.python')
python = python and python:match('^([^\r\n]+)') or '/usr/bin/python3'
local path = read(here .. 'autoplay_pipeline.path')
path = path and path:match('^([^\r\n]+)')
local command = (path and '/usr/bin/env ' .. quoted('PATH=' .. path) .. ' ' or '')
    .. quoted(python) .. ' ' .. quoted(repository .. '/tools/autoplay.py')
local env = reaper.GetExtState('GPhil_AutoplayPipeline', 'envFile')
if env ~= '' then command = command .. ' --env-file ' .. quoted(env) end
command = command .. ' ' .. mode .. ' ' .. quoted(manifest) .. ' --output ' .. quoted(output)
if choice == 4 then command = command .. ' --publish' end
-- Every variable is shell-quoted; filenames are never interpreted as commands.
os.execute('(' .. command .. ' > ' .. quoted(log) .. ' 2>&1; printf "%s" "$?" > ' .. quoted(done) .. ') &')
local function poll()
    local status = read(done)
    if not status then reaper.defer(poll); return end
    os.remove(done)
    local text = status == '0' and 'Completed.' or 'Stopped: review the report for missing decisions or failed checks.'
    reaper.MB(text .. '\n\n' .. log, 'GPhil AUTOPLAY', 0)
end
poll()
