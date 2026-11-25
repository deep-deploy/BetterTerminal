#!/usr/bin/env python3
"""Brand the verified Alpine rootfs without extracting it to the host filesystem."""
import copy
import io
import os
from pathlib import Path
import sys
import tarfile

archive = Path(sys.argv[1])
profile_code = Path(__file__).with_name('betterterminal-profile.sh').read_bytes()
marker = b'# BetterTerminal interactive login banner.'
tmp = archive.with_name(archive.name + '.betterterminal.tmp')
seen = set()
try:
    with tarfile.open(archive, 'r:gz') as src, tarfile.open(tmp, 'w:gz', format=tarfile.PAX_FORMAT) as dst:
        for entry in src:
            name = entry.name.removeprefix('./').rstrip('/')
            if name == 'etc/profile':
                if not entry.isfile():
                    raise ValueError('Expected regular /etc/profile in rootfs')
                data = src.extractfile(entry).read()
                if marker not in data:
                    data = data.rstrip(b'\n') + b'\n\n' + profile_code + b'\n'
                replacement = copy.copy(entry)
                replacement.size = len(data)
                replacement.pax_headers = {k:v for k,v in entry.pax_headers.items() if k != 'size'}
                dst.addfile(replacement, io.BytesIO(data))
                seen.add(name)
            elif name == 'etc/motd':
                replacement = tarfile.TarInfo(entry.name)
                replacement.mode = 0o644
                replacement.uid = replacement.gid = 0
                replacement.mtime = entry.mtime
                dst.addfile(replacement, io.BytesIO(b''))
                seen.add(name)
            else:
                dst.addfile(entry, src.extractfile(entry) if entry.isfile() else None)
        if 'etc/profile' not in seen:
            raise ValueError('No /etc/profile found; refusing to alter rootfs')
        if 'etc/motd' not in seen:
            entry = tarfile.TarInfo('etc/motd')
            entry.mode = 0o644
            dst.addfile(entry, io.BytesIO(b''))
    os.replace(tmp, archive)
finally:
    if tmp.exists():
        tmp.unlink()
