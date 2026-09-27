# Building

Run from the repository root with Python 3.10+:

```sh
python -B scripts/check.py
python -B scripts/build.py
```

Install LuaJIT and/or Lua to run the policy suite. With both installed, both are tested.
The installable package is `dist/HD2-G60-Smart-Targeting-0.1-beta.1.zip`.
The builder uses only Python's standard library and never installs the addon or connects to a game process.

`src/g60` holds authored modules. `addon/entry.lua.in` supplies the loader entry and runtime checks.
`compat` holds the reviewed binding, signatures, IDs, priority catalog and model-derived profiles used by this release.
The public assembler freezes those inputs instead of requiring private executable captures or local asset databases.
The original 0.1 beta reproduced the 0.5.19 deployment bytes. Beta.1 adds optional logging and reports runtime
version 0.5.20; targeting modules and native compatibility profiles retain their previous contents.

`scripts/check.py` verifies the current isolated-tested release against `evidence/release-payload.json`.
The original gameplay-tested hashes remain in `evidence/tested-payload.json`; they are not rewritten.
Beta.1 has optional-logging regression and Windows fixture results, but no new live-game validation.
`scripts/build.py` continues to report `matches_tested_payload: false` for this change from the historical baseline.

## Optional Windows fixture tests

The source includes a C fixture DLL and Windows LuaJIT integration suites. The fixture is built locally and is
never placed in the installable package. To run under Wine, supply a Windows x64 C compiler, a local compatible
`lua-tool.exe` runner and a Windows LuaJIT `lua51.dll`:

```sh
python -B scripts/test_windows.py --compiler /path/to/x86_64-w64-mingw32-clang \
  --runner /path/to/lua-tool.exe --lua-dll /path/to/lua51.dll
```

The runner contract is `lua-tool.exe <lua51.dll> <script.lua> <unused-output> run`.
Set `WINEPREFIX` to an isolated test prefix. These optional tools and proprietary game DLLs are not distributed here.
Tests call only the fixture and synthetic world observations, never a running game's native functions.
