-- Bounded read-only mission preflight. Does not call a gameplay backend.
local M={}
function M.install(env,sample,emit,close)
    local previous=rawget(env,'update')
    local state={version='0.4.2-native-preflight',filter_enabled=false,frames=0,
        observations=0,g60_observations=0,state='starting'}
    if type(previous)~='function' then state.state='no_update';pcall(close);return state end
    local wrapper,closed
    local function stop(reason)
        if closed then return end
        closed=true;state.state=reason
        pcall(emit,'status='..reason..';filter_enabled=false;observations='..state.observations
            ..';g60_observations='..state.g60_observations)
        pcall(close)
        if rawget(env,'update')==wrapper then rawset(env,'update',previous) end
    end
    local function observe(phase)
        if closed then return end
        local ok,result=pcall(sample,phase,state.frames)
        if not ok then
            state.read_failures=(state.read_failures or 0)+1
            -- Loading/scene changes are expected. Keep bounded failure summaries.
            if state.read_failures<=3 or state.read_failures%120==0 then
                local wrote=pcall(emit,'phase='..phase..';frame='..state.frames..';read_failed='..tostring(result))
                if not wrote then stop('log_failed') end
            end
            return
        end
        if type(result)~='table' or type(result.line)~='string' or type(result.g60_count)~='number' then
            stop('invalid_sample');return
        end
        state.observations=state.observations+1
        if result.g60_count>0 then
            state.g60_observations=state.g60_observations+1;state.last_g60_frame=state.frames
        end
        if result.g60_count>0 or state.observations<=6 or state.frames%3600==0 then
            if not pcall(emit,result.line) then stop('log_failed');return end
        end
        if state.g60_observations>=80 then stop('complete') end
    end
    local function after(ok,...)
        if not ok then stop('original_update_error');error((...),0) end
        if not closed and state.frames%15==0 then observe('after') end
        if not closed and state.last_g60_frame and state.frames-state.last_g60_frame>=240 then
            stop('complete')
        end
        if not closed and state.frames>=108000 then stop('frame_budget_reached') end
        return ...
    end
    wrapper=function(...)
        if not closed then
            state.frames=state.frames+1
            if state.frames%15==0 then observe('before') end
        end
        return after(pcall(previous,...))
    end
    state.state='observing';state.stop=function() stop('stopped') end
    rawset(env,'update',wrapper)
    return state
end
return M
