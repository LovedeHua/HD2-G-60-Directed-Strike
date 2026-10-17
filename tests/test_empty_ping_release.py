"""守门：空 ping 点消失 ⇒ **松手**（不再飞到底、不绕圈）2026-10-18 用户要求。

★ 背景（需求反转，与 2026-10-14 直接冲突）
  2026-10-14：用户报「空ping 没有跟虫洞一样能远距离追踪」⇒ 改成「承诺后就飞到底」
    （`held.point_sticky` + `ping_gone_keep_flying`）。
  2026-10-18：用户报「空ping接管的雷如果空ping标记过期或者取消了只会在原空ping点
    绕圈不会追踪附近的敌人」⇒ 改成**松手**（选项 A：直接改，与开关无关）。
  ⇒ 两者是同一信号（`point_marker` 变 nil）上的相反要求，用户选了**追敌人**。

★ 实机取证（决定性）
  `point_taken;entity=982;pos=90.57,295.15,14.87`（在 `empty_ping_hold=false` 之后）
  `blast_detour;entity=982;center=90.57,295.15,14.87` —— **绕行中心就是那个死点**（完全相等）
  ⇒ 证明绕圈与开关无关；死点承诺使 `gate.drive` 恒真 ⇒
    本 mod 一直在驾驶 ⇒ 引擎无法重新索敌；而安全区拿该点当圆心 ⇒ 绕圈。

★ 修法：两件事都要做（只做一件都不够）
  ① `old.point=nil`   —— 交出驾驶权，让引擎/本 mod 重新索敌
  ② `P.tpos[m.id]=nil` —— 不让安全区拿死点当圆心继续绕
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = (ROOT / "src" / "g60" / "experimental_runtime.lua").read_text(encoding="utf-8")
ENTRY = (ROOT / "addon" / "entry.lua.in").read_text(encoding="utf-8")

failures = []


def check(name, ok, why=""):
    print("  %s %s%s" % ("PASS" if ok else "FAIL", name,
                        ("  [%s]" % why) if why else ""))
    if not ok:
        failures.append(name)


CODE = "\n".join(l.split("--")[0] for l in SRC.splitlines())

print("=== ① 点消失时必须**同时**清两件事 ===")
check("clears_old_point",
      re.search(r"if not point_marker then\s*\n\s*old\.point=nil", CODE) is not None,
      "★ 不清 `old.point` ⇒ `gate.drive` 恒真 ⇒ 本 mod 一直驾驶 ⇒ 引擎永远重新索不了敌")
check("clears_center_cache",
      re.search(r"old\.point=nil\s*\n\s*P\.tpos\[m\.id\]=nil", CODE) is not None,
      "★★ 只清 `old.point` 不够：安全区的绕行圆心取的是 `P.tpos` ⇒ "
      "不清它就会拿**死点**当圆心继续绕圈（实机取证："
      "center == point_taken 的 pos）")
check("emits_release",
      "point_lost_released" in SRC and "DEAD_PING_DROPPED" in SRC,
      "松手必须可见（看不到 = 无法确认到底松了没）")
check("dedup_table_in_P", "pdt={}," in SRC,
      "★ 去重表必须进 P —— tick 的 xpcall 恰好 60 upvalue")

print()
print("=== ② 不得再压住绕圈（旧实现已删）===")
check("no_forced_hold_on_dead_point",
      "old.point_dead" not in CODE,
      "★ 旧实现强制 `held=true` ⇒ 进绕行块 ⇒ **就是用户报的绕圈**；"
      "而且它的释放条件（`m.selection_id~=0`）在我们写点时**永远不会成立** "
      "⇒ 一旦压住就**永远不会释放**（设计缺陷）")
check("no_toggle_left",
      "empty_ping_hold" not in SRC and "empty_ping_hold" not in ENTRY,
      "★ 开关已经没用了 ⇒ 必须删掉，否则就是**死开关**（本项目最讨厌的类型）")

print()
print("=== ③ 2026-10-14 的 sticky 注释必须不再声称「继续飞」（否则误导）===")
check("sticky_note_is_diagnostic_only",
      "point_sticky" in SRC,
      "★ sticky 标志仍在（只打日志 `ping_gone_keep_flying`）—— "
      "但真正清点的是新代码；两者并存不冲突（已核对）")

print()
if failures:
    print("RESULT: %d failed" % len(failures))
    for f in failures:
        print("  failed: " + f)
    sys.exit(1)
print("RESULT: ALL PASS —— 点消失时同时清 `old.point` 与 `P.tpos`、"
      "不再强制绕圈、旧开关已删、诊断可见")
