#!/usr/bin/env python3
"""Generate a spawn-replacement mod (fix or standalone).

Same-path prefab overrides do not apply in game (the base game registers last), so a
replacement mod has to swap prefabs at spawn time. This tool writes the whole project:

  * clones the replacement units into the addon, re-owned to the faction of the units
    they replace (so a swapped squad never fights its own side),
  * clones the group prefabs so their members use the same replacements,
  * emits the script with the four hooks that Game Master actually uses,
  * writes addon.gproj with the configured dependencies.

Two modes:
  standalone - every unit is cloned here (no other replacement mod needed)
  fix        - units already replaced by another mod are left alone ("keep"), only the
               gaps are cloned here; that mod stays a dependency

Usage:
    python make-replacement-mod.py config.json --project ../work/my-mod

Config (see example below):
{
  "id": "ArmaDudes_MyMod",
  "guid": "A1D0D0D0C0FFEE08",
  "title": "ArmaDudes My Mod",
  "dependencies": ["58D0FB3206B6F859", "595F2BF2F44836FB"],
  "faction": { "key": "USSR", "component": "6062F6587469882D" },
  "characters": { "filter": "/Factions/OPFOR/USSR" },
  "groups": {
      "filter": "Group_USSR_",
      "outPrefix": "Group_USSRFix_",
      "guidPrefix": "C5E"
  },
  "charGuidPrefix": "C5F",
  "keepFrom": "path/to/other-mod/data.pak",   // fix mode; omit for standalone
  "rules": [["_AAT", "MSV_AAT"], ["_AT", "MSV_AT"]],
  "default": "MSV_RIFLEMAN",
  "sources": {
      "MSV_AAT": "Prefabs/Characters/.../Character_X.et",
      "MSV_RIFLEMAN": "Prefabs/Characters/.../Character_Y.et"
  }
}

Rules are matched in order against the vanilla prefab file name; the first hit wins,
so put specific tokens (_AAT) before general ones (_AT).
"""
import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from refpak import Pak  # noqa: E402

GAME_ADDONS = os.path.expanduser(r'~\Documents\My Games\ArmaReforger\addons')
VANILLA = r'C:\Program Files (x86)\Steam\steamapps\common\Arma Reforger\addons'


def find_guid(pak_path, path):
    blob = open(os.path.join(os.path.dirname(pak_path), 'resourceDatabase.rdb'), 'rb').read()
    low = blob.lower()
    needle = path.lower().encode()
    i = low.find(needle)
    while i >= 0:
        e = i + len(needle)
        if blob[e:e + 1] == b'\x00' and blob[e + 1:e + 7] == b'\x06\x00\x00\x00\x00\x00':
            return blob[e + 7:e + 15][::-1].hex().upper()
        i = low.find(needle, i + 1)
    raise SystemExit('no GUID for %s (is %s the right pak?)' % (path, pak_path))


def vanilla_guid(path):
    for rdb in glob.glob(os.path.join(VANILLA, '**', 'resourceDatabase.rdb'), recursive=True):
        blob = open(rdb, 'rb').read()
        low = blob.lower()
        needle = path.lower().encode()
        i = low.find(needle)
        while i >= 0:
            e = i + len(needle)
            if blob[e:e + 1] == b'\x00' and blob[e + 1:e + 7] == b'\x06\x00\x00\x00\x00\x00':
                return blob[e + 7:e + 15][::-1].hex().upper()
            i = low.find(needle, i + 1)
    raise SystemExit('no vanilla GUID for ' + path)


def write_meta(path, guid, rel):
    open(path + '.meta', 'w', encoding='utf-8', newline='\r\n').write(
        'MetaFileClass {\n Name "{%s}%s"\n Configurations {\n  EntityTemplateResourceClass PC {\n  }\n'
        '  EntityTemplateResourceClass XBOX_ONE : PC {\n  }\n  EntityTemplateResourceClass XBOX_SERIES : PC {\n  }\n'
        '  EntityTemplateResourceClass PS4 : PC {\n  }\n  EntityTemplateResourceClass PS5 : PC {\n  }\n'
        '  EntityTemplateResourceClass HEADLESS : PC {\n  }\n }\n}\n' % (guid, rel))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('config')
    ap.add_argument('--project', required=True, help='output project folder')
    args = ap.parse_args()

    cfg = json.load(open(args.config, encoding='utf-8'))
    proj = os.path.abspath(args.project)
    rhs_pak = cfg['rhsPak']
    pak = Pak(rhs_pak)

    faction = cfg['faction']
    sources = cfg['sources']
    rules = [(k, v) for k, v in cfg['rules']]
    default = cfg['default']

    def target_for(name):
        for token, key in rules:
            if token in name:
                return key
        return default

    # units another mod already replaces: leave their paths alone (fix mode)
    keep = set()
    if cfg.get('keepFrom'):
        other = os.path.join(os.path.dirname(cfg['keepFrom']), 'data.pak') if os.path.isdir(cfg['keepFrom']) else cfg['keepFrom']
        keep = {e[0].lstrip('/') for e in Pak(other).entries if e[0].endswith('.et')}
        print('keep (already replaced by %s): %d' % (os.path.basename(os.path.dirname(other)), len(keep)))

    # vanilla prefabs to work on
    chars, groups = {}, {}
    for pak_path in glob.glob(os.path.join(VANILLA, '**', '*.pak'), recursive=True):
        try:
            pk = Pak(pak_path)
        except Exception:
            continue
        for e in pk.entries:
            name = e[0].lstrip('/')
            if not name.endswith('.et'):
                continue
            if cfg['characters']['filter'] in name and '/Characters/' in name and '/Factions/' in name:
                chars[name] = pak_path
            if cfg['groups']['filter'] in name.split('/')[-1]:
                groups[name] = pak_path

    wanted = sorted(p for p in chars if p not in keep
                    and not p.split('/')[-1].endswith('_Base.et') and 'BaseLoadout' not in p)
    print('characters: %d vanilla, %d to replace' % (len(chars), len(wanted)))

    # clone the replacement units, re-owned to the faction they replace
    dest_char = os.path.join(proj, 'Prefabs', 'Characters')
    os.makedirs(dest_char, exist_ok=True)
    for root, _, files in os.walk(proj):
        for f in files:
            if f.startswith('Character_') and f.endswith('.et'):
                os.remove(os.path.join(root, f))
                m = os.path.join(root, f + '.meta')
                if os.path.exists(m):
                    os.remove(m)

    needed = sorted({target_for(p.split('/')[-1]) for p in wanted})
    refs = {}
    for i, key in enumerate(needed, start=1):
        text = pak.read('/' + sources[key]).decode('utf-8').replace('\r\n', '\n')
        text = text.replace(' components {\n',
                            ' components {\n  SCR_CharacterFactionAffiliationComponent "%s" {\n'
                            '   "faction affiliation" "%s"\n  }\n' % (faction['component'], faction['key']), 1)
        guid = '%s0000000000%03d' % (cfg['charGuidPrefix'], i)
        folder = os.path.join(dest_char, cfg['id'])
        os.makedirs(folder, exist_ok=True)
        name = 'Character_%s_%s.et' % (cfg['id'].split('_')[-1], key)
        rel = 'Prefabs/Characters/%s/%s' % (cfg['id'], name)
        open(os.path.join(folder, name), 'w', encoding='utf-8', newline='\r\n').write(text)
        write_meta(os.path.join(folder, name), guid, rel)
        refs[key] = '{%s}%s' % (guid, rel)

    # group clones
    dest_group = os.path.join(proj, 'Prefabs', 'Groups', 'Replaced')
    os.makedirs(dest_group, exist_ok=True)
    for f in os.listdir(dest_group):
        os.remove(os.path.join(dest_group, f))

    plan, rows, group_ref = {}, [], {}
    for i, path in enumerate(sorted(groups), start=1):
        if path.split('/')[-1].endswith('_Base.et'):
            continue
        plan[path] = ('%s0000000000%03d' % (cfg['groups']['guidPrefix'], i),
                      'Prefabs/Groups/Replaced/%s%s' % (cfg['groups']['outPrefix'], path.split(cfg['groups']['filter'])[-1]))
    for p, (g, rel) in plan.items():
        group_ref[p.split('/')[-1]] = '{%s}%s' % (g, rel)

    for path, (g, rel) in sorted(plan.items()):
        text = Pak(groups[path]).read('/' + path).decode('utf-8').replace('\r\n', '\n')

        def swap_char(m):
            original = m.group(1)
            if original in keep:
                return m.group(0)
            return '"%s"' % refs[target_for(original.split('/')[-1])]

        text = re.sub(r'"\{[0-9A-F]{16}\}(Prefabs/Characters/[^"]*\.et)"', swap_char, text)

        def swap_group(m):
            base = m.group(1).split('/')[-1]
            return '"%s"' % group_ref[base] if base in group_ref else m.group(0)

        text = re.sub(r'"\{[0-9A-F]{16}\}(Prefabs/Groups/[^"]*%s[^"]*\.et)"' % re.escape(cfg['groups']['filter']),
                      swap_group, text)
        open(os.path.join(dest_group, rel.split('/')[-1]), 'w', encoding='utf-8', newline='\r\n').write(text)
        write_meta(os.path.join(dest_group, rel.split('/')[-1]), g, rel)
        rows.append((path.split('/')[-1], g, rel))

    # script
    L = []
    A = L.append
    A('// Spawn-time replacement. Same-path overrides do not apply in game, so every')
    A('// unit is swapped where the editor and the catalog resolve the prefab.')
    A('')
    for key in sorted(refs):
        A('const string %s = "%s";' % (key, refs[key]))
    A('')
    A('ResourceName ArmaDudes_Replace(ResourceName prefab)')
    A('{')
    A('\tstring s = "" + prefab;')
    A('')
    A('\tif (s.Contains("/Groups/"))')
    A('\t{')
    A('\t\tstring group = ArmaDudes_ReplaceGroup(s);')
    A('\t\tif (group != "")')
    A('\t\t\treturn group;')
    A('\t\treturn prefab;')
    A('\t}')
    A('')
    A('\tif (!s.Contains("%s"))' % cfg['characters']['filter'])
    A('\t\treturn prefab;')
    A('')
    A('\tstring file = s;')
    A('\tint slash = s.LastIndexOf("/");')
    A('\tif (slash >= 0)')
    A('\t\tfile = s.Substring(slash + 1, s.Length() - slash - 1);')
    A('')
    for p in wanted:
        name = p.split('/')[-1]
        A('\tif (file == "%s")' % name)
        A('\t\treturn %s;' % target_for(name))
        A('')
    A('\treturn prefab;')
    A('}')
    A('')
    A('string ArmaDudes_ReplaceGroup(string path)')
    A('{')
    A('\tstring file = path;')
    A('\tint slash = path.LastIndexOf("/");')
    A('\tif (slash >= 0)')
    A('\t\tfile = path.Substring(slash + 1, path.Length() - slash - 1);')
    A('')
    for name, g, rel in sorted(rows):
        A('\tif (file == "%s")' % name)
        A('\t\treturn "{%s}%s";' % (g, rel))
        A('')
    A('\treturn "";')
    A('}')
    A('')
    A('modded class SCR_CatalogEntitySpawnerComponent')
    A('{')
    A('\toverride protected IEntity SpawnEntity(ResourceName entityResourceName, notnull IEntity slotOwner)')
    A('\t{')
    A('\t\treturn super.SpawnEntity(ArmaDudes_Replace(entityResourceName), slotOwner);')
    A('\t}')
    A('}')
    A('')
    A('modded class ArmaReforgerScripted')
    A('{')
    A('\toverride IEntity SpawnEntityPrefabEx(ResourceName prefab, bool randomizeEditableVariant, BaseWorld world = null, EntitySpawnParams params = null)')
    A('\t{')
    A('\t\treturn super.SpawnEntityPrefabEx(ArmaDudes_Replace(prefab), randomizeEditableVariant, world, params);')
    A('\t}')
    A('}')
    A('')
    A('// Game Master single-unit placement: GetPrefab resolves the spawn, GetPrefabID')
    A('// maps the substituted prefab back to its registry index (without it the editor')
    A('// reports "not registered in placeable entities" and placement silently fails).')
    A('modded class SCR_PlacingEditorComponentClass')
    A('{')
    A('\toverride ResourceName GetPrefab(int index)')
    A('\t{')
    A('\t\treturn ArmaDudes_Replace(super.GetPrefab(index));')
    A('\t}')
    A('')
    A('\toverride int GetPrefabID(ResourceName prefab)')
    A('\t{')
    A('\t\tint count = CountPrefabs();')
    A('\t\tfor (int i = 0; i < count; i++)')
    A('\t\t{')
    A('\t\t\tif (ArmaDudes_Replace(super.GetPrefab(i)) == prefab)')
    A('\t\t\t\treturn i;')
    A('\t\t}')
    A('\t\treturn super.GetPrefabID(prefab);')
    A('\t}')
    A('}')

    os.makedirs(os.path.join(proj, 'scripts', 'Game', 'ArmaDudes'), exist_ok=True)
    open(os.path.join(proj, 'scripts', 'Game', 'ArmaDudes', 'Replacement.c'), 'w',
         encoding='utf-8', newline='\n').write('\n'.join(L) + '\n')

    deps = ''.join('  "%s"\n' % d for d in cfg['dependencies'])
    open(os.path.join(proj, 'addon.gproj'), 'w', encoding='ascii', newline='\n').write(
        'GameProject {\n ID "%s"\n GUID "%s"\n TITLE "%s"\n Dependencies {\n%s }\n'
        ' Configurations {\n  GameProjectConfig PC {\n  }\n  GameProjectConfig HEADLESS {\n  }\n }\n}\n'
        % (cfg['id'], cfg['guid'], cfg['title'], deps))

    print('clones: %d, groups: %d -> %s' % (len(refs), len(rows), proj))


if __name__ == '__main__':
    main()
