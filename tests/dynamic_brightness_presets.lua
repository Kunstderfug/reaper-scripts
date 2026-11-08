local model = dofile('lib/dynamic_brightness.lua')
local presets = dofile('lib/dynamic_brightness_presets.lua')
local data, writes = '', 0
local api = {
    GetExtState = function(section, key)
        assert(section == 'GPhil_DynamicBrightness' and key == 'presets_v1')
        return data
    end,
    SetExtState = function(section, key, value, persist)
        assert(section == 'GPhil_DynamicBrightness' and key == 'presets_v1' and persist == true)
        assert(not value:find('[\r\n]'))
        data, writes = value, writes + 1
    end,
}
local function settings(maximum)
    local s = model.decode(model.encode(model.defaults))
    s.maximum = maximum or 2.3
    return s
end
local function fails(fn, message)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(message, 1, true), tostring(err))
end

local store = presets.new(api, model)
local list = store.list()
assert(#list == 3 and list[1].name == 'Gentle' and list[2].name == 'Balanced'
    and list[3].name == 'Full brightness')
for i, maximum in ipairs({ 1.5, 2, 3 }) do
    assert(list[i].builtin and list[i].settings.maximum == maximum
        and list[i].settings.minimum == -maximum)
    assert(list[i].settings.frequency == 2000 and list[i].settings.threshold == -30
        and list[i].settings.ceiling == -12 and list[i].settings.attack == 50
        and list[i].settings.release == 300)
end
list[1].settings.maximum = 100
assert(store.list()[1].settings.maximum == 1.5)

-- Cross-project/new-instance persistence, delimiter-safe Unicode, and copied data.
local s = settings()
s.minimum = -2.3
assert(store.save('  Piano;: Étoile 🎹  ', s) == 'Piano;: Étoile 🎹')
s.maximum, s.minimum = 99, -99
local next_project = presets.new(api, model)
local saved = next_project.list()[4]
assert(saved.name == 'Piano;: Étoile 🎹' and not saved.builtin
    and saved.settings.maximum == 2.3 and saved.settings.minimum == -2.3)
saved.settings.frequency = 9000
assert(next_project.list()[4].settings.frequency == 2000)

-- Replacing ignores ASCII case; user presets sort after the factory entries.
store.save('zebra', settings(1))
store.save('ALPHA', settings(3))
store.save('alpha', settings(2))
list = store.list()
assert(#list == 6 and list[4].name == 'alpha' and list[4].settings.maximum == 2
    and list[6].name == 'zebra')
assert(store.delete('AlPhA') and not store.delete('alpha'))

local before, count = data, writes
for _, name in ipairs({ 'gentle', ' BALANCED ', 'FULL BRIGHTNESS' }) do
    fails(function() store.save(name, settings()) end, 'built-in presets')
    fails(function() store.delete(name) end, 'Built-in presets')
end
fails(function() store.save('Too much', settings(12.01)) end, '0–12 dB')
local excessive_cut = settings()
excessive_cut.minimum = -12.01
fails(function() store.save('Too much cut', excessive_cut) end, 'Cut limit')
local positive_cut = settings()
positive_cut.minimum = .01
assert(not pcall(store.save, 'Positive cut', positive_cut))
for _, name in ipairs({ '', '   ', string.rep('a', 61), 'bad\nname', 'bad\0name' }) do
    fails(function() store.save(name, settings()) end, 'Preset names')
end
assert(data == before and writes == count)

-- Malformed storage must not prevent the valid entries from being available.
data = data .. ';garbage;xx:2000,2,-30,-12,50,300;f:2000,2,-30,-12,50,300'
    .. ';626164:2000,99,-30,-12,50,300;67656e746c65:2000,2,-30,-12,50,300'
    .. ';00626164:2000,2,-30,-12,50,300;6f6b:2000,2,-30,-12,50,300'
    .. ';626164:2000,2,-30,-12,50;626164:2000,2,-30,-12,50,300,1'
list = store.list()
assert(#list == 6 and list[4].name == 'ok' and list[4].settings.maximum == 2)
assert(list[4].settings.minimum == 0, 'Legacy six-field presets must keep their original zero-cut behavior')
-- Editing another preset rewrites legacy entries in the seven-field format,
-- preserving zero cut rather than silently adopting the new negative default.
store.save('new bidirectional', settings(2.5))
local upgraded = presets.new(api, model).list()
local by_name = {}
for _, entry in ipairs(upgraded) do by_name[entry.name] = entry.settings end
assert(by_name.ok.minimum == 0 and by_name['new bidirectional'].minimum == model.defaults.minimum)
assert(data:find('6f6b:2000,2,-30,-12,50,300,0', 1, true))
-- Defaults remain gentle, while explicit user presets can use the full limits.
local wide = settings(12)
wide.minimum = -12
store.save('Wide range', wide)
local wide_saved
for _, entry in ipairs(presets.new(api, model).list()) do
    if entry.name == 'Wide range' then wide_saved = entry.settings end
end
assert(wide_saved and wide_saved.maximum == 12 and wide_saved.minimum == -12)
assert(model.defaults.maximum == 3 and model.defaults.minimum == -3)
print('dynamic brightness presets: passed')
