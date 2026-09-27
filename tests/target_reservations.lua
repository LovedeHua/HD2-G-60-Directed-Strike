package.path='src/?.lua;'..package.path
local R=require('g60.target_reservations')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function id(n,g,flags) return string.rep('r',8)..string.char(n,0,0,0,g or 0)..string.rep('\0',7)..string.char(flags or 1,0,0,0) end
local function match(n,g,flags) return {identity_bytes=id(n,g,flags),state=4,flight_start='0000000000100000'} end
local a,b=R.owner(match(1)),R.owner(match(2))
test('one owner excludes competing grenades and may continue its own target',function()
    local r=R.new();r:claim(a,id(10));assert(r:available(a,id(10)) and not r:available(b,id(10)))
    assert(not pcall(r.claim,r,b,id(10)));assert(r:available(b,id(11)))
end)
test('guidance state, timer and activity flag changes do not imply projectile disappearance',function()
    local r=R.new();r:claim(a,id(10));local m=match(1,0,3);m.state=5;m.flight_start='new timer'
    r:reconcile({m,match(2)});assert(not r:available(b,id(10,0,3)))
end)
test('a complete observation frees missing projectiles but preserves surviving owners',function()
    local r=R.new();r:claim(a,id(10));r:claim(b,id(11));r:reconcile({match(2)})
    assert(r:available(b,id(10)) and not r:available(a,id(11)))
end)
test('entity generation reuse releases old owner and does not alias a new target',function()
    local r=R.new();r:claim(a,id(10));assert(r:available(b,id(10,1)))
    r:reconcile({match(1,1),match(2)});assert(r:available(b,id(10)))
end)
test('previously claimed targets remain occupied until their grenade disappears',function()
    local r=R.new();r:claim(a,id(10));r:claim(a,id(11));r:reconcile({match(1),match(2)})
    assert(not r:available(b,id(10)) and not r:available(b,id(11)))
    r:reconcile({match(2)});assert(r:available(b,id(10)) and r:available(b,id(11)))
end)
test('scene reset drops old claims',function()
    local r=R.new();r:claim(a,id(10));r:reset();assert(r:available(b,id(10)))
end)
print('RESULT '..passed..' passed; 0 failed (target reservation lifecycle)')
