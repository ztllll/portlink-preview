import importlib.util,pathlib,tempfile,unittest,zipfile,subprocess,sys
from unittest.mock import patch
SOURCE=pathlib.Path(__file__).with_name('sdk_plan.py')
spec=importlib.util.spec_from_file_location('sdk_plan',SOURCE);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class SdkPlanTest(unittest.TestCase):
 def test_default_plan_never_downloads(self):
  result=subprocess.run([sys.executable,str(SOURCE)],capture_output=True,text=True);self.assertEqual(result.returncode,0);self.assertIn('"downloadsByDefault": false',result.stdout)
 def test_install_without_license_authorization_fails_before_download(self):
  result=subprocess.run([sys.executable,str(SOURCE),'--install'],capture_output=True,text=True);self.assertEqual(result.returncode,2);self.assertIn('requires explicit --accept-sdk-license',result.stderr)
 def test_archive_path_traversal_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp);archive=p/'unsafe.zip'
   with zipfile.ZipFile(archive,'w') as z:z.writestr('../escape','bad')
   with self.assertRaises(ValueError):module.safe_extract(archive,p/'destination')
 def test_safe_sdk_archive_extracts(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp);archive=p/'safe.zip'
   with zipfile.ZipFile(archive,'w') as z:z.writestr('cmdline-tools/bin/sdkmanager','fixture')
   module.safe_extract(archive,p/'destination');self.assertEqual((p/'destination/cmdline-tools/bin/sdkmanager').read_text(),'fixture')
 def test_archive_symlink_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp);archive=p/'symlink.zip'
   entry=zipfile.ZipInfo('cmdline-tools/bin/link');entry.create_system=3;entry.external_attr=(0o120777 << 16)
   with zipfile.ZipFile(archive,'w') as z:z.writestr(entry,'/private/fixture')
   with self.assertRaises(ValueError):module.safe_extract(archive,p/'destination')
 def test_explicit_bad_java_does_not_silently_fallback(self):
  self.assertIsNone(module.select_java('/definitely/not/a/jdk'))
 def test_old_java_and_runtime_only_rejected_before_download(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);(root/'bin').mkdir();(root/'bin/java').write_text('fixture')
   with self.assertRaises(ValueError):module.validate_jdk(root)
   (root/'bin/javac').write_text('fixture')
   def old(args,**kw):return subprocess.CompletedProcess(args,0,'java version "1.8.0"' if args[0].endswith('/java') else 'javac 1.8.0','')
   with patch.object(module.subprocess,'run',old),self.assertRaises(ValueError):module.validate_jdk(root)
 def test_jdk17_java_and_javac_verified(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);(root/'bin').mkdir()
   for name in ('java','javac'):(root/'bin'/name).write_text('fixture')
   def valid(args,**kw):return subprocess.CompletedProcess(args,0,'openjdk version "17.0.18"' if args[0].endswith('/java') else 'javac 17.0.18','')
   with patch.object(module.subprocess,'run',valid):self.assertEqual(module.validate_jdk(root),{'java':17,'javac':17})
 def test_mismatched_jdk_tools_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);(root/'bin').mkdir()
   for name in ('java','javac'):(root/'bin'/name).write_text('fixture')
   def mixed(args,**kw):return subprocess.CompletedProcess(args,0,'openjdk version "17.0.18"' if args[0].endswith('/java') else 'javac 21.0.1','')
   with patch.object(module.subprocess,'run',mixed),self.assertRaises(ValueError):module.validate_jdk(root)
 def test_duplicate_bootstrap_entries_rejected(self):
  import warnings
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp);archive=p/'duplicate.zip'
   with zipfile.ZipFile(archive,'w') as z, warnings.catch_warnings():
    warnings.simplefilter('ignore',UserWarning);z.writestr('cmdline-tools/bin/sdkmanager','one');z.writestr('cmdline-tools/bin/sdkmanager','two')
   with self.assertRaises(ValueError):module.safe_extract(archive,p/'destination')
 def test_component_plan_is_pinned(self):
  self.assertIn('ndk;28.2.13676358',module.PACKAGES);self.assertIn('platforms;android-36',module.PACKAGES);self.assertEqual(len(module.BOOTSTRAP['sha1']),40)
if __name__=='__main__':unittest.main()
