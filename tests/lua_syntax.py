"""语法检查：用 Lua 侧 io.open 读文件再 load()。

lupa 的坑：Python 的 str 传给 Lua 函数会变成 POBJECT，load() 会报
"bad argument #1 to 'load' (function expected, got POBJECT)"，
所以必须让 Lua 自己打开文件。
"""
import pathlib
import sys

import lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent

CHECK = """
(function()
    local fh = assert(io.open(PATH))
    local s = fh:read('a'); fh:close()
    local fn, err = load(s, '@' .. PATH)
    if fn then return 'OK' else return 'FAIL: ' .. tostring(err) end
end)
"""


def main():
    # 默认覆盖 src/g60 下**全部**模块（曾经是硬编码 8 个，
    # 新加的 priority_faults 一度没进检查范围）。
    files = sys.argv[1:] or sorted(
        str(p.relative_to(ROOT)).replace("\\", "/")
        for p in (ROOT / "src/g60").glob("*.lua")
    )
    import os
    os.chdir(ROOT)
    bad = 0
    for f in files:
        rel = f.replace("\\", "/")
        code = ("local fh=assert(io.open(%r)) local s=fh:read('a') fh:close() "
                "local fn,err=load(s,'@'..%r) "
                "R=(fn and 'OK') or ('FAIL: '..tostring(err))") % (rel, rel)
        rt = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
        try:
            rt.execute(code)
            res = rt.eval("R")
        except Exception as exc:                       # noqa: BLE001
            res = "EXC " + str(exc)[:160]
        res = res.decode("utf-8") if isinstance(res, bytes) else str(res)
        if res != "OK":
            bad += 1
        print(f"  {f:38} {res}")
    print(f"\n{len(files) - bad}/{len(files)} 语法通过")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
