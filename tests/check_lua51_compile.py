"""用**游戏自带的 Lua 5.1**（bin/lua51.dll）编译产物 —— 2026-09-30 实机事故的守门。

为什么必须做
------------
本地测试一直用 `lupa`（**Lua 5.5**）做语法检查，而游戏跑的是 **Lua 5.1**。
两者的**函数内局部变量/upvalue 上限不同**：

| 限制 | Lua 5.1 / LuaJIT | Lua 5.5 |
|---|---|---|
| 每个函数的 upvalue 数 | **60**（`LUAI_MAXUPVAL`） | 255 |
| 每个函数的 local 数 | 200 | 200 |

2026-09-30 的实机事故：为性能诊断往 `M.new` 里加了 10 个独立局部变量，
`host:tick` 内那个 `pcall(function() ... end)` 的 upvalue 数被顶到 **61 > 60**
⇒ **整个 chunk 编译失败** ⇒ addon 一行日志都不打，表现为"mod 没生效"。
而 `lupa`/`lua_syntax.py` **全绿**（5.5 上限 255，看不出来）——
白白多花了一轮排查（从"效果差"一路查到"根本没加载"）。

本脚本用**游戏自己的 lua51.dll** 编译，等价于实机加载期的检查。

用法
----
    python tests/check_lua51_compile.py            # 编译 build/entry.lua + src/g60/*.lua
    python tests/check_lua51_compile.py <文件...>  # 只编译指定文件

找不到 lua51.dll 时**跳过**（打印提示、退出码 0）—— 换机器不该让测试红。
可用环境变量 `G60_LUA51` 指定路径。
"""
import ctypes
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

CANDIDATES = (
    os.environ.get("G60_LUA51"),
    r"D:\Steam\steamapps\common\Helldivers 2\bin\lua51.dll",
    r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll",
    r"C:\Program Files\Steam\steamapps\common\Helldivers 2\bin\lua51.dll",
)


def find_dll():
    for c in CANDIDATES:
        if c and pathlib.Path(c).exists():
            return c
    return None


def bind(dll_path):
    d = ctypes.CDLL(dll_path)
    d.luaL_newstate.restype = ctypes.c_void_p
    d.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_size_t, ctypes.c_char_p]
    d.luaL_loadbuffer.restype = ctypes.c_int
    d.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    d.lua_tolstring.restype = ctypes.c_char_p
    d.lua_close.argtypes = [ctypes.c_void_p]
    return d


def compile_one(d, path, label):
    """返回 (ok, message)。只编译不执行 —— 不需要 require/ffi 环境。"""
    state = d.luaL_newstate()
    try:
        data = path.read_bytes()
        rc = d.luaL_loadbuffer(ctypes.c_void_p(state), data, len(data),
                               ("@" + label).encode())
        if rc == 0:
            return True, f"{len(data)} B"
        err = d.lua_tolstring(ctypes.c_void_p(state), -1, None)
        return False, err.decode("utf-8", "replace")[:300]
    finally:
        d.lua_close(ctypes.c_void_p(state))


def main():
    dll = find_dll()
    if not dll:
        print("SKIP: 找不到 lua51.dll（可用 G60_LUA51 指定）—— 本机无法做 Lua 5.1 编译检查")
        return 0
    print(f"使用 {dll}")
    d = bind(dll)

    args = sys.argv[1:]
    if args:
        targets = [pathlib.Path(a) for a in args]
    else:
        targets = []
        entry = ROOT / "build" / "entry.lua"
        if entry.exists():
            targets.append(entry)
        targets += sorted((ROOT / "src/g60").glob("*.lua"))

    failed = []
    for path in targets:
        if not path.exists():
            continue
        label = str(path.relative_to(ROOT)).replace("\\", "/")
        ok, msg = compile_one(d, path, label)
        if ok:
            print(f"  OK    {label:44s} {msg}")
        else:
            failed.append((label, msg))
            print(f"  FAIL  {label:44s} {msg}")

    print()
    if failed:
        print(f"RESULT: {len(failed)} 个文件在 Lua 5.1 下编译失败（lupa/5.5 看不出来！）")
        for label, msg in failed:
            print(f"  - {label}: {msg}")
        print("  ⚠ Lua 5.1 每函数 upvalue 上限 60 / local 上限 200 —— "
              "把新增的独立局部变量收进一个 table 即可（见 experimental_runtime 的 P）。")
        return 1
    print(f"RESULT: ALL PASS ({len(targets)} 个文件在 Lua 5.1 下编译通过)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
