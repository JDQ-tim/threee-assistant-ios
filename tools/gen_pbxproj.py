#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成兼容性最强的 project.pbxproj（objectVersion 56 / Xcode 14+ 可读）。
不使用 PBXFileSystemSynchronizedRootGroup（Xcode16 新特性），
改为显式 PBXFileReference + PBXBuildFile，任何 Xcode 都能打开。
"""
import os
import hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_ROOT = "ThreeeAssistant"

# ---------- 收集文件 ----------
swift_files = []
for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, SRC_ROOT)):
    dirnames.sort()
    for fn in sorted(filenames):
        if fn.endswith(".swift"):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT).replace("\\", "/")
            swift_files.append(rel)
swift_files.sort()

# ---------- 稳定 ID 生成 ----------
_used = {}
_counter = [0]


def oid(*key):
    """生成 Xcode 对象 ID。

    ⚠️ 不要用哈希！之前用 md5 前 24 位，`appgroup` 和父组的键撞了同一个 ID，
       而 Xcode 遇到两个对象同 ID 时**不会报错**，只会让路径解析错乱，
       表现为「Assets.xcassets: No such file or directory」这种极难排查的症状。
       这里改成「自增序号 + 哈希前缀」，序号保证绝对唯一，可读性也更好。
    """
    raw = "|".join(key)
    if raw in _used:
        return _used[raw]["id"]
    _counter[0] += 1
    # 前 8 位取哈希（便于人眼辨认来源），后 16 位是自增序号（保证唯一）
    prefix = hashlib.md5(raw.encode("utf-8")).hexdigest().upper()[:8]
    cand = "%s%016X" % (prefix, _counter[0])
    _used[raw] = {"id": cand}
    return cand

PROJECT = oid("project")
MAIN_GROUP = oid("maingroup")
PRODUCTS_GROUP = oid("productsgroup")
# ⚠️ 必须和 APP_GROUP 分开！曾经这两个共用一个变量，
#    导致「ThreeeAssistant」父组和「App」子组拿到同一个对象 ID，
#    Xcode 不报错，但路径解析全乱（Assets.xcassets 找不到）。
ROOT_SRC_GROUP = oid("rootsrcgroup")
APP_GROUP = oid("appgroup")
CORE_GROUP = oid("coregroup")
DESIGN_GROUP = oid("designgroup")
FEATURES_GROUP = oid("featuresgroup")
LOGIN_GROUP = oid("logingroup")
SCHEDULE_GROUP = oid("schedulegroup")
SETTINGS_GROUP = oid("settingsgroup")
RESOURCES_GROUP = oid("resourcesgroup")
CONFIG_GROUP = oid("configgroup")

TARGET = oid("target")
PRODUCT_REF = oid("productref")
SOURCES_PHASE = oid("sourcesphase")
FRAMEWORKS_PHASE = oid("frameworksphase")
RESOURCES_PHASE = oid("resourcesphase")

PROJ_CONFIG_LIST = oid("projconfiglist")
TARGET_CONFIG_LIST = oid("targetconfiglist")
PROJ_DEBUG = oid("projdebug")
PROJ_RELEASE = oid("projrelease")
TGT_DEBUG = oid("tgtdebug")
TGT_RELEASE = oid("tgtrelease")

INFO_PLIST_REF = oid("fileref", "Config/Info.plist")
ASSETS_REF = oid("fileref", "ThreeeAssistant/Resources/Assets.xcassets")

# ---------- 目录 -> group 映射 ----------
GROUP_MAP = {
    "App": APP_GROUP,
    "Core": CORE_GROUP,
    "Design": DESIGN_GROUP,
    "Features": FEATURES_GROUP,
    "Features/Login": LOGIN_GROUP,
    "Features/Schedule": SCHEDULE_GROUP,
    "Features/Settings": SETTINGS_GROUP,
    "Resources": RESOURCES_GROUP,
}

group_children = {g: [] for g in GROUP_MAP.values()}
group_children[FEATURES_GROUP] = [LOGIN_GROUP, SCHEDULE_GROUP, SETTINGS_GROUP]

file_refs = []      # (id, name, relpath)
build_files = []    # (buildfile_id, fileref_id, name)

for rel in swift_files:
    name = os.path.basename(rel)
    rel_dir = os.path.dirname(rel)[len(SRC_ROOT) + 1:]  # 去掉 "ThreeeAssistant/"
    ref_id = oid("fileref", rel)
    bf_id = oid("buildfile", rel)
    file_refs.append((ref_id, name, rel))
    build_files.append((bf_id, ref_id, name))
    if rel_dir in GROUP_MAP:
        group_children[GROUP_MAP[rel_dir]].append(ref_id)
    else:
        raise RuntimeError("未映射的目录: " + rel_dir)

# ---------- 文本拼装 ----------
L = []
w = L.append

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")
w("")

w("/* Begin PBXBuildFile section */")
for bf_id, ref_id, name in build_files:
    w("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };" % (bf_id, name, ref_id, name))
w("\t\t%s /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = %s /* Assets.xcassets */; };" % (oid("buildfile", "assets"), ASSETS_REF))
w("/* End PBXBuildFile section */")
w("")

w("/* Begin PBXFileReference section */")
w("\t\t%s /* ThreeeAssistant.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ThreeeAssistant.app; sourceTree = BUILT_PRODUCTS_DIR; };" % PRODUCT_REF)
for ref_id, name, rel in file_refs:
    w("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = \"<group>\"; };" % (ref_id, name, name))
w("\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };" % INFO_PLIST_REF)
w("\t\t%s /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = ThreeeAssistant/Resources/Assets.xcassets; sourceTree = SOURCE_ROOT; };" % ASSETS_REF)
w("/* End PBXFileReference section */")
w("")

w("/* Begin PBXFrameworksBuildPhase section */")
w("\t\t%s /* Frameworks */ = {" % FRAMEWORKS_PHASE)
w("\t\t\tisa = PBXFrameworksBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXFrameworksBuildPhase section */")
w("")

w("/* Begin PBXGroup section */")
w("\t\t%s = {" % MAIN_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* ThreeeAssistant */," % ROOT_SRC_GROUP)
w("\t\t\t\t%s /* Config */," % CONFIG_GROUP)
w("\t\t\t\t%s /* Products */," % PRODUCTS_GROUP)
w("\t\t\t);")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* ThreeeAssistant */ = {" % ROOT_SRC_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for g in (APP_GROUP, CORE_GROUP, DESIGN_GROUP, FEATURES_GROUP, RESOURCES_GROUP):
    label = {APP_GROUP: "App", CORE_GROUP: "Core", DESIGN_GROUP: "Design",
             FEATURES_GROUP: "Features", RESOURCES_GROUP: "Resources"}[g]
    w("\t\t\t\t%s /* %s */," % (g, label))
w("\t\t\t);")
w("\t\t\tpath = ThreeeAssistant;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

for g, label in ((APP_GROUP, "App"), (CORE_GROUP, "Core"), (DESIGN_GROUP, "Design"),
                 (LOGIN_GROUP, "Login"), (SCHEDULE_GROUP, "Schedule"), (SETTINGS_GROUP, "Settings")):
    w("\t\t%s /* %s */ = {" % (g, label))
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for child in group_children[g]:
        # 找到名字
        nm = next((n for i, n, r in file_refs if i == child), None)
        w("\t\t\t\t%s /* %s */," % (child, nm))
    w("\t\t\t);")
    w("\t\t\tpath = %s;" % label)
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

w("\t\t%s /* Features */ = {" % FEATURES_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* Login */," % LOGIN_GROUP)
w("\t\t\t\t%s /* Schedule */," % SCHEDULE_GROUP)
w("\t\t\t\t%s /* Settings */," % SETTINGS_GROUP)
w("\t\t\t);")
w("\t\t\tpath = Features;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Resources */ = {" % RESOURCES_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* Assets.xcassets */," % ASSETS_REF)
w("\t\t\t);")
w("\t\t\tpath = Resources;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Config */ = {" % CONFIG_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* Info.plist */," % INFO_PLIST_REF)
w("\t\t\t);")
w("\t\t\tpath = Config;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Products */ = {" % PRODUCTS_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* ThreeeAssistant.app */," % PRODUCT_REF)
w("\t\t\t);")
w("\t\t\tname = Products;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")
w("/* End PBXGroup section */")
w("")

w("/* Begin PBXNativeTarget section */")
w("\t\t%s /* ThreeeAssistant */ = {" % TARGET)
w("\t\t\tisa = PBXNativeTarget;")
w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"ThreeeAssistant\" */;" % TARGET_CONFIG_LIST)
w("\t\t\tbuildPhases = (")
w("\t\t\t\t%s /* Sources */," % SOURCES_PHASE)
w("\t\t\t\t%s /* Frameworks */," % FRAMEWORKS_PHASE)
w("\t\t\t\t%s /* Resources */," % RESOURCES_PHASE)
w("\t\t\t);")
w("\t\t\tbuildRules = (")
w("\t\t\t);")
w("\t\t\tdependencies = (")
w("\t\t\t);")
w("\t\t\tname = ThreeeAssistant;")
w("\t\t\tproductName = ThreeeAssistant;")
w("\t\t\tproductReference = %s /* ThreeeAssistant.app */;" % PRODUCT_REF)
w("\t\t\tproductType = \"com.apple.product-type.application\";")
w("\t\t};")
w("/* End PBXNativeTarget section */")
w("")

w("/* Begin PBXProject section */")
w("\t\t%s /* Project object */ = {" % PROJECT)
w("\t\t\tisa = PBXProject;")
w("\t\t\tattributes = {")
w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
w("\t\t\t\tLastSwiftUpdateCheck = 1500;")
w("\t\t\t\tLastUpgradeCheck = 1500;")
w("\t\t\t\tTargetAttributes = {")
w("\t\t\t\t\t%s = {" % TARGET)
w("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
w("\t\t\t\t\t};")
w("\t\t\t\t};")
w("\t\t\t};")
w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"ThreeeAssistant\" */;" % PROJ_CONFIG_LIST)
w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
w("\t\t\tdevelopmentRegion = \"zh-Hans\";")
w("\t\t\thasScannedForEncodings = 0;")
w("\t\t\tknownRegions = (")
w("\t\t\t\ten,")
w("\t\t\t\tBase,")
w("\t\t\t\t\"zh-Hans\",")
w("\t\t\t);")
w("\t\t\tmainGroup = %s;" % MAIN_GROUP)
w("\t\t\tproductRefGroup = %s /* Products */;" % PRODUCTS_GROUP)
w("\t\t\tprojectDirPath = \"\";")
w("\t\t\tprojectRoot = \"\";")
w("\t\t\ttargets = (")
w("\t\t\t\t%s /* ThreeeAssistant */," % TARGET)
w("\t\t\t);")
w("\t\t};")
w("/* End PBXProject section */")
w("")

w("/* Begin PBXResourcesBuildPhase section */")
w("\t\t%s /* Resources */ = {" % RESOURCES_PHASE)
w("\t\t\tisa = PBXResourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
w("\t\t\t\t%s /* Assets.xcassets in Resources */," % oid("buildfile", "assets"))
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXResourcesBuildPhase section */")
w("")

w("/* Begin PBXSourcesBuildPhase section */")
w("\t\t%s /* Sources */ = {" % SOURCES_PHASE)
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for bf_id, ref_id, name in build_files:
    w("\t\t\t\t%s /* %s in Sources */," % (bf_id, name))
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXSourcesBuildPhase section */")
w("")

w("/* Begin XCBuildConfiguration section */")
w("\t\t%s /* Debug */ = {" % PROJ_DEBUG)
w("\t\t\tisa = XCBuildConfiguration;")
w("\t\t\tbuildSettings = {")
w("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
w("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
w("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
w("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
w("\t\t\t\tCOPY_PHASE_STRIP = NO;")
w("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
w("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
w("\t\t\t\tENABLE_TESTABILITY = YES;")
w("\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;")
w("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
w("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
w("\t\t\t\t\t\"DEBUG=1\",")
w("\t\t\t\t\t\"$(inherited)\",")
w("\t\t\t\t);")
w("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;")
w("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
w("\t\t\t\tMTL_FAST_MATH = YES;")
w("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
w("\t\t\t\tSDKROOT = iphoneos;")
w("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
w("\t\t\t};")
w("\t\t\tname = Debug;")
w("\t\t};")

w("\t\t%s /* Release */ = {" % PROJ_RELEASE)
w("\t\t\tisa = XCBuildConfiguration;")
w("\t\t\tbuildSettings = {")
w("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
w("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
w("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
w("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
w("\t\t\t\tCOPY_PHASE_STRIP = NO;")
w("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
w("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
w("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
w("\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;")
w("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;")
w("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
w("\t\t\t\tMTL_FAST_MATH = YES;")
w("\t\t\t\tSDKROOT = iphoneos;")
w("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
w("\t\t\t\tVALIDATE_PRODUCT = YES;")
w("\t\t\t};")
w("\t\t\tname = Release;")
w("\t\t};")

for cfg_id, cfg_name in ((TGT_DEBUG, "Debug"), (TGT_RELEASE, "Release")):
    w("\t\t%s /* %s */ = {" % (cfg_id, cfg_name))
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    w("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
    w("\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;")
    w("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
    w("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
    w("\t\t\t\tENABLE_PREVIEWS = YES;")
    w("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
    w("\t\t\t\tINFOPLIST_FILE = Config/Info.plist;")
    w("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;")
    w("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
    w("\t\t\t\t\t\"$(inherited)\",")
    w("\t\t\t\t\t\"@executable_path/Frameworks\",")
    w("\t\t\t\t);")
    w("\t\t\t\tMARKETING_VERSION = 0.1;")
    w("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = cn.threees.assistant.ios;")
    w("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
    w("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
    w("\t\t\t\tSWIFT_VERSION = 5.0;")
    w("\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
    w("\t\t\t};")
    w("\t\t\tname = %s;" % cfg_name)
    w("\t\t};")
w("/* End XCBuildConfiguration section */")
w("")

w("/* Begin XCConfigurationList section */")
w("\t\t%s /* Build configuration list for PBXProject \"ThreeeAssistant\" */ = {" % PROJ_CONFIG_LIST)
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w("\t\t\t\t%s /* Debug */," % PROJ_DEBUG)
w("\t\t\t\t%s /* Release */," % PROJ_RELEASE)
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")
w("\t\t%s /* Build configuration list for PBXNativeTarget \"ThreeeAssistant\" */ = {" % TARGET_CONFIG_LIST)
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w("\t\t\t\t%s /* Debug */," % TGT_DEBUG)
w("\t\t\t\t%s /* Release */," % TGT_RELEASE)
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")
w("/* End XCConfigurationList section */")
w("\t};")
w("\trootObject = %s /* Project object */;" % PROJECT)
w("}")

out_path = os.path.join(ROOT, "ThreeeAssistant.xcodeproj", "project.pbxproj")
with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(L) + "\n")

# ---- 自动同步 scheme 里的 target ID ----
# ⚠️ scheme 的 BlueprintIdentifier 是硬编码的 target 对象 ID。
#    每次重生成 pbxproj，这个 ID 都可能变，不同步的话 GitHub Actions 上
#    `xcodebuild -scheme` 会找不到 target —— 而报错信息完全不指向这里。
scheme_path = os.path.join(
    ROOT, "ThreeeAssistant.xcodeproj", "xcshareddata", "xcschemes", "ThreeeAssistant.xcscheme"
)
if os.path.exists(scheme_path):
    import re as _re
    sc = open(scheme_path, encoding="utf-8").read()
    new_sc, n_sub = _re.subn(
        r'(BlueprintIdentifier = ")[0-9A-F]{24}(")',
        lambda m: m.group(1) + TARGET + m.group(2),
        sc,
    )
    if n_sub:
        open(scheme_path, "w", encoding="utf-8", newline="\n").write(new_sc)
    print("scheme synced: %d 处 BlueprintIdentifier -> %s" % (n_sub, TARGET))

print("OK -> %s" % out_path)
print("swift files: %d" % len(swift_files))
print("total objects: %d" % (len(_used)))
