#!/usr/bin/env python3
"""Commit installed dependency bytes for one-time, root-owned runtime setup."""
import hashlib,json,pathlib,subprocess,sys
app=pathlib.Path(sys.argv[1]).resolve()
files=[];rewrites=[]
paths={
 'ClearGateDaemon':app/'Contents/MacOS/ClearGateDaemon',
 'ClearGateHelper':app/'Contents/MacOS/ClearGateHelper',
 'openfortivpn':pathlib.Path('/opt/homebrew/bin/openfortivpn').resolve(),
 'libssl.4.dylib':pathlib.Path('/opt/homebrew/opt/openssl@4/lib/libssl.4.dylib').resolve(),
 'libcrypto.4.dylib':pathlib.Path('/opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib').resolve(),
 'cert.pem':pathlib.Path('/opt/homebrew/etc/openssl@4/cert.pem').resolve()
}
for name,path in paths.items():
 files.append(dict(name=name,source=("@app/Contents/MacOS/"+name if name in ["ClearGateDaemon","ClearGateHelper"] else str(path)),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
 if name in ['openfortivpn','libssl.4.dylib','libcrypto.4.dylib']:
  lines=subprocess.check_output(['otool','-L',str(path)],text=True).splitlines()[1:]
  if name.endswith('.dylib'):lines=lines[1:] # dylib's own install ID is not a dependency.
  for line in lines:
   dependency=line.strip().split(' (',1)[0]
   if dependency.startswith('/opt/homebrew/'):
    target=pathlib.Path(dependency).name
    assert target in ['libssl.4.dylib','libcrypto.4.dylib'],dependency
    rewrites.append(dict(name=name,**{'from':dependency,'to':'@loader_path/'+target}))
(app/'Contents/Resources/HelperInstallManifest.json').write_text(json.dumps(dict(files=files,rewrites=rewrites),indent=2))
