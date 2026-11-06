#!/usr/bin/env python3
from pathlib import Path
import plistlib
ROOT=Path(__file__).resolve().parents[1]
for target in ['StashMac','StashIOS','StashShare','StashKeyboard']:
    ios=target!='StashMac'; ext=target in ['StashShare','StashKeyboard']
    info={'CFBundleName':'$(PRODUCT_NAME)','CFBundleDisplayName':'Stash','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundlePackageType':'XPC!' if ext else 'APPL','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','CKSharingSupported':True,'StashCommerceEnabled':False}
    if target=='StashMac':info.update({'CFBundleName':'Stash','CFBundleIconFile':'Stash.icns','CFBundleIconName':'AppIcon','LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSPrincipalClass':'NSApplication','NSAccessibilityUsageDescription':'Stash pastes your selected clipboard item into the app you were using.','NSScreenCaptureUsageDescription':'Stash reads your active window only when you request on-device Suggestions.','NSAppleEventsUsageDescription':'Stash uses native app integration for clipboard actions.'})
    if ios:info.update({'LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'NSPhotoLibraryUsageDescription':'Save and share images from your clipboard library.'})
    if target=='StashIOS':info['UIApplicationSceneManifest']={'UIApplicationSupportsMultipleScenes':True}
    if target=='StashShare':info['NSExtension']={'NSExtensionPointIdentifier':'com.apple.share-services','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).ShareViewController','NSExtensionAttributes':{'NSExtensionActivationRule':{'NSExtensionActivationSupportsText':True,'NSExtensionActivationSupportsWebURLWithMaxCount':10,'NSExtensionActivationSupportsImageWithMaxCount':10,'NSExtensionActivationSupportsFileWithMaxCount':10}}}
    if target=='StashKeyboard':info['NSExtension']={'NSExtensionPointIdentifier':'com.apple.keyboard-service','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).KeyboardViewController','NSExtensionAttributes':{'IsASCIICapable':False,'PrimaryLanguage':'en-US','RequestsOpenAccess':True}}
    (ROOT/'Config'/f'{target}-Info.plist').write_bytes(plistlib.dumps(info))
    ent={'com.apple.security.application-groups':['group.com.kfathy.stash']}
    if target in ['StashMac','StashIOS']:ent.update({'com.apple.developer.icloud-container-identifiers':['iCloud.com.kfathy.stash'],'com.apple.developer.icloud-services':['CloudKit'],'com.apple.developer.ubiquity-kvstore-identifier':'$(TeamIdentifierPrefix)com.kfathy.stash'})
    if target=='StashIOS':ent['aps-environment']='development';info['UIBackgroundModes']=['remote-notification'];(ROOT/'Config'/f'{target}-Info.plist').write_bytes(plistlib.dumps(info))
    # Direct-distribution Mac needs accessibility event injection and is intentionally not sandboxed.
    if target=='StashMac':ent.update({'com.apple.security.network.client':True,'com.apple.security.network.server':True,'com.apple.security.files.user-selected.read-write':True})
    (ROOT/'Config'/f'{target}.entitlements').write_bytes(plistlib.dumps(ent))
print('Generated Info.plists and entitlements.')
