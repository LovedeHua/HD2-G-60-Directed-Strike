"""Mod Options Menu 的**语言跟随**守门（2026-10-10 用户要求）。

原话：「mod设置的语言要能跟随游戏语言变化，比如说游戏语言是英语，mod设置显示的也是英语」。

这一门要拦住的事故类型：
  · 英语客户端看到中文（或看到 `blast_safe_radius.label` 这种键名）——
    根因通常是"文案只写了一份中文、没有英语回退"或"回退链断了"；
  · 菜单 API `version<2` 时给了函数（旧菜单不认识）或给了超长字符串（截断成乱码）；
  · 读语言失败（启动早期设置表为空 / Steam 没起来）时**抛错** ——
    菜单注册在主链路上，抛错等于整栏菜单消失；
  · 运行期改语言不生效（label 传的是**字符串**快照而不是函数）。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME_ENTRY = ROOT / 'addon' / 'entry.lua.in'
MODULE = ROOT / 'src' / 'g60' / 'menu_text.lua'

CHECKS = []


def check(name, ok, detail):
    CHECKS.append((name, bool(ok), detail))


def main():
    try:
        import lupa
    except ImportError:  # pragma: no cover
        print('SKIP: lupa 不可用')
        return 0

    entry = RUNTIME_ENTRY.read_text(encoding='utf-8')
    src = MODULE.read_text(encoding='utf-8')

    # ---------- 1) 模块自检（英语覆盖 / 键集合一致 / 字节上限）----------
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    M = lua.execute(src)
    problems = [str(v) for v in M.check().values()]
    check('menu_text_selfcheck_clean', not problems,
          '★★ 文案自检必须全过：`en` 必须覆盖**每一个键**（英语客户端绝不能看到中文或键名）、'
          '两套文案键集合必须一致、英语 label≤64 / desc≤400 字节'
          '（v1 菜单的字节上限；超了会退回英语，而英语本身超了就没得退）'
          + ('  实际：' + ' | '.join(problems) if problems else ''))

    # ---------- 2) 回退链：任何未翻译语言都必须显示**英语** ----------
    en_mod = str(M.text('en', 'mod'))
    fallbacks = {lang: str(M.text(lang, 'mod'))
                 for lang in ('de', 'ja', 'ko', 'ru', 'zh-Hant', 'es-419', 'xx')}
    bad = {k: v for k, v in fallbacks.items() if v != en_mod}
    check('untranslated_language_falls_back_to_english', not bad,
          '★★ 没出翻译的语言（德语/日语/韩语/繁体…）必须显示**英语**，'
          '不能显示中文、也不能显示键名 —— 这是"游戏语言是英语时菜单就是英语"的保证。'
          + ('  实际跑偏：' + repr(bad) if bad else ''))
    check('missing_key_falls_back_to_key',
          str(M.text('en', 'no.such.key')) == 'no.such.key',
          '★ 连英语都没有的键退回**键名**（宁可难看也不能是 nil —— 菜单会崩）')
    zh_mod = str(M.text('zh-Hans', 'mod'))
    check('chinese_pack_still_present', zh_mod and zh_mod != en_mod,
          '★ 中文文案仍在（用户是中文玩家；语言跟随不等于"改成英语"）')

    # ---------- 3) 读语言失败必须**安静退回**，不能抛错 ----------
    ok_nil = M.game_code(None, None)
    check('game_code_without_read_is_nil', ok_nil is None,
          '★ `read`/`base` 拿不到时返回 nil（启动早期就是这样），不抛错')

    def boom(*_a):
        raise RuntimeError('read bound')

    ok_boom = M.game_code(lua.eval('function(f) return f end')(boom), 0x140000000)
    check('game_code_survives_read_failure', ok_boom is None,
          '★★ `read` 抛错（本项目 entry 的 read 会 assert 越界）必须被 pcall 吞掉并返回 nil '
          '⇒ 退回英语。菜单注册在主链路上，抛错 = 整栏菜单消失')
    tag, src_ = M.language(lua.eval('function() return nil end'), None)
    check('language_falls_back_to_english',
          str(tag) == 'en' and str(src_) == 'default',
          '★★ 游戏设置读不到 ⇒ `en`/`default`（fail-safe）。'
          ' ⚠ 刻意**不查 Steam 语言**：那要 GetProcAddress，而本工程构建器禁止动态符号解析'
          '（`scripts/build.py` 的 assemble 断言；那些才是真正的高危面）')

    # ---------- 4) entry 侧：函数式 label + 无中文字面量 + 字节上限 ----------
    check('menu_labels_are_functions_on_v2',
          "local functions=(tonumber(h.version) or 1)>=2" in entry
          and "if functions then return function() return menu_tr(key) end end" in entry,
          '★★ `version>=2` 必须传**函数**（菜单每次打开都调用 ⇒ 运行期改语言也能跟上）；'
          ' 传字符串快照的话，改完语言要重开游戏才生效')
    check('menu_labels_use_menu_text',
          "local menu_tr,menu_lang=MenuText.new(read,base)" in entry
          and "label=menu_text(it.key..'.label',64)" in entry
          and "description=menu_text(it.key..'.desc',400)" in entry
          and "mod=menu_text('mod',40)" in entry,
          '★★ label/description/mod 三个字段都必须走 MenuText（并按 64/400/40 字节上限）')
    check('menu_items_have_no_text_literals',
          "label='" not in entry.split('local MENU_ITEMS={')[1].split('local function menu_register')[0]
          and "desc='" not in entry.split('local MENU_ITEMS={')[1].split('local function menu_register')[0],
          '★★ MENU_ITEMS 里**不允许再出现任何 label=/desc= 字面量** —— '
          '文案只有一处来源（menu_text.lua），否则"英语客户端看到中文"永远查不干净')
    check('menu_text_string_path_has_english_fallback',
          "return menu_tr(key,'en')" in entry,
          '★ `version<2` 的字符串路径：超字节上限时退回**英语**（不能截断，截断的中文比英语更难读）')
    check('menu_language_is_logged',
          "emit('menu_lang;tag='" in entry and "line:match('^menu_lang;')" in entry,
          '★★ 必须打 `menu_lang;tag=…;src=game|steam|default;functions=…` 并进白名单 —— '
          '用户报「英语客户端显示中文」时，没有这一行就只能靠猜')

    # ---------- 5) 语言代码映射 ----------
    #   ⚠ 必须用**同一个** Lua runtime 取表：lupa 不允许跨 runtime 传对象。
    codes = M.CODES
    check('english_variants_map_to_en',
          all(str(codes[k]) == 'en' for k in ('us', 'en', 'gb', 'uk', 'en-GB', 'en-AU')),
          '★ 所有英语变体都归到 `en`（en-GB 客户端显示英语本身就是对的）')
    check('chinese_codes_map_to_zh_hans',
          str(codes['cn']) == 'zh-Hans' and str(codes['zh-CN']) == 'zh-Hans',
          '★ 简中代码归到 `zh-Hans`（游戏自己的代码是 `cn`）')
    check('no_dynamic_symbol_resolution',
          "require('ffi')" not in src and 'ffi.C.' not in src and 'cdef' not in src,
          '★★ 文案模块**不得**有任何 ffi 能力（动态符号解析 / 内存改写类）—— '
          '构建器的 assemble 会直接断言失败（本工程的高危面硬边界）；'
          ' 这里查的是**能力**（ffi 调用），不是注释里提没提名字')

    # ---------- 输出 ----------
    passed = sum(1 for _, ok, _ in CHECKS if ok)
    for name, ok, detail in CHECKS:
        if not ok:
            print('  FAIL %-46s [%s]' % (name, detail))
    print('RESULT: %s (%d checks)' % ('ALL PASS' if passed == len(CHECKS) else
                                      '%d passed; %d failed' % (passed, len(CHECKS) - passed),
                                      len(CHECKS)))
    return 0 if passed == len(CHECKS) else 1


if __name__ == '__main__':
    raise SystemExit(main())
