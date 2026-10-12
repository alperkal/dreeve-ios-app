from pathlib import Path
import hashlib
r=Path(__file__).parent
src=r/'DreeveIOS'
files=sorted(p.name for p in src.glob('*.swift'))
assert len(files)>=10

def uuid(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

objects=[]
def add(key, text):
    objects.append(f'\t\t{uuid(key)} /* {key} */ = {{ {text} }};')

def ids(names,prefix):
    return '\n'.join(f'\t\t\t\t{uuid(prefix+n)} /* {n} */,' for n in names)

for f in files:
    add('file_'+f, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>";')
    add('build_'+f, f'isa = PBXBuildFile; fileRef = {uuid("file_"+f)} /* {f} */;')
add('file_Assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
add('build_Assets', f'isa = PBXBuildFile; fileRef = {uuid("file_Assets")} /* Assets.xcassets */;')
add('file_Product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = DreeveIOS.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('group_src', f'isa = PBXGroup; children = (\n{ids(files,"file_")}\n\t\t\t\t{uuid("file_Assets")} /* Assets.xcassets */,\n\t\t\t); path = DreeveIOS; sourceTree = "<group>";')
add('group_products', f'isa = PBXGroup; children = ( {uuid("file_Product")} /* DreeveIOS.app */, ); name = Products; sourceTree = "<group>";')
add('group_root', f'isa = PBXGroup; children = ( {uuid("group_src")} /* DreeveIOS */, {uuid("group_products")} /* Products */, ); sourceTree = "<group>";')
add('phase_sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\n{ids(files,"build_")}\n\t\t\t); runOnlyForDeploymentPostprocessing = 0;')
add('phase_resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ( {uuid("build_Assets")} /* Assets.xcassets in Resources */, ); runOnlyForDeploymentPostprocessing = 0;')
add('phase_frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0;')

build_configs={}
for kind in ('project','target'):
    for mode in ('Debug','Release'):
        key=f'config_{kind}_{mode}'
        if kind=='project':
            settings={
                'ALWAYS_SEARCH_USER_PATHS':'NO',
                'CLANG_ENABLE_MODULES':'YES',
                'CODE_SIGN_STYLE':'Automatic',
                'IPHONEOS_DEPLOYMENT_TARGET':'17.0',
                'SDKROOT':'iphoneos',
                'SWIFT_VERSION':'5.0',
                'SWIFT_OPTIMIZATION_LEVEL':'"-Onone"' if mode=='Debug' else '"-O"',
                'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else '"dwarf-with-dsym"',
                'ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO',
                'GCC_OPTIMIZATION_LEVEL':'0' if mode=='Debug' else 's',
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else '""',
                'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS':'YES',
            }
        else:
            settings={
                'CODE_SIGN_STYLE':'Automatic',
                'GENERATE_INFOPLIST_FILE':'YES',
                'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES',
                'INFOPLIST_KEY_UILaunchScreen_Generation':'YES',
                'IPHONEOS_DEPLOYMENT_TARGET':'17.0',
                'MARKETING_VERSION':'1.0',
                'CURRENT_PROJECT_VERSION':'1',
                'PRODUCT_BUNDLE_IDENTIFIER':'app.dreeve.ios.starter',
                'PRODUCT_NAME':'"$(TARGET_NAME)"',
                'SUPPORTED_PLATFORMS':'"iphoneos iphonesimulator"',
                'SWIFT_EMIT_LOC_STRINGS':'YES',
                'TARGETED_DEVICE_FAMILY':'1',
            }
        kset=' '.join(f'{k} = {v};' for k,v in settings.items())
        add(key, f'isa = XCBuildConfiguration; buildSettings = {{ {kset} }}; name = {mode};')
    add('configs_'+kind, f'isa = XCConfigurationList; buildConfigurations = ( {uuid("config_"+kind+"_Debug")} /* Debug */, {uuid("config_"+kind+"_Release")} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target', f'isa = PBXNativeTarget; buildConfigurationList = {uuid("configs_target")} /* Build configuration list for PBXNativeTarget "DreeveIOS" */; buildPhases = ( {uuid("phase_sources")} /* Sources */, {uuid("phase_frameworks")} /* Frameworks */, {uuid("phase_resources")} /* Resources */, ); buildRules = ( ); dependencies = ( ); name = DreeveIOS; productName = DreeveIOS; productReference = {uuid("file_Product")} /* DreeveIOS.app */; productType = "com.apple.product-type.application";')
add('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {uuid("target")} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {uuid("configs_project")} /* Build configuration list for PBXProject "DreeveIOS" */; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = ( en, Base ); mainGroup = {uuid("group_root")}; productRefGroup = {uuid("group_products")} /* Products */; projectDirPath = ""; projectRoot = ""; targets = ( {uuid("target")} /* DreeveIOS */, );')
pbx='''// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n'''+ '\n'.join(objects)+f'''\n\t}};\n\trootObject = {uuid('project')} /* Project object */;\n}}\n'''
(r/'DreeveIOS.xcodeproj'/'project.pbxproj').write_text(pbx)
print('Swift files:',len(files),'Project chars:',len(pbx))
