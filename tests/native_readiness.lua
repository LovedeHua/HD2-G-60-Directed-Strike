package.path='./src/?.lua;'..package.path
local module=require('g60.native_readiness')
local Observer=require('g60.native_observer')
local function bytes(n,size)
    local out={};for i=1,size do out[i]=string.char(n%256);n=math.floor(n/256) end
    return table.concat(out)
end
local function fixture()
    local base,exe=0x10000000,0x20000000
    local memory={}
    local function put(a,n,size) memory[a]=bytes(n,size) end
    put(exe+0x1b135e0,0x50000000,8);put(0x50000008,0x50001000,8)
    put(0x50001000,0x50002000,8);put(0x50002008,328,4)
    put(base+0x3326340,0x60000000,8);put(base+0x3326e50,1,4)
    put(0x60000000+0x78ac018,0,1);put(0x60000000+0x78ac019,0,1)
    local function read(a,n) assert(memory[a] and #memory[a]==n,'missing fixture bytes');return memory[a] end
    return {base=base,exe=exe,read=read,put=put,memory=memory}
end
local passed=0
local function test(name,fn) local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1 end
test('joined observations never grant lifetime',function()
    local f=fixture();local r=module.capture(f.read,f.base,f.exe,328,{matches={}},nil)
    assert(r.engine_main_thread_observed and r.world_job_completion==1 and r.context_job_busy==0)
    assert(not r.native_lifetime_verified and not r.control_allowed and not r.filter_enabled)
end)
test('different thread and busy context retained',function()
    local f=fixture();f.put(0x60000000+0x78ac018,1,1);f.put(f.base+0x3326e50,0,4)
    local r=module.capture(f.read,f.base,f.exe,99,{matches={}},nil)
    assert(not r.engine_main_thread_observed and r.context_job_busy==1 and r.world_job_completion==0)
end)
test('registry change rejects full readiness sample',function()
    local f=fixture();local count=0
    local function read(a,n)
        if a==f.exe+0x1b135e0 then count=count+1;if count==2 then return bytes(0x50004000,8) end end
        return f.read(a,n)
    end
    local ok,why=pcall(module.capture,read,f.base,f.exe,328,{matches={}},nil)
    assert(not ok and tostring(why):find('fields changed',1,true))
end)
test('ownership uses network index and missing context does not lose result',function()
    local f=fixture();local session={};local queries=0
    local engine={Network={game_session=function() return session end},GameSession={}}
    engine.GameSession.game_object_exists=function(s,id) assert(s==session and id==37);queries=queries+1;return true end
    engine.GameSession.game_object_owned=function(s,id) assert(s==session and id==37);queries=queries+1;return true end
    local identity=bytes(0,8)..bytes(547,4)..bytes(12,4)..bytes(37,4)..bytes(0,4)
    local r=module.capture(f.read,f.base,f.exe,328,{matches={{id=547,state=4,behavior_id=4,
        identity_bytes=identity,index=0,record_bytes=string.rep('\0',0x1f8)}}},engine)
    local m=r.projectiles[1]
    assert(m.network_index==37 and m.ownership.local_ownership_observed and queries==4)
    assert(not m.context_available and m.context_error and not r.control_allowed)
end)
test('invalid network index does not call engine',function()
    local f=fixture();local identity=string.rep('\0',16)..bytes(0xffff,4)..bytes(0,4)
    local r=module.capture(f.read,f.base,f.exe,328,{matches={{id=1,state=3,behavior_id=4,
        identity_bytes=identity}}},{})
    assert(not r.projectiles[1].ownership.local_ownership_observed)
end)
test('wrong thread or busy worker prevents engine ownership queries',function()
    for _,case in ipairs({{thread=99,busy=0},{thread=328,busy=1}}) do
        local f=fixture();f.put(0x60000000+0x78ac018,case.busy,1)
        local identity=string.rep('\0',16)..bytes(37,4)..bytes(0,4)
        local calls=0
        local engine={Network={game_session=function() calls=calls+1;error('must not query') end},GameSession={}}
        local r=module.capture(f.read,f.base,f.exe,case.thread,{matches={{id=1,state=4,
            behavior_id=4,identity_bytes=identity}}},engine)
        assert(calls==0 and not r.projectiles[1].context_available)
        assert(not r.projectiles[1].ownership.local_ownership_observed)
    end
end)
test('short read and excess matches are rejected',function()
    local f=fixture();assert(not pcall(module.capture,function() return '' end,f.base,f.exe,328,{matches={}},nil))
    local matches={};for i=1,17 do matches[i]={} end
    assert(not pcall(module.capture,f.read,f.base,f.exe,328,{matches=matches},nil))
end)
print('RESULT '..passed..' passed; 0 failed')
