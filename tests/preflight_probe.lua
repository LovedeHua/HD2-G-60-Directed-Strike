package.path='./src/?.lua;'..package.path
local Probe=require('g60.preflight_probe')
local passed,failed=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;print('PASS '..name)
    else failed=failed+1;print('FAIL '..name..': '..tostring(err)) end
end
local function fixture(sample,original)
    local calls,closes,lines=0,0,{}
    local previous=original or function(...) calls=calls+1;return nil,7,nil end
    local env={update=previous}
    local s=Probe.install(env,sample,function(line) lines[#lines+1]=line end,function() closes=closes+1 end)
    return env,s,function() return calls,closes,lines,previous end
end
test('80 active observations stop and preserve original nil return values',function()
    local env,s,get=fixture(function() return {line='active',g60_count=1} end)
    for _=1,600 do
        local function check(...) local a,b,c=...;assert(select('#',...)==3 and a==nil and b==7 and c==nil) end
        check(env.update())
    end
    local calls,closes,_,previous=get()
    assert(s.state=='complete' and s.g60_observations==80 and calls==600 and closes==1 and env.update==previous)
end)
test('one short-lived projectile completes after the post-flight grace period',function()
    local env,s=fixture(function(_,frame) return {line='sample',g60_count=frame==15 and 1 or 0} end)
    for _=1,255 do env.update() end
    assert(s.state=='complete' and s.g60_observations==2)
end)
test('loading read failures do not prevent original update or future observations',function()
    local env,s,get=fixture(function(_,frame)
        if frame<=30 then error('scene changing') end
        return {line='valid',g60_count=1}
    end)
    for _=1,630 do env.update() end
    local calls,closes=get()
    assert(calls==630 and closes==1 and s.read_failures==4 and s.state=='complete')
end)
test('idle waiting has a finite frame and log budget',function()
    local env,s,get=fixture(function() return {line='idle',g60_count=0} end)
    for _=1,108000 do env.update() end
    local _,closes,lines=get()
    assert(s.state=='frame_budget_reached' and closes==1 and #lines<100)
end)
test('later mod wrapper is retained when probe stops',function()
    local env,s,get=fixture(function() return {line='idle',g60_count=0} end)
    local wrapper=env.update;local later=function(...) return wrapper(...) end
    env.update=later;s.stop();assert(env.update==later)
    env.update();local calls,closes=get();assert(calls==1 and closes==1)
end)
test('original error identity is preserved and log closes',function()
    local err={};local env,s,get=fixture(function() return {line='idle',g60_count=0} end,function() error(err) end)
    local ok,why=pcall(env.update);local _,closes=get()
    assert(not ok and why==err and s.state=='original_update_error' and closes==1)
end)
print(string.format('RESULT %d passed; %d failed (read-only probe lifecycle)',passed,failed))
if failed>0 then os.exit(1) end
