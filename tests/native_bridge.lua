local protocol = dofile('lib/native_bridge_protocol.lua')
local exporter = dofile('lib/native_click_export.lua')
local function fixture(numerator, denominator, ramp)
    local step = 4 / denominator
    local function to_time(q) return ramp and q*q or q*0.4 end
    local function to_q(t) return ramp and math.sqrt(t) or t/0.4 end
    return {
        TimeMap2_timeToBeats=function(_, t)
            local b=to_q(t)/step; return b%numerator, math.floor(b/numerator)
        end,
        TimeMap_GetMeasureInfo=function(_, measure)
            local q=measure*numerator*step
            return to_time(q),q,q+numerator*step,numerator,denominator,150
        end,
        TimeMap2_QNToTime=function(_, q) return to_time(q) end,
        TimeMap_GetMetronomePattern=function() return denominator, 'A'..string.rep('B',numerator-1) end,
    }
end
local function collect(api, start, finish, grid)
    return exporter.collect(api, 0, {start=start, finish=finish, name='EP_2'}, grid)
end
local clicks=collect(fixture(2,4),0.4,25.60000001)
assert(#clicks==63 and clicks[1].time==0 and clicks[1].beat==2)
assert(clicks[63].time==24800 and clicks[63].beat==2)
-- Denominator beats in 6/8 are eighth notes, including pickup phase.
clicks=collect(fixture(6,8),0.2,1.4)
assert(#clicks==6 and clicks[1].beat==2 and clicks[6].beat==1)
assert(clicks[2].time==200)
-- Use native nonlinear time conversion; do not flatten ramps to starting BPM.
clicks=collect(fixture(2,4,true),1,9)
assert(#clicks==2 and clicks[1].time==0 and clicks[2].time==3000)
local api=fixture(4,4)
api.TimeMap_GetMetronomePattern=function() return 4,'AB.B' end
assert(not pcall(collect,api,0,1.6))
assert(#collect(api,0,1.6,true)==4)
assert(not pcall(collect,fixture(2,4),1,1))
local request=protocol.parse('version=1\ncommand=ping\nregion=Some%20name%25\n')
assert(request.region=='Some name%')
assert(not pcall(protocol.parse,'version=1\ncommand=ping\ncommand=stop\n'))
assert(not pcall(protocol.parse,'version=1\ncommand=%ZZ\n'))
assert(protocol.json(protocol.array())=='[]')
assert(protocol.json({x='a\nb"'})=='{"x":"a\\u000ab\\u0022"}')
-- Missing explicit permission to open a saved project must not change any tabs.
local switched=0
api.EnumProjects=function(i) if i==-1 or i==0 then return 'existing','/existing.RPP' end end
api.ValidatePtr=function() return true end
api.SelectProjectInstance=function() switched=switched+1 end
api.Main_OnCommand=function() error('Must not open a tab') end
assert(not pcall(exporter.run,api,{project='/missing.RPP',output='/unused'}))
assert(switched==1) -- restores only the original selection
print('PASS: native pickup phases, denominator beats, nonlinear tempo, custom pattern refusal, request validation, tab preservation')
