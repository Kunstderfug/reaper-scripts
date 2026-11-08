-- Named settings shared by all projects; project FX state remains separate.
local M = {}
local section, key = 'GPhil_DynamicBrightness', 'presets_v1'
local builtin_specs = {
    { 'Gentle', 1.5, -1.5 }, { 'Balanced', 2, -2 }, { 'Full brightness', 3, -3 },
}
local reserved = {}
for _, spec in ipairs(builtin_specs) do reserved[spec[1]:lower()] = true end

local function name_checked(name)
    assert(type(name) == 'string', 'Enter a preset name.')
    assert(not name:find('[%z\1-\31\127]'), 'Preset names cannot contain control characters.')
    name = name:match('^%s*(.-)%s*$')
    assert(#name >= 1 and #name <= 60, 'Preset names must be 1–60 bytes long.')
    return name
end

local function hex(name)
    return (name:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end

local function unhex(value)
    if #value % 2 ~= 0 or value:find('[^%da-fA-F]') then return nil end
    return (value:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end))
end

function M.new(api, model)
    assert(type(api.GetExtState) == 'function' and type(api.SetExtState) == 'function',
        'Preset storage requires REAPER GetExtState and SetExtState.')
    local function copy(settings)
        assert(type(settings) == 'table', 'Preset settings must be a table.')
        local result = model.decode(model.encode(model.validate(settings)))
        assert(result, 'Could not encode preset settings.')
        return result
    end

    local function read()
        local entries = {}
        local data = api.GetExtState(section, key) or ''
        for row in data:gmatch('[^;]+') do
            local encoded, csv = row:match('^([^:]+):([^:]+)$')
            local name = encoded and unhex(encoded)
            if name then
                local ok, valid_name = pcall(name_checked, name)
                local valid_settings, settings = pcall(model.decode, csv)
                if ok and not reserved[valid_name:lower()] and valid_settings and settings then
                    local valid_copy, clean = pcall(copy, settings)
                    if valid_copy then
                        entries[valid_name:lower()] = { name = valid_name, settings = clean, builtin = false }
                    end
                end
            end
        end
        return entries
    end

    local function sorted(entries)
        local result = {}
        for _, entry in pairs(entries) do result[#result + 1] = entry end
        table.sort(result, function(a, b) return a.name:lower() < b.name:lower() end)
        return result
    end

    local function write(entries)
        local rows = {}
        for _, entry in ipairs(sorted(entries)) do
            rows[#rows + 1] = hex(entry.name) .. ':' .. model.encode(entry.settings)
        end
        api.SetExtState(section, key, table.concat(rows, ';'), true)
    end

    local store = {}
    function store.list()
        local result = {}
        for _, spec in ipairs(builtin_specs) do
            result[#result + 1] = { name = spec[1], builtin = true, settings = copy({
                frequency = 2000, maximum = spec[2], threshold = -30,
                ceiling = -12, attack = 50, release = 300, minimum = spec[3],
            }) }
        end
        for _, entry in ipairs(sorted(read())) do result[#result + 1] = entry end
        return result
    end

    function store.save(name, settings)
        name = name_checked(name)
        assert(not reserved[name:lower()], 'Choose a different name; built-in presets cannot be replaced.')
        local clean = copy(settings)
        local entries = read()
        entries[name:lower()] = { name = name, settings = clean, builtin = false }
        write(entries)
        return name
    end

    function store.delete(name)
        name = name_checked(name)
        assert(not reserved[name:lower()], 'Built-in presets cannot be deleted.')
        local entries = read()
        if not entries[name:lower()] then return false end
        entries[name:lower()] = nil
        write(entries)
        return true
    end
    return store
end

return M
