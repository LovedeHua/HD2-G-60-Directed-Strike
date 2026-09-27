package.path='src/?.lua;'..package.path
local Memory=require('g60.ping_memory')
local Policy=require('g60.target_policy')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function mark(id,slot,age)
    return {id=id,identity='entity-'..id,unit=id,slot=slot,token=slot..':'..id,age=age or 0}
end
local function update(m,second,marks,valid,scene)
    return m:update({scene=scene or 'world',time=string.format('%016x',second*1000000),marks=marks},valid or function() return true end)
end
local function ids(value)
    local out={};for _,v in ipairs(value and value.queue or {}) do out[#out+1]=tostring(v.id) end;return table.concat(out,',')
end
test('A then B then C remembers C B A after all UI markers disappear',function()
    local m=Memory.new()
    assert(ids(update(m,1,{mark(1,0)}))=='1')
    assert(ids(update(m,2,{mark(2,1)}))=='2,1')
    assert(ids(update(m,3,{mark(3,2)}))=='3,2,1')
    local result=update(m,99999,{});assert(ids(result)=='3,2,1' and not result.current)
    for _,r in ipairs(result.queue) do assert(not r.current) end
end)
test('first observation orders by mark time and ring ties follow newest ring entry',function()
    local m=Memory.new();assert(ids(update(m,10,{mark(1,126,3),mark(2,127,1),mark(3,0,0)}))=='3,2,1')
    m=Memory.new();assert(ids(update(m,10,{mark(1,127),mark(2,0)}))=='2,1')
end)
test('unchanged visible older mark cannot leapfrog newer remembered mark',function()
    local m=Memory.new();update(m,1,{mark(1,0)})
    update(m,2,{mark(1,0,1),mark(2,1)})
    assert(ids(update(m,3,{mark(1,0,2)}))=='2,1')
    -- A delayed old record of the same enemy must not replace its later ping.
    assert(ids(update(m,4,{mark(2,2,4)}))=='2,1')
end)
test('re-marking older target promotes it without duplicate entries',function()
    local m=Memory.new();update(m,1,{mark(1,0)});update(m,2,{mark(2,1)})
    assert(ids(update(m,3,{mark(1,2)}))=='1,2')
    update(m,4,{mark(1,2,1),mark(2,1,2)})
    assert(ids(update(m,5,{mark(2,1,0)}))=='2,1')
end)
test('forgetting newest reveals older marks without resurrecting its unchanged ring row',function()
    local m=Memory.new();update(m,1,{mark(1,0)});update(m,2,{mark(2,1)})
    m:forget('entity-2');assert(ids(update(m,3,{mark(2,1,1)}))=='1')
    assert(ids(update(m,4,{mark(2,1,0)}))=='2,1')
    m:forget('entity-1');assert(ids(update(m,5,{}))=='2')
end)
test('invalid and recycled identities are pruned; world changes and rewind reset history',function()
    local m=Memory.new();update(m,1,{mark(1,0)});update(m,2,{mark(2,1)})
    assert(ids(update(m,3,{},function(v) return v.id~=2 end))=='1')
    assert(update(m,4,{},nil,'new-world')==nil)
    update(m,5,{mark(3,0)});assert(update(m,2,{})==nil)
end)
test('bounded history retains the newest 32 distinct entities',function()
    local m=Memory.new();local result
    for i=1,40 do result=update(m,i,{mark(i,i%128)}) end
    assert(#result.queue==32 and result.queue[1].id==40 and result.queue[32].id==9)
    result.queue[1].identity='changed';result.queue[2].id=1000
    result=update(m,41,{});assert(result.queue[1].identity=='entity-40' and result.queue[2].id==39)
end)
test('older remembered mark beats automatic rank when newest mark is absent from candidates',function()
    local m=Memory.new();update(m,1,{mark(1,0)});update(m,2,{mark(2,1)})
    local history=update(m,3,{})
    local charger={entity={identity='entity-1',resource='1a7fcdff98c664b0'},score=1}
    local titan={entity={identity='unmarked-titan',resource='9e2e17f2ccccafdd'},score=100}
    local row,why,index=Policy.choose({titan,charger},{[titan.entity.resource]={rank=10},[charger.entity.resource]={rank=40}},history)
    assert(row==charger and why=='REMEMBERED_PING' and index==2)
end)
print('RESULT '..passed..' passed; 0 failed (newest-first persistent mark history)')
