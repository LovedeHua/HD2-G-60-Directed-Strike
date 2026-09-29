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
-- ★★★ 裁剪 E：上游这张 test 套件原本断言"8 种小虫 + Hive Guard + Impaler 触手会被 veto"。
--   本工程要求"未标记虫洞时完全按游戏原生处理"，所以：
--     · small_filter.excluded 已整表清空（见 src/g60/small_filter.lua 顶部）
--     · designed_targets_only=false ⇒ env.target_allowed=nil ⇒ `not allowed` 恒真
--   两者合起来 ⇒ selection_veto.plan() 对**任何**敌人选择都返回 keep，永不进入 search。
--   下面三条把这个行为钉死，同时确认"放宽的只是目标筛选，安全校验一条没松"。
local EXCLUDED_UPSTREAM = {
    '51eea86bf6997e4e','9a8a3aae287b230c','aab438596f5e8fd9','72a83e49ced6db3d',
    '3d0e03e2d574e1ca','5ca832447445c0ba','be39e313a1e46bb9',
    '672f7da17f3ba34a','a1f37bf2a40fbde4'}
test('bughole-only fork never vetoes any enemy selection',function()
    for _,resource in ipairs(EXCLUDED_UPSTREAM) do
        local c,a,s=fixture();s.selected.resource=resource
        assert(c:step(s.ref).kind=='keep' and a.calls==0)
    end
    -- 普通敌人与未知变体同样保持原生
    for _,resource in ipairs({'0123456789abcdef','1a7fcdff98c664b0'}) do
        local c,a,s=fixture();s.selected.resource=resource
        assert(c:step(s.ref).kind=='keep' and a.calls==0)
    end
end)
test('bughole-only fork keeps native guidance and never enters search',function()
    local c,a,s=fixture()
    assert(c:step(s.ref).kind=='keep' and a.calls==0 and a.movement=='old-guidance')
    for _=1,10 do
        a:native_step(s.selected)
        assert(c:step(s.ref).kind=='keep' and a.calls==0)
        assert(a.movement=='guidance:521' and next(c.searching)==nil)
    end
end)
test('bughole-only fork keeps every scope and lifetime proof',function()
    -- 上面的放宽只针对"目标筛选"；下列拒绝路径必须原样生效
    local c,a,s=fixture();s.selected=nil;s.selection_complete=false
    assert(c:step(s.ref)==nil and a.calls==0)
    c,a,s=fixture();s.expired=true
    assert(c:step(s.ref)==nil and a.calls==0 and a.deadline=='unchanged-deadline')
    c,a,s=fixture();s.active=false
    assert(c:step(s.ref)==nil and a.calls==0)
    for _,field in ipairs({'single_behavior_step','selection_stable_until_guidance',
                           'authority','lifetime','callsite'}) do
        c,a,s=fixture();a.lease[field]=false
        assert(c:step(s.ref)==nil and a.calls==0)
    end
end)
test('native allowed selection resumes guidance with no custom retarget',function()
    -- 裁剪版：candidates 里出现新的选择时同样不 retarget、不进 search（a.calls 保持 0）
    local c,a,s=fixture();c:step(s.ref)
    local allowed={ref=ref('900'),resource='0000000000000001'}
    a:native_step(allowed);assert(c:step(s.ref).kind=='keep' and a.calls==0)
    a:native_step(allowed);assert(a.movement=='guidance:900' and next(c.searching)==nil)
end)
test('native state 3 retains original orbit and selection transition',function()
    local c,a,s=fixture();s.state=3
    assert(c:step(s.ref).kind=='keep' and a.calls==0)
end)
test('unreadable selection cannot be treated as an empty target',function()
    local c,a,s=fixture();s.selected=nil;s.selection_complete=false
    assert(c:step(s.ref)==nil and a.calls==0)
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
    local c,a,s=fixture()
    c:step(s.ref);a:native_step(s.selected);a:native_step(s.selected)
    -- 裁剪版保持 guidance（不再被 veto 打断），但 one-step 证明缺失时依然拒绝调用
    assert(a.movement=='guidance:521')
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
