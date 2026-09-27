package.path='./src/?.lua;'..package.path
local Authority=require('g60.native_authority')
local passed,failed=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name)
    else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function fixture()
    local f={session={},exist_calls=0,owned_calls=0,session_calls=0,ids={}}
    f.engine={Network={},GameSession={}}
    f.engine.Network.game_session=function()
        f.session_calls=f.session_calls+1;return f.session
    end
    f.engine.GameSession.game_object_exists=function(session,id)
        assert(session==f.session);f.exist_calls=f.exist_calls+1
        f.ids[#f.ids+1]=id;return true
    end
    f.engine.GameSession.game_object_owned=function(session,id)
        assert(session==f.session);f.owned_calls=f.owned_calls+1
        f.ids[#f.ids+1]=id;return true
    end
    function f.inspect(id) return Authority.inspect(f.engine,id or 77) end
    return f
end
test('local network ownership never grants control or lifetime',function()
    local f=fixture();local r=f.inspect()
    assert(r.local_ownership_observed and not r.control_allowed and not r.native_lifetime_verified)
    assert(f.exist_calls==2 and f.owned_calls==2 and f.session_calls==3)
    for _,id in ipairs(f.ids) do assert(id==77) end
end)
test('missing object never enters unsafe native owner lookup',function()
    local f=fixture();f.engine.GameSession.game_object_exists=function() return false end
    assert(not f.inspect().local_ownership_observed and f.owned_calls==0)
end)
test('remote ownership refused',function()
    local f=fixture();f.engine.GameSession.game_object_owned=function() return false end
    assert(not f.inspect().local_ownership_observed)
end)
test('ownership migration during query refused',function()
    local f=fixture();local n=0
    f.engine.GameSession.game_object_owned=function() n=n+1;return n==1 end
    assert(not f.inspect().local_ownership_observed and n==2)
end)
test('object disappearing skips second owner lookup',function()
    local f=fixture();local n=0
    f.engine.GameSession.game_object_exists=function() n=n+1;return n==1 end
    assert(not f.inspect().local_ownership_observed and f.owned_calls==1)
end)
test('session replacement during query refused',function()
    local f=fixture();local n=0
    f.engine.Network.game_session=function() n=n+1;return n==1 and f.session or {} end
    assert(not f.inspect().local_ownership_observed and f.owned_calls==1)
end)
test('no session never accesses object API',function()
    local f=fixture();f.session=nil
    assert(not f.inspect().local_ownership_observed and f.exist_calls==0)
end)
test('unsupported IDs cause no engine calls',function()
    for _,id in ipairs({-1,0x7fff,0x8000,0xffffffff,1.5,math.huge,0/0,'77'}) do
        local f=fixture();assert(not Authority.inspect(f.engine,id).local_ownership_observed)
        assert(f.session_calls==0)
    end
end)
test('missing API and exceptions fail closed',function()
    assert(not Authority.inspect(nil,77).local_ownership_observed)
    local f=fixture();f.engine.GameSession.game_object_owned=nil
    assert(not f.inspect().local_ownership_observed and f.session_calls==0)
    f=fixture();f.engine.GameSession.game_object_owned=function() error('unavailable') end
    assert(not f.inspect().local_ownership_observed)
end)
test('numeric truthy API results do not become ownership proof',function()
    local f=fixture();f.engine.GameSession.game_object_exists=function() return 1 end
    assert(not f.inspect().local_ownership_observed and f.owned_calls==0)
    f=fixture();f.engine.GameSession.game_object_owned=function() return 1 end
    assert(not f.inspect().local_ownership_observed)
end)
print(string.format('RESULT %d passed; %d failed',passed,failed))
if failed>0 then os.exit(1) end
