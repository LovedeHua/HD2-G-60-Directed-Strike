-- Read-only integration of independently reviewed dependencies. No control lease.
local Layout=require('g60.native_observer')
local Authority=require('g60.native_authority')
local Search=require('g60.native_search_context')
local M={}
function M.capture(reader,base,exe,thread,observation,engine)
    for _,address in ipairs({base,exe}) do
        assert(type(address)=='number' and address>=65536 and address<2^47
            and address%4096==0,'module base bound')
    end
    assert(type(thread)=='number' and thread>0 and thread%1==0,'thread ID bound')
    assert(type(observation)=='table' and type(observation.matches)=='table'
        and #observation.matches<=16,'observation bound')
    local guards,total={},0
    local function read(a,n)
        assert(type(a)=='number' and a%1==0 and a>=65536 and a+n<2^47
            and n>0 and n<=16,'readiness read bound')
        total=total+n;assert(total<=512,'readiness budget')
        local b=reader(a,n);assert(type(b)=='string' and #b==n,'short readiness read')
        guards[#guards+1]={a,n,b};return b
    end
    local function pointer(a) return Layout.pointer(read(a,8),0) end
    -- Same read chain as reviewed EXE 0xa3e50, without making a native call.
    local registry=pointer(exe+0x1b135e0)
    local threads=pointer(registry+8)
    local main=pointer(threads)
    local main_thread=Layout.u32(read(main+8,4),0)
    local world=pointer(base+0x3326340)
    local world_completion=Layout.u32(read(base+0x3326e50,4),0)
    local context_busy=read(world+0x78ac018,1):byte(1)
    local context_active=read(world+0x78ac019,1):byte(1)
    local rows={}
    for _,m in ipairs(observation.matches) do
        if m.behavior_id==4 and (m.state==3 or m.state==4) then
            local row={id=m.id,state=m.state,context_available=false}
            assert(type(m.identity_bytes)=='string' and #m.identity_bytes==24,'identity bytes required')
            row.network_index=Layout.u32(m.identity_bytes,16)
            local quiet=main_thread==thread and world_completion==1 and context_busy==0
                and context_active==0
            row.ownership=quiet and Authority.inspect(engine,row.network_index) or
                {local_ownership_observed=false,reason='thread or observed job state not ready',
                 control_allowed=false,native_lifetime_verified=false}
            -- Samples stay bounded even if a mission contains many grenades.
            if quiet and m.state==4 and #rows<4 then
                local ok,context=pcall(Search.capture,reader,base,m,engine)
                if ok then
                    row.context_available=true
                    row.orbit_anchor_id=context.orbit_anchor.id
                    row.orbit_divisor=context.orbit_divisor
                    row.orbit_slot=context.orbit_slot
                    row.path_agent_present=context.path_agent_present
                    row.selection_cleared=context.selection.cleared
                    row.context_bytes=context.bytes_read
                else row.context_error=tostring(context) end
            else row.context_error=not quiet and 'thread or observed job state not ready'
                or m.state==3 and 'state 3: no cancellation needed' or 'per-sample context limit' end
            rows[#rows+1]=row
        end
    end
    for _,g in ipairs(guards) do
        total=total+g[2];assert(total<=512,'readiness budget')
        assert(reader(g[1],g[2])==g[3],'readiness fields changed')
    end
    return {main_thread_id=main_thread,current_thread_id=thread,
        engine_main_thread_observed=main_thread==thread,
        world_job_completion=world_completion,context_job_busy=context_busy,
        context_job_active=context_active,projectiles=rows,bytes_read=total,
        native_lifetime_verified=false,control_allowed=false,filter_enabled=false}
end
return M
