#!/usr/bin/env python3
"""Verify private runtime relocation and reject unprivileged installation."""
import pathlib,tempfile,subprocess,json,os,sys,hashlib
app=pathlib.Path(sys.argv[1]).resolve()
manifest=json.loads((app/'Contents/Resources/HelperInstallManifest.json').read_text())
with tempfile.TemporaryDirectory(prefix='cg-runtime-') as tmp:
 base=pathlib.Path(tmp)
 for item in manifest['files']:
  source=str(app)+item['source'][4:] if item['source'].startswith('@app/') else item['source']
  data=pathlib.Path(source).read_bytes()
  assert hashlib.sha256(data).hexdigest()==item['sha256']
  (base/item['name']).write_bytes(data);(base/item['name']).chmod(0o755)
 for rewrite in manifest['rewrites']:
  subprocess.run(['install_name_tool','-change',rewrite['from'],rewrite['to'],str(base/rewrite['name'])],check=True,capture_output=True)
 for name in ['openfortivpn','libssl.4.dylib','libcrypto.4.dylib']:
  subprocess.run(['codesign','--force','--sign','-',str(base/name)],check=True,capture_output=True)
 environment=dict(os.environ,OPENSSL_CONF='/dev/null',DYLD_PRINT_LIBRARIES='1')
 result=subprocess.run([str(base/'openfortivpn'),'--version'],env=environment,capture_output=True,text=True,check=True)
 assert '1.24.1' in result.stdout
 loaded=[line for line in result.stderr.splitlines() if 'libssl.4.dylib' in line or 'libcrypto.4.dylib' in line]
 assert loaded and all(tmp in line for line in loaded),loaded
 assert os.geteuid()!=0,'This fixture must run unprivileged'
 result=subprocess.run([str(app/'Contents/MacOS/ClearGateInstaller'),str(app),str(os.getuid())],capture_output=True,text=True)
 assert result.returncode!=0 and 'Administrator authorization' in result.stderr
 result=subprocess.run([str(app/'Contents/MacOS/ClearGateInstaller'),'--uninstall'],capture_output=True,text=True)
 assert result.returncode!=0 and 'Administrator authorization' in result.stderr
 print('Passed isolated OpenSSL runtime relocation/hash checks and unprivileged install/uninstall rejection. No system installation or VPN connection.')
