"""upvalue 预算门：`host:tick` 的 upvalue 个数必须**留有余量**。

为什么需要
----------
Lua 5.1 的 `LUAI_MAXUPVAL = 60`。超了 ⇒ **整份 chunk 编译失败** ⇒
addon 一行日志都不打，表现为「mod 没生效」。

本工程已经**两次**撞线：
  · 2026-09-30 —— 往 `M.new` 加 10 个局部变量（实机事故，排查花了一轮）
  · 2026-10-18 —— 加"启动宽限期"时又撞（**这次编译门当场拦住**）

⚠ 两次的共同点：**不知道离 60 还有几个**。
  编译门 `check_lua51_compile.py` 只在**已经超了**之后才报错 —— 它拦得住，
  但它是**事后**的；没有任何东西告诉你"现在 58，只剩 2 个余量"。

⚠ 用户原话（2026-10-18）：「减少upvalue数量，要不然以后这个问题会一直出现」。
  ⇒ 本文件做两件事：**测量**（个数 + 名字清单）+ **守门**（留余量）。

怎么测
------
用 `lupa`（LuaJIT）加载 `src/g60/experimental_runtime.lua`：
  · `require` 桩成"什么都能当函数调"的魔法表
  · `ffi` 同样桩掉
  · `env` 用元表兜住（任何字段都返回一个返回 nil 的函数）
然后 `M.new(env)` 拿到 `host`，对 `host.tick` 逐个 `debug.getupvalue`。

⚠ LuaJIT 的 upvalue **上限**比 Lua 5.1 宽，但**个数统计是同一个语义** ——
  所以"用 LuaJIT 数、拿 Lua 5.1 的 60 当阈值"是成立的。
⚠ 这是**近似但可复核**的测量：它数的是真实闭包的 upvalue 表，不是静态猜的
  （我第一版用朴素的 `do/end` 计数做静态分析，**当场失败**）。
"""
import pathlib
import sys

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME = ROOT / 'src' / 'g60' / 'experimental_runtime.lua'

# Lua 5.1 的硬上限（`LUAI_MAXUPVAL`）。
LUA51_MAXUPVAL = 60
# ★ 本工程自定的**预算**：留出余量。
#   为什么是 50 而不是 59：撞线的代价是"整包静默失效"，
#   而余量越大，下一次加东西时越不会踩雷。50 留 10 个余量。
BUDGET = 50

STUB = """
local function magic()
    return setmetatable({}, {__index=function(t,k) return magic() end,
                              __call=function() return magic() end,
                              __tostring=function() return 'stub' end,
                              __len=function() return 0 end})
end
local cache={}
require=function(n) cache[n]=cache[n] or magic(); return cache[n] end
ffi={cast=function() return magic() end, sizeof=function() return 8 end,
     string=function() return '' end, new=function() return magic() end,
     C=setmetatable({},{__index=function() return magic() end})}
"""

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print(('  PASS ' if ok else '  FAIL ') + name + (('  [' + detail + ']') if detail else ''))
    if not ok:
        failures.append(name)


def measure():
    """返回 (个数, 名字清单)。失败时返回 (None, 原因)。"""
    lua = lj.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUB)
    src = RUNTIME.read_text(encoding='utf-8')
    try:
        M = lua.execute('return (function()\n' + src + '\nend)()')
    except Exception as e:
        return None, '模块加载失败: %s' % str(e)[:200]
    env = lua.eval("setmetatable({}, {__index=function() return function() return nil end end})")
    try:
        host = M.new(env)
        tick = host['tick']
    except Exception as e:
        return None, 'M.new 失败: %s' % str(e)[:200]
    dbg = lua.eval('debug')
    names, i = [], 1
    while i <= 300:
        r = dbg.getupvalue(tick, i)
        if r is None:
            break
        names.append(str(r[0]))
        i += 1
    return names, None


def main():
    print('=== upvalue 预算：host:tick（Lua 5.1 硬上限 %d，本工程预算 %d）==='
          % (LUA51_MAXUPVAL, BUDGET))
    names, err = measure()
    if err:
        # ⚠ 测量本身失败**必须红**，不许静默跳过 ——
        #   否则门会因为"测不到"而假装通过（本工程明令忌讳）。
        check('upvalue_measurable', False, err)
        print()
        print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
        print('failed: ' + ', '.join(failures))
        return 1

    n = len(names)
    print('  实测 upvalue 个数: %d  （余量 %d）' % (n, LUA51_MAXUPVAL - n))
    for k in range(0, n, 5):
        print('     ' + '  '.join(x.ljust(20) for x in names[k:k + 5]))
    print()

    check('upvalue_measurable', True, '测到 %d 个' % n)
    check('tick_upvalue_within_budget', n <= BUDGET,
          '★ `host:tick` 的 upvalue 必须 ≤ %d（实测 %d，硬上限 %d）。'
          '超预算时请把散落的局部变量**归组进一张表**（`P` 或 `S3`）——'
          'N 个 upvalue 会降成 1 个。' % (BUDGET, n, LUA51_MAXUPVAL))
    # ★ 反向门：也要挡住"直接贴到硬上限"。
    check('tick_upvalue_has_headroom', n < LUA51_MAXUPVAL,
          '★ 至少要离硬上限 %d 有余量（实测 %d）—— 贴着 60 时任何新增都会让整包静默失效'
          % (LUA51_MAXUPVAL, n))
    # ★ 已归组的两张表必须在清单里（否则归组被谁回退了都不知道）。
    check('grouped_tables_still_captured', 'P' in names and 'S3' in names,
          '★ `P` 与 `S3` 都应在 upvalue 清单里（归组是省 upvalue 的手段，别被回退）')

    print()
    if failures:
        print('RESULT: %d passed; %d failed' % (checks - len(failures), len(failures)))
        print('failed: ' + ', '.join(failures))
        return 1
    print('RESULT: ALL PASS (%d checks)' % checks)
    return 0


if __name__ == '__main__':
    sys.exit(main())
