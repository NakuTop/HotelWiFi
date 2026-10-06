#!/usr/bin/env python3
"""Verify all shipped slices, deployment targets, and runtime library locations."""
from pathlib import Path
import json
import re
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, text=True)


app = Path(sys.argv[1])
executables = [app / 'Contents/MacOS' / name
               for name in ('HotelWiFiApp', 'hotelwifi', 'HotelWiFiHelper')]
libraries = list((app / 'Contents/Frameworks').glob('*.dylib'))
expected = set(output('/usr/bin/lipo', '-archs', str(executables[0])).split())
assert expected and expected <= {'arm64', 'x86_64'}, 'Unsupported architecture'
for path in executables + libraries:
    assert set(output('/usr/bin/lipo', '-archs', str(path)).split()) == expected, str(path)
    for arch in sorted(expected):
        load_commands = output('/usr/bin/otool', '-arch', arch, '-l', str(path))
        minimum = re.search(r'\bminos (\d+)\.(\d+)', load_commands)
        assert minimum, 'Missing deployment version: ' + str(path)
        version = tuple(map(int, minimum.groups()))
        assert version == (14, 0) if path in executables else version <= (14, 0), str(path)
        dependencies = output('/usr/bin/otool', '-arch', arch, '-L', str(path)).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(' (compatibility version')[0]
            if dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            if dependency.startswith('@rpath/'):
                assert (app / 'Contents/Frameworks' / dependency.removeprefix('@rpath/')).is_file(), dependency
            else:
                raise AssertionError('Nonportable runtime dependency: ' + dependency)
print(json.dumps({'architectures': sorted(expected), 'minimumMacOS': '14.0',
                  'executablesChecked': len(executables), 'bundledLibrariesChecked': len(libraries),
                  'runtimeDependenciesPortable': True}))
