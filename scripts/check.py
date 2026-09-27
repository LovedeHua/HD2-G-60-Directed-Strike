"""Portable tests and current release hashes, preserving the historical baseline."""
import json
from pathlib import Path
import re
import shutil
import subprocess
from build import ROOT, assemble, package_files, sha

SUITES = ('run', 'search_return', 'selection_veto', 'native_observer', 'native_authority',
          'native_search_context', 'native_readiness', 'preflight_probe', 'titan_route',
          'weakpoint_route', 'charger_route', 'target_allowlist', 'target_reservations',
          'structure_route', 'ping_memory', 'arrival_policy', 'entry_logging')


def main():
    results = []
    for runtime in ('luajit', 'lua'):
        if not shutil.which(runtime):
            continue
        for suite in SUITES:
            p = subprocess.run([runtime, 'tests/' + suite + '.lua'], cwd=ROOT,
                               capture_output=True, text=True, timeout=30)
            m = re.search(r'RESULT (\d+) passed; (\d+) failed', p.stdout)
            assert p.returncode == 0 and m and int(m[2]) == 0, p.stdout + p.stderr
            results.append({'runtime': runtime, 'suite': suite, 'passed': int(m[1])})
    assert results, 'Install LuaJIT or Lua to run the policy tests'
    files = package_files()
    baseline = json.loads((ROOT / 'evidence/tested-payload.json').read_text())
    release = json.loads((ROOT / 'evidence/release-payload.json').read_text())
    assert sha(assemble()) == release['entry_sha256'], 'Release entry differs from validated release source'
    for name, digest in release['addon_sha256'].items():
        assert sha(files[name]) == digest, 'Archive mismatch: ' + name
    manifest = json.loads(files['manifest.json'])
    assert manifest['Version'] == 1 and manifest['Options'][0]['Include'] == ['Addon']
    assert files['Addon/9ba626afa44a3aa3.patch_0.stream'] == b''
    report = {'passed': True, 'checks': results, 'total': sum(r['passed'] for r in results),
              'matches_tested_payload': sha(assemble()) == baseline['entry_sha256'],
              'matches_release_payload': True, 'entry_sha256': sha(assemble()),
              'game_process_attached': False, 'native_lifetime_verified': False}
    (ROOT / 'build').mkdir(exist_ok=True)
    (ROOT / 'build/public-validation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
