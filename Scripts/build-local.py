#!/usr/bin/env python3
"""Development-only packaging. Isolated signing keychain; no system trust changes.
The delivered app has no Python dependency. Never logs private keys or passwords.
"""
from pathlib import Path
import os, subprocess, secrets, tempfile, hashlib

root = Path(__file__).resolve().parent.parent
signing = root / '.local-signing'
if signing.is_symlink(): raise SystemExit('Signing directory must not be a symbolic link')
signing.mkdir(mode=0o700, exist_ok=True)
if signing.stat().st_uid != os.getuid() or signing.stat().st_mode & 0o077:
    raise SystemExit('Signing directory must belong to this user with mode 0700')
keychain = signing / 'HotelWiFi.keychain-db'
password_file = signing / 'keychain-password'
cert_file = signing / 'certificate.der'

def run(args, **kwargs):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        message = result.stderr.decode(errors='replace')
        if 'password' in globals(): message = message.replace(password, '[REDACTED]')
        raise SystemExit(Path(args[0]).name + ' failed: ' + message)
    return result

if not keychain.exists():
    password = secrets.token_urlsafe(40)
    fd = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as f: f.write(password)
    with tempfile.TemporaryDirectory(prefix='.hotelwifi-build.signing-', dir=root) as td:
        td = Path(td)
        cfg = td/'openssl.cnf'
        cfg.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=HotelWiFi Local '+secrets.token_hex(8)+'\n[ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
        run(['/usr/bin/openssl','req','-x509','-newkey','rsa:3072','-nodes','-sha256','-days','3650','-config',str(cfg),'-keyout',str(td/'key.pem'),'-out',str(td/'cert.pem')])
        run(['/usr/bin/openssl','x509','-in',str(td/'cert.pem'),'-outform','DER','-out',str(cert_file)])
        env = dict(os.environ, HOTELWIFI_P12_PASSWORD=password)
        run(['/usr/bin/openssl','pkcs12','-export','-inkey',str(td/'key.pem'),'-in',str(td/'cert.pem'),'-out',str(td/'identity.p12'),'-passout','env:HOTELWIFI_P12_PASSWORD'],env=env)
        # security creates a keychain in the search list; restore the exact original list immediately.
        import shlex
        original = shlex.split(run(['/usr/bin/security','list-keychains','-d','user']).stdout.decode())
        try:
            run(['/usr/bin/security','create-keychain','-p',password,str(keychain)])
        finally:
            run(['/usr/bin/security','list-keychains','-d','user','-s',*original])
        run(['/usr/bin/security','unlock-keychain','-p',password,str(keychain)])
        run(['/usr/bin/security','import',str(td/'identity.p12'),'-k',str(keychain),'-P',password,'-T','/usr/bin/codesign'])
        run(['/usr/bin/security','set-key-partition-list','-S','apple-tool:,apple:,codesign:','-s','-k',password,str(keychain)])
else:
    for p in [password_file,cert_file,keychain]:
        if p.is_symlink() or p.stat().st_uid != os.getuid(): raise SystemExit('Unsafe signing material')
    password = password_file.read_text()
run(['/usr/bin/security','unlock-keychain','-p',password,str(keychain)])
identity = hashlib.sha1(cert_file.read_bytes()).hexdigest().upper()
import shlex
original = shlex.split(run(['/usr/bin/security','list-keychains','-d','user']).stdout.decode())
try:
    run(['/usr/bin/security','list-keychains','-d','user','-s',str(keychain),*original])
    subprocess.run(['/bin/bash',str(root/'Scripts/build.sh')],cwd=root,check=True,
        env=dict(os.environ,HOTELWIFI_SIGNING_IDENTITY=identity,HOTELWIFI_SIGNING_KEYCHAIN=str(keychain),HOTELWIFI_LOCAL_SIGNING='1'))
finally:
    run(['/usr/bin/security','list-keychains','-d','user','-s',*original])
    run(['/usr/bin/security','lock-keychain',str(keychain)])
