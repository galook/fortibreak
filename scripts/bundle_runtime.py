#!/usr/bin/env python3
"""Copy the Homebrew VPN engine, its OpenSSL libraries and CA bundle into the app, relocated to load only from beside the engine."""
import pathlib,shutil,subprocess,sys
app=pathlib.Path(sys.argv[1]).resolve()
helpers=app/'Contents/Helpers';licenses=app/'Contents/Resources/Licenses'
for folder in [helpers,licenses]:shutil.rmtree(folder,ignore_errors=True);folder.mkdir(parents=True)
sources={
 'openfortivpn':'/opt/homebrew/bin/openfortivpn',
 'libssl.4.dylib':'/opt/homebrew/opt/openssl@4/lib/libssl.4.dylib',
 'libcrypto.4.dylib':'/opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib'
}
for name,source in sources.items():
 target=helpers/name
 shutil.copyfile(pathlib.Path(source).resolve(),target);target.chmod(0o755)
 lines=subprocess.check_output(['otool','-L',str(target)],text=True).splitlines()[1:]
 if name.endswith('.dylib'):lines=lines[1:] # dylib's own install ID is not a dependency.
 for line in lines:
  dependency=line.strip().split(' (',1)[0]
  if dependency.startswith('/opt/homebrew/'):
   library=pathlib.Path(dependency).name
   assert library in ['libssl.4.dylib','libcrypto.4.dylib'],dependency
   subprocess.run(['install_name_tool','-change',dependency,'@loader_path/'+library,str(target)],check=True,capture_output=True)
shutil.copyfile(pathlib.Path('/opt/homebrew/etc/openssl@4/cert.pem').resolve(),app/'Contents/Resources/cert.pem')
for name,source in {'openfortivpn-LICENSE':'/opt/homebrew/opt/openfortivpn/LICENSE','openfortivpn-LICENSE.OpenSSL':'/opt/homebrew/opt/openfortivpn/LICENSE.OpenSSL','OpenSSL-LICENSE.txt':'/opt/homebrew/opt/openssl@4/LICENSE.txt'}.items():
 shutil.copyfile(pathlib.Path(source).resolve(),licenses/name)
