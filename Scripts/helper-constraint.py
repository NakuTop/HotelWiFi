#!/usr/bin/env python3
"""Build-time only: pin SMAppService's spawn constraint to the signed helper.

The plist is written after signing the helper and before sealing the enclosing
app. Updating it never weakens the XPC certificate or caller checks.
"""
from pathlib import Path
import plistlib
import hashlib
import re
import subprocess
import sys


def expected_constraint(app):
    helper = app / 'Contents/MacOS/HotelWiFiHelper'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(helper)], check=True)
    archs = subprocess.check_output(['/usr/bin/lipo', '-archs', str(helper)], text=True).split()
    hashes = set()
    for arch in archs:
        output = subprocess.run(['/usr/bin/codesign', '-d', '--arch', arch, '--verbose=4', str(helper)],
                                capture_output=True, text=True, check=True).stderr
        if re.search(r'^Identifier=com\.hotelwifi\.helper$', output, re.M) is None:
            raise ValueError('Unexpected helper signing identifier')
        found = re.findall(r'^CandidateCDHash \S+=([0-9a-fA-F]{40})$', output, re.M)
        if not found:
            raise ValueError('Missing code directory hash for ' + arch)
        hashes.update(bytes.fromhex(h) for h in found)
    if not hashes:
        raise ValueError('No signed helper architectures')
    return {'signing-identifier': 'com.hotelwifi.helper', 'cdhash': {'$in': sorted(hashes)}}


def main():
    mode, app_path = sys.argv[1:]
    if mode not in ('write', 'verify'):
        raise ValueError('Expected write or verify')
    app = Path(app_path)
    path = app / 'Contents/Library/LaunchDaemons/com.hotelwifi.RecoveryGuardian.plist'
    value = plistlib.loads(path.read_bytes())
    expected = expected_constraint(app)
    # Local certificates have no Apple Team ID. On the tested macOS release,
    # BTM retains the first helper's cdhash even after unregister/register.
    # A new signed helper gets its own registration; the updater first drains
    # and unregisters the previous one. The XPC service name remains stable.
    generation = hashlib.sha256(b''.join(expected['cdhash']['$in'])).hexdigest()[:24]
    label = 'com.hotelwifi.RecoveryGuardian.' + generation
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if mode == 'write':
        value['SpawnConstraint'] = expected
        value['Label'] = label
        info['HotelWiFiGuardianLabel'] = label
        path.write_bytes(plistlib.dumps(value, sort_keys=False))
        info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
    elif value.get('SpawnConstraint') != expected or value.get('Label') != label or info.get('HotelWiFiGuardianLabel') != label:
        raise ValueError('Spawn constraint does not match this signed helper; rebuild the package')
    print('Helper spawn constraint ' + ('written' if mode == 'write' else 'verified'))


if __name__ == '__main__':
    main()
