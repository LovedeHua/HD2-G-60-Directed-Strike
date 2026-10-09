"""Reproducible public build. Python stdlib only; no game installation required."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import struct
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'compat/build.json').read_text())

# ★★ 发布版本的**唯一来源**（2026-10-01）★★
#   发新版**只改这一行**，下面三处自动跟随：
#     manifest.json 的 Name / Options[0].Name  -> TITLE
#     dist/ 下的成品包文件名                    -> ZIP_NAME
#     BUILD-INFO.json 的 version                -> VERSION
#
#   为什么不放 compat/build.json：
#     · 它的顶层 key 被 tests/test_bughole_scope.py 的 `build_json_no_new_top_key` 钉死
#       （只允许 `aliases` 增加条目）⇒ 加不了我们自己的键；
#     · 它的 `public_version` 是**上游基线**版本，被 `build_json_pinned:*` 钉死
#       （必须与上游 0.1-beta.1 逐值相同）⇒ 不能拿它当我们的版本号。
#
#   事故背景：发 Release v0.1.2 时成品包还叫 `G60-BugHole-Lock-0.1.0.zip`
#   —— 因为 TITLE / ZIP_NAME 把 '0.1.0' 硬编码在代码里，与 Release 标签完全脱节。
RELEASE_VERSION = '0.1.7'
# ★ v0.1.7 的内容（2026-10-09，全部实机验证）：
#   · **无敌人时也能炸毁标记虫洞** —— 强制提升 state=4（`force_lock_enabled`，
#     本工程唯一的受控写通道；实机 5 颗雷 / 5 个虫洞全部炸毁）。
#   · **ping 空地路同样支持无敌人** —— 同一套提升 + 门控把"TTL 内的 ping"
#     当成与标记同级的玩家意图（实机生效）。
#   · 清理：研究脚手架（code_probe 默认关闭、候选组探针移除）。
#   ⚠ 这是本工程第一次绕过引擎 API 直接写游戏状态；`force_lock_enabled=false` 一键回退。
VERSION = RELEASE_VERSION
# ★ 裁剪版身份：独立 GUID + 独立资源名 + 独立标题，与上游官方包互不覆盖(管理器槽位二选一)。
# ★ 2026-10-09 改名（用户拍板）：**G-60 Bug Hole Lock → G-60 Directed Strike**。
#   旧名（Bug Hole Lock）是 v0.1.6 之前的能力写照；v0.1.7 之后它不只打虫洞，而是
#   「**只打玩家点的目标**」（虫洞 / 构筑 / 泰坦 / ping 空地）—— 这也正是它与上游
#   `Smart Targeting` 的本质区别。三处名字（资源名 / 显示名 / 包名）一起改，
#   归档槽位 `ARCHIVE` 与 `GUID` **不动** ⇒ 加载器那边是原地升级，不是新 mod。
NAME = 'mods/hd2test/g60_directed_strike'
GUID = '9c1d4e77-2b83-4f6a-91e5-0d7b3a6c8f42'
TITLE = f'G-60 Directed Strike {VERSION}'
# ★ ZIP_NAME / TITLE 都从 `release_version` 派生（见文件头注释）。
#   `derived_from` 里的 'etxp/HD2-G60-Smart-Targeting 0.1-beta.1' 指的是**上游基线**，
#   与我们的版本号无关，**不要**跟着改。
ZIP_NAME = f'G60-Directed-Strike-{VERSION}.zip'
ARCHIVE = 'Addon/9ba626afa44a3aa3.patch_0'


def resource_hash(name):
    """MurmurHash64A —— 换资源名后必须重算 archive 里的 nameHash。
    已对上游校验：resource_hash('mods/etxp/g60_small_filter') == tested-payload.resource_id。"""
    data = name.encode('utf-8')
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def assert_alias_order(aliases):
    """★ 校验每个模块的依赖都排在自己之前。

    build.py 把每个模块包成 (function() ... end)()，并把 require('g60.X')
    替换成对应的 chunk 别名。别名在使用者**之后**定义时，模块顶层
    `local Y=require('g60.y')` 替换后就是 `local Y=Y` —— 右值取外层 nil，
    于是整条依赖链在运行期静默失效。

    真实事故（2026-09-28 11:08）：
        link;mark=531;matched=1;...;entered=0;locked=0
        structure_unavailable;...: attempt to index upvalue 'Geometry' (a nil value)
    新加的 geometry 被我排在 native_priority **之后**，而 native_priority
    顶层就 require 它 ⇒ Geometry 恒 nil ⇒ 标记读到了却永远锁不上。

    这类错误肉眼极难发现（构建通过、语法通过、单测通过），只能自动校验。
    """
    order = {name: i for i, name in enumerate(aliases)}
    for name in aliases:
        source = (ROOT / 'src/g60' / (name + '.lua')).read_text()
        for dep in re.findall(r"require\('g60\.([a-z_0-9]+)'\)", source):
            if dep not in order:
                raise AssertionError(
                    f"module '{name}' requires unknown module 'g60.{dep}'")
            if order[dep] >= order[name]:
                raise AssertionError(
                    f"module order: 'g60.{name}' (pos {order[name]}) requires "
                    f"'g60.{dep}' (pos {order[dep]}) but is defined LATER. "
                    f"build.py inlines modules as local chunk aliases, so the "
                    f"dependency would be nil at run time. Move 'geometry'/etc "
                    f"before its users in compat/build.json aliases.")


def assert_field_refs():
    """★ 校验跨模块字段引用真实存在（2026-09-28 11:40 实机事故的直接修复）。

    事故：native_priority.lua 的 takeover_probe 里写
        local life=math.max(0,1-spent/Policy.lifetime_ticks)
    而该文件的 `Policy` 是 g60.target_policy（第 6 行），
    `lifetime_ticks` 属于 g60.arrival_policy（第 8 行才 require）。
    Lua 对 nil 做算术 ⇒
        attempt to perform arithmetic on field 'lifetime_ticks' (a nil value)
    **每一帧**都抛错，被 runtime 的 pcall 吞成 structure_unavailable，
    于是「标记读到、G-60 到 state 4，却一次都锁不上」。

    与 assert_alias_order 同类：这类错误 luac 通过、单测通过、只有实机炸。
    两者一起构成"构建期必须拦住的语义错误"关卡。
    """
    proc = subprocess.run(
        [sys.executable, '-B', 'tests/check_field_refs.py'],
        cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        raise AssertionError(
            'cross-module field check failed:\n' + proc.stdout + proc.stderr)


def assemble():
    aliases = CONFIG['aliases']
    assert_alias_order(aliases)
    assert_field_refs()
    modules = []
    for name, alias in aliases.items():
        source = (ROOT / 'src/g60' / (name + '.lua')).read_text()
        for key, value in aliases.items():
            source = source.replace("require('g60." + key + "')", value)
        modules.append('local ' + alias + '=(function()\n' + source + '\nend)()')
    for alias, filename, factory in [
        ('Binding', 'native_search_binding.lua', False),
        ('TitanProfile', 'titan_profile.lua', False),
        ('WeakpointProfiles', 'weakpoint_profiles.lua', True),
        ('StructureProfiles', 'structure_profiles.lua', True),
        # ★ 变体 profile（2026-09-29）：工厂函数，拿 TitanProfile 作为基线。
        #   与 structure_profiles 复用 common.getters 是同一机制。
        ('TitanVariants', 'titan_variants.lua', True),
        # ★ 体内爆点名册（2026-10-03）：与虫洞的"距离<4m"机制**分开**，
        #   见 compat/blast_sites.lua 文件头。无需工厂参数。
        ('BlastSites', 'blast_sites.lua', False),
        ('PriorityCatalog', 'priority_catalog.lua', False),
        ('FuseProfile', 'fuse_profile.lua', False),
    ]:
        source = (ROOT / 'compat' / filename).read_text()
        modules.insert(-1, 'local ' + alias + '=(function()\n' + source + '\nend)()'
                       + ('(TitanProfile)' if factory else ''))
    text = (ROOT / 'addon/entry.lua.in').read_text().replace('@@MODULES@@', '\n'.join(modules))
    text = text.replace('@@VERSION@@', VERSION)
    # ★ 两个占位符语义不同，别混（2026-10-01）：
    #   @@VERSION@@          = **本裁剪版的发布版本**（RELEASE_VERSION）—— "这是哪一版 mod"
    #   @@RUNTIME_BASELINE@@ = **上游运行时基线**（build.json 的 runtime_version，0.5.20）
    #                          —— "基于哪一版上游运行时"
    #   以前 @@VERSION@@ 填的是 runtime_version，日志写 `version=0.5.20-bughole`，
    #   与本 mod 的版本（当时已到 0.1.2）完全不是一回事，排查时容易误判。
    text = text.replace('@@RUNTIME_BASELINE@@', CONFIG['runtime_version'])
    text = text.replace('@@GAME_GUARDS@@', CONFIG['game_guards_lua'])
    text = text.replace('@@ENGINE_CODE@@', CONFIG['engine_code'])
    # ★★ 2026-10-09 受控例外（用户明确拍板"走写内存这条路"）★★
    #   `WriteProcessMemory` 从"一律禁止"改为**计数式允许**：
    #     · 恰好 1 处调用（`.WriteProcessMemory(`）—— 防被顺手复制到别处；
    #     · 全文提及 ≤ 2 次（cdef 声明 + 那唯一一处调用）。
    #   配套硬边界写在 addon/entry.lua.in 的 write() 与 src/g60/native_priority.lua
    #   的 promote_state4 里，并有守门钉着：单次 ≤64 字节、写前复核 + 写后回读、
    #   只允许用于状态记录的 3 个 dword（state/behavior/mid）。
    #   其余高危能力（VirtualAlloc / VirtualProtect / LoadLibrary / GetProcAddress /
    #   MinHook / ffi.copy）**仍然一律禁止** —— 那些才是真正的高危面。
    assert text.count('.WriteProcessMemory(') == 1, (
        'WriteProcessMemory 必须恰好 1 处调用（受控例外），实际 '
        + str(text.count('.WriteProcessMemory(')) + ' 处')
    assert text.count('WriteProcessMemory') <= 2, (
        'WriteProcessMemory 全文提及不得超过 2 次（cdef + 调用点），实际 '
        + str(text.count('WriteProcessMemory')) + ' 次')
    for forbidden in ('VirtualAlloc', 'VirtualProtect', 'LoadLibrary',
                      'GetProcAddress', 'MinHook', 'ffi.copy', "require('g60.", '@@'):
        assert forbidden not in text, 'Unexpected runtime capability: ' + forbidden
    assert 'native_lifetime_verified=true' not in text
    return text.encode()


def archive(body):
    # ★ 不再从上游 evidence/tested-payload.json 取 resource_id —— 那个值属于上游资源名。
    #   这里按本工程的 NAME 现算，避免"换了名字却还用旧 hash"导致 loader 认不出资源。
    resource_id = resource_hash(NAME)
    lua_type = 0xA14E8DFA2CD117E2
    offset = 192
    payload = struct.pack('<II', len(body), 2) + body
    size = (offset + len(payload) + 15) & ~15
    result = bytearray(size)
    struct.pack_into('<III20sQQ24s', result, 0, 0xF0000011, 1, 1, b'', size, 0, b'')
    struct.pack_into('<IIQIIII', result, 72, 0, 0, lua_type, 1, 0, 16, 16)
    struct.pack_into('<7Q6I', result, 104, resource_id, lua_type, offset,
                     0, 0, 0, 0, len(payload), 0, 0, 16, 16, 0)
    result[offset:offset + len(payload)] = payload
    return bytes(result)


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode()


def package_files():
    entry = assemble()
    body = ('-- HD2-Addon: ' + NAME + '\n').encode() + entry
    files = {ARCHIVE: archive(body), ARCHIVE + '.stream': b'', ARCHIVE + '.gpu_resources': b''}
    title = TITLE
    description = ('Bughole-only build. When YOU mark one of the nine supported bug holes '
                   '(eight normal nests plus the large colony hole used by the Bile Titan nest), '
                   'the grenade is redirected to detonate there and interrupts whatever enemy '
                   'lock the game had chosen. With no bug-hole mark this addon does nothing and '
                   'G-60 keeps the game native targeting. Enemy priority, tuned weakpoints, '
                   'Shrieker Nest, Spore Spewer and objective eggs are all removed. '
                   'Experimental original native calls; requires Bingus Shared Loader API 1. '
                   'Mutually exclusive with the upstream HD2-G60-Smart-Targeting package '
                   '(enable one or the other, not both).')
    files['manifest.json'] = json_bytes({'Version': 1, 'Guid': GUID, 'Name': title,
        'Description': description, 'Options': [{'Name': title, 'Description': description, 'Include': ['Addon']}]})
    # ★ 只打"仍然成立"的文档。上游 README / docs / CHANGELOG 描述的是完整功能
    #   (自动敌人优先级、弱点、尖啸者巢、任务虫卵)，与本裁剪版不符，打进去会误导使用者。
    for pattern in ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md'):
        for path in ROOT.glob(pattern):
            if path.is_file():
                files[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    files['Source/' + NAME.rsplit('/', 1)[-1] + '.lua'] = body
    files['BUILD-INFO.json'] = json_bytes({'version': VERSION, 'runtime_baseline': CONFIG['runtime_version'],
        'derived_from': 'etxp/HD2-G60-Smart-Targeting 0.1-beta.1',
        'entry_sha256': sha(entry), 'resource_name': NAME, 'resource_id': f'{resource_hash(NAME):016X}',
        'bughole_profiles': 9,
        'addon_sha256': {n: sha(b) for n, b in files.items() if n.startswith('Addon/')}})
    return files


def write_zip(path, files):
    path.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(path, 'w', compression=ZIP_DEFLATED) as z:
        for name, data in sorted(files.items()):
            info = ZipInfo(name, (2026, 9, 27, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, data)


def main():
    files = package_files()
    (ROOT / 'build').mkdir(exist_ok=True)
    (ROOT / 'build/entry.lua').write_bytes(assemble())
    # ★ 本工程基线：上游 check.py 那套"产物必须与 release 逐字节一致"的断言对裁剪版
    #   必然不成立（我们就是来改的）。这里记录本工程自己的 entry / addon 哈希，
    #   供 check.py 与之后的改动做回归比对。
    derived = {'derived_from': 'etxp/HD2-G60-Smart-Targeting 0.1-beta.1',
               'resource_name': NAME, 'resource_id': f'{resource_hash(NAME):016X}',
               'entry_sha256': sha(assemble()),
               'addon_sha256': {n: sha(b) for n, b in files.items() if n.startswith('Addon/')}}
    (ROOT / 'evidence').mkdir(exist_ok=True)
    (ROOT / 'evidence/derived-payload.json').write_text(json.dumps(derived, indent=2) + '\n')
    target = ROOT / 'dist' / ZIP_NAME
    write_zip(target, files)
    print(json.dumps({'package': str(target.relative_to(ROOT)), 'sha256': sha(target.read_bytes()),
                      'entry_sha256': derived['entry_sha256'],
                      'resource_id': derived['resource_id'],
                      'resource_name': NAME, 'guid': GUID}, indent=2))


if __name__ == '__main__':
    main()
