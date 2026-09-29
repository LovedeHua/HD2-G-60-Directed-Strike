"""Measure the per-frame memory-read cost of this addon with a synthetic memory image.

Why
---
This addon hooks `update`, so `host:tick()` runs every frame. Two captures happen on
every tick regardless of whether any G-60 is in flight:

    jobs_ready()        -> native_readiness.capture(reader, base, exe, thread, {matches={}}, nil)
    Layout.capture()    -> native_observer.capture(reader, base)

`jobs_ready()` passes an EMPTY match list, so it never reaches `Search.capture` — the
expensive path. `Layout.capture` walks five engine queues and then the behaviour array.

Both are pure string/pointer arithmetic (no FFI), so they run under lupa. We build a
minimal image that satisfies their assertions, wrap `reader` in a counting function, and
report exact read calls and bytes. `Search.capture` / `Candidates.capture` are *not*
measured here: they need the compiled C fixture, so their cost is reported separately
from the code's own budget assertions.

Run: python -B tests/test_perf_probe.py

★ Known limitation of the synthetic image
------------------------------------------
`Layout.capture` / `Readiness.capture` 的读次数与字节数由包裹的 `reader` 计数器给出，
**与 mock 内容无关**，所以这两个数字是可靠的。

但本 mock 的五个引擎队列读回来在 Lua 侧被判为"全部 pending"
(`all_observed_queues_complete=false`)，而 Python 侧直读是全零 —— 说明队列体的
构造与 `u32()` 的取字节方式之间还有偏差。后果：探针只覆盖到 **capture 本身**的成本，
**没有覆盖 capture 之后 `runtime` 是否继续进入 G-60 处理路径**。
按 `experimental_runtime.lua` 的逻辑，`all_complete=false` 时会直接 `return`，
即本探针测的正是"游戏繁忙 → mod 当帧早退"这条路径的成本（这是常见情况）。
G-60 在飞时的完整路径（Search.capture / priority / titan / arrival）**未实测**，
只能引用代码自带的预算上限。
"""
import os
import pathlib
import re
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
QUEUE_DEBUG = True
sys.path.insert(0, str(ROOT / 'src'))

BASE = 0x140000000          # 4096-aligned, satisfies the module-base assert
EXE = 0x150000000
THREAD = 0x2A44
ROOTP = 0x200000000         # behaviour root
CLOCK = 0x300000000
MANAGER = 0x400000000       # behaviour manager
WORLD = 0x500000000
REGISTRY = 0x600000000
THREADS = 0x700000000
MAIN = 0x800000000
OPTIONAL = 0x900000000
MODE = 0xA0000000
CAND = 0xB0000000

# native_observer 用 hex64(identity,0) == '8e325c933e55bf62' 判定，
# 而 hex64 是 format('%08x%08x', u32(s,4), u32(s,0)) ⇒ u64 小端读出来就是这个值。
G60_RESOURCE = 0x8E325C933E55BF62
G60_ID = 0x11111111


def u32(v):
    return v.to_bytes(4, 'little')


def u64(v):
    return v.to_bytes(8, 'little')


class Image:
    """Sparse byte-addressable memory. Unwritten addresses read as zero."""

    def __init__(self):
        self.mem = {}

    def put(self, addr, data):
        self.mem[addr] = bytes(data)

    def ptr(self, addr, value):
        self.put(addr, u64(value))

    def get(self, addr, n):
        out = bytearray(n)
        for a in list(self.mem):
            if addr <= a < addr + n:
                chunk = self.mem[a]
                off = a - addr
                take = min(len(chunk), n - off)
                out[off:off + take] = chunk[:take]
        return bytes(out)


def build(count_g60, selection_flag=0, queues_complete=True):
    m = Image()
    m.ptr(BASE + 0x346BF98, ROOTP)            # behaviour root
    m.ptr(BASE + 0x347CF20, OPTIONAL)          # optional group
    m.put(OPTIONAL + 0x134D01, b'\0')          # optional_enabled = false
    m.ptr(BASE + 0x347CEF0, MODE)
    m.put(MODE + 0x1F86A, b'\0')               # update_mode = 0
    m.ptr(BASE + 0x3326348, CLOCK)
    m.put(CLOCK + 0x18, u64(2_000_000))        # native microsecond clock
    m.ptr(BASE + 0x3326740, MANAGER)           # behaviour manager
    m.ptr(BASE + 0x3326548, CAND)             # candidate manager (for Candidates.capture)

    # root flags: [1]=1, [2]=0, [3]=0
    m.put(ROOTP + 0xF3F828, b'\1\0\0')

    # five queues: every stride's first u32 is the "pending" flag
    # 五个队列。★ 注意 native_observer 第 80 行是
    #   queue(name, pointer(root+root_offset) + layout.first, ...)
    # 也就是说 pointer() 的返回值本身必须 8 对齐（first 是之后的偏移），
    # 这里之前写成了"已加过 first 的地址"，导致 ptr() 的 %8 断言失败。
    queue_base = {0x10: 0x51000000, 0x18: 0x52000000, 0x20: 0x53000000,
                  0x28: 0x54000000, 0x38: 0x55000000}
    for root_off, base_addr in queue_base.items():
        m.ptr(ROOTP + root_off, base_addr)
    if not queues_complete:
        # 让第一个 raycast 槽 pending -> all_observed_queues_complete = false
        m.put(0x51000000 + 0x40010, u32(1))
    # 队列体本身未写入 = 全零 = 没有 pending 槽

    # behaviour header
    hdr = bytearray(0x70)
    hdr[0x20:0x24] = u32(max(count_g60, 1))     # capacity
    hdr[0x2C:0x30] = u32(count_g60)             # count
    hdr[0x34:0x38] = u32(count_g60)             # active
    m.put(MANAGER, bytes(hdr))
    m.put(MANAGER + 0x58, u64(0x600000000))     # entities array
    m.put(MANAGER + 0x60, u64(0x610000000))     # states array
    for i in range(count_g60):
        ent = 0x620000000 + i * 0x100
        ident = bytearray(24)
        ident[0:8] = G60_RESOURCE.to_bytes(8, 'little')
        ident[8:12] = u32(G60_ID + i)
        ident[16:20] = u32(7)                    # network index
        ident[20:24] = u32(0)                    # flags -> native_update_eligible
        m.put(0x600000000 + i * 8, u64(ent))
        m.put(ent, bytes(ident))
        rec = bytearray(0x1F8)
        rec[0:4] = u32(4)                        # behavior_id
        rec[8:12] = u32(4)                       # state 4 = search
        rec[0x18:0x1C] = u32(0xFFFFFFFF)         # selection id = invalid
        rec[0x68:0x6C] = u32(G60_ID + i)
        rec[0x79] = selection_flag
        rec[0x188:0x190] = u64(1_000_000)
        m.put(0x610000000 + i * 0x1F8, bytes(rec))

    # readiness chain
    m.ptr(EXE + 0x1B135E0, REGISTRY)
    m.ptr(REGISTRY + 8, THREADS)
    m.ptr(THREADS, MAIN)
    m.put(MAIN + 8, u32(THREAD))
    m.ptr(BASE + 0x3326340, WORLD)
    m.put(BASE + 0x3326E50, u32(1))
    m.put(WORLD + 0x78AC018, b'\0')
    m.put(WORLD + 0x78AC019, b'\0')
    return m


PROBE = r'''
package.path = '__LUA_SRC__' .. ';' .. package.path
local Observer = require('g60.native_observer')local Readiness = require('g60.native_readiness')
-- IMG 是 SETUP 注入的全局，不要 local（chunk 顶层 vararg 是 nil）
local function counter()
    local calls, bytes = 0, 0
    local f = function(addr, n)
        calls = calls + 1; bytes = bytes + n
        return IMG.get(addr, n)
    end
    return f, function() return calls, bytes end
end
local out = {}
local reader, snap = counter()
local obs = Observer.capture(reader, BASE)
local oc, ob = snap()
local reader2, snap2 = counter()
local ready = Readiness.capture(reader2, BASE, EXE, THREAD, {matches = {}}, nil)
local rc, rb = snap2()
out.readiness = {rc, rb, ready.engine_main_thread_observed, ready.world_job_completion}
local qd = {}
for i, q in ipairs(obs.queues) do qd[#qd+1] = q.name .. '=' .. #q.pending end
return string.format('%d %d %d %s %d|%d %d %s %d|%s',
    oc, ob, #obs.matches, tostring(obs.all_observed_queues_complete), obs.behavior_count,
    rc, rb, tostring(ready.engine_main_thread_observed), ready.world_job_completion,
    table.concat(qd, ','))
'''


# ★ lupa 在 encoding=None 时把 Python str 传成 POBJECT（拼接会炸），所以路径/地址
#   一律用字面量注入，函数仍走 Lua 侧 setter。
SETUP = r'''
function __setup(img_get)
    IMG = {get = img_get}
end
'''
# 地址用字面量注入（lupa 传 Python int 会变 POBJECT），用词边界避免误伤。
for _ph, _v in (('BASE', BASE), ('EXE', EXE), ('THREAD', THREAD)):
    PROBE = re.sub(r'\b%s\b' % _ph, str(_v), PROBE)


def measure(label, **kw):
    img = build(**kw)
    rt = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    rt.execute(SETUP)
    rt.eval("__setup")(img.get)
    # ★ 用相对路径：绝对路径里的中文会被 lupa 当 latin-1 读成乱码。
    os.chdir(ROOT)
    # rt.execute 不把 chunk 的返回值带回 Python（拿到 None）⇒ 包成函数用 eval 调，
    # 并在 Lua 侧拼成字符串返回，Python 只解析字符串（避开 Lua table 跨语言转换）。
    probe = '(function()\n' + PROBE.replace('__LUA_SRC__', 'src/?.lua') + '\nend)()'
    raw = rt.eval(probe)                      # encoding=None ⇒ lupa 回 bytes
    line = raw.decode('utf-8') if isinstance(raw, bytes) else str(raw)
    try:
        o, ob, gm, qc, bc, r, rb2, mt, wjc = line.split('|')[0].split() + line.split('|')[1].split()
    except ValueError:
        raise SystemExit('probe returned unexpected: ' + repr(line))
    obs = (int(o), int(ob), int(gm), qc, int(bc))
    rdy = (int(r), int(rb2), mt, int(wjc))
    if QUEUE_DEBUG:
        print('        队列 pending:', line.split('|')[2])
    print(f"  {label}")
    print(f"      Layout.capture : {obs[0]:>5} reads  {obs[1]:>7,} B  "
          f"| G-60 matches={obs[2]}  queues_complete={str(obs[3]):5}  behavior_count={obs[4]}")
    print(f"      Readiness      : {rdy[0]:>5} reads  {rdy[1]:>7,} B  "
          f"| main_thread_ok={rdy[2]}  world_job_completion={rdy[3]}")
    print(f"      每帧合计(两件事都在 tick 里): {obs[0] + rdy[0]:>5} reads  {obs[1] + rdy[1]:>7,} B")
    return obs, rdy


def main():
    print('=== 每帧固定开销（tick 开头无条件执行的两件事）===')
    a = measure('[A] 无 G-60 在场 / 队列空闲', count_g60=0)
    print()
    b = measure('[B] 无 G-60 / 有待处理队列(游戏自己在跑 raycast)', count_g60=0, queues_complete=False)
    print()
    c = measure('[C] 有 1 个 G-60(state-4, 无锁定目标)', count_g60=1)
    print()
    d = measure('[D] 有 1 个 G-60 且已锁定目标(触发 entity 哈希探测)', count_g60=1, selection_flag=1)

    print()
    print('=== 相对 60fps 帧预算 (16.67 ms) 的估算 ===')
    # 同进程 FFI ReadProcessMemory：进程内读自身地址，约 0.3–1 µs/次（页已在 TLB/cache 时）
    for us in (0.3, 1.0):
        for tag, (obs, rdy) in (('A 无G-60', a), ('B 队列忙', b), ('C 1个G-60', c), ('D 锁定中', d)):
            n = obs[0] + rdy[0]
            ms = n * us / 1000.0
            print(f"  {us:>3} µs/次  {tag:9s} {n:>4} reads -> {ms:7.4f} ms/帧 "
                  f"({100 * ms / 16.67:5.2f}% 帧预算)")
    print()
    print('  注：这是保守下界。真实开销还要加上 Lua 解释、字符串拼接与 FFI 桥接，')
    print('      以及 G-60 飞行期间才进入的 Search/Titan/Arrival 路径（各自有代码内预算上限：')
    print('      search context ≤65536 B/2048 calls，snapshot ≤262144 B/8192 calls，')
    print('      readiness ≤512 B，target data ≤262144 B/4096 calls）。')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
