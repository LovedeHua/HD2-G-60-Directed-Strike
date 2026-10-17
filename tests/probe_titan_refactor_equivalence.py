"""重构等价性守门：泰坦链三个文件（adaptive / blast_route / navigation）
在**任意次重构**后，行为必须与基线**逐位一致**。

★ 为什么需要它
  这三个文件的注释里有大量「移植自上游」的血统说明。去掉那些字样是**纯外观**改动，
  但一旦手滑改了某个数值或分支，行为就变了 —— 而外观改动**看起来**都像安全的。
  ⇒ 必须有一道机械判据：同一组输入，`Adaptive.refine` 的输出必须逐位相同。
  这是"行为不变"的证明，不是我说了算。

★ 基线从哪来
  `tests/baselines/titan_chain_baseline.json`：由**重构前**的代码生成（git 里的原始版本）。
  它记录：对 N 组确定性输入的 `arrival_point` / `arrival_region` /
  `Navigation.project` 输出。

★ 用法
  1) 生成/更新基线（只在**确认代码行为正确**时做）：
       python tests/probe_titan_refactor_equivalence.py --write
  2) 校验（默认）：
       python tests/probe_titan_refactor_equivalence.py
"""
import json
import pathlib
import sys

import lupa.luajit21 as lj

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / "tests" / "baselines" / "titan_chain_baseline.json"


def load_module(rt, relpath, deps):
    """把模块包进 function()...end 求值（文件以 return M 结尾）。"""
    src = (ROOT / relpath).read_text(encoding="utf-8")
    prelude = "".join("local %s=%s\n" % (n, v) for n, v in deps.items())
    rt.execute("__m = (function()\n" + prelude + src + "\nend)()")
    return rt.globals().__getitem__("__m")


def build_runtime():
    rt = lj.LuaRuntime(unpack_returned_tuples=True)
    # arrival_policy 是真实实现（三个文件都依赖它的几何判定）
    rt.globals().ArrivalPolicy = load_module(rt, "src/g60/arrival_policy.lua", {})
    rt.execute("""
    function require(n)
      if n == 'g60.arrival_policy' then return ArrivalPolicy end
      if n == 'g60.navigation' then return Navigation end
      error('unexpected require: '..tostring(n))
    end
    """)
    rt.globals().Navigation = load_module(rt, "src/g60/navigation.lua", {})
    rt.globals().BlastRoute = load_module(rt, "src/g60/blast_route.lua", {})
    # ⚠ 必须把模块也绑成**全局**：文件里 `require('g60.adaptive')` 的调用方
    #   与判据都按全局名取（同理 Adaptive 要能在 execute 里直接引用）。
    rt.globals().Adaptive = load_module(rt, "src/g60/adaptive.lua", {})
    return rt, rt.globals().Adaptive, rt.globals().Navigation, rt.globals().ArrivalPolicy


# 确定性输入网格：覆盖 姿态可靠/不可靠、净空充足/不足、法线倾斜、不同 standoff
# 确定性输入网格：覆盖 姿态可靠/不可靠、净空充足/不足、法线倾斜
#   ⚠ 法线用 (x,y,z) 三元组显式写，避免 set 无序（第一版我用 {0,0,-1} 字面量，
#     在 Python 里那是 **set**、不可索引 ⇒ 直接 IndexError。改用 tuple。）
NORMALS = ((0.0, 0.0, -1.0), (0.3, 0.0, -0.95), (-0.4, 0.2, -0.89))
CASES = []
for zi, z in enumerate((10.0, 8.0, 6.0, 4.0)):
    for xi, x in enumerate((0.0, 1.5, -2.5)):
        for ni, n in enumerate(NORMALS):
            CASES.append({
                "id": "z%d_x%d_n%d" % (zi, xi, ni),
                "point": [x, 0.0, z],
                "origin": [0.0, 0.0, 0.0],
                "normal": list(n),
                "pose_unreliable": False,
            })
for i in range(4):
    CASES.append({
        "id": "unrel%d" % i,
        "point": [0.0, 0.0, 10.0 - i],
        "origin": [0.0, 0.0, 0.0], "normal": [0, 0, -1],
        "pose_unreliable": True,
    })
CASES.append({"id": "floor_low", "point": [0.0, 0.0, 2.0], "origin": [0.0, 0.0, 0.0],
              "normal": [0, 0, -1], "pose_unreliable": False})
CASES.append({"id": "floor_edge", "point": [0.0, 0.0, 1.4], "origin": [0.0, 0.0, 0.0],
              "normal": [0, 0, -1], "pose_unreliable": False})


def lua_case(rt, c):
    rt.execute("""
    __t = {point={%(px)r,%(py)r,%(pz)r}, origin={%(ox)r,%(oy)r,%(oz)r},
            belly_outward={%(nx)r,%(ny)r,%(nz)r},
            right={1,0,0}, forward={0,1,0}, body_center={%(ox)r,%(oy)r,%(oz)r},
            pose_signature={0,0,0,1,0,0,0}, pose_unreliable=%(pu)s}
    __own = {0,0,0}
    __route = {route={}}
    """ % {"px": c["point"][0], "py": c["point"][1], "pz": c["point"][2],
           "ox": c["origin"][0], "oy": c["origin"][1], "oz": c["origin"][2],
           "nx": c["normal"][0], "ny": c["normal"][1], "nz": c["normal"][2],
           "pu": "true" if c["pose_unreliable"] else "false"})


def snapshot(rt, adapt, nav, pol):
    out = {}
    for c in CASES:
        lua_case(rt, c)
        rt.execute("__ok,__r = pcall(Adaptive.refine, __own, __t, nil, {}, __route, 1.0)")
        ok = rt.eval("__ok")
        rec = {"ok": bool(ok)}
        if ok:
            rec["terminal"] = rt.eval("__r.terminal")
            ap = rt.eval("__r.arrival_point")
            rec["arrival_point"] = [round(float(ap[i]), 9) for i in range(1, 4)] if ap else None
            reg = rt.eval("__r.arrival_region")
            if reg:
                rec["region"] = {
                    "kind": str(reg["kind"]), "radius": round(float(reg["radius"]), 9),
                    "depth": round(float(reg["depth"]), 9), "min_z": round(float(reg["min_z"]), 9),
                    "lo": round(float(reg["lo"]), 9) if reg["lo"] is not None else None,
                    "normal": [round(float(reg["normal"][i]), 9) for i in range(1, 4)],
                }
            else:
                rec["region"] = None
            nav_state = rt.eval("__r.route and __r.route.navigation")
            rec["nav_mode"] = str(nav_state["mode"]) if nav_state and nav_state["mode"] else None
        else:
            rec["err"] = str(rt.eval("__r"))[:120]
        out[c["id"]] = rec
    # Navigation.project 也纳入（它是绕行几何的核心）
    rt.execute("""
    __n = Navigation.project({0,0,0}, {0,0,10},
        {normal={0,0,-1}, radius=2, depth=0.8, min_z=1.25})
    """)
    pr = rt.eval("__n")
    out["_project"] = [round(float(pr[i]), 9) for i in range(1, 4)]

    # ★★ BlastRoute 直接调用（第一版漏了它 ⇒ 变异测试证明本门对 blast_route/navigation
    #    是**盲的**：改 `underside 0.4→0.5`、`圆柱 radius 2.0→2.1` 都抓不到。
    #    只经 Adaptive 间接测是不够的 —— Adaptive 会覆盖 BlastRoute 的结果。）
    BLAST_CASES = []
    for kind in ("titan", "underside", "thorax", "head", "rear"):
        for pz in (10.0, 8.0, 5.0):
            for own in ((0, 0, 0), (2, 1, 0), (0, 0, 3.0)):
                BLAST_CASES.append({"kind": kind, "pz": pz, "own": list(own)})
    blast = rt.globals().BlastRoute
    for i, bc in enumerate(BLAST_CASES):
        rt.execute("""
        __prof = {kind=%(k)s}
        __bt = {point={0,0,%(pz)r}, origin={0,0,0}, right={1,0,0}, forward={0,1,0},
                body_center={0,0,0}, belly_outward={0,0,-1}}
        __base = {point={0,0,%(pz)r}, terminal=false, route={}}
        __own2 = {%(ox)r,%(oy)r,%(oz)r}
        __ok2,__rb = pcall(BlastRoute.refine, __own2, __bt, nil, __prof, __base)
        """ % {"k": "'%s'" % bc["kind"], "pz": bc["pz"],
               "ox": bc["own"][0], "oy": bc["own"][1], "oz": bc["own"][2]})
        ok2 = rt.eval("__ok2")
        key = "blast_%s_z%d_o%d" % (bc["kind"], int(bc["pz"]), i % 3)
        if ok2:
            ap2 = rt.eval("__rb.arrival_point")
            reg2 = rt.eval("__rb.arrival_region")
            # ⚠ 区域形状随 kind 不同：圆柱有 radius/depth，ellipsoid 有
            #   length/width/height/forward。第一版只读 radius/depth ⇒
            #   2026-10-18 修好 ellipsoid 之后 head/rear 会返回 ellipsoid，
            #   这里 `float(None)` 直接崩。改成**按 kind 取该形状的字段**。
            region = None
            if reg2:
                region = {"kind": str(reg2["kind"])}
                for f in ("radius", "depth", "length", "width", "height", "min_z", "lo"):
                    v = reg2[f]
                    region[f] = round(float(v), 9) if v is not None else None
                fw = reg2["forward"]
                region["forward"] = ([round(float(fw[j]), 9) for j in (1, 2)]
                                     if fw is not None else None)
            out[key] = {
                "ok": True,
                "terminal": rt.eval("__rb.terminal"),
                "arrival_point": [round(float(ap2[j]), 9) for j in range(1, 4)] if ap2 else None,
                "region": region,
                "stage": str(rt.eval("__rb.route.stage")),
            }
        else:
            out[key] = {"ok": False, "err": str(rt.eval("__rb"))[:120]}

    # ★★ Navigation 内部图搜索的确定性输出（project + plan 都测）
    for i, (own, goal) in enumerate((((0, 0, 0), (0, 0, 10)), ((3, 2, 0), (0, 0, 8)),
                                     ((0, 0, 5), (1, 1, 10)))):
        rt.execute("""
        __tt = {point={0,0,10}, origin={0,0,0}, right={1,0,0}, forward={0,1,0},
                body_center={0,0,0}}
        __rreg = {normal={0,0,-1}, radius=2, depth=0.8, min_z=1.25}
        __plan,__why = Navigation.plan({%(ox)r,%(oy)r,%(oz)r}, __tt,
            {%(gx)r,%(gy)r,%(gz)r}, __rreg, nil, 1.0)
        """ % {"ox": own[0], "oy": own[1], "oz": own[2],
               "gx": goal[0], "gy": goal[1], "gz": goal[2]})
        pl = rt.eval("__plan")
        key = "navplan%d" % i
        if pl:
            pp = rt.eval("__plan.point")
            out[key] = {"ok": True, "terminal": rt.eval("__plan.terminal"),
                        "mode": str(rt.eval("__plan.mode")),
                        "point": [round(float(pp[j]), 9) for j in range(1, 4)],
                        "nodes": rt.eval("__plan.nodes"),
                        "length": round(float(rt.eval("__plan.length")), 6)}
        else:
            out[key] = {"ok": False, "why": str(rt.eval("__why"))[:120]}
    return out


def main():
    rt, adapt, nav, pol = build_runtime()
    got = snapshot(rt, adapt, nav, pol)
    write = "--write" in sys.argv
    if write:
        BASE.parent.mkdir(parents=True, exist_ok=True)
        BASE.write_text(json.dumps(got, indent=1, sort_keys=True), encoding="utf-8")
        print("已写入基线：%s（%d 条用例）" % (BASE, len(got)))
        return 0
    if not BASE.exists():
        print("FAIL 基线不存在：%s（先跑 --write）" % BASE)
        return 1
    want = json.loads(BASE.read_text(encoding="utf-8"))
    bad = []
    for k in sorted(set(want) | set(got)):
        if want.get(k) != got.get(k):
            bad.append(k)
    print("=== 泰坦链重构等价性（%d 条用例）===" % (len(want) - 1))
    if bad:
        for k in bad[:10]:
            print("  FAIL %s" % k)
            print("       基线: %s" % json.dumps(want.get(k), ensure_ascii=False)[:150])
            print("       现在: %s" % json.dumps(got.get(k), ensure_ascii=False)[:150])
        print("RESULT: %d / %d 条不一致" % (len(bad), len(want)))
        return 1
    print("RESULT: ALL PASS —— 全部用例逐位一致，重构未改变行为")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
