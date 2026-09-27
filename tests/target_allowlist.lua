package.path='src/?.lua;'..package.path
local Allowlist=require('g60.target_allowlist')
local Veto=require('g60.selection_veto')
local Policy=require('g60.target_policy')
local titan={resource='9e2e17f2ccccafdd'}
local charger={resource='1a7fcdff98c664b0'}
local dragon={resource='960b48a421a3faaa'}
local profiles={[charger.resource]=charger,[dragon.resource]=dragon}
local allowed=Allowlist.new(titan,profiles)
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('allowlist requires an exact profile and rejects nil, unknowns, variants and small enemies',function()
    assert(allowed(titan.resource) and allowed(charger.resource) and allowed(dragon.resource))
    for _,key in ipairs({'d522fd4748d443a5','ef04cb84d097a497','672f7da17f3ba34a','be39e313a1e46bb9','FFFFFFFFFFFFFFFF',''}) do assert(not allowed(key)) end
    assert(not allowed(nil));profiles['1111111111111111']={resource='1111111111111111'}
    assert(not allowed('1111111111111111'))
    assert(not pcall(Allowlist.new,titan,{[charger.resource]=dragon}))
end)
test('minimal veto clears forbidden native selection and continues orbit while preserving allowed selection',function()
    local s={resource='8e325c933e55bf62',behavior_id=4,state=4,active=true,expired=false,
        ref={id='547',generation='1',scene='test'},selection_complete=true,
        selected={ref={id='526',generation='1',scene='test'},resource='d522fd4748d443a5'}}
    assert(Veto.plan(s,false).kind=='keep')
    assert(Veto.plan(s,false,allowed).kind=='search')
    s.selected.resource=charger.resource;assert(Veto.plan(s,false,allowed).kind=='keep')
    s.selected=nil;s.selection_cleared=true;local r=Veto.plan(s,true,allowed)
    assert(r.kind=='search' and not r.clear_selection)
end)
test('neither mark, lock nor catalog rank can promote an enemy without a custom profile',function()
    local forbidden={entity={resource='ef04cb84d097a497',identity='x'},score=1000}
    local good={entity={resource=charger.resource,identity='y'},score=1}
    local row=Policy.choose({forbidden,good},{[forbidden.entity.resource]={rank=1},[charger.resource]={rank=40}},
        {identity='x',current=true},{identity='x'},allowed)
    assert(row==good)
    local marked=Policy.choose({good,{entity={resource=titan.resource,identity='t'},score=100}},
        {[titan.resource]={rank=10}}, {identity='y',current=true},nil,allowed)
    assert(marked==good)
end)
print('RESULT '..passed..' passed; 0 failed (exact custom-profile target allowlist)')
