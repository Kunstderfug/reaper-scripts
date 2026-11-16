-- A data-only mailbox protocol; requests never contain executable Lua.
local M = {}
local array_mt = {__jsonarray=true}
function M.array(t) return setmetatable(t or {}, array_mt) end
function M.json(v)
    local kind = type(v)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' then return tostring(v) end
    if kind == 'number' then
        assert(v == v and math.abs(v) < math.huge, 'Nonfinite JSON number')
        return string.format('%.17g', v)
    end
    if kind == 'string' then
        return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
            return string.format('\\u%04x', c:byte())
        end) .. '"'
    end
    assert(kind == 'table', 'Unsupported JSON value')
    local parts = {}
    if (getmetatable(v) or {}).__jsonarray or #v > 0 then
        for _, item in ipairs(v) do parts[#parts + 1] = M.json(item) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    for key, item in pairs(v) do parts[#parts + 1] = M.json(key) .. ':' .. M.json(item) end
    return '{' .. table.concat(parts, ',') .. '}'
end
function M.read(path)
    local f = assert(io.open(path, 'rb'))
    local data = f:read('*a'); f:close()
    return data
end
function M.write(path, data)
    local temp = path .. '.tmp'
    local f = assert(io.open(temp, 'wb'))
    assert(f:write(data)); assert(f:close())
    assert(os.rename(temp, path))
end
function M.parse(data)
    assert(#data < 16384, 'Request too large')
    local result = {}
    for line in data:gmatch('[^\n]+') do
        local key, value = line:match('^([a-z_]+)=(.*)$')
        assert(key and not result[key], 'Invalid or duplicate request field')
        -- Literal percent signs are encoded by the client too.
        assert(not value:gsub('%%%x%x', ''):find('%%'), 'Invalid percent escape')
        result[key] = value:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
        assert(not result[key]:find('%z'), 'NUL in request')
    end
    assert(result.version == '1', 'Unsupported protocol version')
    return result
end
return M
