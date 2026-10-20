#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo '缺少完整 Xcode / iPhoneOS SDK。安装 Xcode 后设置 DEVELOPER_DIR 为 Xcode.app/Contents/Developer，再运行。' >&2
  exit 2
fi
bash "$project_root/scripts/prepare-vlc.sh"
bash "$project_root/scripts/prepare-python.sh"
python3 "$project_root/scripts/generate-project.py"
xcodebuild -project "$project_root/TVWebDAV.xcodeproj" -scheme TVWebDAV -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$project_root/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
bash "$project_root/scripts/bundle-python.sh" "$project_root/build/DerivedData/Build/Products/Release-iphoneos/TVWebDAV.app" -iphoneos
python3 - "$project_root" <<'PY'
from pathlib import Path
import sys,zipfile,hashlib,plistlib,subprocess,shutil
root=Path(sys.argv[1]);app=root/'build/DerivedData/Build/Products/Release-iphoneos/TVWebDAV.app'
if not app.is_dir():raise SystemExit('未找到 iPhoneOS 应用，不能打包 IPA')
info=plistlib.loads((app/'Info.plist').read_bytes())
if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms',[]):raise SystemExit('拒绝将模拟器应用伪装成真机 IPA')
# 个人自签包只保留真机 arm64，去除第三方框架旧签名，交给自签工具统一签名。
for framework in (app/'Frameworks').glob('*.framework'):
 binary=framework/framework.stem
 architectures=subprocess.check_output(['lipo','-archs',str(binary)],text=True).split()
 if architectures != ['arm64']:
  if 'arm64' not in architectures:raise SystemExit('嵌入框架缺少真机 arm64')
  thin=binary.with_name(binary.name+'.arm64')
  subprocess.run(['lipo',str(binary),'-thin','arm64','-output',str(thin)],check=True)
  thin.replace(binary)
 subprocess.run(['codesign','--remove-signature',str(framework)],check=False,capture_output=True)
 signature=framework/'_CodeSignature'
 if signature.exists():shutil.rmtree(signature)
ipa=root/'build/TVWebDAV-0.1.0-unsigned.ipa'
with zipfile.ZipFile(ipa,'w',zipfile.ZIP_DEFLATED) as z:
 for f in app.rglob('*'):
  if f.is_file():z.write(f,Path('Payload')/app.name/f.relative_to(app))
(root/'build/SHA256.txt').write_text(hashlib.sha256(ipa.read_bytes()).hexdigest()+'  '+ipa.name+'\n')
print('未签名 IPA：',ipa)
print('请使用你自己的签名工具重新签名后安装。此文件没有开发团队或分发证书。')
PY
