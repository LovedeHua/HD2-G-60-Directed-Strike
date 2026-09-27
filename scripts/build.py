"""Reproducible public build. Python stdlib only; no game installation required."""
import hashlib
import json
from pathlib import Path
import struct
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'compat/build.json').read_text())
VERSION = CONFIG['public_version']
NAME = 'mods/etxp/g60_small_filter'
GUID = '58a16a67-a72b-474a-ad05-adbaaa99da78'
ARCHIVE = 'Addon/9ba626afa44a3aa3.patch_0'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def assemble():
    aliases = CONFIG['aliases']
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
        ('PriorityCatalog', 'priority_catalog.lua', False),
        ('FuseProfile', 'fuse_profile.lua', False),
    ]:
        source = (ROOT / 'compat' / filename).read_text()
        modules.insert(-1, 'local ' + alias + '=(function()\n' + source + '\nend)()'
                       + ('(TitanProfile)' if factory else ''))
    text = (ROOT / 'addon/entry.lua.in').read_text().replace('@@MODULES@@', '\n'.join(modules))
    text = text.replace('@@VERSION@@', CONFIG['runtime_version'])
    text = text.replace('@@GAME_GUARDS@@', CONFIG['game_guards_lua'])
    text = text.replace('@@ENGINE_CODE@@', CONFIG['engine_code'])
    for forbidden in ('VirtualAlloc', 'VirtualProtect', 'WriteProcessMemory', 'LoadLibrary',
                      'GetProcAddress', 'MinHook', 'ffi.copy', "require('g60.", '@@'):
        assert forbidden not in text, 'Unexpected runtime capability: ' + forbidden
    assert 'native_lifetime_verified=true' not in text
    return text.encode()


def archive(body):
    baseline = json.loads((ROOT / 'evidence/tested-payload.json').read_text())
    resource_id = int(baseline['resource_id'], 16)
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
    title = 'HD2 G-60 Smart Targeting ' + VERSION.replace('-', ' ')
    description = ('G-60 priority targeting, tuned weakpoints, one grenade per target, and locally marked '
                   'bug holes, nests and objective eggs. Experimental original native calls; '
                   'requires Bingus Shared Loader API 1. See compatibility and beta limitations.')
    files['manifest.json'] = json_bytes({'Version': 1, 'Guid': GUID, 'Name': title,
        'Description': description, 'Options': [{'Name': title, 'Description': description, 'Include': ['Addon']}]})
    for pattern in ('*.md', 'LICENSE', 'docs/*.md', 'evidence/*.json', 'assets/cover-16x9.png', 'assets/cover-4x3.png'):
        for path in ROOT.glob(pattern):
            if path.is_file():
                files[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    files['Source/g60_small_filter.lua'] = body
    files['BUILD-INFO.json'] = json_bytes({'version': VERSION, 'runtime_baseline': CONFIG['runtime_version'],
        'entry_sha256': sha(entry), 'resource_name': NAME,
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
    baseline = json.loads((ROOT / 'evidence/tested-payload.json').read_text())
    # A changed development checkout remains buildable; checks report whether
    # it still matches this release. Never silently certify changed source.
    matches = all(sha(files[n]) == digest for n, digest in baseline['addon_sha256'].items())
    (ROOT / 'build').mkdir(exist_ok=True)
    (ROOT / 'build/entry.lua').write_bytes(assemble())
    target = ROOT / 'dist' / ('HD2-G60-Smart-Targeting-' + VERSION + '.zip')
    write_zip(target, files)
    print(json.dumps({'package': str(target.relative_to(ROOT)), 'sha256': sha(target.read_bytes()),
                      'matches_tested_payload': matches}, indent=2))


if __name__ == '__main__':
    main()
