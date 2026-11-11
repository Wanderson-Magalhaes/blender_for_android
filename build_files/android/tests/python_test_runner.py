# SPDX-FileCopyrightText: 2026 Blender Authors
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run an official unittest module in a fresh Android factory scene.

Arguments after --: module file, JSON result file. Does not save preferences.
"""
import importlib.util
import io
import json
from pathlib import Path
import sys
import traceback
import unittest
import bpy

# The native launcher appends its own flags (--disable-crash-handler) after these, so take
# the first two rather than unpacking everything after `--`.
_args = sys.argv[sys.argv.index('--') + 1:]
module_path, output_path = Path(_args[0]), Path(_args[1])
report = {'version': bpy.app.version_string, 'module': module_path.name,
          'complete': False, 'passed': False}
try:
    spec = importlib.util.spec_from_file_location(module_path.stem, module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    report.update(tests_run=result.testsRun, passed=result.wasSuccessful() and result.testsRun > 0,
                  failures=[(test.id(), error) for test, error in result.failures],
                  errors=[(test.id(), error) for test, error in result.errors],
                  skipped=[(test.id(), reason) for test, reason in result.skipped],
                  log=stream.getvalue())
except BaseException:
    report['error'] = traceback.format_exc()
report['complete'] = True
output_path.write_text(json.dumps(report, indent=2))
print('ANDROID_PYTHON_TEST_RESULT', json.dumps({k:v for k,v in report.items() if k != 'log'}), flush=True)
