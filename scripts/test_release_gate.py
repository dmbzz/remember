import os, subprocess, sys, tempfile, unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/release_gate.py'
class GateTest(unittest.TestCase):
    def test_push_and_dispatch(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); (root/'app').mkdir()
            def git(*args):
                return subprocess.check_output(['git','-C',str(root),*args], text=True, stderr=subprocess.DEVNULL).strip()
            git('init','-q'); git('config','user.email','ci@example.invalid'); git('config','user.name','CI Test')
            spec = root/'app/pubspec.yaml'; spec.write_text('version: 1.0.2+43\n')
            git('add','.'); git('commit','-qm','base'); previous = git('rev-parse','HEAD')
            def run(version, event='push', mode='', ref='refs/heads/main'):
                spec.write_text('version: '+version+'\n')
                git('add','.'); git('commit','-qm','test','--allow-empty')
                output=root/'out'; output.write_text('')
                env={**os.environ,'GITHUB_EVENT_NAME':event,'GITHUB_REF':ref,'PUSH_BEFORE':previous,'RELEASE_MODE':mode,'GITHUB_OUTPUT':str(output)}
                result=subprocess.run([sys.executable,str(SCRIPT)],cwd=root,env=env,capture_output=True,text=True)
                return result.returncode,output.read_text()
            self.assertEqual(run('1.0.2+43')[1].splitlines()[:2], ['run=false','publish=false'])
            self.assertEqual(run('1.0.3+44')[1].splitlines()[:2], ['run=true','publish=true'])
            self.assertNotEqual(run('1.0.3+43')[0], 0)
            self.assertNotEqual(run('1.0.2+44')[0], 0)
            self.assertEqual(run('1.0.2+43','workflow_dispatch','test')[1].splitlines()[:2], ['run=true','publish=false'])
            self.assertEqual(run('1.0.2+43','workflow_dispatch','recover')[1].splitlines()[:2], ['run=false','publish=false'])
            self.assertNotEqual(run('1.0.3+44','workflow_dispatch','publish','refs/heads/other')[0],0)
if __name__=='__main__': unittest.main()
