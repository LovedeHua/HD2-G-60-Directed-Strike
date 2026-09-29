"""虫洞清单的**实机验证状态**报告。

清单收录 ≠ 实机可用。profile 里的 nodes/offset/belly_hash 是爆点参数，
猜错会让 G-60 飞到错误位置甚至炸不塌 —— 所以必须区分"在清单里"和"真的炸过"。

用法:
    python -B tests/hole_coverage.py                 # 用最新日志
    python -B tests/hole_coverage.py --log <路径>     # 指定日志
    python -B tests/hole_coverage.py --out _dumps/hole_coverage.json

数据来源:
  · 清单      —— compat/structure_profiles.lua
  · 实体名    —— 离线 datalibrary 的名字表（用 MurmurHash64A 反查）
  · 实机证据  —— 日志里 structure_mark(ACCEPTED) + arrival_detonated 的配对
"""
import argparse
import json
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROFILE = ROOT / "compat" / "structure_profiles.lua"

# 故意不接管的（不是虫洞：孢子菇 / 任务虫卵）
EXCLUDED = {
    "aa28caf964d05500": "bug_fog_generator(普通孢子菇)",
    "e02e6bd34b606a85": "bug_fog_generator_large(大型孢子菇)",
    "06d3c4720e642fc1": "embryo_01(任务虫卵)",
}

# 复用基线参数的类型 —— 风险较低：组件集/碰撞参数与基线几乎逐条相同
BORROWED = {
    "7e4c6b45bcc45c3f": "8c31b749759cbd61",   # warrior_captive  -> warrior
    "b6a181adcf547aeb": "8c31b749759cbd61",   # warrior_ceiling -> warrior
    "9d8632a79c2d9789": "8c31b749759cbd61",   # warrior_tutorial-> warrior
    "d666aa61d804d311": "8901f188db366b4b",   # scavenger_captive-> scavenger
    "0df874e208040d2f": "8901f188db366b4b",   # bug_spawner_base -> scavenger
}
# 没有基线、参数是保守假设的类型 —— 风险最高
GUESSED = {
    "688949109126ece4": "mechanical_bughole(机械虫洞)",
    "5cf84155e60c6e4d": "mechanical_bughole_scavenger(机械虫洞变体)",
}


def murmur64a(name: str) -> int:
    data = name.encode("utf-8")
    mask = (1 << 64) - 1
    mix = 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack("<Q", data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], "little")) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def build_name_map():
    """资源哈希 -> 实体名。用 datalibrary 的字符串表 + MurmurHash64A 反查。"""
    name_map = {}
    for cand in (
        ROOT.parent / "hd2-charge-mod/offline/datalibrary/hashes.txt",
        ROOT / "snapshot" / "hashes.txt",
    ):
        if not cand.exists():
            continue
        for line in cand.read_text(encoding="utf-8", errors="replace").splitlines():
            s = line.strip()
            if not s or s.startswith("//"):
                continue
            if "/materials/" in s or "/textures/" in s or s.startswith("packages/"):
                continue
            name_map[f"{murmur64a(s):016x}"] = s.rsplit("/", 1)[-1]
        break
    return name_map


# 出现在标记里但**不是虫巢**的资源（玩家标了敌人/投掷物，mod 正确地不接管）
NON_HOLE_HINTS = ("cha_", "cyber", "bot_", "chaos", "terran", "human", "elite")


def classify(resource, names, listed):
    """把一个被标记的资源归类: listed / excluded / enemy_or_projectile / MISSED。"""
    if resource in listed:
        return "listed"
    if resource in EXCLUDED:
        return "excluded"
    nm = names.get(resource, "")
    if nm and any(nm.startswith(t) for t in NON_HOLE_HINTS):
        return "enemy"                 # 玩家标记了敌人
    if resource == "16f397ca5f51f271":
        return "projectile"            # 带 StratagemBallComponent 的投掷物本体
    if nm and any(t in nm for t in ("bug_spawner", "colony_bug", "mechanical_bughole")):
        return "MISSED"                # ★ 真正的漏网之鱼：虫巢却不在清单里
    return "unknown"


def parse_log(path: pathlib.Path):
    """从日志提取实机证据。返回 (detonated, marked, rejected, soft_invalid)。"""
    if not path.exists():
        return set(), set(), {}, set()
    t2r, det, marked, soft = {}, set(), set(), set()
    rejected = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        d = dict(p.split("=", 1) for p in line.split(";")[1:] if "=" in p)
        kind = line.split(";")[0]
        if kind == "structure_mark":
            r, why = d.get("resource"), d.get("reason")
            if why == "ACCEPTED":
                t2r[d["target"]] = r
                marked.add(r)
            else:
                rejected[r] = rejected.get(r, 0) + 1
        elif kind == "arrival_detonated" and d.get("target") in t2r:
            det.add(t2r[d["target"]])
        elif kind == "structure_target_soft_invalid" and d.get("resource"):
            soft.add(d["resource"])
    return det, marked, rejected, soft


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", type=pathlib.Path,
                    default=pathlib.Path.home() / "AppData/Local/CowboyBingus/Helldivers2"
                                               "/Logs/G60BugholeLock.log")
    ap.add_argument("--out", type=pathlib.Path, default=None)
    args = ap.parse_args()

    prof_txt = PROFILE.read_text(encoding="utf-8")
    entries = re.findall(r'profiles\["([0-9a-f]{16})"\]=\{resource="[0-9a-f]{16}",'
                         r'kind="(structure_\w+)",nodes=(\d+)', prof_txt)
    listed = [h for h, _, _ in entries]
    names = build_name_map()
    det, marked, rejected, soft = parse_log(args.log)

    rows = []
    for h, kind, nodes in entries:
        if h in GUESSED:
            risk = "★HIGH(无基线，保守假设)"
        elif h in BORROWED:
            risk = "low(复用同模型基线)"
        elif h == "095686275a113614":
            risk = "low(上游原始参数)"
        else:
            risk = "low(上游标定值)"
        rows.append({
            "resource": h,
            "name": names.get(h, "(未收录)"),
            "nodes": int(nodes),
            "kind": kind,
            "in_list": True,
            "marked": h in marked,
            "detonated": h in det,
            "risk": risk,
        })

    verified = [r for r in rows if r["detonated"]]
    unverified = [r for r in rows if not r["detonated"]]
    # 清单外但被标记过的 = 真正的漏网之鱼
    by_class = {}
    for r, n in rejected.items():
        by_class.setdefault(classify(r, names, set(listed)), []).append(
            {"resource": r, "name": names.get(r, "(未收录)"), "rejected": n})
    missed = by_class.get("MISSED", [])

    w = 74
    print(f"日志: {args.log}")
    print("=" * w)
    print(f"{'资源':18} {'实体':34} {'清单':5} {'标记过':7} {'★炸过':7} 风险")
    print("-" * w)
    for r in sorted(rows, key=lambda x: (not x["detonated"], x["name"])):
        print(f"  {r['resource']}  {r['name'][:34]:34} "
              f"{'YES':5} {'YES' if r['marked'] else '—':7} "
              f"{'★YES' if r['detonated'] else '未验证':7} {r['risk']}")
    print("=" * w)
    print(f"清单收录 {len(rows)} 条 | 实机验证 ★{len(verified)} | 未验证 {len(unverified)}")
    if soft:
        print(f"软信号路径(target_valid=false 但只读复核通过)命中 {len(soft)} 种: {sorted(soft)}")
    if missed:
        print(f"\n⚠ 真正的漏网之鱼(虫巢却不在清单里) {len(missed)} 种:")
        for m in missed:
            print(f"   {m['resource']}  {m['name']}  被拒 {m['rejected']} 次")
    else:
        print("\n✓ 没有清单外的虫巢被标记过 —— 覆盖无遗漏")
    for cls, label in (("enemy", "玩家标记了敌人(正确不接管)"),
                       ("projectile", "玩家标记了投掷物(正确不接管)"),
                       ("excluded", "孢子菇/任务虫卵(按设计不接管)"),
                       ("unknown", "未识别的被拒资源")):
        if by_class.get(cls):
            items = ", ".join(f"{m['name']}x{m['rejected']}" for m in by_class[cls])
            print(f"  · {label}: {items}")

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(
            {"log": str(args.log), "rows": rows, "verified": len(verified),
             "unverified": len(unverified), "missed": missed,
             "rejected_by_class": {k: v for k, v in by_class.items()},
             "soft_invalid": sorted(soft)}, indent=2), encoding="utf-8")
        print(f"\n已写出 {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
