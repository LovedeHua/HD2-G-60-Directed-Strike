-- Exercise the real entry's logging/initialization boundary without native calls.
local file=assert(io.open('addon/entry.lua.in','rb'))
local template=file:read('*a');file:close()
local boundary=assert(template:find('    ffi.cdef',1,true))
local source=template:sub(1,boundary-1):gsub('@@MODULES@@','')
    ..' return {emit=emit,close=close} end)\nassert(ok,why)\nreturn why\n'
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function start(loader)
    local env=setmetatable({CowboyBingusModLoader=loader},{__index=_G})
    env._G=env
    env.require=function(name)
        assert(name=='ffi')
        return {os='Windows',abi=function(name) return name=='64bit' end}
    end
    local chunk
    if setfenv then chunk=assert(loadstring(source));setfenv(chunk,env)
    else chunk=assert(load(source,'entry logging','t',env)) end
    return chunk()
end
test('missing log service does not block initialization',function()
    local api=start({api=1});api.emit('started');api.close()
end)
test('open returning nil does not block initialization',function()
    local api=start({api=1,open_log=function() return nil,'permission denied' end})
    api.emit('started');api.close()
end)
test('open throwing does not block initialization',function()
    local api=start({api=1,open_log=function() error('permission denied') end})
    api.emit('started');api.close()
end)
for _,failure in ipairs({'write_return','write_throw','flush_return','flush_throw'}) do
    test(failure..' disables only logging and closes once',function()
        local writes,closes=0,0
        local handle={write=function(self)
            writes=writes+1
            if failure=='write_return' then return nil,'disk full' end
            if failure=='write_throw' then error('disk full') end
            return self
        end,flush=function()
            if failure=='flush_return' then return nil,'disk full' end
            if failure=='flush_throw' then error('disk full') end
            return true
        end,close=function() closes=closes+1;error('close failed') end}
        local api=start({api=1,open_log=function() return handle end})
        api.emit('started');api.emit('second');api.close();api.close()
        assert(writes==1 and closes==1)
    end)
end
test('malformed log handle does not escape diagnostics',function()
    local api=start({api=1,open_log=function() return true end})
    api.emit('started');api.close()
end)
test('working log keeps output and closes once',function()
    local output,closes={},0
    local handle={write=function(self,s) output[#output+1]=s;return self end,
        flush=function() return true end,close=function() closes=closes+1 end}
    local api=start({api=1,open_log=function(name)
        assert(name=='G60BugholeLock.log');return handle
    end})
    api.emit('one');api.emit('two');api.close();api.close();api.emit('three')
    assert(table.concat(output)=='one\ntwo\n' and closes==1)
end)
test('required loader API remains checked',function()
    local ok,err=pcall(start,{api=2})
    assert(not ok and tostring(err):find('loader API unavailable',1,true))
end)
print('RESULT '..passed..' passed; 0 failed (optional entry logging)')
