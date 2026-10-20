-- Routing and exclusive selection for three shared-reverb return buses.
local M = {}
M.tag = 'P_EXT:GPhilReverbAmbience'
-- IDs are persistent identities, independent of the current gain difference.
M.presets = {
    { id = '-3', name = 'Ambience A (-3 dB)', db = -3 },
    { id = '0', name = 'Ambience B (0 dB)', db = 0 },
    { id = '3', name = 'Ambience C (+3 dB)', db = 3 },
}

function M.new(r)
    local api = {}

    function api.levels(buses)
        local levels = {}
        for _, preset in ipairs(M.presets) do
            local gain = r.GetMediaTrackInfo_Value(buses[preset.id], 'D_VOL')
            levels[preset.id] = gain > 0 and 20 * math.log(gain, 10) or -math.huge
        end
        return levels
    end

    function api.difference(buses)
        local levels = api.levels(buses)
        return math.max(0, math.min(10, (levels['3'] - levels['-3']) / 2))
    end

    function api.is_default_difference(buses)
        local levels = api.levels(buses)
        return math.abs(levels['-3'] + 3) < 0.0001 and math.abs(levels['3'] - 3) < 0.0001
    end

    function api.set_difference(project, difference)
        assert(type(difference) == 'number' and difference == difference
            and difference >= 0 and difference <= 10, 'Difference must be from 0 to 10 dB.')
        local buses = assert(api.find(project), 'Ambience buses are missing.')
        r.Undo_BeginBlock2(project)
        r.PreventUIRefresh(1)
        for _, entry in ipairs({ { '-3', 'A', -difference }, { '3', 'C', difference } }) do
            local track, letter, db = buses[entry[1]], entry[2], entry[3]
            if db == 0 then db = 0 end -- Avoid a negative zero in the track name.
            r.SetMediaTrackInfo_Value(track, 'D_VOL', 10 ^ (db / 20))
            local label = db > 0 and '+' .. string.format('%g', db) or string.format('%g', db)
            r.GetSetMediaTrackInfo_String(track, 'P_NAME',
                'Ambience ' .. letter .. ' (' .. label .. ' dB)', true)
        end
        r.PreventUIRefresh(-1)
        r.TrackList_AdjustWindows(false)
        r.UpdateArrange()
        r.Undo_EndBlock2(project, 'Set ambience difference to ' .. difference .. ' dB', -1)
    end

    local function scan(project)
        local buses, count = {}, 0
        local ids = { a = '-3', b = '0', c = '3' }
        for i = 0, r.CountTracks(project) - 1 do
            local track = r.GetTrack(project, i)
            local _, id = r.GetSetMediaTrackInfo_String(track, M.tag, '', false)
            if id == '' then
                local _, name = r.GetTrackName(track)
                local letter, suffix = name:lower():match('^%s*ambience%s+([abc])(.-)%s*$')
                if letter and (suffix == '' or suffix:match('^%s+%([%+%-%.%d]+%s*db%)$')) then
                    id = ids[letter]
                end
            end
            if id ~= '' then
                assert((id == '-3' or id == '0' or id == '3') and not buses[id],
                    'Ambience bus names or tags are duplicated or invalid. No routing has been changed.')
                buses[id], count = track, count + 1
            end
        end
        return buses, count
    end

    function api.find(project)
        local buses, count = scan(project)
        return count == 3 and buses or nil
    end

    local function sources_for(project)
        local named = {}
        for i = 0, r.CountTracks(project) - 1 do
            local track = r.GetTrack(project, i)
            local _, name = r.GetTrackName(track)
            local number = name:lower():match('^%s*verb%s*([12])%s*$')
                or name:lower():match('^%s*rev%s*([12])%s*$')
            if number then
                assert(not named[number], 'More than one reverb track has the same name.')
                named[number] = track
            end
        end
        if named['1'] and named['2'] then return { named['1'], named['2'] } end
        assert(not named['1'] and not named['2'] and r.CountSelectedTracks(project) == 2,
            'Name the reverb returns verb 1 and verb 2, or select exactly two reverb return tracks.')
        return { r.GetSelectedTrack(project, 0), r.GetSelectedTrack(project, 1) }
    end

    function api.setup(project)
        local buses, existing_count = scan(project)
        local sources = sources_for(project)
        local managed, source_set, sends = {}, {}, {}
        for _, track in pairs(buses) do managed[track] = true end
        for _, source in ipairs(sources) do source_set[source] = true end
        -- Preflight the full graph before touching an existing project.
        for _, source in ipairs(sources) do
            assert(not managed[source] and not r.GetParentTrack(source)
                and r.GetMediaTrackInfo_Value(source, 'I_NCHAN') == 2
                and r.GetTrackNumSends(source, 1) == 0,
                'Reverb returns must be stereo, outside folders, with no hardware sends. '
                    .. 'No routing has been changed.')
            sends[source] = {}
            for i = 0, r.GetTrackNumSends(source, 0) - 1 do
                local target = r.GetTrackSendInfo_Value(source, 0, i, 'P_DESTTRACK')
                assert(managed[target] and not sends[source][target],
                    'A reverb has an unrelated or duplicate output send. No routing has been changed.')
                sends[source][target] = true
            end
        end
        for _, bus in pairs(buses) do
            assert(not r.GetParentTrack(bus)
                and r.GetMediaTrackInfo_Value(bus, 'I_NCHAN') == 2
                and r.GetTrackNumSends(bus, 0) == 0 and r.GetTrackNumSends(bus, 1) == 0,
                'Existing ambience buses must be stereo Master returns outside folders. '
                    .. 'No routing has been changed.')
            for i = 0, r.GetTrackNumSends(bus, -1) - 1 do
                assert(source_set[r.GetTrackSendInfo_Value(bus, -1, i, 'P_SRCTRACK')],
                    'An ambience bus receives an unrelated track. No routing has been changed.')
            end
        end
        local created, added_sends, changes = {}, {}, {}
        local changed = false
        local function begin()
            if changed then return end
            r.Undo_BeginBlock2(project)
            r.PreventUIRefresh(1)
            changed = true
        end
        local function value(track, key, new)
            local old = r.GetMediaTrackInfo_Value(track, key)
            if old == new then return end
            begin()
            changes[#changes + 1] = { track, key, old }
            assert(r.SetMediaTrackInfo_Value(track, key, new), 'Could not configure ambience routing.')
        end
        local function string_value(track, key, new)
            local _, old = r.GetSetMediaTrackInfo_String(track, key, '', false)
            if old == new then return end
            begin()
            changes[#changes + 1] = { track, key, old, true }
            assert(r.GetSetMediaTrackInfo_String(track, key, new, true), 'Could not label ambience bus.')
        end
        local active_count = 0
        for _, bus in pairs(buses) do
            if r.GetMediaTrackInfo_Value(bus, 'B_MUTE') == 0 then active_count = active_count + 1 end
        end
        local ok, err = xpcall(function()
            for _, preset in ipairs(M.presets) do
                local track = buses[preset.id]
                if not track then
                    begin()
                    local index = r.CountTracks(project)
                    r.InsertTrackInProject(project, index, 0)
                    track = assert(r.GetTrack(project, index), 'Could not create ambience bus.')
                    created[#created + 1] = track
                    buses[preset.id] = track
                    string_value(track, 'P_NAME', preset.name)
                    for key, new in pairs({ D_VOL = 10 ^ (preset.db / 20), D_PAN = 0,
                        D_WIDTH = 1, D_PANLAW = 1, I_PANMODE = 0,
                        B_MUTE = (active_count == 0 and preset.id == '0') and 0 or 1 }) do
                        value(track, key, new)
                    end
                end
                string_value(track, M.tag, preset.id)
                value(track, 'B_SHOWINTCP', 0)
                value(track, 'B_SHOWINMIXER', 1)
                value(track, 'B_MAINSEND', 1)
                for _, source in ipairs(sources) do
                    if not sends[source][track] then
                        begin()
                        local send = r.CreateTrackSend(source, track)
                        assert(send >= 0, 'Could not create reverb send.')
                        added_sends[#added_sends + 1] = { source, send }
                        for key, new in pairs({ I_SENDMODE = 0, D_VOL = 1, D_PAN = 0,
                            D_PANLAW = 1, B_MUTE = 0, B_PHASE = 0, B_MONO = 0,
                            I_SRCCHAN = 0, I_DSTCHAN = 0, I_MIDIFLAGS = 31 }) do
                            assert(r.SetTrackSendInfo_Value(source, 0, send, key, new),
                                'Could not configure reverb send.')
                        end
                    end
                end
            end
            if existing_count < 3 and active_count == 0 then value(buses['0'], 'B_MUTE', 0) end
            for _, source in ipairs(sources) do value(source, 'B_MAINSEND', 0) end
        end, debug.traceback)
        if not ok then
            for i = #added_sends, 1, -1 do
                r.RemoveTrackSend(added_sends[i][1], 0, added_sends[i][2])
            end
            for i = #changes, 1, -1 do
                local c = changes[i]
                if c[4] then r.GetSetMediaTrackInfo_String(c[1], c[2], c[3], true)
                else r.SetMediaTrackInfo_Value(c[1], c[2], c[3]) end
            end
            for i = #created, 1, -1 do r.DeleteTrack(created[i]) end
        end
        if changed then
            r.PreventUIRefresh(-1)
            r.TrackList_AdjustWindows(false)
            r.UpdateArrange()
            r.Undo_EndBlock2(project, 'Set up reverb ambience routing and mixer buses', -1)
        end
        assert(ok, err)
        return buses, changed
    end

    function api.select(project, id)
        local buses = assert(api.find(project), 'Ambience buses are missing.')
        local target = assert(buses[id], 'Unknown ambience alternative.')
        r.Undo_BeginBlock2(project)
        r.PreventUIRefresh(1)
        -- Mute every alternative before enabling one: never sum two wet returns.
        for _, preset in ipairs(M.presets) do
            r.SetMediaTrackInfo_Value(buses[preset.id], 'B_MUTE', 1)
        end
        r.SetMediaTrackInfo_Value(target, 'B_MUTE', 0)
        r.PreventUIRefresh(-1)
        r.UpdateArrange()
        local _, name = r.GetTrackName(target)
        r.Undo_EndBlock2(project, 'Switch to ' .. name, -1)
    end

    return api
end

return M
