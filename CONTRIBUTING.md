# Contributing

Run `python -B scripts/check.py` before proposing changes. Explain the gameplay problem, the affected target and the validation performed.
For route or arrival changes, include tests for missed/blocked approaches as well as successful arrival.
Native call changes require signature, ABI, identity and ownership evidence plus Windows fixture tests.
Separate synthetic test results from gameplay confirmation; do not treat observation stability as proof of native lifetime.

Do not add executable-memory patches, instruction hooks, trampolines, integrity bypasses or custom DLL loading in the game.
Do not commit game executables, DLLs, memory dumps, raw asset captures, personal logs or credentials.
Keep the mod GUID and `mods/etxp/g60_small_filter` resource stable unless an intentional migration is documented.
