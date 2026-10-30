-- Isolate newly recorded CC runs; merge fitted anchors without touching older MIDI.
local M = {}
local lanes = { [1]=true, [3]=true, [11]=true, [13]=true, [21]=true, [22]=true }
local function parse(data)
    local events, tick, pos = {}, 0, 1
    while pos <= #data do
        local delta, flags, msg
        delta, flags, msg, pos = string.unpack('<i4Bs4', data, pos)
        tick = tick + delta
        local e = { tick=tick, flags=flags, msg=msg, index=#events+1 }
        events[#events+1] = e
        if msg:sub(1,7) == '\255\15CCBZ ' then
            local parent = events[#events-1]
            assert(parent and parent.tick == tick and parent.msg:byte(1) & 240 == 176,
                'Unattached CC curve metadata; recording pass skipped.')
            parent.meta = e; e.parent = parent
        end
    end
    return events
end
local function pack(events)
    local data, tick = {}, 0
    for _, e in ipairs(events) do
        data[#data+1] = string.pack('<i4Bs4', e.tick-tick, e.flags, e.msg)
        tick = e.tick
    end
    return table.concat(data)
end
local function key(e) return tostring(e.tick) .. ':' .. e.msg end
local function lane(e)
    if #e.msg == 3 and e.msg:byte(1) & 240 == 176 and lanes[e.msg:byte(2)] then
        return e.msg:byte(1) * 128 + e.msg:byte(2)
    end
end
function M.prepare(before, after, ppq)
    local old, events, runs, current, notes = {}, parse(after), {}, {}, {}
    for _, buffer in ipairs(before) do
        for _, e in ipairs(parse(buffer)) do if lane(e) then old[key(e)] = true end end
    end
    for _, e in ipairs(events) do
        local status = #e.msg > 0 and e.msg:byte(1) & 240 or 0
        if status == 128 or status == 144 then notes[#notes+1] = e end
        local id = lane(e)
        if id then
            if old[key(e)] then current[id] = nil
            else
                local run = current[id]
                if not run then run={}; current[id]=run; runs[#runs+1]=run end
                run[#run+1] = e
            end
        end
    end
    local jobs = {}
    for _, run in ipairs(runs) do
        if #run >= 3 then
            local subset = {}
            for _, e in ipairs(notes) do subset[#subset+1] = e end
            for _, e in ipairs(run) do
                subset[#subset+1] = e
                if e.meta then subset[#subset+1] = e.meta end
            end
            table.sort(subset, function(a,b) return a.index < b.index end)
            -- Keep source duration, including trailing silence; this marker is not merged back.
            subset[#subset+1] = {tick=events[#events].tick, flags=0, msg=''}
            jobs[#jobs+1] = {before=pack(subset), ppq=ppq, run=run}
        end
    end
    return {events=events, jobs=jobs, original=after}
end
function M.merge(plan)
    if #plan.jobs == 0 then return plan.original end
    local replacements, removed = {}, {}
    for _, job in ipairs(plan.jobs) do
        local anchors = {}
        for _, e in ipairs(job.run) do
            anchors[key(e)] = anchors[key(e)] or {}
            table.insert(anchors[key(e)], e)
            removed[e.index] = true
            if e.meta then removed[e.meta.index] = true end
        end
        local last = job.run[#job.run]
        for _, fitted in ipairs(parse(assert(job.after))) do
            if lane(fitted) then
                local matching = anchors[key(fitted)]
                assert(matching and #matching > 0, 'Optimizer introduced an unexpected recorded CC anchor.')
                local original = table.remove(matching,1)
                -- Preserve the final outgoing segment toward MIDI outside this recording run.
                local out = original == last and original or fitted
                replacements[original.index] = {out}
                local meta = original == last and original.meta or fitted.meta
                if meta then table.insert(replacements[original.index], meta) end
            end
        end
        assert(replacements[job.run[1].index] and replacements[last.index],
            'Optimizer removed a recording boundary; pass skipped.')
    end
    local result = {}
    for _, e in ipairs(plan.events) do
        if replacements[e.index] then
            for _, replacement in ipairs(replacements[e.index]) do result[#result+1]=replacement end
        elseif not removed[e.index] then result[#result+1]=e end
    end
    return pack(result)
end
M.parse, M.pack = parse, pack
return M
