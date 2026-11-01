#!/usr/bin/env python3
"""Write .meta files for same-path override resources.

Workbench only registers a resource that has a .meta, and it assigns a *random*
GUID when the vanilla one is already taken. For an override the .meta must carry
the vanilla GUID in `Name`, otherwise the pak loads and does nothing.

  python tools/gen-metas.py --project work\\mod --map context/guid-map.json
"""
import argparse
import json
import os

TEMPLATE = """MetaFileClass {
 Name "{%s}%s"
 Configurations {
  EntityTemplateResourceClass PC {
  }
  EntityTemplateResourceClass XBOX_ONE : PC {
  }
  EntityTemplateResourceClass XBOX_SERIES : PC {
  }
  EntityTemplateResourceClass PS4 : PC {
  }
  EntityTemplateResourceClass PS5 : PC {
  }
  EntityTemplateResourceClass HEADLESS : PC {
  }
 }
}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--project', required=True)
    ap.add_argument('--map', required=True, help='JSON { "Prefabs/....et": "{GUID}" }')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()

    mapping = json.load(open(a.map, encoding='utf-8'))
    written = skipped = 0
    for rel, guid in mapping.items():
        src = os.path.join(a.project, *rel.split('/'))
        if not os.path.exists(src):
            skipped += 1
            continue
        dest = src + '.meta'
        text = TEMPLATE % (guid.strip('{}'), rel)
        if os.path.exists(dest) and open(dest, encoding='utf-8').read() == text:
            continue
        if a.check:
            print('would write', os.path.relpath(dest, a.project))
        else:
            with open(dest, 'w', encoding='utf-8', newline='\r\n') as f:
                f.write(text)
            written += 1

    print('metas written: %d, missing sources: %d' % (written, skipped))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
