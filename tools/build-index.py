#!/usr/bin/env python3
"""Build an AI-readable index of installed Arma Reforger addons + launcher presets.

  python build-index.py index
  python build-index.py extract [preset-name | all]

`index` reads the launcher presets, every addon's .gproj/meta and every data.pak
file table. `extract` writes only text/code resources loose so they can be read
and edited without repacking the pak.
"""
import concurrent.futures
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'skill', 'arma-reforger-modding', 'scripts'))
from refpak import Pak  # noqa: E402

HOME = os.path.expanduser('~')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONS = os.environ.get('ARMA_ADDONS') or os.path.join(
    HOME, 'Documents', 'My Games', 'ArmaReforger', 'addons')
CTX = os.path.join(ROOT, 'context')
WORK = os.path.join(ROOT, 'work')


def find_settings():
    """Newest launcher settings file, no account or app id baked in."""
    env = os.environ.get('ARMA_PRESETS')
    if env:
        return env
    pattern = os.path.join(HOME, 'Documents', 'My Games', 'ArmaReforger', 'profile',
                           '.save', 'app*_user*', 'settings', 'ReforgerGameSettings.conf')
    found = glob.glob(pattern)
    return max(found, key=os.path.getmtime) if found else None


SETTINGS = find_settings()

# Resources a human edits as text. Everything else is a build artifact (textures,
# models, audio, terrain tiles) and stays in the pak/manifest only.
TEXT_EXT = ('.c', '.conf', '.et', '.layout', '.agr', '.ast', '.gproj', '.json', '.txt',
            '.emat', '.gamemat', '.layer', '.ent', '.st', '.styles', '.fnt', '.cbt', '.ai')


def parse_presets():
    presets = []
    cur = None
    pending = None
    for line in open(SETTINGS, encoding='utf-8-sig', errors='replace'):
        if re.match(r'^\s*SCR_WorkshopAddonPreset "', line):
            cur = {'name': None, 'mods': []}
            presets.append(cur)
            pending = None
            continue
        if cur is None:
            continue
        g = re.search(r'm_sGuid "([0-9A-Fa-f]{16})"', line)
        m = re.search(r'm_sName "([^"]*)"', line)
        if g:
            pending = g.group(1).upper()
        elif m:
            if cur['name'] is None:
                cur['name'] = m.group(1)
            else:
                cur['mods'].append({'name': m.group(1), 'guid': pending})
                pending = None
    return presets


def parse_gproj(path):
    out = {'id': None, 'guid': None, 'title': None, 'deps': []}
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return out
    for key, field in (('ID', 'id'), ('GUID', 'guid'), ('TITLE', 'title')):
        m = re.search(r'^\s*%s "([^"]*)"' % key, txt, re.M)
        if m:
            out[field] = m.group(1)
    deps = re.search(r'Dependencies\s*\{(.*?)\}', txt, re.S)
    if deps:
        out['deps'] = re.findall(r'"([0-9A-Fa-f]{16})"', deps.group(1))
    return out


def addon_dirs():
    found = {}
    for name in sorted(os.listdir(ADDONS)):
        path = os.path.join(ADDONS, name)
        if not os.path.isdir(path) or name == 'saves':
            continue
        guid = name.rsplit('_', 1)[-1].upper() if '_' in name else name.upper()
        found[guid] = {'folder': name, 'path': path}
    return found


def scan(guid, info):
    gproj = parse_gproj(os.path.join(info['path'], 'addon.gproj'))
    meta = {}
    try:
        meta = json.load(open(os.path.join(info['path'], 'meta'), encoding='utf-8-sig', errors='replace')).get('meta', {})
    except Exception:
        pass
    rev = (meta.get('versions') or [{}])[0]
    pak = os.path.join(info['path'], 'data.pak')
    files, bytes_ = [], 0
    if os.path.exists(pak):
        p = Pak(pak)
        files = [e[0].lstrip('/') for e in p.entries]
        bytes_ = sum(e[3] for e in p.entries)
    return guid, {
        'guid': guid,
        'folder': info['folder'],
        'name': meta.get('name') or gproj['title'] or info['folder'],
        'project_id': gproj['id'],
        'title': gproj['title'],
        'version': rev.get('version'),
        'game_version': rev.get('gameVersion'),
        'dependencies': gproj['deps'],
        'workshop_dependencies': [d.get('assetId') for d in rev.get('dependencies', [])],
        'scenarios': [s.get('gameId') for s in rev.get('scenarios', [])],
        'files': len(files),
        'bytes': bytes_,
        'pak': os.path.basename(pak) if os.path.exists(pak) else None,
    }, files


def cmd_index():
    if not SETTINGS:
        sys.exit('ReforgerGameSettings.conf not found. Set ARMA_PRESETS to its path.')
    if not os.path.isdir(ADDONS):
        sys.exit('Addon folder not found: %s (set ARMA_ADDONS)' % ADDONS)
    os.makedirs(CTX, exist_ok=True)
    presets = parse_presets()
    dirs = addon_dirs()
    print('presets:', [(p['name'], len(p['mods'])) for p in presets])
    print('addon dirs:', len(dirs))

    missing = []
    for p in presets:
        for m in p['mods']:
            m['installed'] = bool(m['guid'] and m['guid'] in dirs)
            if not m['installed']:
                missing.append((p['name'], m['name'], m['guid']))

    defs = {}
    manifests = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(scan, g, i): g for g, i in dirs.items()}
        for n, f in enumerate(concurrent.futures.as_completed(futs), 1):
            guid, info, files = f.result()
            defs[guid] = info
            manifests[guid] = files
            if n % 20 == 0:
                print('  scanned %d/%d' % (n, len(futs)))

    # scenarios per addon are visible in meta; map scenario guid -> addon
    scen = {}
    for guid, info in defs.items():
        for s in info['scenarios']:
            scen[s] = guid

    with open(os.path.join(CTX, 'presets.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump({'source': SETTINGS, 'presets': presets, 'missing': missing,
                   'scenarios': scen, 'addons': defs}, f, indent=1)
    with open(os.path.join(CTX, 'manifests.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(manifests, f, indent=0)

    # human-readable index
    names = [p['name'] for p in presets]
    seta = {m['guid'] for m in presets[0]['mods']}
    setb = {m['guid'] for m in presets[1]['mods']}
    only_a = [defs.get(g, {'name': g})['name'] for g in sorted(seta - setb)]
    only_b = [defs.get(g, {'name': g})['name'] for g in sorted(setb - seta)]
    total_files = sum(d['files'] for d in defs.values())
    lines = ['# Installed Arma Reforger addons', '',
             'Generated from `%s`.' % SETTINGS, '',
             '| preset | mods | installed |', '| --- | --- | --- |']
    for p in presets:
        ok = sum(1 for m in p['mods'] if m['installed'])
        lines.append('| %s | %d | %d |' % (p['name'], len(p['mods']), ok))
    lines += ['', '## Preset differences', '',
              '**Only in %s:** %s' % (names[0], ', '.join(only_a) or '(none)'), '',
              '**Only in %s:** %s' % (names[1] if len(names) > 1 else '-', ', '.join(only_b) or '(none)'), '',
              '## Addons', '',
              '%d addons, %d files, %.2f GB uncompressed.' % (len(defs), total_files,
                                                              sum(d['bytes'] for d in defs.values()) / 2**30),
              '', '| addon | GUID | version | files | deps |', '| --- | --- | --- | --- | --- |']
    presets_of = {}
    for p in presets:
        for m in p['mods']:
            presets_of.setdefault(m['guid'], []).append(p['name'])
    for guid, d in sorted(defs.items(), key=lambda kv: kv[1]['name'].lower()):
        lines.append('| %s | %s | %s | %d | %s |' % (
            d['name'], guid, d['version'] or '?', d['files'],
            ', '.join(presets_of.get(guid, [])) + ('; deps: ' + ','.join(d['dependencies']) if d['dependencies'] else '')))
    if missing:
        lines += ['', '## Not installed', '']
        lines += ['- %s (%s) from %s' % (n, g, p) for p, n, g in missing]
    open(os.path.join(CTX, 'INDEX.md'), 'w', encoding='utf-8', newline='\n').write('\n'.join(lines) + '\n')
    print('wrote', CTX)


def cmd_extract(which):
    data = json.load(open(os.path.join(CTX, 'presets.json'), encoding='utf-8'))
    manifests = json.load(open(os.path.join(CTX, 'manifests.json'), encoding='utf-8'))
    defs = data['addons']
    presets = data['presets']
    if which == 'all':
        guids = sorted(defs)
        label = 'all'
    else:
        p = next((p for p in presets if p['name'].lower() == which.lower()), None)
        if not p:
            sys.exit('unknown preset %r; have %s' % (which, [x['name'] for x in presets]))
        guids = [m['guid'] for m in p['mods'] if m['installed']]
        label = p['name']
    outroot = os.path.join(WORK, re.sub(r'[^A-Za-z0-9]+', '-', label).strip('-'))
    plan = []
    for guid in guids:
        d = defs[guid]
        texts = [f for f in manifests[guid] if os.path.splitext(f)[1].lower() in TEXT_EXT]
        plan.append((d, texts))
    print('extracting %d addons, %d text files -> %s' %
          (len(plan), sum(len(t) for _, t in plan), outroot))

    def run(item):
        d, texts = item
        pak = os.path.join(ADDONS, d['folder'], 'data.pak')
        p = Pak(pak)
        dest = os.path.join(outroot, d['folder'])
        n = 0
        for e in p.entries:
            if e[0].lstrip('/') not in set(texts):
                continue
            full = os.path.join(dest, *e[0].strip('/').split('/'))
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, 'wb') as f:
                f.write(p._payload(e))
            n += 1
        # keep the project file so Workbench can open the folder as a project
        for extra in ('addon.gproj', 'meta'):
            src = os.path.join(ADDONS, d['folder'], extra)
            if os.path.exists(src):
                os.makedirs(dest, exist_ok=True)
                with open(src, 'rb') as s, open(os.path.join(dest, extra), 'wb') as t:
                    t.write(s.read())
        return d['folder'], n

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        for i, (folder, n) in enumerate(ex.map(run, plan), 1):
            print('  [%d/%d] %-60s %5d files' % (i, len(plan), folder[:60], n))
    print('done ->', outroot)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == 'index':
        cmd_index()
    elif sys.argv[1] == 'extract':
        cmd_extract(sys.argv[2] if len(sys.argv) > 2 else 'all')
    else:
        print(__doc__)
        sys.exit(1)
