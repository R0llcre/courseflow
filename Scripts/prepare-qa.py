#!/usr/bin/env python3
"""Prepare an isolated QA app without dropping the production sandbox entitlements.

Close the QA app through its normal UI before running this script.
"""
from pathlib import Path
import datetime,json,os,plistlib,shutil,subprocess

cache=Path.home()/'Library/Caches'
build=Path(os.environ.get('COURSEFLOW_BUILD_DIR',str(cache/'CourseflowBuild-20260908')))
configuration=os.environ.get('COURSEFLOW_CONFIGURATION','Debug')
if configuration not in {'Debug','Release'}:raise SystemExit('Unsupported build configuration.')
source=build/f'Build/Products/{configuration}/Courseflow.app'
qa=cache/'Courseflow-QA.app'
r=subprocess.run(['pgrep','-fl',str(qa/'Contents/MacOS/Courseflow')],capture_output=True,text=True)
if r.returncode!=1:raise SystemExit('Close the QA App before preparing a new build.')

def entitlements(app):
 r=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True)
 return plistlib.loads(r.stdout)

expected=entitlements(source)
assert expected.get('com.apple.security.app-sandbox') is True
assert expected.get('com.apple.security.network.client') is True
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
stage=cache/f'Courseflow-QA-stage-{stamp}.app'
shutil.copytree(source,stage)
p=stage/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
info.update(CFBundleIdentifier='dev.courseflow.personal.qa',CFBundleName='课序 QA',CFBundleDisplayName='课序 QA')
p.write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--deep','--sign','-','--preserve-metadata=entitlements,requirements,flags',str(stage)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(stage)],check=True)
assert entitlements(stage)==expected
if qa.exists():qa.rename(cache/f'Courseflow-QA-backup-{stamp}.app')
stage.rename(qa)
print(json.dumps({'qa':str(qa),'sandboxEntitlementsMatch':True}))
