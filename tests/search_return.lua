-- SYNTHETIC adapter only. No game connection or native function execution.
package.path='./src/?.lua;'..package.path
local Filter=require('g60.small_filter')
local Controller=require('g60.search_return')
local U=require('g60.util')
local passed,failed=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name)
    else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function ref(id,gen,scene) return {id=id,generation=gen or 'SYNTHETIC',scene=scene or 'fixture'} end
local function fixture()
    local s={resource='8e325c933e55bf62',behavior_id=4,ref=ref('547'),state=4,
        active=true,expired=false,complete=true,aliased=false,scores_current=true,
        selected={ref=ref('521'),resource='be39e313a1e46bb9'},
        candidates={
            {ref=ref('521'),resource='be39e313a1e46bb9',score=0.003750000149011612},
            {ref=ref('525'),resource='51eea86bf6997e4e',score=0.002624999964609742},
        }}
    local lease={snapshot=s,authority=true,lifetime=true,callsite=true,
        phase='after_behavior_update',
        token='synthetic-callback-1',timer_bytes='original-start',deadline_bytes='original-expiry'}
    local a={lease=lease,calls=0,operations={}}
    function a:acquire() return self.lease end
    function a:apply(l,plan)
        self.calls=self.calls+1;self.operations[#self.operations+1]=plan
        return {status='applied',token=l.token,timer_bytes=l.timer_bytes,
            deadline_bytes=l.deadline_bytes,state=l.snapshot.state,movement_updated=true,
            transitions_used=false,selection_cleared=plan.kind=='search',target=U.ref(plan.target)}
    end
    return Controller.new(a),a,s
end
test('recorded two-small-enemy scores require search plus movement update',function()
    local c,a,s=fixture();local p,status=c:step(s.ref)
    assert(p.kind=='search' and status=='SEARCH_MOVEMENT_APPLIED')
    assert(a.calls==1 and a.operations[1].clear_selection==true)
end)
test('no adapter cannot activate filtering',function()
    local c=Controller.new();local p,status=c:step(ref('547'))
    assert(p==nil and status=='RUNTIME_ADAPTER_UNAVAILABLE')
end)
test('Lua after-update is not an after-behavior lease',function()
    local c,a,s=fixture();a.lease.phase='before_native_update'
    local p,reason=c:step(s.ref)
    assert(p==nil and reason=='WRONG_CONTROL_PHASE' and a.calls==0)
end)
test('unknown phase cannot rank cached scores',function()
    local c,a,s=fixture();a.lease.phase=nil
    assert(c:step(s.ref)==nil and a.calls==0)
end)
test('no current target leaves vanilla search alone on first observation',function()
    local c,a,s=fixture();s.selected=nil
    local p=c:step(s.ref);assert(p.kind=='keep' and a.calls==0)
end)
test('search continues updating movement after clearing selection',function()
    local c,a,s=fixture();c:step(s.ref);s.selected=nil
    local p=c:step(s.ref)
    assert(p.kind=='search' and a.calls==2 and a.operations[2].clear_selection==false)
end)
test('allowed vanilla target releases custom search',function()
    local c,a,s=fixture();c:step(s.ref)
    s.selected={ref=ref('900'),resource='0000000000000001'}
    local p=c:step(s.ref);assert(p.kind=='keep' and a.calls==1 and next(c.searching)==nil)
end)
test('mixed candidates select positive allowed score with first tie preserved',function()
    local c,a,s=fixture()
    s.candidates[3]={ref=ref('900'),resource='0000000000000001',score=0.1}
    s.candidates[4]={ref=ref('901'),resource='0000000000000002',score=0.1}
    local p=c:step(s.ref);assert(p.kind=='retarget' and p.target.id=='900')
    assert(a.operations[1].kind=='retarget')
end)
test('negative observed score cannot clear a target',function()
    local c,a,s=fixture();s.candidates[1].score=-1
    local p,status=c:step(s.ref);assert(p==nil and status=='SCORE_NOT_READY' and a.calls==0)
end)
test('freshness is not inferred from a positive score',function()
    local c,a,s=fixture();s.scores_current=false
    local p,status=c:step(s.ref);assert(p==nil and status=='STALE_SCORES' and a.calls==0)
end)
for _,field in ipairs({'authority','lifetime','callsite'}) do
    test('missing '..field..' evidence prevents backend execution',function()
        local c,a,s=fixture();a.lease[field]=false
        assert(c:step(s.ref)==nil and a.calls==0)
    end)
end
test('despawn generation mismatch never follows an old lease',function()
    local c,a,s=fixture();assert(c:step(ref('547','REUSED'))==nil and a.calls==0)
end)
test('expired projectile leaves original expiration untouched',function()
    local c,a,s=fixture();s.expired=true
    local p,status=c:step(s.ref);assert(p==nil and status=='INACTIVE' and a.calls==0)
end)
test('duplicate or sparse candidates do not produce a command',function()
    local c,a,s=fixture();s.candidates[2].ref=ref('521')
    assert(c:step(s.ref)==nil and a.calls==0)
    c,a,s=fixture();s.candidates[4]=s.candidates[2];s.candidates[2]=nil
    assert(c:step(s.ref)==nil and a.calls==0)
end)
test('stale callback with no mutation can retry after fresh acquisition',function()
    local c,a,s=fixture();local original=a.apply
    a.apply=function() return {status='stale',mutated=false} end
    local p,status=c:step(s.ref);assert(p==nil and status=='STALE_LEASE' and not c.disabled)
    a.apply=original;assert(c:step(s.ref).kind=='search')
end)
test('clear-only backend is rejected and not retried',function()
    local c,a,s=fixture();local original=a.apply
    a.apply=function(self,l,p) local r=original(self,l,p);r.movement_updated=false;return r end
    local p,status=c:step(s.ref);assert(p==nil and status=='CONTROL_POSTCONDITION_FAILED')
    c:step(s.ref);assert(c.disabled and a.calls==1)
end)
test('resetting the native flight timer disables further writes',function()
    local c,a,s=fixture();local original=a.apply
    a.apply=function(self,l,p)
        local r=original(self,l,p)
        l.timer_bytes='new-start';r.timer_bytes='new-start' -- includes mutated lease regression
        return r
    end
    assert(c:step(s.ref)==nil and c.disabled)
end)
test('state transition backend is refused',function()
    local c,a,s=fixture();local original=a.apply
    a.apply=function(self,l,p) local r=original(self,l,p);r.transitions_used=true;return r end
    assert(c:step(s.ref)==nil and c.disabled)
end)
test('partial failure disables further operations',function()
    local c,a,s=fixture()
    a.apply=function(self) self.calls=self.calls+1;error('partial native operation') end
    assert(c:step(s.ref)==nil and c.disabled);c:step(s.ref);assert(a.calls==1)
end)
test('release and scene change discard old search state',function()
    local c,a,s=fixture();c:step(s.ref);c:release(s.ref);s.selected=nil
    assert(c:step(s.ref).kind=='keep')
    c,a,s=fixture();c:step(s.ref)
    s.ref=ref('547','SYNTHETIC','new-scene');s.selected=nil
    assert(c:step(s.ref).kind=='keep' and next(c.searching)==nil)
end)
test('other weapons cannot execute the control operation',function()
    local c,a,s=fixture();s.resource='2d398d1ec35e0838';s.behavior_id=621
    assert(c:step(s.ref)==nil and a.calls==0)
end)
print(string.format('RESULT %d passed; %d failed (synthetic adapter, no native calls)',passed,failed))
if failed>0 then os.exit(1) end
