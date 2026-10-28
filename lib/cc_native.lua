-- Temporary batch transport for native MIDI buffers; no project mutations.
local M = {}
local function quote(value)
    assert(not value:find('[\r\n]'), 'Paths may not contain newlines')
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end
function M.prepare(api, binary, targets, ccs, tolerance, jitter)
    local input = os.tmpname()
    local output = input .. '.cc-output'
    local ok, result = xpcall(function()
        local f = assert(io.open(input, 'wb'))
        f:write('GCC1', string.pack('<I4', #targets))
        for _, target in ipairs(targets) do f:write(string.pack('<I4I8', target.ppq, #target.before), target.before) end
        assert(f:close())
        local command = table.concat({ quote(binary), quote(input), quote(output), '--native-batch',
            '--gestures', '--keep-snapshots', '--cc', quote(ccs), '--tolerance', tostring(tolerance),
            jitter and '--de-jitter' or '' }, ' ')
        local response = api.ExecProcess(command, 0)
        local code, log = (response or ''):match('^(-?%d+)\r?\n(.*)$')
        assert(tonumber(code) == 0, 'Optimization failed before applying changes:\n' .. (response or 'No result'))
        local f = assert(io.open(output, 'rb')); local data = f:read('*a'); f:close()
        assert(data:sub(1, 4) == 'GCC1', 'Invalid optimizer result.')
        local count, pos = string.unpack('<I4', data, 5)
        assert(count == #targets, 'MIDI batch count mismatch.')
        for _, target in ipairs(targets) do
            local ppq, length; ppq, length, pos = string.unpack('<I4I8', data, pos)
            assert(ppq == target.ppq and length <= #data - pos + 1, 'Invalid MIDI result length/PPQ.')
            target.after = data:sub(pos, pos + length - 1); pos = pos + length
        end
        assert(pos == #data + 1, 'Unexpected MIDI result data.')
        return log
    end, debug.traceback)
    os.remove(input); os.remove(output)
    if not ok then error(result, 0) end
    return result
end
return M
