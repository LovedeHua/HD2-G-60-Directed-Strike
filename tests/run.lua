package.path = './src/?.lua;./tests/?.lua;' .. package.path
local F = require('fixture')
local U = require('g60.util')
local passed,failed=0,0
local function eq(a,b) assert(a==b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1; print('PASS ' .. name)
    else failed=failed+1; print('FAIL ' .. name .. ': ' .. tostring(err)) end
end
local function selected(c,p,id,reason)
    local d,s=c:step(p or F.projectile()); assert(d,s); eq(d.target.id,id)
    if reason then eq(d.reason,reason) end
    return d
end
test('automatic ordering exhausts all four priorities',function()
    local a,c=F.new()
    for _,k in ipairs({'charger','spore_charger','impaler','bile_titan'}) do a:add(k,k) end
    for i,k in ipairs({'bile_titan','impaler','spore_charger','charger'}) do
        selected(c,F.projectile(tostring(i)),k)
        a.entities[U.key(F.ref(k))].alive=false
    end
end)
test('marked charger beats titan outside candidate list',function()
    local a,c=F.new(); local ch=a:add('C','charger'); a:add('T','bile_titan')
    a.pool={F.ref('T')}; c:observe_ping('owner-1',ch.ref,true,2)
    selected(c,nil,'C','PLAYER_MARK')
end)
test('marked commander beats titan',function()
    local a,c=F.new(); local e=a:add('C','commander'); a:add('T','bile_titan')
    c:observe_ping('owner-1',e.ref,true,0); selected(c,nil,'C','PLAYER_MARK')
end)
test('commander gets no automatic promotion',function()
    local a,c=F.new(); a:add('C','commander',1); a:add('H','charger',100)
    selected(c,nil,'H')
end)
for _,faction in ipairs({'automaton','illuminate'}) do
    test(faction .. ' marked priority retains vanilla aim',function()
        local a,c=F.new(); local e=a:add('E','tank',3,faction); a:add('T','bile_titan')
        c:observe_ping('owner-1',e.ref,true,1)
        eq(selected(c,nil,'E','PLAYER_MARK').aim.mode,'vanilla')
    end)
end
test('UI disappears before throw and memory has no TTL',function()
    local a,c=F.new(); local e=a:add('C','charger'); a:add('T','bile_titan')
    c:observe_ping('owner-1',e.ref,true,1); c:observe_ping('owner-1',nil,true,99999)
    eq(selected(c,nil,'C').source,'remembered')
end)
test('new valid mark replaces memory',function()
    local a,c=F.new(); local e=a:add('C','charger'); local t=a:add('T','bile_titan')
    c:observe_ping('owner-1',e.ref,true,1); c:observe_ping('owner-1',t.ref,true,2)
    c:observe_ping('owner-1',nil,true,3); selected(c,nil,'T','PLAYER_MARK')
end)
test('invalid mark does not erase valid remembered intent',function()
    local a,c=F.new(); local e=a:add('C','charger')
    c:observe_ping('owner-1',e.ref,true,1); c:observe_ping('owner-1',F.ref('missing'),true,2)
    selected(c,nil,'C','PLAYER_MARK')
end)
test('two owners have independent memories',function()
    local a,c=F.new(); local x=a:add('C','charger'); local y=a:add('T','bile_titan')
    c:observe_ping('owner-1',x.ref,true,1); c:observe_ping('owner-2',y.ref,true,1)
    selected(c,F.projectile('p1'),'C'); selected(c,F.projectile('p2','owner-2'),'T')
end)
test('unreadable ping uses vanilla not automatic priority',function()
    local a,c=F.new(); a:add('T','bile_titan'); local e=a:add('C','charger'); a.vanilla=e.ref
    c:observe_ping('owner-1',nil,false,0); selected(c,nil,'C','VANILLA')
end)
test('unreadable ping does not destroy valid in-flight lock',function()
    local a,c=F.new(); a:add('C','charger'); selected(c,nil,'C')
    a:add('T','bile_titan'); c:observe_ping('owner-1',nil,false,2)
    selected(c,nil,'C'); eq(a.scan_count,1)
end)
test('closer or higher priority newcomers never steal a lock',function()
    local a,c=F.new(); a:add('C','charger',20); selected(c,nil,'C')
    a:add('C2','charger',1); a:add('T','bile_titan',1)
    for i=1,100 do selected(c,nil,'C') end
    eq(a.scan_count,1)
end)
test('new ping affects next grenade and preserves existing grenade',function()
    local a,c=F.new(); local x=a:add('C','charger'); local y=a:add('T','bile_titan')
    c:observe_ping('owner-1',x.ref,true,0); selected(c,nil,'C')
    c:observe_ping('owner-1',y.ref,true,1); selected(c,nil,'C')
    selected(c,F.projectile('second'),'T')
end)
for _,flag in ipairs({'alive','active','exists','targetable'}) do
    test('reacquire after target ' .. flag .. ' becomes false',function()
        local a,c=F.new(); local x=a:add('C','charger'); selected(c,nil,'C')
        x[flag]=false; a:add('T','bile_titan'); selected(c,nil,'T')
    end)
end
for _,flag in ipairs({'destroyed','out_of_range','lost'}) do
    test('reacquire after ' .. flag,function()
        local a,c=F.new(); local x=a:add('C','charger'); selected(c,nil,'C')
        x[flag]=true; a:add('T','bile_titan'); selected(c,nil,'T')
    end)
end
test('entity generation reuse never follows recycled handle',function()
    local a,c=F.new(); local x=a:add('C','charger'); selected(c,nil,'C')
    x.ref.generation='2'; a:add('T','bile_titan'); selected(c,nil,'T')
end)
test('scene transition clears memory and locks',function()
    local a,c=F.new(); local x=a:add('C','charger'); c:observe_ping('owner-1',x.ref,true,0)
    selected(c,nil,'C'); c:set_scene('mission-2')
    eq(next(c.locks),nil); eq(next(c.memory.owners),nil); eq(c:step(F.projectile()),nil)
end)
test('stable tie break regardless of candidate ordering',function()
    local a,c=F.new(); a:add('B','charger',5); a:add('A','charger',5)
    selected(c,nil,'A'); a.pool={F.ref('A'),F.ref('B')}
    selected(c,F.projectile('p2'),'A')
end)
test('native score preferred when every candidate provides one',function()
    local a,c=F.new(); a:add('A','charger',1).score=1; a:add('B','charger',50).score=8
    selected(c,nil,'B')
end)
test('partial native scores use consistent distance ordering',function()
    local a,c=F.new(); a:add('A','charger',1); a:add('B','charger',50).score=8
    selected(c,nil,'A')
end)
test('unmarked hole excluded even from vanilla fallback',function()
    local a,c=F.new(); local h=a:add('H','bug_hole'); a.vanilla=h.ref
    eq(c:step(F.projectile()),nil)
end)
test('marked hole without verified entrance safely falls back',function()
    local a,c=F.new(); local h=a:add('H','bug_hole'); local t=a:add('T','bile_titan'); a.vanilla=t.ref
    c:observe_ping('owner-1',h.ref,true,0); eq(selected(c,nil,'T','VANILLA').aim.mode,'vanilla')
    eq(a.node_calls,0)
end)
test('verified marked hole beats titan and persists after ping expires',function()
    local a,c=F.new({catalog=F.catalog('bug_hole')}); local h=a:add('H','bug_hole')
    h.nodes={['fixture-node']={x=3,y=4,z=5}}; h.alive=false; h.targetable=false
    a:add('T','bile_titan'); c:observe_ping('owner-1',h.ref,true,0)
    c:observe_ping('owner-1',nil,true,1)
    local d=selected(c,nil,'H','PLAYER_MARK_BUG_HOLE'); eq(d.aim.mode,'bug_hole')
    eq(d.aim.position.y,5); h.destroyed=true; selected(c,nil,'T')
end)
test('weakpoint position updates with moving bone and local offset',function()
    local a,c=F.new({catalog=F.catalog('charger')}); local e=a:add('C','charger')
    e.nodes={['fixture-node']={x=2,y=3,z=4}}
    eq(selected(c,nil,'C').aim.position.y,4)
    e.nodes['fixture-node'].y=10; eq(selected(c,nil,'C').aim.position.y,11)
    eq(a.scan_count,1)
end)
test('missing primary node uses verified fallback node then vanilla',function()
    local a,c=F.new({catalog=F.catalog('charger')}); local e=a:add('C','charger')
    e.nodes={['fixture-fallback']={x=1,y=2,z=3}}
    eq(selected(c,nil,'C').aim.node,'fixture-fallback')
    e.nodes={}; eq(selected(c,nil,'C').aim.mode,'vanilla')
end)
for _,field in ipairs({'variant','skeleton','resource'}) do
    test('unknown ' .. field .. ' uses vanilla without node lookup',function()
        local a,c=F.new({catalog=F.catalog('charger')}); local e=a:add('C','charger'); e[field]='unknown'
        eq(selected(c,nil,'C').aim.mode,'vanilla'); eq(a.node_calls,0)
    end)
end
test('unverified profile stays disabled',function()
    local catalog=F.catalog('charger'); catalog.charger.variants['fixture-variant'].validation.status='candidate'
    local a,c=F.new({catalog=catalog}); a:add('C','charger')
    eq(selected(c,nil,'C').aim.mode,'vanilla'); eq(a.node_calls,0)
end)
test('commander weakpoint only applies when marked',function()
    local a,c=F.new({catalog=F.catalog('commander')}); local e=a:add('C','commander')
    e.nodes={['fixture-node']={x=1,y=2,z=3}}; a.vanilla=e.ref
    eq(selected(c,nil,'C').aim.mode,'vanilla'); c:observe_ping('owner-1',e.ref,true,0)
    eq(selected(c,F.projectile('p2'),'C').aim.mode,'weakpoint')
end)
test('nonfinite bone point falls back without changing entity',function()
    local a,c=F.new({catalog=F.catalog('charger')}); local e=a:add('C','charger')
    e.nodes={['fixture-node']={x=0/0,y=1,z=2}}
    eq(selected(c,nil,'C').aim.mode,'vanilla')
end)
test('invalid entity position cannot be selected',function()
    local a,c=F.new(); a:add('T','bile_titan').position.x=math.huge; a:add('C','charger')
    selected(c,nil,'C')
end)
test('aim failure keeps lock and recovers on same entity',function()
    local a,c=F.new(); local e=a:add('C','charger'); selected(c,nil,'C')
    e.vanilla=nil; a:add('T','bile_titan'); eq(c:step(F.projectile()),nil)
    e.vanilla={x=1,y=0,z=1}; selected(c,nil,'C'); eq(a.scan_count,1)
end)
test('other seeker weapons never invoke selection',function()
    local a,c=F.new(); a:add('C','charger'); local p=F.projectile(); p.resource='fixture:spear'
    eq(c:step(p),nil); eq(a.scan_count,0); eq(next(c.locks),nil)
end)
test('adapter exception falls back without escaping',function()
    local a,c=F.new(); local e=a:add('C','charger'); a.vanilla=e.ref
    a.candidates=function() error('fixture failure') end
    selected(c,nil,'C','VANILLA')
end)
test('resolver error leaves vanilla in control',function()
    local a,c=F.new(); a:add('C','charger'); a.resolve=function() error('bad read') end
    eq(c:step(F.projectile()),nil)
end)
test('logger failure cannot break selection',function()
    local a,c=F.new({log=function() error('full disk') end}); a:add('C','charger'); selected(c,nil,'C')
end)
test('logger volume bounded',function()
    local a,c=F.new({log_limit=3}); a:add('C','charger'); selected(c,nil,'C'); eq(#a.events,3)
end)
test('projectile despawn releases all per-projectile state',function()
    local a,c=F.new(); a:add('C','charger'); selected(c,nil,'C'); c:release(F.ref('projectile-1'))
    eq(next(c.locks),nil); eq(next(c.seen),nil)
end)
test('owner departure clears memory and locks',function()
    local a,c=F.new(); a:add('C','charger'); selected(c,nil,'C'); c:forget_owner('owner-1')
    eq(next(c.locks),nil); eq(next(c.memory.owners),nil)
end)
test('no narrowing or rounding of 64-bit entity IDs',function()
    local a,c=F.new(); a:add('18446744073709551614','charger')
    selected(c,nil,'18446744073709551614'); eq(U.ref({id=12,generation='1',scene='s'}),nil)
end)
test('repeated frames do not rescore or grow logs',function()
    local a,c=F.new(); a:add('C','charger'); selected(c,nil,'C'); local n=#a.events
    for i=1,1000 do selected(c,nil,'C') end
    eq(a.scan_count,1); eq(#a.events,n)
end)
test('shutdown reset discards all state',function()
    local a,c=F.new(); a:add('C','charger'); selected(c,nil,'C'); c:reset()
    eq(c.scene,nil); eq(next(c.locks),nil); eq(c:step(F.projectile()),nil)
end)
local Detector = require('g60.detector')
local function identity()
    return {resource=Detector.resource, unit_resource=Detector.resource, behavior_id=4,
        components={throwable=true, explosive=true}}
end
test('G60 configuration identity accepts exact resource and components',function()
    eq(Detector.matches(identity()),true)
    local p=identity(); p.resource=p.resource:upper(); eq(Detector.matches(p),true)
end)
test('G50 resource is excluded even with a G60 behavior ID',function()
    local p=identity(); p.resource='2d398d1ec35e0838'; eq(Detector.matches(p),false)
end)
test('G60 resource alone never proves configuration identity',function()
    eq(Detector.matches({resource=Detector.resource}),false)
    for _,key in ipairs({'unit_resource','behavior_id','components'}) do
        local p=identity(); p[key]=nil; eq(Detector.matches(p),false)
    end
end)
test('changed behavior fails identity without a build-number gate',function()
    local p=identity(); p.behavior_id=621; eq(Detector.matches(p),false)
    p.behavior_id=4; p.build='future'; eq(Detector.matches(p),true)
end)
test('identity never converts lossy numeric resource hashes',function()
    for _,v in ipairs({123, '0x8e325c933e55bf62', '8e325c933e55bf6', 'zz325c933e55bf62'}) do
        local p=identity(); p.resource=v; eq(Detector.matches(p),false)
    end
    eq(Detector.matches(nil),false)
end)
test('missing required native component rejects configuration identity',function()
    for _,key in ipairs({'throwable','explosive'}) do
        local p=identity(); p.components[key]=false; eq(Detector.matches(p),false)
    end
end)
test('real detector can gate core while preserving synthetic world isolation',function()
    local a,c=F.new(); a:add('C','charger')
    a.is_g60=function(_,p) return Detector.matches(p) end
    local p=F.projectile(); for k,v in pairs(identity()) do p[k]=v end
    selected(c,p,'C'); c:release(p.ref)
    p.resource='2d398d1ec35e0838'; eq(c:step(p),nil); eq(next(c.locks),nil)
end)
print(string.format('RESULT %d passed; %d failed (synthetic, no gameplay validation)',passed,failed))
if failed>0 then os.exit(1) end
