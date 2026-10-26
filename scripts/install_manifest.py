#!/usr/bin/env python3
"""Commit the signed app's bundled helper and dependency bytes for one-time, root-owned runtime setup."""
import hashlib,json,pathlib,sys
app=pathlib.Path(sys.argv[1]).resolve()
paths={
 'FortiBreakDaemon':'Contents/MacOS/FortiBreakDaemon',
 'FortiBreakHelper':'Contents/MacOS/FortiBreakHelper',
 'openfortivpn':'Contents/Helpers/openfortivpn',
 'libssl.4.dylib':'Contents/Helpers/libssl.4.dylib',
 'libcrypto.4.dylib':'Contents/Helpers/libcrypto.4.dylib',
 'cert.pem':'Contents/Resources/cert.pem'
}
files=[dict(name=name,source='@app/'+path,sha256=hashlib.sha256((app/path).read_bytes()).hexdigest()) for name,path in paths.items()]
(app/'Contents/Resources/HelperInstallManifest.json').write_text(json.dumps(dict(files=files),indent=2))
