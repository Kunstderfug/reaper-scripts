-- Run inside REAPER to regenerate data/bezier.f32le. Uses a separate project tab.
local script = debug.getinfo(1, "S").source:sub(2)
local root = assert(script:match("^(.*[/\\])"))
reaper.Main_OnCommand(40859, 0)
reaper.InsertTrackAtIndex(0, false)
local track = reaper.GetTrack(0, 0)
local ok, chunk = reaper.GetTrackStateChunk(track, "", false)
assert(ok)
chunk = chunk:gsub("\n>\n?$", "\n<VOLENV2\nACT 1 -1\nVIS 0 1 1\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 0 0\nPT 1 1 0\n>\n>")
assert(reaper.SetTrackStateChunk(track, chunk, false))
local envelope = assert(reaper.GetTrackEnvelopeByName(track, "Volume"))
local bytes = {}
for ti = -20, 20 do
    reaper.DeleteEnvelopePointRange(envelope, -10, 10)
    reaper.InsertEnvelopePoint(envelope, 0, 0, 5, ti / 20, false, true)
    reaper.InsertEnvelopePoint(envelope, 1, 1, 0, 0, false, true)
    reaper.Envelope_SortPoints(envelope)
    for i = 0, 1024 do
        local _, value = reaper.Envelope_Evaluate(envelope, i / 1024, 48000, 1)
        bytes[#bytes + 1] = string.pack("<f", value)
    end
end
local file = assert(io.open(root .. "data/bezier.f32le", "wb"))
file:write(table.concat(bytes))
file:close()
reaper.ShowConsoleMsg("Wrote native curve reference: " .. root .. "data/bezier.f32le\n")
