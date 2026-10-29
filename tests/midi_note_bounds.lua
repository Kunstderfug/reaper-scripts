local bounds = dofile('lib/midi_note_bounds.lua')
local function event(time, status, pitch, velocity, flags)
    return { time = time, message = string.char(status, pitch, velocity), flags = flags or 0 }
end
local function last(events, start, finish, extra)
    local takes = { { before = events } }
    if extra then takes[#takes + 1] = { before = extra } end
    return bounds.last_end(takes, start or 0, finish or 12)
end
local function near(a, b) assert(a and math.abs(a - b) < 1e-10, tostring(a) .. ' ~= ' .. tostring(b)) end

-- Musical tail, not recording duration, terminal CC, text, or muted flags.
near(last({ event(1, 0x90, 60, 100, 2), event(6.5, 0x80, 60, 0),
    event(11, 0xb0, 11, 127), event(12, 0xb0, 123, 0),
    { time = 12, message = '\255text' } }), 6.5)
near(last({ event(1, 0x90, 60, 100), event(4, 0x90, 60, 0) }), 4)
near(last({ event(1, 0x90, 60, 100), event(4.1, 0x80, 60, 0) }), 4.1)
assert(last({ event(11, 0xb0, 11, 127) }) == nil)
assert(bounds.last_end({}, 0, 12) == nil)

-- Channel/pitch identities and FIFO pairing for repeated overlapping pitches.
near(last({ event(1, 0x90, 60, 100), event(2, 0x91, 60, 100),
    event(3, 0x80, 60, 0), event(8, 0x81, 60, 0) }), 8)
near(last({ event(1, 0x90, 60, 100), event(2, 0x90, 60, 100),
    event(3, 0x80, 60, 0), event(8, 0x80, 60, 0) }, 3.5, 12), 8)
near(last({ event(1, 0x90, 60, 100), event(2, 0x90, 61, 100),
    event(3, 0x80, 60, 0), event(9, 0x80, 61, 0) }), 9)
near(last({ event(1, 0x90, 60, 100), event(3, 0x80, 60, 0) }, 0, 12,
    { event(2, 0x90, 65, 100), event(10, 0x80, 65, 0) }), 10)

-- A held note crossing either old item boundary remains part of the result.
near(last({ event(-1, 0x90, 60, 100), event(2, 0x80, 60, 0) }), 2)
near(last({ event(10, 0x90, 60, 100), event(14, 0x80, 60, 0) }), 14)
assert(last({ event(-2, 0x90, 60, 100), event(0, 0x80, 60, 0),
    event(12, 0x90, 61, 100), event(14, 0x80, 61, 0) }) == nil)

-- Sorting is stable, local, and leaves the original event array untouched.
local unsorted = { event(8, 0x80, 60, 0), event(1, 0x90, 60, 100),
    event(2, 0x90, 61, 100), event(4, 0x80, 61, 0) }
local first = unsorted[1]
near(last(unsorted), 8)
assert(unsorted[1] == first and unsorted[2].time == 1)
near(last({ event(1, 0x90, 60, 100), event(4, 0x80, 60, 0),
    event(4, 0x90, 60, 100), event(7, 0x80, 60, 0) }), 7)

-- Incomplete/malformed visible note data conservatively prevents trimming.
near(last({ event(1, 0x90, 60, 100) }), 12)
near(last({ event(-1, 0x90, 60, 100) }), 12)
near(last({ event(4, 0x80, 60, 0) }), 12)
near(last({ event(1, 0x90, 60, 100), event(14, 0x80, 60, 0),
    event(2, 0x90, 61, 100) }), 14)
near(last({ { time = 2, message = string.char(0x90, 60) } }), 12)
near(last({ event(2, 0x90, 128, 100) }), 12)
near(last({ event(0 / 0, 0x90, 60, 100) }), 12)
near(last({ { time = 2, message = false } }), 12)
assert(last({ event(12, 0x90, 60, 100) }) == nil)

print('PASS: note ends, holds, hidden notes, channels/pitches, overlapping FIFO, multiple takes, stable sorting, incomplete data, CC exclusion')
