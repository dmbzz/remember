import hashlib, os, runpy, sys, tempfile, types, unittest
from pathlib import Path
from unittest.mock import patch
SCRIPT = Path(__file__).resolve().parents[1]/'scripts/publish_github_release.py'
SHA='a'*40
class Response:
    def __init__(self, data=None, code=200, binary=b''):
        self._data=data; self.status_code=code; self.ok=code<400; self.binary=binary
    def json(self): return self._data
    def iter_content(self, size): yield self.binary
    def close(self): pass
class Fake:
    def __init__(self, *, ref=SHA, draft=True, corrupt=False):
        self.headers={}; self.ref=ref; self.release=None; self.assets={}; self.draft=draft; self.corrupt=corrupt; self.patched=False
    def get(self,url,**kw): return self.request('GET',url,**kw)
    def request(self,method,url,**kw):
        if '/git/ref/tags/' in url: return Response({'object':{'type':'commit','sha':self.ref}})
        if url.endswith('/releases') and method=='GET': return Response([self.release] if self.release else [])
        if url.endswith('/releases') and method=='POST':
            self.release={'id':1,'tag_name':'v1.0.3','draft':True,'upload_url':'https://upload.invalid/assets{?name,label}'}; return Response(self.release)
        if url.endswith('/releases/1/assets') and method=='GET': return Response(list(self.assets.values()))
        if url.startswith('https://upload.invalid'):
            data=kw['data'].read(); name=kw['params']['name']; idx=len(self.assets)+1
            a={'id':idx,'name':name,'body':data}; self.assets[name]=a; return Response(a)
        if '/releases/assets/' in url:
            idx=int(url.rsplit('/',1)[1]); data=next(a['body'] for a in self.assets.values() if a['id']==idx)
            return Response(binary=(data+b'x') if self.corrupt else data)
        if url.endswith('/releases/1') and method=='PATCH': self.patched=True; return Response({})
        raise AssertionError((method,url))
class PublishTest(unittest.TestCase):
    def execute(self, fake):
        with tempfile.TemporaryDirectory() as temp:
            old=os.getcwd(); os.chdir(temp)
            try:
                Path('dist').mkdir(); Path('dist/Remember-1.0.3-Android.apk').write_bytes(b'apk')
                Path('dist/Remember-1.0.3-Windows-完整包.zip').write_bytes(b'zip')
                env={'GITHUB_REPOSITORY':'owner/repo','GITHUB_SHA':SHA,'RELEASE_VERSION':'1.0.3','GITHUB_TOKEN':'not-a-real-token'}
                with patch.dict(os.environ,env), patch.dict(sys.modules,{'requests':types.SimpleNamespace(Session=lambda:fake)}):
                    runpy.run_path(str(SCRIPT),run_name='__main__')
            finally: os.chdir(old)
    def test_upload_download_then_publish(self):
        fake=Fake(); self.execute(fake); self.assertTrue(fake.patched); self.assertEqual(len(fake.assets),3)
    def test_corrupted_download_fails_before_publish(self):
        fake=Fake(corrupt=True)
        with self.assertRaises(ValueError): self.execute(fake)
        self.assertFalse(fake.patched)
    def test_conflicting_tag_fails_before_publish(self):
        fake=Fake(ref='b'*40)
        with self.assertRaises(ValueError): self.execute(fake)
        self.assertFalse(fake.patched); self.assertEqual(len(fake.assets),0)
    def test_existing_asset_mismatch_never_overwritten(self):
        fake=Fake(); fake.release={'id':1,'tag_name':'v1.0.3','draft':True,'upload_url':'https://upload.invalid/assets{?name,label}'}
        fake.assets={'Remember-1.0.3-Android.apk':{'id':1,'name':'Remember-1.0.3-Android.apk','body':b'wrong'}}
        with self.assertRaises(ValueError): self.execute(fake)
        self.assertFalse(fake.patched); self.assertEqual(fake.assets['Remember-1.0.3-Android.apk']['body'],b'wrong')
if __name__=='__main__': unittest.main()
