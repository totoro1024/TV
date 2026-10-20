#!/usr/bin/env python3
"""生成只依赖本地 Swift Package 的 Xcode 工程，不需要安装第三方生成器。"""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
def ident(name):return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
objects=[]
def obj(name,body):
 i=ident(name);objects.append(f'{i} = {{ {body} }};');return i
refs=[];builds=[]
pyref=obj('python-ref','isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = "build/Vendor/PythonIOS/Python.xcframework"; sourceTree = "<group>";')
refs.append(pyref)
pybuild=obj('python-build',f'isa = PBXBuildFile; fileRef = {pyref};')
pycopy=obj('python-copy',f'isa = PBXBuildFile; fileRef = {pyref}; settings = {{ ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,); }};')
vlcref=obj('vlc-ref','isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = "build/Vendor/MobileVLCKit-binary/MobileVLCKit.xcframework"; sourceTree = "<group>";')
refs.append(vlcref)
vlcbuild=obj('vlc-build',f'isa = PBXBuildFile; fileRef = {vlcref};')
vlccopy=obj('vlc-copy',f'isa = PBXBuildFile; fileRef = {vlcref}; settings = {{ ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,); }};')
embed=obj('embed',f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = ({vlccopy},{pycopy},); name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0;')
for file in sorted(list((root/'App').glob('*.swift')) + list((root/'App').glob('*.c'))):
 ref=obj('ref-'+file.name,f'isa = PBXFileReference; lastKnownFileType = {"sourcecode.c.c" if file.suffix == ".c" else "sourcecode.swift"}; path = "App/{file.name}"; sourceTree = "<group>";')
 refs.append(ref);builds.append(obj('build-'+file.name,f'isa = PBXBuildFile; fileRef = {ref};'))
app=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = TVWebDAV.app; sourceTree = BUILT_PRODUCTS_DIR;')
productgroup=obj('products',f'isa = PBXGroup; children = ({app},); name = Products; sourceTree = "<group>";')
main=obj('main',f'isa = PBXGroup; children = ({",".join(refs)},{productgroup},); sourceTree = "<group>";')
package=obj('package','isa = XCLocalSwiftPackageReference; relativePath = .;')
lib=obj('lib',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = TVCore;')
libbuild=obj('lib-build',f'isa = PBXBuildFile; productRef = {lib};')
sources=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({libbuild},{vlcbuild},{pybuild},); runOnlyForDeploymentPostprocessing = 0;')
asset=obj('assets','isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = App/Assets.xcassets; sourceTree = "<group>";')
assetbuild=obj('assets-build',f'isa = PBXBuildFile; fileRef = {asset};')
licenseref=obj('vlc-license','isa = PBXFileReference; lastKnownFileType = text; path = "ThirdParty/MobileVLCKit/COPYING.txt"; sourceTree = "<group>";')
licensebuild=obj('vlc-license-build',f'isa = PBXBuildFile; fileRef = {licenseref};')
fflicenseref=obj('ffmpeg-license','isa = PBXFileReference; lastKnownFileType = text; path = "ThirdParty/FFmpegHeaders/COPYING.LGPLv2.1"; sourceTree = "<group>";')
fflicensebuild=obj('ffmpeg-license-build',f'isa = PBXBuildFile; fileRef = {fflicenseref};')
soupreference=obj('soup-license','isa = PBXFileReference; lastKnownFileType = text; path = "ThirdParty/SwiftSoup/LICENSES.txt"; sourceTree = "<group>";')
soupbuild=obj('soup-license-build',f'isa = PBXBuildFile; fileRef = {soupreference};')
resources=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({assetbuild},{licensebuild},{fflicensebuild},{soupbuild},); runOnlyForDeploymentPostprocessing = 0;')
projectconfigs=[];targetconfigs=[]
for config in ['Debug','Release']:
 projectconfigs.append(obj('project-'+config,f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; }};'))
 targetconfigs.append(obj('target-'+config,f'''isa = XCBuildConfiguration; name = {config}; buildSettings = {{
 ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
 PRODUCT_NAME = TVWebDAV; PRODUCT_BUNDLE_IDENTIFIER = com.totoro.tv.ios; INFOPLIST_FILE = App/Info.plist;
 SWIFT_OBJC_BRIDGING_HEADER = "App/TVWebDAV-Bridging-Header.h";
 HEADER_SEARCH_PATHS = "$(SRCROOT)/ThirdParty/FFmpegHeaders";
 GCC_C_LANGUAGE_STANDARD = gnu11;
 SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
 IPHONEOS_DEPLOYMENT_TARGET = 17.0; CURRENT_PROJECT_VERSION = 27; MARKETING_VERSION = 0.1.0;
 SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{'DEBUG' if config=='Debug' else ''}";
 "CODE_SIGN_IDENTITY[sdk=iphonesimulator*]" = "-";
 CODE_SIGN_STYLE = Automatic; ENABLE_USER_SCRIPT_SANDBOXING = YES;
 LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"; ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES;
 SWIFT_OPTIMIZATION_LEVEL = "{'-Onone' if config=='Debug' else '-O'}"; GENERATE_INFOPLIST_FILE = NO;
 }};'''))
pconfigs=obj('pconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(projectconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
tconfigs=obj('tconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(targetconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target',f'''isa = PBXNativeTarget; buildConfigurationList = {tconfigs}; buildPhases = ({sources},{frameworks},{resources},{embed},);
 buildRules = (); dependencies = (); name = TVWebDAV; packageProductDependencies = ({lib},); productName = TVWebDAV; productReference = {app}; productType = "com.apple.product-type.application";''')
project=obj('project',f'''isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {pconfigs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0;
 knownRegions = (zh_CN, en, Base,); mainGroup = {main}; productRefGroup = {productgroup}; packageReferences = ({package},); projectDirPath = ""; projectRoot = ""; targets = ({target},);''')
folder=root/'TVWebDAV.xcodeproj';folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
schemes=folder/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'TVWebDAV.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TVWebDAV.app" BlueprintName="TVWebDAV" ReferencedContainer="container:TVWebDAV.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug"/><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TVWebDAV.app" BlueprintName="TVWebDAV" ReferencedContainer="container:TVWebDAV.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>
''')
print(folder)
