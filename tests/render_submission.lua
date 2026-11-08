-- Run from repository root: lua tests/render_submission.lua
local submission = dofile('lib/render_submission.lua')
local flag = 16 << 16
for _, case in ipairs({
    { settings=8, delay=0, expected=2 },
    { settings=8|flag, delay=0.5, expected=2 },
    { settings=8|flag, delay=5, expected=5 },
    { settings=8, delay=60, expected=2 },
}) do
    local values = { RENDER_SETTINGS=case.settings, RENDER_DELAY=case.delay }
    local api = { GetSetProjectInfo=function(project, key, value, set)
        assert(project == 'project')
        if set then values[key] = value end
        return assert(values[key])
    end }
    submission.prepare(api, 'project')
    assert(values.RENDER_SETTINGS == case.settings|flag, 'Unrelated render flags must survive')
    assert(values.RENDER_DELAY == case.expected, 'Respect longer enabled delays only')
end
print('PASS: initialization enabled, minimum delay, longer preset delay, disabled stale delay')
