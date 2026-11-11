#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Blender Authors
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run applicable official Python suites and Android regressions on an installed APK.

Each suite starts in a fresh unsaved factory scene. Existing external launch
arguments are restored. No preferences/projects are saved, and no app data is cleared.
"""
import argparse
import json
from pathlib import Path
import time
import uuid
from run_render_regressions import Device, find_tool, ARGS_FILE, FILES, PACKAGE

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MODULES = ('mathutils', 'bmesh', 'bpy_path', 'bpy_utils_units', 'idprop', 'prop',
           'prop_array', 'text', 'grease_pencil', 'annotations', 'bpy_driver_secure_eval', 'gpu')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('-s', '--serial', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--adb')
    parser.add_argument('--ktx-fixtures', required=True, type=Path)
    parser.add_argument('--timeout', type=float, default=180)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    device = Device(find_tool('adb', args.adb), args.serial)
    remote = FILES + '/python-regressions-' + uuid.uuid4().hex
    report = {'serial': args.serial, 'passed': False, 'suites': {}}
    original = device.call('shell', 'cat', ARGS_FILE, check=False)
    saved_args = original.stdout if original.returncode == 0 else None
    changed = False
    try:
        report['package_before'] = device.text('shell', 'dumpsys', 'package', PACKAGE)
        device.call('shell', 'mkdir', '-p', remote, remote + '/ktx-fixtures')
        for fixture in args.ktx_fixtures.iterdir():
            if fixture.is_file():
                device.push(fixture, remote + '/ktx-fixtures/' + fixture.name)
        device.push(HERE / 'python_test_runner.py', remote + '/python_test_runner.py')
        paths = [REPO / 'tests/python' / ('bl_pyapi_' + name + '.py') for name in MODULES]
        paths += [HERE / 'android_final_regressions.py', HERE / 'upstream_regressions.py']
        for path in paths:
            name = path.stem
            device.push(path, remote + '/' + path.name)
            result_path = remote + '/' + name + '.json'
            if name == 'upstream_regressions':
                launch = '--factory-startup --python ' + remote + '/' + path.name + ' -- ' + result_path + ' ui'
            else:
                launch = '--factory-startup --python ' + remote + '/python_test_runner.py -- ' + remote + '/' + path.name + ' ' + result_path
            local_args = output / 'launch-args.txt'
            local_args.write_text(launch)
            device.push(local_args, ARGS_FILE)
            changed = True
            device.call('shell', 'am', 'force-stop', PACKAGE)
            device.call('shell', 'am', 'start', '-n', PACKAGE + '/.BlenderActivity')
            print('[python-test] START', name, flush=True)
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                raw = device.call('shell', 'cat', result_path, check=False)
                if raw.returncode == 0:
                    try:
                        result = json.loads(raw.stdout)
                    except json.JSONDecodeError:
                        time.sleep(0.5)
                        continue
                    if result.get('complete'):
                        if name == 'upstream_regressions':
                            result['passed'] = bool(result['tests']) and all(t['passed'] for t in result['tests'].values())
                        report['suites'][name] = result
                        (output / (name + '.json')).write_text(json.dumps(result, indent=2))
                        print('[python-test]', name, 'PASS' if result['passed'] else 'FAIL', result.get('tests_run', len(result.get('tests', {}))), flush=True)
                        break
                time.sleep(0.5)
            else:
                report['suites'][name] = {'passed': False, 'error': 'Timed out without complete results'}
                print('[python-test]', name, 'TIMEOUT', flush=True)
            (output / 'report.json').write_text(json.dumps(report, indent=2))
        report['passed'] = len(report['suites']) == len(paths) and all(r['passed'] for r in report['suites'].values())
    except Exception as error:
        report['error'] = repr(error)
    finally:
        if changed:
            try:
                if saved_args is None:
                    device.call('shell', 'rm', '-f', ARGS_FILE)
                else:
                    backup = output / 'launch-args-before.txt'
                    backup.write_bytes(saved_args)
                    device.push(backup, ARGS_FILE)
            except Exception as error:
                report.update(passed=False, cleanup_error=repr(error))
        (output / 'logcat-crash.txt').write_bytes(device.call('logcat', '-b', 'crash', '-d', check=False).stdout)
        (output / 'report.json').write_text(json.dumps(report, indent=2))
    print('ANDROID_PYTHON_REGRESSIONS', 'PASS' if report['passed'] else 'FAIL', output, flush=True)
    return 0 if report['passed'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
