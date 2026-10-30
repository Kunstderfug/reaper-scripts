-- Capture idle MIDI baselines and locate recorded takes independently of selection.
local M = {}
local function guid(api,take)
    local ok,id = api.GetSetMediaItemTakeInfo_String(take,'GUID','',false)
    assert(ok and id ~= '', 'Cannot identify MIDI take.')
    return id
end
local function mapping(api,take)
    return {api.MIDI_GetProjQNFromPPQPos(take,0), api.MIDI_GetProjQNFromPPQPos(take,960)}
end
local function same_mapping(a,b)
    return math.abs(a[1]-b[1]) < 1e-7 and math.abs(a[2]-b[2]) < 1e-7
end
function M.capture(api,project,previous)
    local state = {takes={}, known={}, tracks={}, items={}}
    for i=0,api.CountTracks(project)-1 do
        local track = api.GetTrack(project,i)
        local armed = api.GetMediaTrackInfo_Value(track,'I_RECARM') == 1
        if armed then state.tracks[track]=true end
        for j=0,api.CountTrackMediaItems(track)-1 do
            local item = api.GetTrackMediaItem(track,j)
            for k=0,api.CountTakes(item)-1 do
                local take = api.GetTake(item,k)
                if api.TakeIsMIDI(take) then
                    local id = guid(api,take)
                    state.known[id]=true
                    if armed then
                        local ok,hash = api.MIDI_GetHash(take,false,'')
                        assert(ok,'Could not fingerprint MIDI take.')
                        local cached = previous and previous.takes[id]
                        local data
                        if cached and cached.hash == hash then data=cached.data
                        else
                            local read; read,data = api.MIDI_GetAllEvts(take,'')
                            assert(read,'Could not snapshot MIDI before recording.')
                        end
                        local entry={data=data, hash=hash, mapping=mapping(api,take), item=item}
                        state.takes[id]=entry
                        state.items[item]=state.items[item] or {}
                        table.insert(state.items[item],entry)
                    end
                end
            end
        end
    end
    return state
end
function M.candidates(api,project,baseline)
    local entries = {}
    for i=0,api.CountTracks(project)-1 do
        local track = api.GetTrack(project,i)
        if baseline.tracks[track] then
            for j=0,api.CountTrackMediaItems(track)-1 do
                local item = api.GetTrackMediaItem(track,j)
                for k=0,api.CountTakes(item)-1 do
                    local take=api.GetTake(item,k)
                    if api.TakeIsMIDI(take) then
                        local id=guid(api,take)
                        local prior=baseline.takes[id]
                        local ok,hash=api.MIDI_GetHash(take,false,'')
                        assert(ok,'Could not fingerprint recorded MIDI.')
                        if not prior or prior.hash ~= hash then
                            local buffers, safe = {}, true
                            if prior then
                                safe=same_mapping(prior.mapping,mapping(api,take))
                                buffers[1]=prior.data
                            elseif baseline.known[id] then safe=false
                            else
                                -- A newly created overdub take may contain a copy of earlier data.
                                for _, old in ipairs(baseline.items[item] or {}) do
                                    if same_mapping(old.mapping,mapping(api,take)) then buffers[#buffers+1]=old.data
                                    else safe=false end
                                end
                            end
                            if safe then entries[#entries+1]={item=item,take=take,old=buffers} end
                        end
                    end
                end
            end
        end
    end
    return entries
end
return M
