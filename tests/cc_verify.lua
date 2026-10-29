local verify=dofile('lib/cc_verify.lua')
local function event(delta,flags,msg) return string.pack('<i4Bs4',delta,flags,msg) end
local a=event(10,0,string.char(176,11,40))..event(20,16,string.char(176,11,70))
local b=event(10,0,string.char(176,11,40))..event(20,16,string.char(176,11,71))
local result=verify.describe(a,b)
assert(result:find('event 2, tick 30',1,true) and result:find('B0 0B 46',1,true) and result:find('B0 0B 47',1,true))
assert(verify.describe(a,a:sub(1,12)):find('end of buffer',1,true))
assert(verify.describe(a,nil):find('could not read',1,true))
local function curve(kind,tension,parent,flags,delta)
    return event(10,flags or 80,parent or string.char(176,22,75))
        ..event(delta or 0,0,'\255\15CCBZ '..string.char(kind)..string.pack('<f',tension or -.0625))
end
local original,normalized=curve(2),curve(0)
local matched,count=verify.matches(original,normalized)
assert(matched and count==1)
assert(verify.matches(original,original))
assert(not verify.matches(normalized,original)) -- Only observed normalization direction.
assert(not verify.matches(curve(1),normalized))
assert(not verify.matches(curve(3),normalized))
assert(not verify.matches(original,curve(0,.5))) -- Tension remains exact.
assert(not verify.matches(original,curve(0,nil,string.char(176,22,76))))
assert(not verify.matches(curve(2,nil,nil,16),curve(0,nil,nil,16))) -- Linear parent.
assert(not verify.matches(curve(2,nil,string.char(144,60,90)),curve(0,nil,string.char(144,60,90))))
assert(not verify.matches(curve(2,nil,nil,nil,1),curve(0,nil,nil,nil,1))) -- Detached metadata.
assert(not verify.matches(a,b))
assert(not verify.matches(original,normalized:sub(1,-2)))
assert(not verify.matches(original,nil))
print('CC verification: exact first differing event, ticks, flags, message, truncation and read failure passed')
print('CC Bezier verification: only attached type 2 -> 0 accepted; tension, values, timing and other types remain strict')
