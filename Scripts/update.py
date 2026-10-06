#!/usr/bin/env python3
"""Developer installer. The shipped app has no Python dependency.

Drain the old guardian through the signed app, retain its recovery journals,
and verify the new service's signed XPC handshake before reporting success.
"""
from datetime import datetime, timezone
from pathlib import Path
import json
import os
import plistlib
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
APP = Path('/Applications/HotelWiFi.app')
SOURCE = ROOT / 'dist/HotelWiFi.app'
STATE = Path.home() / 'Library/Application Support/HotelWiFi'


def command(args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def designated_requirement(path):
    result = command(['/usr/bin/codesign', '-d', '-r-', str(path)])
    requirements = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith('designated => ')]
    if len(requirements) != 1:
        raise SystemExit('Cannot verify the app designated signing requirement')
    return requirements[0]


def running_app():
    return str(APP / 'Contents/MacOS/HotelWiFiApp') in command(['/bin/ps', '-axo', 'comm=']).stdout.splitlines()


def wait_for(predicate, message, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.5)
    raise SystemExit(message)


def fresh_state(name, since):
    try:
        path = STATE / name
        if path.is_symlink() or path.stat().st_uid != os.getuid():
            return {}
        value = json.loads(path.read_text())
        if datetime.fromisoformat(value['at'].replace('Z', '+00:00')) < since:
            return {}
        return value
    except (OSError, ValueError, KeyError):
        return {}


def main():
    if not APP.is_dir() or APP.is_symlink() or SOURCE.is_symlink():
        raise SystemExit('Expected an existing installation at /Applications/HotelWiFi.app')
    command(['/bin/bash', str(ROOT/'Scripts/verify-package.sh'), str(SOURCE)])
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)])
    if designated_requirement(APP) != designated_requirement(SOURCE):
        raise SystemExit('The update must have the same app signing identity')
    old_info = plistlib.loads((APP/'Contents/Info.plist').read_bytes())
    if int(old_info.get('CFBundleVersion', '0')) < 9:
        raise SystemExit('This older version requires 停止并恢复 and 注销服务 before a manual update')
    new_info = plistlib.loads((SOURCE/'Contents/Info.plist').read_bytes())
    if running_app():
        command(['/usr/bin/swift', '-e', 'import AppKit; for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.hotelwifi.app") { _ = app.terminate() }'])
        wait_for(lambda: not running_app(), '应用未完成退出恢复，更新未执行。')
    started = datetime.now(timezone.utc).replace(microsecond=0)
    command(['/usr/bin/open', '-n', str(APP), '--args', '--prepare-update'])
    print('等待旧版处理恢复事务并注销服务…', flush=True)
    wait_for(lambda: fresh_state('update-ready.json', started).get('ready') is True and not running_app(),
             '旧服务未确认可更新，未覆盖应用；请查看窗口中的原因。')
    state = fresh_state('update-ready.json', started)
    if not state.get('journalsPreserved') or state.get('guardianLabel') != old_info.get('HotelWiFiGuardianLabel'):
        raise SystemExit('更新准备状态与已安装版本不一致，未覆盖应用。')
    job = subprocess.run(['/bin/launchctl', 'print', 'system/' + state['guardianLabel']], capture_output=True, text=True)
    if job.returncode == 0 or 'Could not find service' not in job.stderr:
        raise SystemExit('旧服务尚未注销或状态不明，未覆盖应用。')
    backup_dir = ROOT / '.update-backups'
    if backup_dir.is_symlink():
        raise SystemExit('Unsafe backup directory')
    backup_dir.mkdir(mode=0o700, exist_ok=True)
    backup = backup_dir / (datetime.now().strftime('%Y%m%d-%H%M%S') + '.app')
    if backup.exists():
        raise SystemExit('Backup already exists')
    os.rename(APP, backup)
    try:
        command(['/usr/bin/ditto', str(SOURCE), str(APP)])
        command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)])
    except Exception:
        # Before starting a new registration, a copy/seal failure is reversible.
        # Keep the failed package for inspection and reinstall the original.
        if APP.exists():
            os.rename(APP, backup.with_name(backup.stem + '-failed.app'))
        os.rename(backup, APP)
        command(['/usr/bin/open', '-n', str(APP), '--args', '--repair-helper'])
        print('安装未完成，已恢复原应用并请求重新登记；恢复日志保留。', flush=True)
        raise
    started = datetime.now(timezone.utc).replace(microsecond=0)
    command(['/usr/bin/open', '-n', str(APP), '--args', '--repair-helper'])
    print('新版已安装，等待经过身份校验的服务响应…', flush=True)
    wait_for(lambda: fresh_state('helper-registration.json', started).get('guardianLabel') == new_info['HotelWiFiGuardianLabel'] and
             fresh_state('helper-registration.json', started).get('helperReady') is True,
             '新版已安装但服务尚未通过响应验证。若系统要求，请批准后台服务并点击“修复后台服务”。恢复日志仍保留。')
    print('更新完成：后台恢复服务已响应；原版本保留于 ' + str(backup), flush=True)


if __name__ == '__main__':
    main()
