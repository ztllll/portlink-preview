#!/usr/bin/env python3
"""Read-only structural verification of a native Mac bundle. Not notarization."""
import argparse,json,os,pathlib,plistlib,subprocess,sys

def command(args):
 r=subprocess.run(args,capture_output=True,text=True,timeout=30)
 return {'exitCode':r.returncode,'stdout':r.stdout.strip(),'stderr':r.stderr.strip()}
def main():
 parser=argparse.ArgumentParser();parser.add_argument('app',type=pathlib.Path);args=parser.parse_args();app=args.app.resolve()
 if not app.is_dir() or app.suffix!='.app':parser.error('explicit existing .app path required')
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());report={'bundle':info.get('CFBundleIdentifier'),'version':info.get('CFBundleShortVersionString'),'build':info.get('CFBundleVersion'),'minimumSystem':info.get('LSMinimumSystemVersion'),'machO':[],'warnings':[]};failed=False
 report['signature']=command(['codesign','--verify','--deep','--strict','--verbose=2',str(app)]);failed|=report['signature']['exitCode']!=0
 report['signingMetadata']=command(['codesign','-dvvv',str(app)]);report['entitlements']=command(['codesign','-d','--entitlements',':-',str(app)])
 seen=set()
 for root,dirs,files in os.walk(app):
  for name in files:
   p=pathlib.Path(root)/name;real=p.resolve()
   if real in seen:continue
   seen.add(real)
   if not real.is_relative_to(app):report['warnings'].append('external symlink: '+str(p.relative_to(app)));failed=True;continue
   kind=command(['file','-b',str(p)])
   if 'Mach-O' not in kind['stdout']:continue
   arch=command(['lipo','-archs',str(p)]);sign=command(['codesign','--verify','--strict',str(p)]);deps=command(['otool','-L',str(p)])
   versions=command(['xcrun','vtool','-show-build',str(p)])
   minimums=[l.strip().split()[-1] for l in versions['stdout'].splitlines() if l.strip().startswith('minos ')]
   item={'path':str(p.relative_to(app)),'architectures':arch,'minimumSystems':minimums,'signature':sign,'dependencies':deps};report['machO'].append(item)
   declared=tuple(int(x) for x in str(report['minimumSystem']).split('.'))
   for version in minimums:
    if tuple(int(x) for x in version.split('.'))>declared:report['warnings'].append('embedded minimum exceeds app declaration: '+str(p.relative_to(app))+' '+version);failed=True
   failed|=arch['exitCode']!=0 or 'arm64' not in arch['stdout'] or sign['exitCode']!=0 or deps['exitCode']!=0
   for line in deps['stdout'].splitlines()[1:]:
    # Universal otool output repeats an absolute file header per architecture.
    # Only indented lines are actual load dependencies, not that header.
    if not line.startswith(('\t',' ')):continue
    dep=line.strip().split(' (compatibility')[0]
    if dep.startswith(('/Users/','/tmp/','/private/tmp/','/opt/homebrew/')):report['warnings'].append('nonportable dependency: '+dep);failed=True
 assets=list(app.glob('Contents/Frameworks/App.framework/**/flutter_assets'))
 report['flutterAssetsPresent']=bool(assets);failed|=not assets
 manifests=list(app.rglob('NativeAssetsManifest.json'))
 report['nativeAssetsManifests']=[{'path':str(p.relative_to(app)),'data':json.loads(p.read_text())} for p in manifests]
 for p in manifests:
  if '/Users/' in p.read_text() or '/tmp/' in p.read_text():report['warnings'].append('absolute development path in native asset manifest');failed=True
 report['structureVerified']=not failed;report['notice']='Signature structure and arm64 inclusion only; not Developer ID, notarization, GUI or real-server acceptance.'
 print(json.dumps(report,ensure_ascii=False,indent=2));return 1 if failed else 0
if __name__=='__main__':sys.exit(main())
