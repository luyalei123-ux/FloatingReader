#!/usr/bin/env python3
"""Prepare a clean, allowlisted source archive and a separate release folder."""
from pathlib import Path
import hashlib,json,re,shutil,zipfile
ROOT=Path(__file__).resolve().parent.parent
VERSION=(ROOT/'VERSION').read_text().strip()
WIN=(ROOT/'windows/VERSION').read_text().strip()
OUT=ROOT/'dist'/('release-v'+VERSION)
OUT.mkdir(parents=True,exist_ok=True)
allowed={'.gitattributes','.gitignore','.github','README.md','LICENSE','THIRD_PARTY_NOTICES.md','VERSION','CHANGELOG.md','CONTRIBUTING.md','SECURITY.md','global.json','assets','docs','macos','windows','scripts'}
blocked={'bin','obj','dist','.git','ModuleCache','__pycache__','WebView2','EBWebView','User Data'}
private=re.compile(r'/Users/[A-Za-z0-9_.-]+/|github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
files=[]
for top in sorted(allowed):
 p=ROOT/top
 candidates=p.rglob('*') if p.is_dir() else [p]
 for f in candidates:
  if not f.is_file() or f.is_symlink():continue
  rel=f.relative_to(ROOT)
  if any(part in blocked for part in rel.parts) or f.name=='.DS_Store':continue
  if f.suffix.lower() in {'.zip','.app','.dmg','.exe','.dll','.pdb','.pfx','.p12','.key','.nupkg','.pyc'}:continue
  if f.name in {'settings.json','reading-bookmark.json','Cookies','Login Data','Local State'} or f.name.startswith('.env'):continue
  raw=f.read_bytes()
  if f.name!='prepare-release.py' and b'\0' not in raw and private.search(raw.decode('utf-8',errors='ignore')):raise SystemExit('Private marker in '+str(rel))
  files.append(f)
archive=OUT/f'FloatingReader-Source-v{VERSION}.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for f in files:z.write(f,'FloatingReader-GitHub/'+f.relative_to(ROOT).as_posix())
assets=[(f'FloatingReader-macOS-Intel-{VERSION}.zip',f'FloatingReader-macOS-Intel-{VERSION}.zip'),(f'FloatingReader-macOS-AppleSilicon-{VERSION}.zip',f'FloatingReader-macOS-AppleSilicon-{VERSION}.zip'),(f'FloatingReader-Windows-x64-{WIN}-preview.zip',f'FloatingReader-Windows-x64-{WIN}-preview.zip')]
for source,name in assets:
 p=ROOT/'dist'/source
 if not p.exists():raise SystemExit('Build missing: '+source)
 shutil.copy2(p,OUT/name)
for f in OUT.glob('*.zip'):
 with zipfile.ZipFile(f) as z:
  if z.testzip() is not None:raise SystemExit('Invalid archive: '+f.name)
(OUT/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.name+'\n' for f in sorted(OUT.glob('*.zip'))))
shutil.copy2(ROOT/'docs/RELEASE_NOTES.md',OUT/'RELEASE_NOTES.md')
(OUT/'PREPARATION-REPORT.json').write_text(json.dumps({'source_version':VERSION,'windows_version':WIN,'source_files':len(files),'uploaded':False,'windows_native_tested':False,'apple_native_tested':False,'artifacts':[f.name for f in sorted(OUT.glob('*.zip'))]},ensure_ascii=False,indent=2)+'\n')
print(OUT)
print('Source files:',len(files))
