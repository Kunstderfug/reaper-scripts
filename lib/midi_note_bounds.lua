-- Inspect note durations only; never edit events or rely on CC/source endings.
local M = {}

local function note_events(events)
    local notes, malformed = {}, false
    for index, event in ipairs(events) do
        local message = event.message
        if type(message) ~= 'string' then
            malformed = true
        elseif #message > 0 then
            local status = message:byte(1) & 0xf0
            if status == 0x80 or status == 0x90 then
                local time = event.time
                if #message ~= 3 or message:byte(2) >= 128 or message:byte(3) >= 128
                    or type(time) ~= 'number' or time ~= time or math.abs(time) == math.huge then
                    malformed = true
                else
                    notes[#notes + 1] = { time = time, order = index,
                        key = (message:byte(1) & 0x0f) * 128 + message:byte(2),
                        on = status == 0x90 and message:byte(3) > 0 }
                end
            end
        end
    end
    table.sort(notes, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.order < b.order
    end)
    return notes, malformed
end

function M.last_end(takes, start, finish)
    local latest, uncertain
    for _, take in ipairs(takes) do
        local notes, malformed = note_events(take.before)
        uncertain = uncertain or malformed
        local pending = {}
        for _, note in ipairs(notes) do
            local queue = pending[note.key]
            if note.on then
                if not queue then queue = { first = 1, last = 0 }; pending[note.key] = queue end
                queue.last = queue.last + 1
                queue[queue.last] = note.time
            elseif queue and queue.first <= queue.last then
                local onset = queue[queue.first]
                queue[queue.first] = nil
                queue.first = queue.first + 1
                -- Include held notes that begin before the item or finish past
                -- its old edge; exclude notes fully hidden outside its span.
                if onset < finish and note.time > start then
                    latest = math.max(latest or note.time, note.time)
                end
            elseif note.time > start and note.time < finish then
                -- An unmatched visible note-off can represent an incomplete
                -- source. Its missing onset makes tail trimming ambiguous.
                uncertain = true
            end
        end
        for _, queue in pairs(pending) do
            for i = queue.first, queue.last do
                if queue[i] < finish then uncertain = true end
            end
        end
    end
    if uncertain then return math.max(finish, latest or finish) end
    return latest
end

return M
