-- Synthetic scheduler and native adapter: never executes game functions.
package.path='./src/?.lua;'..package.path
local Controller=require('g60.search_return')
local Veto=require('g60.selection_veto')
local passed,failed=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name)
    else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function ref(id) return {id=id,scene='synthetic-scene',generation='synthetic-generation'} end
local function fixture()
    local s={ref=ref('547'),resource='8e325c933e55bf62',behavior_id=4,
        state=4,active=true,expired=false,selection_complete=true,
        selected={ref=ref('521'),resource='be39e313a1e46bb9'}}
    local a={calls=0,movement='old-guidance',tick=0,start='unchanged-start',deadline='unchanged-deadline'}
    a.lease={snapshot=s,authority=true,lifetime=true,callsite=true,token='synthetic-1',
        timer_bytes=a.start,deadline_bytes=a.deadline,phase='before_native_update',
        single_behavior_step=true,selection_stable_until_guidance=true}
    function a:acquire() return self.lease end
    function a:apply(l,p)
        self.calls=self.calls+1;assert(p.kind=='search')
        s.selected=nil;self.movement='orbit'
        return {status='applied',token=l.token,timer_bytes=self.start,deadline_bytes=self.deadline,
            state=s.state,movement_updated=true,transitions_used=false,selection_cleared=true}
    end
    -- Reproduces the reviewed order, not a live simulation: guidance first,
    -- reselection second. Native actual step cadence remains unverified.
    function a:native_step(next_selected)
        self.tick=self.tick+1
        if s.selected then self.movement='guidance:'..s.selected.ref.id end
        s.selected=next_selected
        self.lease.token='synthetic-'..(self.tick+1)
    end
    return Controller.new(a,{mode='selected_veto'}),a,s
end
test('ordinary Warrior veto does not read candidate scores',function()
    local c,a,s=fixture();s.candidates=nil;s.scores_current=false
    local p=c:step(s.ref);assert(p.kind=='search' and a.movement=='orbit' and a.calls==1)
end)
test('all eight exact small resources including Hive Guard are vetoed',function()
    for _,resource in ipairs({'51eea86bf6997e4e','9a8a3aae287b230c','aab438596f5e8fd9',
        '72a83e49ced6db3d','3d0e03e2d574e1ca','5ca832447445c0ba','be39e313a1e46bb9',
        'a1f37bf2a40fbde4'}) do
        local c,a,s=fixture();s.selected.resource=resource
        assert(c:step(s.ref).kind=='search' and a.calls==1)
    end
end)
test('Hive Guard exclusion preserves Charger and Brood Commander eligibility',function()
    for _,resource in ipairs({'1a7fcdff98c664b0','d522fd4748d443a5'}) do
        local c,a,s=fixture();s.selected.resource='a1f37bf2a40fbde4'
        assert(c:step(s.ref).kind=='search' and a.calls==1)
        local allowed={ref=ref('900'),resource=resource}
        a:native_step(allowed)
        assert(c:step(s.ref).kind=='keep' and a.calls==1)
        a:native_step(allowed)
        assert(a.movement=='guidance:900' and next(c.searching)==nil)
    end
end)
test('repeated native reselection is vetoed before each synthetic guidance step',function()
    local c,a,s=fixture();local small=s.selected
    for _=1,10 do
        assert(c:step(s.ref).kind=='search');a:native_step(small)
        assert(a.movement=='orbit' and a.start=='unchanged-start' and a.deadline=='unchanged-deadline')
    end
end)
test('native allowed selection resumes guidance with no custom retarget',function()
    local c,a,s=fixture();c:step(s.ref)
    local allowed={ref=ref('900'),resource='0000000000000001'}
    a:native_step(allowed);assert(c:step(s.ref).kind=='keep' and a.calls==1)
    a:native_step(allowed);assert(a.movement=='guidance:900' and next(c.searching)==nil)
end)
test('native state 3 retains original orbit and selection transition',function()
    local c,a,s=fixture();s.state=3
    assert(c:step(s.ref).kind=='keep' and a.calls==0)
end)
test('empty selection after a veto still replaces the movement point',function()
    local c,a,s=fixture();c:step(s.ref);a.movement='old-point'
    assert(c:step(s.ref).kind=='search' and a.calls==2 and a.movement=='orbit')
end)
test('unreadable selection cannot be treated as an empty target',function()
    local c,a,s=fixture();s.selected=nil;s.selection_complete=false
    assert(c:step(s.ref)==nil and a.calls==0)
end)
test('lost target with a stale guidance flag requires clearing again',function()
    local c,a,s=fixture();c:step(s.ref)
    s.selection_cleared=false
    local original=a.apply
    function a:apply(l,p) assert(p.clear_selection==true);return original(self,l,p) end
    assert(c:step(s.ref).kind=='search' and a.calls==2)
end)
test('only verified cleared fields can skip the NULL setter during continued search',function()
    local c,a,s=fixture();c:step(s.ref);s.selection_cleared=true
    local original=a.apply
    function a:apply(l,p) assert(p.clear_selection==false);return original(self,l,p) end
    assert(c:step(s.ref).kind=='search' and a.calls==2)
end)
for _,field in ipairs({'single_behavior_step','selection_stable_until_guidance','authority','lifetime','callsite'}) do
    test('missing '..field..' proof prevents calls',function()
        local c,a,s=fixture();a.lease[field]=false
        assert(c:step(s.ref)==nil and a.calls==0)
    end)
end
test('after-behavior lease cannot execute the pre-guidance policy',function()
    local c,a,s=fixture();a.lease.phase='after_behavior_update'
    local p,reason=c:step(s.ref)
    assert(p==nil and reason=='UNVERIFIED_GUIDANCE_WINDOW' and a.calls==0)
end)
test('two native substeps demonstrate why one-step proof is required',function()
    local c,a,s=fixture();local small=s.selected
    c:step(s.ref);a:native_step(small);a:native_step(small)
    assert(a.movement=='guidance:521') -- counterexample, never a passing gameplay claim
    c,a,s=fixture();a.lease.single_behavior_step=false
    assert(c:step(s.ref)==nil and a.calls==0)
end)
test('expired projectile never refreshes orbit or deadline',function()
    local c,a,s=fixture();s.expired=true
    assert(c:step(s.ref)==nil and a.calls==0 and a.deadline=='unchanged-deadline')
end)
test('unknown variants retain vanilla behavior',function()
    local c,a,s=fixture();s.selected.resource='0123456789abcdef'
    assert(c:step(s.ref).kind=='keep' and a.calls==0)
end)
test('other weapons and scene mismatches cannot be vetoed',function()
    local c,a,s=fixture();s.resource='2d398d1ec35e0838';s.behavior_id=621
    assert(c:step(s.ref)==nil and a.calls==0)
    c,a,s=fixture();s.selected.ref.scene='another-scene'
    assert(c:step(s.ref)==nil and a.calls==0)
end)
test('unsupported mode never silently uses the ranker',function()
    local _,a,s=fixture();local c=Controller.new(a,{mode='typo'})
    assert(c:step(s.ref)==nil and a.calls==0)
end)
print(string.format('RESULT %d passed; %d failed (synthetic scheduling only)',passed,failed))
if failed>0 then os.exit(1) end
