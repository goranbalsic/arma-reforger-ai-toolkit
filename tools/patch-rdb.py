#!/usr/bin/env python3
"""Stamp resource GUIDs into a built resourceDatabase.rdb.

A same-path prefab override only works if the addon's resource database claims
the *vanilla* GUID for that path. Workbench assigns null GUIDs when the project's
resources were authored outside the editor, which makes the pak inert.

  python tools/patch-rdb.py --rdb build/mod/resourceDatabase.rdb --map-guids

The GUID is 8 bytes little-endian, located 8 bytes after the null-terminated
resource path:
    <path>\\0  u32 flags  u16 0  u64 guid_le  ...
"""
import argparse
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def norm(p):
    return p.replace('\\', '/').strip('/').lower()


def harvest_guids():
    """path -> {GUID} from every prefab/config reference we have on disk."""
    roots = [
        os.path.join(ROOT, 'context', 'vanilla-ussr'),
        os.path.join(ROOT, 'context'),
        os.path.join(ROOT, 'work', 'all'),
    ]
    pat = re.compile(r'"(\{[0-9A-Fa-f]{16}\})([^"]+\.(?:et|conf))"')
    idx = {}
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            for f in files:
                if not f.endswith(('.et', '.conf')):
                    continue
                try:
                    raw = open(os.path.join(dirpath, f), 'rb').read()
                except OSError:
                    continue
                if raw[:2] in (b'\xff\xfe', b'\xfe\xff'):
                    txt = raw.decode('utf-16', errors='replace')
                else:
                    txt = raw.decode('utf-8-sig', errors='replace')
                for g, p in pat.findall(txt):
                    idx.setdefault(norm(p), g.upper())
    return idx


def patch(rdb_path, mapping, dry_run=False):
    data = bytearray(open(rdb_path, 'rb').read())
    lower = bytes(data).lower()
    patched, missing, suspicious = 0, [], []
    for vpath, guid in mapping.items():
        needle = vpath.encode('utf-8').lower()
        start = 0
        hits = 0
        while True:
            i = lower.find(needle, start)
            if i < 0:
                break
            start = i + 1
            end = i + len(needle)
            # record must look like <path>\0 <u32> <u16> <8 bytes guid>
            if data[end] != 0:
                continue
            off = end + 1 + 4 + 2
            slot = data[off:off + 8]
            if slot == b'\x00' * 8:
                data[off:off + 8] = bytes.fromhex(guid.strip('{}'))[::-1]
                patched += 1
                hits += 1
            else:
                # already stamped (ours or another addon) - leave alone but count
                hits += 1
        if hits == 0:
            missing.append(vpath)
    if not dry_run:
        open(rdb_path, 'wb').write(data)
    return patched, missing, suspicious


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rdb', required=True)
    ap.add_argument('--map', help='JSON {"virtual/path.et": "GUID"} (optional)')
    ap.add_argument('--pak', help='data.pak to read paths from (default: next to the rdb)')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()

    if a.map:
        import json
        mapping = {norm(k): v.upper() for k, v in json.load(open(a.map, encoding='utf-8')).items()}
    else:
        # default: every path in our pak gets its vanilla GUID
        sys.path.insert(0, os.path.join(ROOT, 'skill', 'arma-reforger-modding', 'scripts'))
        from refpak import Pak
        pak = a.pak or os.path.join(os.path.dirname(a.rdb), 'data.pak')
        paths = [e[0].lstrip('/') for e in Pak(pak).entries]
        idx = harvest_guids()
        mapping = {}
        unresolved = []
        for p in paths:
            g = idx.get(norm(p))
            if g:
                mapping[norm(p)] = g
            else:
                unresolved.append(p)
        if unresolved:
            print('no GUID known for %d paths:' % len(unresolved))
            for p in unresolved[:10]:
                print('  ', p)
            return 1

    patched, missing, _ = patch(a.rdb, mapping, dry_run=a.check)
    print('patched %d/%d entries' % (patched, len(mapping)))
    if missing:
        print('not found in rdb: %d' % len(missing))
        for p in missing[:10]:
            print('  ', p)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
