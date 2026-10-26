"""Assemble Apple's PNG-backed ICNS chunks from our original vector-rendered icon."""
import pathlib, struct, sys
chunks = []
for kind, name in [('icp4','16x16'),('icp5','32x32'),('ic07','128x128'),('ic08','256x256'),('ic09','512x512'),('ic10','512x512@2x')]:
    data = pathlib.Path(f'build/Icon.iconset/icon_{name}.png').read_bytes()
    chunks.append(kind.encode() + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
pathlib.Path(sys.argv[1]).write_bytes(b'icns' + struct.pack('>I', len(body)+8) + body)
