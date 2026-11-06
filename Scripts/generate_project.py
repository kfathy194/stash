#!/usr/bin/env python3
"""Generate the five-target Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib, plistlib, json, os
from release_metadata import validate
ROOT = Path(__file__).resolve().parents[1]
release = validate(os.environ.get('STASH_RELEASE_VERSION', (ROOT/'Config/ReleaseVersion.txt').read_text().strip()), os.environ.get('STASH_BUILD_NUMBER', '2'), '0'*40)
def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def quote(value): return json.dumps(str(value))
objects = {}
def add(object_key, isa, **kw):
    key = uid(object_key); objects[key] = dict(isa=isa, **kw); return key
class Ref(str): pass
def ref(x): return Ref(x)
def serialize(v):
    if isinstance(v, Ref): return v
    if isinstance(v, dict): return '{ ' + ' '.join(str(k)+' = '+serialize(x)+';' for k,x in v.items())+' }'
    if isinstance(v, list): return '(' + ', '.join(serialize(x) for x in v) + (',' if v else '') + ')'
    if isinstance(v, int): return str(v)
    return quote(v)
products = []
# The core is also a standalone Swift package. A native static framework avoids
# Xcode manifest sandbox requirements in restricted build environments.
package = None
targets = []
macid = uid('target.StashMac'); helperid = uid('target.StashMCP')
specs = [('StashMac','Stash','com.kfathy.stash','macosx','com.apple.product-type.application','app'),('StashIOS','Stash iOS','com.kfathy.stash.ios','iphoneos','com.apple.product-type.application','app'),('StashShare','Stash Share','com.kfathy.stash.ios.share','iphoneos','com.apple.product-type.app-extension','appex'),('StashKeyboard','Stash Keyboard','com.kfathy.stash.ios.keyboard','iphoneos','com.apple.product-type.app-extension','appex'),('StashMCP','StashMCP','com.kfathy.stash.mcp','macosx','com.apple.product-type.tool',''),('StashCore','StashCore','com.kfathy.stash.core','auto','com.apple.product-type.framework','framework')]
groups = []
for folder, product, bundle, sdk, producttype, suffix in specs:
    sourceRefs = []; sourceBuild = []
    for path in sorted((ROOT/('StashCore/Sources/StashCore' if folder=='StashCore' else folder)).glob('*.swift')):
        f = add(str(path.relative_to(ROOT)), 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=path.name, sourceTree='<group>'); sourceRefs.append(ref(f))
        b = add('build.'+str(path.relative_to(ROOT)), 'PBXBuildFile', fileRef=ref(f)); sourceBuild.append(ref(b))
    if suffix == 'app':
        assets = add(folder+'.assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Assets.xcassets', sourceTree='<group>'); sourceRefs.append(ref(assets))
        assetBuild = add(folder+'.assets.build','PBXBuildFile',fileRef=ref(assets)); resources = [ref(assetBuild)]
    else: resources = []
    if folder=='StashMac':
        brand=add('brand.icns','PBXFileReference',lastKnownFileType='image.icns',path='Branding/Stash.icns',sourceTree='SOURCE_ROOT')
        brandbuild=add('brand.icns.build','PBXBuildFile',fileRef=ref(brand));resources.append(ref(brandbuild))
    group = add('group.'+folder, 'PBXGroup', children=sourceRefs, path='StashCore/Sources/StashCore' if folder=='StashCore' else folder, sourceTree='<group>'); groups.append(ref(group))
    productref = add('product.'+folder, 'PBXFileReference', explicitFileType='wrapper.application' if suffix=='app' else 'wrapper.app-extension' if suffix=='appex' else 'wrapper.framework' if suffix=='framework' else 'compiled.mach-o.executable', path=product + ('.'+suffix if suffix else ''), sourceTree='BUILT_PRODUCTS_DIR'); products.append(ref(productref))
    sources = add('sources.'+folder,'PBXSourcesBuildPhase',buildActionMask=2147483647,files=sourceBuild,runOnlyForDeploymentPostprocessing=0)
    frameworks = []
    deps = []
    if folder not in ('StashMCP','StashCore'):
        b=add('link.'+folder,'PBXBuildFile',fileRef=ref(uid('product.StashCore'))); frameworks.append(ref(b))
    fw=add('frameworks.'+folder,'PBXFrameworksBuildPhase',buildActionMask=2147483647,files=frameworks,runOnlyForDeploymentPostprocessing=0)
    res=add('resources.'+folder,'PBXResourcesBuildPhase',buildActionMask=2147483647,files=resources,runOnlyForDeploymentPostprocessing=0)
    phases=[ref(sources),ref(fw),ref(res)]; targetdeps=[]
    if folder not in ('StashMCP','StashCore'):
        proxy=add('coreproxy.'+folder,'PBXContainerItemProxy',containerPortal=ref(uid('project')),proxyType=1,remoteGlobalIDString=ref(uid('target.StashCore')),remoteInfo='StashCore')
        d=add('coredependency.'+folder,'PBXTargetDependency',target=ref(uid('target.StashCore')),targetProxy=ref(proxy));targetdeps.append(ref(d))
    if folder in ('StashMac','StashIOS'):
        embed=[]
        children=['StashMCP'] if folder=='StashMac' else ['StashShare','StashKeyboard']
        for child in children:
            proxy=add('proxy.'+child,'PBXContainerItemProxy',containerPortal=ref(uid('project')),proxyType=1,remoteGlobalIDString=ref(uid('target.'+child)),remoteInfo=child)
            d=add('dependency.'+child,'PBXTargetDependency',target=ref(uid('target.'+child)),targetProxy=ref(proxy)); targetdeps.append(ref(d))
            b=add('embedbuild.'+child,'PBXBuildFile',fileRef=ref(uid('product.'+child)),settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']}); embed.append(ref(b))
        phase=add('embed.'+folder,'PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='Contents/Helpers' if folder=='StashMac' else '',dstSubfolderSpec=1 if folder=='StashMac' else 13,files=embed,name='Embed Helper' if folder=='StashMac' else 'Embed Extensions',runOnlyForDeploymentPostprocessing=0); phases.append(ref(phase))
    configs=[]
    for mode in ('Debug','Release'):
        settings={'PRODUCT_NAME':product,'PRODUCT_BUNDLE_IDENTIFIER':bundle,'SDKROOT':sdk,'SWIFT_VERSION':'6.0','SWIFT_STRICT_CONCURRENCY':'complete','SWIFT_DEFAULT_ACTOR_ISOLATION':'nonisolated','INFOPLIST_FILE':'Config/'+folder+'-Info.plist','GENERATE_INFOPLIST_FILE':'NO','CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':str(release['build_number']),'MARKETING_VERSION':release['version'],'CLANG_ENABLE_MODULES':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','SWIFT_COMPILATION_MODE':'singlefile' if mode=='Debug' else 'wholemodule','ENABLE_USER_SCRIPT_SANDBOXING':'YES','MACOSX_DEPLOYMENT_TARGET':'14.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0','TARGETED_DEVICE_FAMILY':'1,2','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon' if suffix=='app' else '', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME':'AccentColor', 'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks' if sdk=='macosx' else '@executable_path/Frameworks','@executable_path/../../Frameworks']}
        if folder not in ('StashMCP','StashCore'):settings['CODE_SIGN_ENTITLEMENTS']='Config/'+folder+'.entitlements'
        if folder in ('StashShare','StashKeyboard'): settings.update({'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES'})
        if folder=='StashMCP':settings.update({'SKIP_INSTALL':'YES','ENABLE_HARDENED_RUNTIME':'YES','INFOPLIST_FILE':'','GENERATE_INFOPLIST_FILE':'YES'})
        elif folder=='StashCore':settings.update({'SDKROOT':'auto','SUPPORTED_PLATFORMS':'macosx iphoneos iphonesimulator','SKIP_INSTALL':'YES','MACH_O_TYPE':'staticlib','DEFINES_MODULE':'YES','GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_FILE':'','SWIFT_INCLUDE_PATHS':'$(SRCROOT)/StashCore/Sources/CSQLite','OTHER_LDFLAGS':'-lsqlite3','APPLICATION_EXTENSION_API_ONLY':'YES'})
        else: settings['ENABLE_HARDENED_RUNTIME']='YES'
        settings['SWIFT_INCLUDE_PATHS']='$(SRCROOT)/StashCore/Sources/CSQLite'
        if folder not in ('StashMCP','StashCore'):settings['OTHER_LDFLAGS']='$(inherited) -lsqlite3'
        c=add('config.'+folder+'.'+mode,'XCBuildConfiguration',buildSettings=settings,name=mode); configs.append(ref(c))
    configlist=add('configlist.'+folder,'XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
    t=add('target.'+folder,'PBXNativeTarget',buildConfigurationList=ref(configlist),buildPhases=phases,buildRules=[],dependencies=targetdeps,name=folder,packageProductDependencies=deps,productName=product,productReference=ref(productref),productType=producttype); targets.append(ref(t))
productGroup=add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
main=add('main','PBXGroup',children=groups+[ref(productGroup)],sourceTree='<group>')
configs=[]
for mode in ('Debug','Release'):
    configs.append(ref(add('projectconfig.'+mode,'XCBuildConfiguration',name=mode,buildSettings={'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'6.0','MACOSX_DEPLOYMENT_TARGET':'14.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0'})))
cl=add('projectconfiglist','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
project=add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2700'},buildConfigurationList=ref(cl),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=ref(main),productRefGroup=ref(productGroup),projectDirPath='',projectRoot='',packageReferences=[],targets=targets)
p=ROOT/'Stash.xcodeproj';p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':{Ref(k):v for k,v in objects.items()},'rootObject':ref(project)})+'\n')
schemes=p/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
for target,product,*_ in specs:
    filename=product+('.app' if target in ('StashMac','StashIOS') else '.appex' if target in ('StashShare','StashKeyboard') else '')
    buildref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target."+target)}" BuildableName="{filename}" BlueprintName="{target}" ReferencedContainer="container:Stash.xcodeproj"/>'
    (schemes/(target+'.xcscheme')).write_text(f'<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildref}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>')
print('Generated Stash.xcodeproj with app, extension, helper and shared-core targets.')
