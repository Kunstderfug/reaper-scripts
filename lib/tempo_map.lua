-- Lossless tempo-map transactions shared by Tempo Set's queue and direct paths.
-- Inject the API so the same implementation can be exercised outside REAPER.
local M = {}

function M.new(api)
    local map = {}
    local function check(ok, message)
        if not ok then error("Tempo map: " .. message, 3) end
    end
    local function number(value)
        return type(value) == "number" and value == value and math.abs(value) < math.huge
    end
    local function close(a, b)
        return number(a) and number(b) and math.abs(a - b) <= 0.000001
    end
    local function has(flags, bit)
        return flags & bit ~= 0
    end
    local function check_pattern_support()
        local version = api.GetAppVersion and api.GetAppVersion()
        local major, minor = tostring(version):match("^(%d+)%.(%d+)")
        check(major and (tonumber(major) > 7 or tonumber(major) == 7 and tonumber(minor) >= 28),
            "custom metronome patterns require REAPER 7.28 or newer for lossless restoration")
    end
    local function preflight()
        for _, name in ipairs({ "CountTempoTimeSigMarkers", "GetTempoTimeSigMarker",
            "SetTempoTimeSigMarker", "DeleteTempoTimeSigMarker",
            "GetSetTempoTimeSigMarkerFlag", "GetProjectTimeSignature2", "SetCurrentBPM" }) do
            check(type(api[name]) == "function", "missing REAPER API " .. name .. "; update REAPER before rendering")
        end
    end
    function map.commit()
        if api.UpdateTimeline then api.UpdateTimeline() end
        if api.UpdateArrange then api.UpdateArrange() end
    end
    local function read_marker(proj, index)
        local ok, time, measure, beat, bpm, num, denom, linear = api.GetTempoTimeSigMarker(proj, index)
        check(ok, "could not read marker " .. index .. "; no incomplete map will be saved")
        check(number(time) and number(bpm) and bpm > 0 and number(num) and number(denom),
            "invalid values on marker " .. index)
        local flags = api.GetSetTempoTimeSigMarkerFlag(proj, index, 0, false)
        check(number(flags) and flags >= 0 and flags % 1 == 0, "could not read flags on marker " .. index)
        local m = { timepos = time, measurepos = measure, beatpos = beat, bpm = bpm,
            timesig_num = num, timesig_denom = denom, lineartempo = linear, flags = flags }
        if has(flags, 8) then
            check_pattern_support()
            check(type(api.TimeMap_GetMetronomePattern) == "function", "custom metronome patterns require a newer REAPER")
            local pattern_denom, pattern = api.TimeMap_GetMetronomePattern(proj, time, "EXTENDED")
            check(number(pattern_denom) and pattern_denom > 0 and type(pattern) == "string" and pattern ~= "",
                "could not read metronome pattern on marker " .. index)
            m.metronome_pattern = pattern
        end
        if api.GetSetTempoTimeSigMarkerBasis then
            m.beat_basis = api.GetSetTempoTimeSigMarkerBasis(proj, index, 0, false)
            check(number(m.beat_basis) and m.beat_basis > 0, "could not read beat basis on marker " .. index)
        end
        return m
    end
    function map.capture(proj)
        preflight()
        local bpm, bpi = api.GetProjectTimeSignature2(proj)
        check(number(bpm) and bpm > 0 and number(bpi) and bpi > 0, "could not read project tempo/meter defaults")
        local state = { project_bpm = bpm, project_bpi = bpi, markers = {} }
        -- SWS provides access to the default denominator, which the native
        -- project-default getter omits. These variables belong to the active tab.
        if api.SNM_GetIntConfigVar and api.SNM_SetIntConfigVar then
            local active = not api.EnumProjects or proj == 0 or api.EnumProjects(-1, "") == proj
            if active then
                local denominator = api.SNM_GetIntConfigVar("projtsdenom", -1)
                check(number(denominator) and denominator > 0, "could not read default meter denominator")
                state.project_denom = denominator
            end
        end
        local count = api.CountTempoTimeSigMarkers(proj)
        check(number(count) and count >= 0 and count % 1 == 0, "could not count tempo markers")
        for i = 0, count - 1 do state.markers[i + 1] = read_marker(proj, i) end
        check(api.CountTempoTimeSigMarkers(proj) == count, "map changed while being captured")
        return state
    end
    local function validate(state)
        preflight()
        check(type(state) == "table" and type(state.markers) == "table", "missing complete original snapshot")
        check(number(state.project_bpm) and state.project_bpm > 0 and number(state.project_bpi) and state.project_bpi > 0,
            "snapshot is missing project defaults")
        if state.project_denom ~= nil then
            check(number(state.project_denom) and state.project_denom > 0, "snapshot has invalid default denominator")
        end
        for i, m in ipairs(state.markers) do
            check(number(m.timepos) and number(m.bpm) and m.bpm > 0 and number(m.timesig_num)
                and number(m.timesig_denom) and number(m.flags) and m.flags >= 0 and m.flags % 1 == 0,
                "incomplete snapshot marker " .. i)
            check(i == 1 or state.markers[i - 1].timepos < m.timepos, "snapshot markers must have distinct ordered positions")
            if has(m.flags, 8) then
                check_pattern_support()
                check(api.TimeMap_GetMetronomePattern and type(m.metronome_pattern) == "string" and m.metronome_pattern ~= "",
                    "snapshot is missing a custom metronome pattern")
            end
            if m.beat_basis ~= nil then
                check(api.GetSetTempoTimeSigMarkerBasis and number(m.beat_basis) and m.beat_basis > 0,
                    "snapshot beat basis cannot be restored")
            end
        end
    end
    local function find(proj, time)
        for i = 0, api.CountTempoTimeSigMarkers(proj) - 1 do
            local ok, marker_time = api.GetTempoTimeSigMarker(proj, i)
            check(ok, "could not resolve restored marker")
            if close(marker_time, time) then return i end
        end
        error("Tempo map: inserted marker could not be found", 3)
    end
    local function metadata(proj, index, m)
        if m.beat_basis ~= nil then api.GetSetTempoTimeSigMarkerBasis(proj, index, m.beat_basis, true) end
        -- Pattern assignment may alter flags; apply the complete saved mask last.
        if has(m.flags, 8) then
            api.TimeMap_GetMetronomePattern(proj, m.timepos, "SET:" .. m.metronome_pattern)
        end
        api.GetSetTempoTimeSigMarkerFlag(proj, index, m.flags, true)
    end
    local function compare_marker(a, b, index, musical_positions)
        for _, key in ipairs({ "timepos", "bpm", "timesig_num", "timesig_denom" }) do
            check(close(a[key], b[key]), "marker " .. index .. " readback differs: " .. key)
        end
        for _, key in ipairs({ "lineartempo", "flags", "metronome_pattern", "beat_basis" }) do
            check(a[key] == b[key], "marker " .. index .. " readback differs: " .. key)
        end
        if musical_positions then
            for _, key in ipairs({ "measurepos", "beatpos" }) do
                if number(a[key]) and a[key] >= 0 then
                    check(close(a[key], b[key]), "marker " .. index .. " musical position differs: " .. key)
                end
            end
        end
    end
    local function defaults(proj, state)
        local bpm, bpi = api.GetProjectTimeSignature2(proj)
        if not close(bpm, state.project_bpm) then
            check(api.SetCurrentBPM, "cannot restore changed default BPM")
            api.SetCurrentBPM(proj, state.project_bpm, false)
        end
        if not close(bpi, state.project_bpi) then
            check(api.SNM_SetIntConfigVar, "cannot restore changed default meter; SWS is required")
            check(api.SNM_SetIntConfigVar("projmeaslen", state.project_bpi), "default meter restoration failed")
        end
        if state.project_denom then
            check(api.SNM_GetIntConfigVar and api.SNM_SetIntConfigVar, "cannot restore default meter denominator")
            if api.SNM_GetIntConfigVar("projtsdenom", -1) ~= state.project_denom then
                check(api.SNM_SetIntConfigVar("projtsdenom", state.project_denom), "default denominator restoration failed")
            end
        end
        bpm, bpi = api.GetProjectTimeSignature2(proj)
        check(close(bpm, state.project_bpm) and close(bpi, state.project_bpi), "project defaults restoration failed readback")
    end
    local function rebuild_active(proj, state, musical_positions)
        validate(state) -- Never delete a point before verifying snapshot + APIs.
        local _, current_bpi = api.GetProjectTimeSignature2(proj)
        if not close(current_bpi, state.project_bpi) or state.project_denom then
            check(api.SNM_GetIntConfigVar and api.SNM_SetIntConfigVar,
                "changed project meter defaults require SWS for restoration")
            check(not api.EnumProjects or proj == 0 or api.EnumProjects(-1, "") == proj,
                "activate the original project before restoring its meter defaults")
        end
        for i = api.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do
            check(api.DeleteTempoTimeSigMarker(proj, i), "failed to delete temporary marker " .. i)
        end
        defaults(proj, state)
        for _, m in ipairs(state.markers) do
            -- Exactly one coordinate system: seconds, with measure/beat unused.
            check(api.SetTempoTimeSigMarker(proj, -1, m.timepos, -1, -1, m.bpm,
                m.timesig_num, m.timesig_denom, m.lineartempo), "failed to insert marker")
        end
        for _, m in ipairs(state.markers) do metadata(proj, find(proj, m.timepos), m) end
        map.commit()
        local actual = map.capture(proj)
        check(#actual.markers == #state.markers, "marker count differs after restoration")
        for i, m in ipairs(state.markers) do compare_marker(m, actual.markers[i], i, musical_positions) end
        check(close(actual.project_bpm, state.project_bpm) and close(actual.project_bpi, state.project_bpi),
            "project defaults differ after marker restoration")
        if state.project_denom then check(actual.project_denom == state.project_denom, "default denominator differs after restoration") end
    end
    local function rebuild(proj, state, musical_positions)
        validate(state)
        if api.ValidatePtr and proj ~= 0 then
            check(api.ValidatePtr(proj, "ReaProject*"), "the original project is no longer open")
        end
        local previous = api.EnumProjects and api.EnumProjects(-1, "")
        local switch = proj ~= 0 and previous and previous ~= proj
        if switch then
            check(api.SelectProjectInstance, "cannot activate the original project for restoration")
        end
        -- SWS project-default variables belong to the active tab. Temporarily
        -- activate the originating project, then return to the user's tab even
        -- when a marker write fails during restoration.
        local ok, reason = pcall(function()
            if switch then
                api.SelectProjectInstance(proj)
                check(api.EnumProjects(-1, "") == proj, "could not activate the original project")
            end
            rebuild_active(proj, state, musical_positions)
        end)
        local switched_back, switch_error = true, nil
        if switch then
            switched_back, switch_error = pcall(function()
                check(not api.ValidatePtr or api.ValidatePtr(previous, "ReaProject*"), "the previously active project is no longer open")
                api.SelectProjectInstance(previous)
                check(api.EnumProjects(-1, "") == previous, "could not reactivate the previous project")
            end)
        end
        if not ok then
            error(tostring(reason) .. (switched_back and "" or "\n" .. tostring(switch_error)), 3)
        end
        check(switched_back, tostring(switch_error))
    end
    function map.restore(proj, state)
        rebuild(proj, state, true)
        return true
    end
    function map.scale(proj, original, factor)
        check(number(factor) and factor > 0, "tempo multiplier must be positive")
        validate(original)
        local scaled = { project_bpm = original.project_bpm * factor, project_bpi = original.project_bpi,
            project_denom = original.project_denom, markers = {} }
        for i, m in ipairs(original.markers) do
            local copy = {}
            for k, v in pairs(m) do copy[k] = v end
            copy.timepos, copy.bpm = m.timepos / factor, m.bpm * factor
            scaled.markers[i] = copy
        end
        -- Scale the default too: tempo before the first marker must follow the
        -- same inverse time factor, including projects with no original markers.
        rebuild(proj, scaled, false)
        return true
    end
    function map.ensure(proj, time, bpm, explicit_override)
        check(number(time) and number(bpm) and bpm > 0, "invalid region-start tempo")
        local before = map.capture(proj) -- Includes API + complete metadata preflight.
        for i, m in ipairs(before.markers) do
            if close(m.timepos, time) then
                m.bpm = bpm
                if explicit_override then m.flags = m.flags & ~2 end
                check(api.SetTempoTimeSigMarker(proj, i - 1, m.timepos, -1, -1, bpm,
                    m.timesig_num, m.timesig_denom, m.lineartempo), "failed to set region-start tempo")
                metadata(proj, find(proj, m.timepos), m)
                map.commit()
                compare_marker(m, read_marker(proj, find(proj, m.timepos)), i, false)
                return true
            end
        end
        check(api.SetTempoTimeSigMarker(proj, -1, time, -1, -1, bpm, 0, 0, false),
            "failed to insert region-start tempo")
        map.commit()
        local marker = read_marker(proj, find(proj, time))
        check(close(marker.bpm, bpm) and not has(marker.flags, 2), "region-start tempo override was not enabled")
        return true
    end
    return map
end

return M
