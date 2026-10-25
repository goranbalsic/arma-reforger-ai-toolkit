#!/usr/bin/env python3
"""refpak - read, list, extract and pack Arma Reforger .pak archives (PAC1).

Used by the arma-ai skill so AI can turn a shipped mod back into editable source.

  python refpak.py list     <file.pak>
  python refpak.py find     <file.pak> <substring>       (case-insensitive path filter)
  python refpak.py manifest <file.pak> [out.jsonl]
  python refpak.py cat      <file.pak> <virtual/path>
  python refpak.py extract  <file.pak> <outdir> [.c,.conf,.et,...]

Layout (verified against Workbench core/data.pak):
  FORM u32be size "PAC1"
  chunk*  = magic[4] u32be size payload
    HEAD  28 bytes index header (unused)
    DATA  all file payloads, concatenated
    FILE  recursive entry tree:
            u8 kind (0=dir,1=file), u8 nameLen, name
            dir : u32le childCount, children...
            file: u32le absolute offset in pak, u32le storedLen,
                  u32le fileLen, u32le unk, u16 unk, u8 compressed,
                  u8 level, u32le timestamp
"""
import os
import struct
import sys
import zlib

MAGIC = {'FORM', 'PAC1', 'HEAD', 'DATA', 'FILE'}


class Pak:
    def __init__(self, path):
        self.path = path
        self.size = os.path.getsize(path)
        self.data_start = None
        self.file_start = None
        self.file_len = 0
        self.entries = []          # (virtual_path, offset, stored_len, file_len, compressed)
        self._scan_chunks()
        self._parse_tree()

    def _read(self, off, n):
        with open(self.path, 'rb') as f:
            f.seek(off)
            return f.read(n)

    def _scan_chunks(self):
        pos = 12
        while pos + 8 <= self.size:
            magic = self._read(pos, 4)
            n = struct.unpack('>I', self._read(pos + 4, 4))[0]
            if magic == b'HEAD':
                pos += 8 + n
            elif magic == b'DATA':
                self.data_start = pos + 8
                pos += 8 + n
            elif magic == b'FILE':
                self.file_start, self.file_len = pos + 8, n
                break
            else:
                pos += 8 + n
        if self.data_start is None or self.file_start is None:
            raise ValueError('not a PAC1 pak: %s' % self.path)

    def _parse_tree(self):
        buf = self._read(self.file_start, self.file_len)
        pos = 0

        def entry(prefix):
            nonlocal pos
            kind = buf[pos]; pos += 1
            nlen = buf[pos]; pos += 1
            name = buf[pos:pos + nlen].decode('utf-8', 'replace'); pos += nlen
            vpath = prefix + name if prefix else name
            if kind == 0:
                count = struct.unpack_from('<I', buf, pos)[0]; pos += 4
                for _ in range(count):
                    entry(vpath + '/')
            else:
                off, stored, full = struct.unpack_from('<III', buf, pos); pos += 12
                pos += 4 + 2
                compressed = buf[pos] != 0; pos += 1
                pos += 1 + 4
                self.entries.append((vpath, off, stored, full, compressed))

        entry('')

    def _payload(self, e):
        _, off, stored, full, compressed = e
        # The FILE offset is absolute in the pak. Fall back to DATA-relative if it
        # clearly points outside the DATA window (format drift across versions).
        if off + stored > self.size:
            off += self.data_start
        raw = self._read(off, stored if compressed else full)
        if not compressed:
            return raw
        for wbits in (15, -15):                    # zlib header, then raw deflate
            try:
                d = zlib.decompressobj(wbits)
                out = d.decompress(raw) + d.flush()
                if len(out) == full:
                    return out
            except zlib.error:
                pass
        # last resort: scan for a valid stream start
        for skip in range(0, min(64, len(raw))):
            for wbits in (15, -15):
                try:
                    d = zlib.decompressobj(wbits)
                    out = d.decompress(raw[skip:]) + d.flush()
                    if len(out) == full:
                        return out
                except zlib.error:
                    pass
        raise ValueError('cannot decompress %s' % e[0])

    def read(self, vpath):
        vpath = vpath.replace('\\', '/').strip('/').lower()
        for e in self.entries:
            if e[0].strip('/').lower() == vpath:
                return self._payload(e)
        raise KeyError(vpath)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    cmd, pak_path = argv[1], argv[2]
    if cmd == 'list':
        p = Pak(pak_path)
        total = 0
        for vpath, off, stored, full, comp in p.entries:
            total += full
            print('%10d %s%s' % (full, vpath, '' if comp else '  [stored]'))
        print('-- %d files, %.1f MB uncompressed' % (len(p.entries), total / 1048576))
    elif cmd == 'find':
        p = Pak(pak_path)
        needle = argv[3].lower()
        for vpath, off, stored, full, comp in p.entries:
            if needle in vpath.lower():
                print('%10d %s' % (full, vpath))
    elif cmd == 'manifest':
        import json
        p = Pak(pak_path)
        out = sys.stdout if len(argv) < 4 else open(argv[3], 'w', encoding='utf-8', newline='\n')
        for vpath, off, stored, full, comp in p.entries:
            out.write(json.dumps({'path': vpath, 'size': full}, ensure_ascii=False) + '\n')
        if out is not sys.stdout:
            out.close()
    elif cmd == 'cat':
        p = Pak(pak_path)
        sys.stdout.buffer.write(p.read(argv[3]))
    elif cmd == 'extract':
        outdir = argv[3]
        wanted = None
        if len(argv) > 4:
            wanted = {e.strip().lower() for e in argv[4].split(',') if e.strip()}
        p = Pak(pak_path)
        n = 0
        for e in p.entries:
            vpath, off, stored, full, comp = e
            if wanted is not None and os.path.splitext(vpath)[1].lower() not in wanted:
                continue
            dest = os.path.join(outdir, *vpath.strip('/').split('/'))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, 'wb') as f:
                f.write(p._payload(e))
            n += 1
        print('extracted %d files to %s' % (n, outdir))
    else:
        print('unknown command: %s' % cmd)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
