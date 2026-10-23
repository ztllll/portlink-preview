import contextlib,importlib.util,io,json,pathlib,sys,tempfile,unittest,zipfile
from unittest.mock import patch
SOURCE=pathlib.Path(__file__).with_name('verify_apk.py')
spec=importlib.util.spec_from_file_location('verify_apk',SOURCE);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class ApkCheckTest(unittest.TestCase):
 def fixture(self,root,drop=None,abi='arm64-v8a'):
  tools=root/'sdk/build-tools/36.0.0';tools.mkdir(parents=True)
  for tool in ('aapt','apksigner'): (tools/tool).write_text('fixture')
  apk=root/'preview.apk';names=['AndroidManifest.xml','classes.dex','assets/flutter_assets/AssetManifest.bin','assets/flutter_assets/NativeAssetsManifest.json','lib/'+abi+'/libflutter.so']
  with zipfile.ZipFile(apk,'w') as z:
   for name in names:
    if name!=drop:z.writestr(name,'synthetic fixture')
  return apk,root/'sdk'
 def inspect(self,apk,sdk,signature=0,package='dev.portlink.portlink',minimum=24):
  def probe(args):return {'exitCode':signature,'stdout':'verified','stderr':''} if 'verify' in args else {'exitCode':0,'stdout':"package: name='"+package+"'\nsdkVersion:'"+str(minimum)+"'",'stderr':''}
  out=io.StringIO()
  with patch.object(sys,'argv',['verify_apk',str(apk),'--sdk-root',str(sdk)]),patch.object(module,'probe',probe),contextlib.redirect_stdout(out):code=module.main()
  return code,json.loads(out.getvalue())
 def test_valid_structure_and_signature_metadata(self):
  with tempfile.TemporaryDirectory() as tmp:
   apk,sdk=self.fixture(pathlib.Path(tmp));code,report=self.inspect(apk,sdk);self.assertEqual(code,0);self.assertTrue(report['structureAndSignatureVerified']);self.assertIn('not production signing',report['notice'])
 def test_no_arm64_cannot_claim_target_architecture(self):
  with tempfile.TemporaryDirectory() as tmp:
   apk,sdk=self.fixture(pathlib.Path(tmp),abi='x86_64');self.assertEqual(self.inspect(apk,sdk)[0],1)
 def test_missing_dex_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   apk,sdk=self.fixture(pathlib.Path(tmp),drop='classes.dex');self.assertEqual(self.inspect(apk,sdk)[0],1)
 def test_missing_native_manifest_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   apk,sdk=self.fixture(pathlib.Path(tmp),drop='assets/flutter_assets/NativeAssetsManifest.json');self.assertEqual(self.inspect(apk,sdk)[0],1)
 def test_invalid_signature_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   apk,sdk=self.fixture(pathlib.Path(tmp));self.assertEqual(self.inspect(apk,sdk,signature=1)[0],1)
 def test_wrong_package_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   apk,sdk=self.fixture(pathlib.Path(tmp));self.assertEqual(self.inspect(apk,sdk,package='example.fixture')[0],1)
 def test_wrong_minimum_sdk_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   apk,sdk=self.fixture(pathlib.Path(tmp));self.assertEqual(self.inspect(apk,sdk,minimum=23)[0],1)
if __name__=='__main__':unittest.main()
