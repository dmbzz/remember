import io, json, os, runpy, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import urllib.request

SCRIPT = Path(__file__).with_name('recover_release.py')
SHA = 'a' * 40

class RecoveryTest(unittest.TestCase):
    def run_case(self, *, version='1.0.3', expired=False, job='success', branch='main', event='push'):
        def urlopen(request, timeout):
            url = request.full_url
            if '/artifacts?' in url:
                data = {'artifacts': [{'name': 'Remember-1.0.3', 'expired': expired}]}
            elif '/jobs?' in url:
                data = {'jobs': [{'name': 'build', 'conclusion': job}]}
            else:
                data = {'status': 'completed', 'event': event, 'head_branch': branch, 'head_sha': SHA,
                        'path': '.github/workflows/release.yml'}
            return io.BytesIO(json.dumps(data).encode())
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'output'
            env = {'RECOVERY_RUN_ID': '123', 'RECOVERY_VERSION': version,
                   'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_TOKEN': 'test-only',
                   'GITHUB_OUTPUT': str(output)}
            with patch.dict(os.environ, env), patch.object(urllib.request, 'urlopen', urlopen), \
                 patch('subprocess.check_output', return_value='version: 1.0.3+44\n'):
                runpy.run_path(str(SCRIPT), run_name='__main__')
            return output.read_text()

    def test_original_artifact(self):
        self.assertIn('source_sha=' + SHA, self.run_case())
    def test_mismatch_version(self):
        with self.assertRaises(ValueError): self.run_case(version='1.0.4')
    def test_expired_artifact(self):
        with self.assertRaises(ValueError): self.run_case(expired=True)
    def test_failed_build(self):
        with self.assertRaises(ValueError): self.run_case(job='failure')
    def test_wrong_branch(self):
        with self.assertRaises(ValueError): self.run_case(branch='other')
    def test_manual_test_run_cannot_become_release(self):
        with self.assertRaises(ValueError): self.run_case(event='workflow_dispatch')

if __name__ == '__main__': unittest.main()
