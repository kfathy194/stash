#!/usr/bin/env python3
"""Assemble Apple's ICNS PNG representations without an IconServices daemon."""
from pathlib import Path
import struct
root = Path(__file__).resolve().parents[1]
images = [('icp4','16x16'),('icp5','32x32'),('icp6','32x32@2x'),('ic07','128x128'),('ic08','256x256'),('ic09','512x512'),('ic10','512x512@2x'),('ic11','16x16@2x'),('ic12','32x32@2x'),('ic13','128x128@2x'),('ic14','256x256@2x')]
chunks = []
for kind,size in images:
    data=(root/'Branding/Stash.iconset'/('icon_'+size+'.png')).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    chunks.append(kind.encode('ascii')+struct.pack('>I',len(data)+8)+data)
body=b''.join(chunks)
(root/'Branding/Stash.icns').write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
print('Created Stash.icns with 11 native representations.')
