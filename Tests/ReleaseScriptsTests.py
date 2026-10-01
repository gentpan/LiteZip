"""Exercise distribution failure paths without credentials or Apple uploads."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['MOCK_CALL_LOG'], 'a') as f:
    f.write(json.dumps([tool, *args]) + '\n')
failure = os.environ.get('MOCK_FAILURE', '')
if tool == 'security':
    print('1) ABCDEF "Developer ID Application: Test Developer (TESTTEAM)"')
elif tool == 'codesign' and '--display' in args:
    print('Executable=test', file=sys.stderr)
    if failure != 'signature':
        print('Authority=Developer ID Application: Test Developer (TESTTEAM)', file=sys.stderr)
elif tool == 'xcrun' and args[:2] == ['notarytool', 'history']:
    if failure == 'credentials':
        sys.exit(1)
    print('{}')
elif tool == 'xcrun' and args[:2] == ['notarytool', 'submit']:
    print(json.dumps({'id': '11111111-1111-1111-1111-111111111111'}))
elif tool == 'xcrun' and args[:2] == ['notarytool', 'wait']:
    print(json.dumps({'status': 'Invalid' if failure == 'rejected' else 'Accepted'}))
    if failure == 'wait':
        sys.exit(1)
elif tool == 'xcrun' and args[:2] == ['notarytool', 'log']:
    Path(args[3]).write_text(json.dumps({'status': 'Invalid' if failure == 'rejected' else 'Accepted'}))
elif tool == 'xcrun' and args[:2] == ['stapler', 'staple'] and failure == 'staple':
    sys.exit(1)
elif tool == 'xcrun' and args[:2] == ['stapler', 'validate'] and failure == 'ticket':
    sys.exit(1)
elif tool == 'spctl' and failure == 'gatekeeper':
    sys.exit(1)
'''


class ReleaseScriptsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='LiteZip release tests ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.app = self.base / 'Input With Spaces.app'
        contents = self.app / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '9.8.7',
            'CFBundleIdentifier': 'test.release',
        }))
        # Include every bundled executable so adding engines cannot silently skip signing.
        self.engines = ('7zz', 'zstd', 'lzip', 'lz4', 'brotli', 'lrzip', 'snzip')
        engine_dir = contents / 'Resources' / 'Engine'
        engine_dir.mkdir(parents=True)
        for name in self.engines:
            (engine_dir / name).write_bytes(b'test executable')
        self.dist = self.base / 'output with spaces'
        self.dist.mkdir()
        self.archive = self.dist / 'LiteZip-9.8.7-macOS-universal.zip'
        self.archive.write_bytes(b'previous release')
        (self.dist / 'SHA256SUMS').write_bytes(b'previous checksum')
        mock_bin = self.base / 'bin'
        mock_bin.mkdir()
        for name in ('security', 'codesign', 'xcrun', 'spctl'):
            path = mock_bin / name
            path.write_text(MOCK_TOOL)
            path.chmod(0o755)
        self.calls = self.base / 'calls.jsonl'
        self.env = dict(os.environ, PATH=f'{mock_bin}:{os.environ["PATH"]}',
                        LITEZIP_DIST_DIR=str(self.dist), LITEZIP_NOTARY_PROFILE='test-profile',
                        MOCK_CALL_LOG=str(self.calls))
        self.env.pop('LITEZIP_SIGN_IDENTITY', None)

    def run_script(self, failure='', script='notarize.sh'):
        self.env['MOCK_FAILURE'] = failure
        return subprocess.run(['bash', str(ROOT / 'Scripts' / script), str(self.app)],
                              env=self.env, capture_output=True, text=True)

    def read_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def assert_previous_release(self):
        self.assertEqual(self.archive.read_bytes(), b'previous release')
        self.assertEqual((self.dist / 'SHA256SUMS').read_bytes(), b'previous checksum')

    def test_failures_preserve_previous_release(self):
        for failure in ('rejected', 'wait', 'staple', 'ticket', 'gatekeeper'):
            with self.subTest(failure=failure):
                result = self.run_script(failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_previous_release()
        logs = list(self.dist.glob('.notarize-*/apple-log.json'))
        self.assertEqual(len(logs), 5)
        self.assertTrue(any(json.loads(p.read_text())['status'] == 'Invalid' for p in logs))

    def test_ad_hoc_signature_cannot_be_distributed(self):
        result = self.run_script('signature')
        self.assertNotEqual(result.returncode, 0)
        self.assert_previous_release()
        self.assertFalse(any(c[:3] == ['xcrun', 'notarytool', 'submit'] for c in self.read_calls()))

    def test_invalid_credentials_stop_before_signing(self):
        result = self.run_script('credentials', 'sign.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assert_previous_release()
        self.assertFalse(any(c[0] == 'codesign' for c in self.read_calls()))

    def test_signing_automatically_notarizes_and_checks_the_final_package(self):
        result = self.run_script(script='sign.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.read_calls()
        self.assertTrue(any(c[:3] == ['xcrun', 'notarytool', 'submit'] for c in calls))
        self.assertTrue(any(c[:3] == ['xcrun', 'stapler', 'validate'] for c in calls))
        self.assertTrue(any(c[0] == 'spctl' for c in calls))
        signed = [c[-1] for c in calls if c[:2] == ['codesign', '--force']]
        self.assertCountEqual(signed, [str(self.app / 'Contents' / 'Resources' / 'Engine' / name)
                                     for name in self.engines] +
                              [str(self.app / 'Contents' / 'PlugIns' / 'LiteZipFinder.appex'), str(self.app)])
        with zipfile.ZipFile(self.archive) as archive:
            info = plistlib.loads(archive.read('LiteZip.app/Contents/Info.plist'))
            self.assertEqual(info['CFBundleShortVersionString'], '9.8.7')
        checksum = (self.dist / 'SHA256SUMS').read_text().strip()
        self.assertEqual(checksum, f'{hashlib.sha256(self.archive.read_bytes()).hexdigest()}  {self.archive.name}')


if __name__ == '__main__':
    unittest.main(verbosity=2)
