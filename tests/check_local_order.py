"""通用检查：任何 `local` 都不得在**它的声明之前**或**声明所在块之外**被使用。

为什么需要（同一类坑咬了两次，都是实机才暴露）：
  ① 2026-10-10 `faction`
       `local function faction` 定义在 `if structure_ping then` 块**内部**，
       而兜底 veto 那处调用在该块**闭合之后** ⇒ 取到全局 `faction` = nil ⇒
       `frame_error;…:8960: attempt to call global 'faction' (a nil value)`，
       每触发一次就**中止当帧剩余全部处理**。
  ② 2026-10-10 `pointer`
       `local function pointer` 在第 683 行，而 players_scan 在第 242 行就用它
       ⇒ `safe_players;n=0;reason=…:7297: attempt to call global 'pointer' (a nil value)`
       ⇒ 队友安全区**整段静默失效**（fail-safe 兜住了行为，但功能是死的）。

  Lua 的可见性由**词法块 + 文本位置**决定，与缩进无关 —— 肉眼极难发现，
  而 `luac` 通过、单测通过、只有实机炸（本工程的"构建期必须拦住"清单又加一条）。

判据（对每个标识符出现处）：
  存在某个同名 `local` 声明 D，使得
    · D 所在块链是"使用处块链"的**前缀**（= 使用处位于 D 的块内或更深），且
    · D 的文本位置在使用处**之前**
  ⇒ 可见（合法）。否则该标识符解析为**全局** —— 几乎总是 bug。

已知的保守取舍（宁可漏报也不误报）：
  · 字段访问 `x.name` / `x:name` 跳过；
  · `local x = function() … end` 里 x 在其自身函数体内被当作可见（Lua 实际不可见）
    ⇒ 这一类**漏报**，不误报；
  · 声明名自身、关键字、以及 `goto`/标签等跳过。

用法：python tests/check_local_order.py [文件或目录…]（默认 src/g60 全部 + compat）
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

KEYWORDS = {
    'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto',
    'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true',
    'until', 'while',
}

TOKEN = re.compile(r"[A-Za-z_][A-Za-z_0-9]*|\S")


def strip_comments_and_strings(src):
    """去注释与字符串（保留换行以便报行号）。返回清洗后的字符流。"""
    i, n, out = 0, len(src), []
    while i < n:
        if src.startswith('--[[', i) or src.startswith('--[=[', i):
            j = (src.index(']]', i) + 2) if src.startswith('--[[', i) \
                else (src.index(']=]', i) + 3)
            out.append('\n' * src.count('\n', i, j))
            i = j
            continue
        if src.startswith('--', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        c = src[i]
        if c in '"\'':
            q, j = c, i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == q:
                    j += 1
                    break
                if src[j] == '\n':
                    break
                j += 1
            out.append('\n' * src.count('\n', i, j))
            i = j
            continue
        if src.startswith('[[', i):
            j = src.index(']]', i) + 2
            out.append('\n' * src.count('\n', i, j))
            i = j
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def scan(clean):
    """一趟扫完：返回 (decls, uses)。
    decls: name -> [(pos, chain_tuple)]
    uses:  [(name, pos, chain_tuple)]
    chain 用"块开启处的字符位置"元组表示，前缀关系即"块包含"关系。
    """
    decls, uses = {}, []
    noisy = set()                 # 当过函数参数或 for 变量的名字 ⇒ 整体跳过
    stack = []
    skip_then = 0
    pending_params = None        # function 的参数表收集状态
    pending_for = None           # for 循环变量（只登记名字，见下）
    tokens = list(TOKEN.finditer(clean))
    prev_significant = None       # 上一个非空 token 文本
    prev_end = -1
    for idx, m in enumerate(tokens):
        t = m.group(0)
        pos = m.start()
        # ---- 块结构（与 tests/../_dumps/scope_chain2.py 同一套状态机）----
        if t == 'if':
            skip_then = 0
        elif t == 'elseif':
            skip_then = 1
        elif t == 'then':
            if not skip_then:
                stack.append(pos)
            skip_then = 0
        elif t == 'do':
            stack.append(pos)
        elif t == 'function':
            stack.append(pos)
            pending_params = []
        elif t == 'repeat':
            stack.append(pos)
        elif t in ('end', 'until'):
            if stack:
                stack.pop()
        # ---- 函数参数 / for 变量：**不**当声明处理，只登记进 noisy ----
        #   它们同样是 local，但作用域分析对它们极易误报（参数表、`in ipairs(…)`、
        #   `for i=1,n` 的界限表达式…）⇒ 只要某个名字在文件里当过参数或循环变量，
        #   就整体跳过这个名字。实测咬人的两个（`faction` / `pointer`）都是
        #   `local function` 名，不属于这一类 ⇒ 漏报可接受、误报不可接受。
        if pending_params is not None:
            if t == '(':
                pending_params = True
            elif t == ')' and pending_params is not True:
                pending_params = None
        if pending_params is True:
            if re.match(r'^[A-Za-z_]\w*$', t) and t not in KEYWORDS:
                noisy.add(t)
            elif t == ')':
                pending_params = None
        # ---- for 循环变量 ----
        if t == 'for':
            pending_for = True
        elif pending_for is True and t in ('do', '='):
            pending_for = None
        elif pending_for is True and re.match(r'^[A-Za-z_]\w*$', t) and t not in KEYWORDS:
            noisy.add(t)
        # ---- 声明：**只收 `local function NAME`** ----
        #   为什么只收这一种：实测咬人的两次（`faction` / `pointer`）都是这个形状。
        #   收 `local a,b=…` 会把"多赋值左侧"（`planned,value,detail=pcall(…)`）误判成
        #   "使用" ⇒ 大量误报。本检查的原则是**宁可漏报也不误报**（误报会让门失去信任）。
        if t == 'local':
            j = idx + 1
            if j < len(tokens) and tokens[j].group(0) == 'function':
                j += 1
                if j < len(tokens) and re.match(r'^[A-Za-z_]\w*$', tokens[j].group(0)):
                    nm = tokens[j]
                    decls.setdefault(nm.group(0), []).append((nm.start(), tuple(stack)))
            else:
                # ⚠ `local NAME=…` 这种形式**不收**（多赋值左侧会被误判成使用），
                #   但要把它的名字登记进 noisy —— 否则"同名另有 local NAME= 声明"时，
                #   那些真正的使用会被拿去和别处的 `local function NAME` 比对 ⇒ 误报。
                #   实测：`after`（`local after,agent_after='nil','nil'` 与
                #   文件末尾的 `local function after(...)` 同名）。
                while j < len(tokens):
                    tk = tokens[j].group(0)
                    if tk in ('=', ';', '\n'):
                        break
                    if re.match(r'^[A-Za-z_]\w*$', tk):
                        noisy.add(tk)
                    j += 1
        # ---- 使用处 ----
        if re.match(r'^[A-Za-z_]\w*$', t) and t not in KEYWORDS:
            field = (prev_significant in ('.', ':'))
            # ⚠ 表构造里的**键**（`{pt=…, seen=…}`）不是变量使用 —— 实测这一条
            #   制造了绝大多数误报。判据：后面紧跟 `=`（且不是 `==`）。
            nxt = tokens[idx + 1].group(0) if idx + 1 < len(tokens) else ''
            is_key = (nxt == '=')
            # 声明名自身不算"使用"
            is_decl_name = any(d[0] == pos for lst in decls.values() for d in lst)
            if not field and not is_key and not is_decl_name:
                uses.append((t, pos, tuple(stack)))
        if t.strip():
            prev_significant = t
            prev_end = m.end()
    return decls, uses, noisy


def analyze(path):
    src = path.read_text(encoding='utf-8')
    clean = strip_comments_and_strings(src)
    decls, uses, noisy = scan(clean)
    problems = []
    for name, pos, chain in uses:
        if name not in decls or name in noisy:
            continue                      # 全局变量 / 噪声名字：本检查不管
        ok = False
        for dpos, dchain in decls[name]:
            if dpos < pos and chain[:len(dchain)] == dchain:
                ok = True
                break
        if not ok:
            line = clean.count('\n', 0, pos) + 1
            problems.append((line, name))
    return problems


def main():
    args = sys.argv[1:]
    if args:
        targets = [pathlib.Path(a) for a in args]
    else:
        targets = sorted((ROOT / 'src/g60').glob('*.lua')) + sorted((ROOT / 'compat').glob('*.lua'))
    bad = 0
    for p in targets:
        if p.is_dir():
            files = sorted(p.rglob('*.lua'))
        else:
            files = [p]
        for f in files:
            probs = analyze(f)
            if probs:
                bad += len(probs)
                for line, name in probs:
                    print('  BUG  %s:%d  使用了尚未可见的 local `%s`（会解析成全局 ⇒ nil）'
                          % (f.relative_to(ROOT).as_posix(), line, name))
            else:
                print('  OK   %s' % f.relative_to(ROOT).as_posix())
    if bad:
        print('\nRESULT: %d 处 local 作用域错误（构建期必须拦住）' % bad)
        return 1
    print('\nRESULT: ALL PASS（没有"声明前/块外使用 local"的情况）')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
