-- Verify event data, allowing only REAPER's observed CCBZ type 2 -> 0 normalization.
local M={}
function M.matches(wanted,actual)
    if wanted==actual then return true,0 end
    if not actual or #wanted~=#actual then return false end
    local ok,equal,count=pcall(function()
        local a,b,normalized=1,1,0
        local parent_message,parent_flags
        while a<=#wanted do
            local da,fa,ma,db,fb,mb
            da,fa,ma,a=string.unpack('<i4Bs4',wanted,a)
            db,fb,mb,b=string.unpack('<i4Bs4',actual,b)
            if da~=db or fa~=fb then return false end
            if ma~=mb then
                -- REAPER 7.83 drops type 2 when ingesting existing Bezier
                -- metadata. Native proof: identical stored chunks and every
                -- MIDI_GetCCShape result for both original and optimized buffers.
                local attached=parent_message and #parent_message==3
                    and parent_message:byte(1)&240==176 and parent_flags>>4==5
                if not (attached and da==0 and #ma==12 and #mb==12
                    and ma:sub(1,7)=='\255\15CCBZ ' and mb:sub(1,7)==ma:sub(1,7)
                    and ma:byte(8)==2 and mb:byte(8)==0 and ma:sub(9)==mb:sub(9)) then return false end
                normalized=normalized+1
            end
            parent_message,parent_flags=ma,fa
        end
        return b==#actual+1,normalized
    end)
    return ok and equal or false,count
end
local function hex(value)
    return (value:gsub('.',function(c) return string.format('%02X ',c:byte()) end)):sub(1,160)
end
local function event_at(data,byte)
    local pos,tick,index=1,0,0
    while pos<=#data do
        local start=pos
        local delta,flags,msg
        delta,flags,msg,pos=string.unpack('<i4Bs4',data,pos)
        tick=tick+delta; index=index+1
        if pos>byte then return string.format('event %d, tick %d, flags 0x%02X, message %s (byte %d)',index,tick,flags,hex(msg),start) end
    end
    return 'end of buffer'
end
function M.describe(wanted,actual)
    if not actual then return 'REAPER could not read the applied MIDI.' end
    local byte=1
    while byte<=math.min(#wanted,#actual) and wanted:byte(byte)==actual:byte(byte) do byte=byte+1 end
    local a,b=pcall(event_at,wanted,byte)
    local c,d=pcall(event_at,actual,byte)
    return string.format('Buffer lengths: expected %d, read back %d; first difference at byte %d.\nExpected: %s\nRead back: %s',
        #wanted,#actual,byte,a and b or 'unparseable event',c and d or 'unparseable event')
end
function M.failure(api,target,actual)
    local _,name=api.GetSetMediaItemTakeInfo_String(target.take,'P_NAME','',false)
    local report='MIDI verification failed after applying result.\nTake: '..name..'\n'..M.describe(target.after,actual)
    local ok,path=pcall(function()
        if not api.GetResourcePath or not actual then return end
        local directory=api.GetResourcePath()..'/Data/GPhil/CC-diagnostics'
        api.RecursiveCreateDirectory(directory,0)
        local prefix=directory..'/'..os.date('%Y%m%d_%H%M%S')..'_'..tostring(math.floor(api.time_precise()*1000))
        for suffix,data in pairs({ original=target.before, expected=target.after, actual=actual, report=report }) do
            local file=assert(io.open(prefix..'.'..suffix,'wb')); assert(file:write(data)); assert(file:close())
        end
        return prefix
    end)
    return report..(ok and path and ('\nLocal diagnostic files: '..path..'.*') or '')
end
return M
