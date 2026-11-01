import importlib.util, tempfile, unittest, zipfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('packager',Path(__file__).with_name('package_github_release.py'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class PackageTest(unittest.TestCase):
    def test_clean_relocatable_package_and_reject_private_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); repo=root/'repo'; app=repo/'server/app'; app.mkdir(parents=True)
            for p in [app/'__init__.py', app/'main.py', repo/'scripts/ci_run_server_hidden.ps1', repo/'server/requirements-portable.txt']:
                p.parent.mkdir(parents=True,exist_ok=True); p.write_text('# safe')
            win=root/'win'
            for n in ['app.exe','flutter_windows.dll','data/app.so','data/icudtl.dat','data/flutter_assets/AssetManifest.bin']:
                p=win/n; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(b'fake')
            runtime=root/'runtime'; runtime.mkdir()
            for n in ['python.exe','python313.dll','python313.zip','Lib/site-packages/fastapi/__init__.py','Lib/site-packages/uvicorn/__init__.py','Lib/site-packages/sqlalchemy/__init__.py','Lib/site-packages/aiosqlite/__init__.py']:
                p=runtime/n; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(b'fake')
            apk=root/'app.apk'
            with zipfile.ZipFile(apk,'w') as z: z.writestr('AndroidManifest.xml',b'fake')
            output=root/'out'; result=m.package(repo,win,runtime,apk,output,'1.0.3')
            with zipfile.ZipFile(result) as z:
                self.assertIsNone(z.testzip()); names=set(z.namelist())
                self.assertIn('Remember/backend/runtime/python.exe',names)
                pth=z.read('Remember/backend/runtime/python313._pth').decode()
                self.assertIn('../server',pth); self.assertIn('Lib/site-packages',pth); self.assertIn('import site',pth)
                config=z.read('Remember/backend/server/config/config.local.yaml').decode()
                self.assertIn('data/recordings',config); self.assertNotIn('C:\\Users',config)
            (app/'config.user.yaml').write_text('private')
            with self.assertRaisesRegex(ValueError,'prohibited'):
                m.package(repo,win,runtime,apk,root/'out2','1.0.3')
if __name__=='__main__': unittest.main()
