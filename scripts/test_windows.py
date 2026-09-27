"""Optional Windows x64 fixture suite under Wine; never attaches to the game."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from build import ROOT, assemble, sha


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--compiler', required=True, help='Windows x64 C compiler')
    p.add_argument('--runner', required=True, type=Path, help='Windows lua-tool.exe runner')
    p.add_argument('--lua-dll', required=True, type=Path, help='Locally supplied Windows LuaJIT lua51.dll')
    args = p.parse_args()
    folder = ROOT / 'build/windows'; folder.mkdir(parents=True, exist_ok=True)
    dll = folder / 'g60_owned_fixture.dll'
    subprocess.run([args.compiler, '-shared', '-O2', '-Wall', '-Wextra', '-Werror',
                    str(ROOT / 'tests/native_minimal_fixture.c'), '-o', str(dll)], check=True)
    entry = folder / 'entry.lua'; entry.write_bytes(assemble())
    binding = folder / 'g60/native_search_binding.lua'; binding.parent.mkdir(exist_ok=True)
    binding.write_bytes((ROOT / 'compat/native_search_binding.lua').read_bytes())
    def win(path): return 'Z:' + str(path.resolve()).replace('/', '\\')
    prefix = 'package.path=' + json.dumps(win(folder) + '/?.lua;' + win(ROOT / 'src') + '/?.lua;') + '..package.path\n'
    for key, path in {'G60_ENTRY': entry, 'G60_FIXTURE_DLL': dll,
        'G60_TITAN_PROFILE': ROOT / 'compat/titan_profile.lua',
        'G60_WEAKPOINT_PROFILE': ROOT / 'compat/weakpoint_profiles.lua',
        'G60_STRUCTURE_PROFILE': ROOT / 'compat/structure_profiles.lua',
        'G60_PRIORITY_CATALOG': ROOT / 'compat/priority_catalog.lua',
        'G60_FUSE_PROFILE': ROOT / 'compat/fuse_profile.lua',
        'G60_TEST_LOG': folder / 'addon.log'}.items():
        prefix += key + '=' + json.dumps(win(path)) + '\n'
    groups = [('native_minimal_windows',), ('native_search_context', 'titan_context', 'titan_route',
        'weakpoint_context', 'weakpoint_route', 'priority_data', 'experimental_windows',
        'priority_windows', 'arrival_windows', 'weakpoint_windows', 'charger_windows',
        'allowlist_windows', 'ping_history_windows', 'allocation_windows', 'structure_windows')]
    env = dict(os.environ, WINEDEBUG='-all', WINEDLLOVERRIDES='winemenubuilder.exe=d', DISPLAY='', WAYLAND_DISPLAY='')
    output = []
    for index, suites in enumerate(groups):
        script = folder / ('run-' + str(index) + '.lua')
        script.write_text(prefix + ''.join('assert(loadfile(' + json.dumps(win(ROOT / 'tests' / (s + '.lua'))) + '))()\n' for s in suites))
        result = subprocess.run(['wine', str(args.runner), win(args.lua_dll), win(script),
                                 win(folder / 'unused'), 'run'], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=60)
        output.append(result.stdout + result.stderr)
        assert result.returncode == 0, output[-1]
    report = {'passed': True, 'game_process_attached': False, 'native_lifetime_verified': False,
              'entry_sha256': sha(entry.read_bytes()),
              'output': '\n'.join(output)}
    (folder / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(report['output'])


if __name__ == '__main__': main()
