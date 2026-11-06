#!/usr/bin/env python3
"""Create the reviewable source archive, excluding local runtime data and builds."""
from pathlib import Path
import zipfile
root=Path(__file__).resolve().parents[1]
output=root/'Deliverables/Stash-source.zip'
folders=['StashCore','StashMac','StashIOS','StashShare','StashKeyboard','StashMCP','Stash.xcodeproj','Config','Scripts','Branding','docs']
exclude={'.DS_Store','.build','.swiftpm','xcuserdata','__pycache__'}
paths=[root/'README.md',root/'.gitignore']
for name in folders:
    paths.extend(p for p in (root/name).rglob('*') if p.is_file() and not any(part in exclude for part in p.relative_to(root).parts))
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
    for path in sorted(paths):archive.write(path,'Stash-source/'+str(path.relative_to(root)))
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert 'Stash-source/docs/ACCEPTANCE.md' in archive.namelist()
    assert not any('/Build/' in x or '/.work/' in x for x in archive.namelist())
print(f'{output.name}: {output.stat().st_size:,} bytes, {len(paths)} source files, CRC validation passed')
