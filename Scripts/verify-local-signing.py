#!/usr/bin/env python3
"""Verifies the actual packaged signatures, including spoof rejection; no network or root operations."""
from pathlib import Path
import subprocess, tempfile, hashlib, json, shutil, shlex, plistlib
root = Path(__file__).resolve().parent.parent
app = root/'dist/HotelWiFi.app'
result = {}
with tempfile.TemporaryDirectory(prefix='.hotelwifi-build.verify-signing-',dir=root) as td:
    td = Path(td)
    subprocess.run(['/usr/bin/codesign','--display','--extract-certificates='+str(td/'cert'),str(app)],check=True,capture_output=True)
    fingerprint = hashlib.sha1((td/'cert0').read_bytes()).hexdigest()
    for executable, identifier in [('HotelWiFiApp','com.hotelwifi.app'),('hotelwifi','com.hotelwifi.cli'),('HotelWiFiHelper','com.hotelwifi.helper')]:
        target = app if executable=='HotelWiFiApp' else app/'Contents/MacOS'/executable
        requirement = 'anchor = H"'+fingerprint+'" and identifier "'+identifier+'"'
        check = subprocess.run(['/usr/bin/codesign','--verify','--strict','-R','='+requirement,str(target)],capture_output=True)
        assert check.returncode == 0, executable+' did not match its pinned certificate/identifier'
        result[executable] = 'matching certificate and identifier'
    cli = app/'Contents/MacOS/hotelwifi'
    wrong = subprocess.run(['/usr/bin/codesign','--verify','-R','=anchor = H"'+'0'*40+'"',str(cli)],capture_output=True)
    assert wrong.returncode != 0 and b'failed to satisfy' in wrong.stderr
    spoof = td/'spoof'
    shutil.copy2(cli,spoof)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','com.hotelwifi.cli',str(spoof)],check=True,capture_output=True)
    rejected = subprocess.run(['/usr/bin/codesign','--verify','-R','=anchor = H"'+fingerprint+'" and identifier "com.hotelwifi.cli"',str(spoof)],capture_output=True)
    assert rejected.returncode != 0 and b'failed to satisfy' in rejected.stderr
    result['wrong_certificate_rejected'] = True
    result['same_identifier_adhoc_spoof_rejected'] = True
    # Exercise stale helper hashes and mismatched job metadata on a temporary
    # package only; no launchd registration or network operation is performed.
    copied = td/'constraint-fixture.app'
    shutil.copytree(app, copied)
    launch = copied/'Contents/Library/LaunchDaemons/com.hotelwifi.RecoveryGuardian.plist'
    original_plist = launch.read_bytes()
    value = plistlib.loads(original_plist)
    value['SpawnConstraint']['cdhash']['$in'] = [bytes(20)]
    launch.write_bytes(plistlib.dumps(value))
    stale = subprocess.run(['/usr/bin/env','python3',str(root/'Scripts/helper-constraint.py'),'verify',str(copied)],capture_output=True)
    assert stale.returncode != 0 and b'Spawn constraint does not match' in stale.stderr
    result['stale_spawn_constraint_rejected'] = True
    launch.write_bytes(original_plist)
    info_path = copied/'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes()); info['HotelWiFiGuardianLabel'] = 'com.hotelwifi.RecoveryGuardian.' + '0'*24
    info_path.write_bytes(plistlib.dumps(info))
    mismatch = subprocess.run(['/usr/bin/env','python3',str(root/'Scripts/helper-constraint.py'),'verify',str(copied)],capture_output=True)
    assert mismatch.returncode != 0 and b'Spawn constraint does not match' in mismatch.stderr
    result['mismatched_service_generation_rejected'] = True
    search = shlex.split(subprocess.run(['/usr/bin/security','list-keychains','-d','user'],check=True,capture_output=True,text=True).stdout)
    result['project_keychain_removed_from_search_list'] = not any('.local-signing' in p for p in search)
    assert result['project_keychain_removed_from_search_list']
    result['xpc_runtime_authorization'] = 'requires separate system-approved daemon acceptance; static requirement checks do not substitute'
(root/'Evidence').mkdir(exist_ok=True)
(root/'Evidence/local-signing-verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(result,ensure_ascii=False,indent=2))
