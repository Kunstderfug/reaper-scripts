local model = dofile('lib/reverb_ambience.lua')
local function fixture()
    local tracks = {
        { P_NAME = 'BUS', D_VOL = 0.68, sends = {} },
        { P_NAME = 'verb 1', D_VOL = 0.053, B_MAINSEND = 1, I_NCHAN = 2, sends = {} },
        { P_NAME = 'verb 2', D_VOL = 0.196, B_MAINSEND = 1, I_NCHAN = 2, sends = {} },
    }
    local r = {}
    r.CountTracks = function() return #tracks end
    r.GetTrack = function(_, i) return tracks[i + 1] end
    r.CountSelectedTracks = function() return 0 end
    r.GetTrackName = function(t) return true, t.P_NAME end
    r.GetSetMediaTrackInfo_String = function(t, k, v, set)
        if set then t[k] = v end
        return true, t[k] or ''
    end
    r.GetParentTrack = function(t) return t.parent end
    r.GetMediaTrackInfo_Value = function(t, k) return t[k] or 0 end
    r.SetMediaTrackInfo_Value = function(t, k, v) t[k] = v; return true end
    local function receives(t)
        local result = {}
        for _, source in ipairs(tracks) do
            for _, send in ipairs(source.sends) do
                if send.target == t then result[#result + 1] = { source = source, send = send } end
            end
        end
        return result
    end
    r.GetTrackNumSends = function(t, c)
        if c == -1 then return #receives(t) end
        return c == 0 and #t.sends or 0
    end
    r.GetTrackSendInfo_Value = function(t, c, i, k)
        if c == -1 then
            local recv = receives(t)[i + 1]
            return k == 'P_SRCTRACK' and recv.source or recv.send[k]
        end
        local send = t.sends[i + 1]
        return k == 'P_DESTTRACK' and send.target or send[k]
    end
    r.RemoveTrackSend = function(t, _, i) table.remove(t.sends, i + 1); return true end
    r.InsertTrackInProject = function()
        tracks[#tracks + 1] = { sends = {}, I_NCHAN = 2, B_MAINSEND = 1,
            B_SHOWINTCP = 1, B_SHOWINMIXER = 1, B_MUTE = 0, D_VOL = 1 }
    end
    r.DeleteTrack = function(t)
        for _, source in ipairs(tracks) do
            for i = #source.sends, 1, -1 do
                if source.sends[i].target == t then table.remove(source.sends, i) end
            end
        end
        for i, track in ipairs(tracks) do
            if track == t then table.remove(tracks, i); break end
        end
    end
    r.CreateTrackSend = function(s, t)
        s.sends[#s.sends + 1] = { target = t }
        return #s.sends - 1
    end
    r.SetTrackSendInfo_Value = function(t, _, i, k, v)
        t.sends[i + 1][k] = v; return true
    end
    for _, name in ipairs({ 'Undo_BeginBlock2', 'Undo_EndBlock2', 'PreventUIRefresh',
        'TrackList_AdjustWindows', 'UpdateArrange' }) do r[name] = function() end end
    return model.new(r), tracks, r
end

local api, tracks, initial_r = fixture()
local buses, created = api.setup(0)
assert(created and #tracks == 6)
assert(api.is_default_difference(buses), 'Initial defaults not recognized')
assert(tracks[1].D_VOL == 0.68, 'Dry gain changed')
assert(tracks[2].D_VOL == 0.053 and tracks[3].D_VOL == 0.196, 'Reverb balance changed')
for _, source in ipairs({ tracks[2], tracks[3] }) do
    assert(source.B_MAINSEND == 0 and #source.sends == 3, 'Duplicate/missing reverb output')
    for i, send in ipairs(source.sends) do
        assert(send.target == buses[model.presets[i].id])
        assert(send.I_SENDMODE == 0 and send.D_VOL == 1 and send.D_PAN == 0)
        assert(send.I_SRCCHAN == 0 and send.I_DSTCHAN == 0 and send.I_MIDIFLAGS == 31)
    end
end
for _, preset in ipairs(model.presets) do
    local bus = buses[preset.id]
    assert(bus.B_SHOWINTCP == 0 and bus.B_SHOWINMIXER == 1, 'Bus is not mixer-only')
    assert(math.abs(20 * math.log(bus.D_VOL, 10) - preset.db) < 1e-10)
    assert(bus.B_MUTE == (preset.db == 0 and 0 or 1))
end
for _, id in ipairs({ '3', '-3', '0' }) do
    api.select(0, id)
    for key, bus in pairs(buses) do assert(bus.B_MUTE == (key == id and 0 or 1)) end
end
api.select(0, '3')
for _, difference in ipairs({ 0, 0.5, 5, 10, 3 }) do
    api.set_difference(0, difference)
    local levels = api.levels(buses)
    assert(math.abs(levels['-3'] + difference) < 1e-10, 'A is not negative difference')
    assert(math.abs(levels['3'] - difference) < 1e-10, 'C is not positive difference')
    assert(levels['0'] == 0 and buses['0'].P_NAME == 'Ambience B (0 dB)', 'B changed')
    assert(math.abs(api.difference(buses) - difference) < 1e-10, 'Difference not recovered')
    assert(api.is_default_difference(buses) == (difference == 3), 'Reset availability is wrong')
    assert(buses['3'].B_MUTE == 0 and buses['-3'].B_MUTE == 1, 'Active choice changed')
    assert(#tracks[2].sends == 3 and tracks[2].D_VOL == 0.053, 'Source routing/gain changed')
end
assert(buses['-3'].P_NAME == 'Ambience A (-3 dB)' and buses['3'].P_NAME == 'Ambience C (+3 dB)')
buses['-3'].D_VOL = 10 ^ (-2 / 20)
buses['3'].D_VOL = 10 ^ (4 / 20)
assert(not api.is_default_difference(buses), 'Manual asymmetric fader changes did not enable reset')
api.set_difference(0, 3)
assert(api.is_default_difference(buses) and buses['3'].B_MUTE == 0, 'Reset changed active bus')
for _, value in ipairs({ -1, 11, '5', math.huge, 0 / 0 }) do
    assert(not pcall(api.set_difference, 0, value), 'Invalid difference accepted')
end
local _, again = api.setup(0)
assert(not again and #tracks == 6 and #tracks[2].sends == 3, 'Rerun duplicated routing')
-- Delete just one alternative; recreate only that bus and its two sends.
local old_a, old_b = buses['-3'], buses['0']
initial_r.DeleteTrack(buses['3'])
local repaired, repaired_change = api.setup(0)
assert(repaired_change and #tracks == 6 and repaired['-3'] == old_a and repaired['0'] == old_b)
assert(#tracks[2].sends == 3 and repaired['0'].B_MUTE == 0, 'Partial setup was not repaired')

api, tracks = fixture()
tracks[2].P_NAME = 'Other'
assert(not pcall(api.setup, 0) and #tracks == 3, 'Missing first source accepted')

local r
api, tracks, r = fixture()
r.CreateTrackSend = function() return -1 end
assert(not pcall(api.setup, 0) and #tracks == 3, 'Failed setup left new tracks')
assert(tracks[2].B_MAINSEND == 1 and tracks[3].B_MAINSEND == 1, 'Rollback lost original output')

api, tracks = fixture()
tracks[2].sends = { { target = tracks[1] } }
assert(not pcall(api.setup, 0) and #tracks == 3 and tracks[2].B_MAINSEND == 1,
    'Unsupported existing routing changed')

-- Reuse a manually named structure, preserve its mix, and repair missing links.
api, tracks, r = fixture()
buses = api.setup(0)
api.set_difference(0, 6)
api.select(0, '3')
local existing_send = tracks[2].sends[1]
existing_send.D_VOL = 0.75
for _, bus in pairs(buses) do
    bus[model.tag], bus.B_SHOWINTCP, bus.B_SHOWINMIXER = '', 1, 0
end
tracks[2].B_MAINSEND, tracks[3].B_MAINSEND = 1, 1
table.remove(tracks[3].sends, 2)
-- An arbitrary track selection must not override the named reverb pair.
r.CountSelectedTracks = function() return 2 end
r.GetSelectedTrack = function() error('Should auto-detect the named reverbs') end
local reused, reuse_change = api.setup(0)
assert(reuse_change and #tracks == 6 and reused['3'] == buses['3'], 'Existing buses duplicated')
assert(#tracks[2].sends == 3 and #tracks[3].sends == 3, 'Missing send was not repaired')
assert(tracks[2].sends[1] == existing_send and existing_send.D_VOL == 0.75, 'Existing send changed')
assert(math.abs(api.difference(reused) - 6) < 1e-10 and reused['3'].B_MUTE == 0,
    'Existing gain/active alternative changed')
for _, bus in pairs(reused) do
    assert(bus.B_SHOWINTCP == 0 and bus.B_SHOWINMIXER == 1, 'Existing bus not mixer-only')
end
local _, no_change = api.setup(0)
assert(not no_change, 'Already correct structure was modified')

-- Roll back changes to existing buses as well as newly added routing.
reused['-3'].B_SHOWINTCP = 1
tracks[2].B_MAINSEND = 1
r.RemoveTrackSend(tracks[3], 0, 1)
local previous_send_count = #tracks[3].sends
r.SetTrackSendInfo_Value = function() return false end
assert(not pcall(api.setup, 0), 'Injected routing failure was not reported')
assert(#tracks == 6 and #tracks[3].sends == previous_send_count
    and reused['-3'].B_SHOWINTCP == 1 and tracks[2].B_MAINSEND == 1,
    'Failed repair did not restore the previous structure')

api, tracks, r = fixture()
buses = api.setup(0)
r.CreateTrackSend(tracks[1], buses['0'])
assert(not pcall(api.setup, 0), 'Unrelated dry receive was silently adopted')

api, tracks, r = fixture()
tracks[2].P_NAME, tracks[3].P_NAME = 'REV 1', 'REV 2'
assert(api.setup(0), 'REV name aliases were not detected')

-- Exercise the actual window's mouse handling, including release-only slider
-- commits and reset after a fader edit made outside the window.
local ui_api, ui_tracks, ui_r = fixture()
local ui_buses = ui_api.setup(0)
local next_frame, undo_count = nil, 0
ui_r.EnumProjects = function() return 0 end
ui_r.defer = function(callback) next_frame = callback end
ui_r.Undo_EndBlock2 = function() undo_count = undo_count + 1 end
local ui_gfx = { mouse_x = 0, mouse_y = 0, mouse_cap = 0, w = 490, h = 315 }
for _, name in ipairs({ 'init', 'set', 'rect', 'setfont', 'drawstr', 'circle', 'update', 'quit' }) do
    ui_gfx[name] = function() end
end
ui_gfx.getchar = function() return 0 end
local environment = setmetatable({ reaper = ui_r, gfx = ui_gfx }, { __index = _G })
assert(loadfile('./GPhil_reverbAmbience.lua', 't', environment))()
local function mouse(x, y, down)
    ui_gfx.mouse_x, ui_gfx.mouse_y, ui_gfx.mouse_cap = x, y, down and 1 or 0
    assert(next_frame)()
end
mouse(300, 205, true) -- Quick 6 dB.
mouse(300, 205, false)
assert(math.abs(ui_api.difference(ui_buses) - 6) < 1e-10, 'Quick button failed')
mouse(60, 245, true) -- Reset.
mouse(60, 245, false)
assert(ui_api.is_default_difference(ui_buses), 'Reset button failed')
local default_undo_count = undo_count
mouse(60, 245, true)
mouse(60, 245, false)
assert(undo_count == default_undo_count, 'Default reset button was not disabled')
ui_buses['-3'].D_VOL = 10 ^ (-8 / 20) -- Simulate a manual REAPER fader change.
mouse(60, 245, true)
mouse(60, 245, false)
assert(ui_api.is_default_difference(ui_buses), 'Manual fader change did not activate reset')
mouse(245, 157, true) -- Slider midpoint = 5 dB.
assert(ui_api.is_default_difference(ui_buses), 'Slider changed gains before release')
mouse(245, 157, false)
assert(math.abs(ui_api.difference(ui_buses) - 5) < 1e-10, 'Slider release did not apply difference')
assert(ui_buses['0'].D_VOL == 1 and ui_buses['0'].B_MUTE == 0 and #ui_tracks == 6)
print('PASS: routing, symmetric gains, window slider/presets/reset, manual-fader reset, rerun, rollback')
