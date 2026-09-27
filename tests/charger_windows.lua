local ffi=require('ffi')
local native=ffi.load(G60_FIXTURE_DLL)
local W=G60WeakpointWindows
local L=require('g60.native_observer')
local passed=0
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
local function setup(key)
    key=key or '3aff5fd7d5450b99';return W.setup(key,W.profiles[key])
end
test('only Behemoth resources use rear; ordinary and Spore Chargers use Head',function()
    for _,key in ipairs({'3aff5fd7d5450b99','a05bd1ec67b3ac4c','fd5247653c897803'}) do
        assert(W.profiles[key].kind=='rear' and W.profiles[key].region==nil)
    end
    for _,key in ipairs({'1a7fcdff98c664b0','6b202392f4ab605e'}) do
        assert(W.profiles[key].kind=='head' and W.profiles[key].region==nil)
        local f=setup(key);f.position={10,1.9,2.2};f.host:tick();f.host:tick()
        assert(native.fixture_explosions()==1 and not f.host.disabled,table.concat(f.logs,'\n'))
    end
end)
test('Behemoth rear arrival explodes once but old front belly and head positions do not',function()
    for _,key in ipairs({'3aff5fd7d5450b99','a05bd1ec67b3ac4c','fd5247653c897803'}) do
        for _,case in ipairs({{{10,-2.74,1.47},true},{{10,.59,1},false},{{10,1.9,2.2},false},
            {{10,-2.74,4},false},{{11,-2.74,1.47},false}}) do
            local f=setup(key);f.position=case[1];f.host:tick()
            assert((native.fixture_explosions()==1)==case[2] and not f.host.disabled,table.concat(f.logs,'\n'))
            f.host:tick();assert(native.fixture_explosions()==(case[2] and 1 or 0))
            assert(L.u32(f.read(f.source.record,0x1f8),0x188)==1000000)
        end
    end
end)
test('rear arrival checks current abdomen and cannot explode at a previous body position',function()
    local f=setup();f.position={10,-6,1.47};f.host:tick()
    f.weakpoint_geometry.point={10,2.66,1.77}
    f.weakpoint_geometry.body_center={10,5,2.151};f.weakpoint_geometry.origin={10,5,0}
    f.u64(f.clock,0x18,2100000);f.position={10,-2.74,1.47};f.host:tick()
    assert(native.fixture_explosions()==0 and not f.host.disabled,table.concat(f.logs,'\n'))
    f.position={10,2.26,1.47};f.host:tick()
    assert(native.fixture_explosions()==1 and not f.host.disabled,table.concat(f.logs,'\n'))
end)
print('RESULT '..passed..' passed; 0 failed (split Charger targets, Windows owned fixture)')
