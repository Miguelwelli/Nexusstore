#!/usr/bin/env python3
"""Generate NexusStore.xcodeproj/project.pbxproj.

The pbxproj format is verbose and easy to corrupt by hand, so this script owns it: every source file
under NexusStore/ is discovered from the filesystem and referenced with stable, deterministic IDs.
Re-run `python3 Tools/generate_xcodeproj.py` after adding files. CI verifies the committed project is
in sync with the sources.

The core/ folder is compiled directly into the app target (each Swift file carries its own imports),
so the project has **no external dependencies** and builds on a clean Xcode without resolving anything.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "NexusStore"
BUNDLE_ID = "com.nexusstore.app"
DEPLOYMENT_TARGET = "16.0"

PROJECT_SETTINGS = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
"""

TARGET_SETTINGS = """\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = NexusStore/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Nexus Store";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.nexusstore.app;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_INSTALL_OBJC_HEADER = NO;
\t\t\t\tSWIFT_STRICT_CONCURRENCY = minimal;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSUPPORTS_MACCATALYST = NO;
"""

CONFIG_VARIANTS = {
    "Debug": """\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
""",
    "Release": """\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
""",
}

SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "__TARGET__" BuildableName = "NexusStore.app" BlueprintName = "NexusStore" ReferencedContainer = "container:NexusStore.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "__TARGET__" BuildableName = "NexusStore.app" BlueprintName = "NexusStore" ReferencedContainer = "container:NexusStore.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsForBuild = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "__TARGET__" BuildableName = "NexusStore.app" BlueprintName = "NexusStore" ReferencedContainer = "container:NexusStore.xcodeproj"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def uid(*parts: str) -> str:
    return hashlib.sha1("::".join(parts).encode("utf-8")).hexdigest().upper()[:24]


class Node:
    """A folder or a leaf file in the group tree."""

    def __init__(self, path: Path, is_dir: bool):
        self.path = path
        self.is_dir = is_dir
        self.children: list[Node] = []

    @property
    def rel(self) -> str:
        return self.path.relative_to(ROOT).as_posix()

    @property
    def name(self) -> str:
        return self.path.name

    def key(self) -> str:
        return uid("group", self.rel) if self.is_dir else uid("file", self.rel)


def build_tree() -> tuple[Node, list[Node], list[Node]]:
    """Returns (root group, swift files, resource files)."""
    root = Node(ROOT / "NexusStore", True)
    nodes: dict[Path, Node] = {root.path: root}
    swift: list[Node] = []
    resources: list[Node] = []
    skip_dirs = {".git", "__pycache__"}

    for path in sorted((ROOT / "NexusStore").rglob("*")):
        if any(part in skip_dirs for part in path.parts):
            continue
        if path.is_dir():
            if path.suffix == ".xcassets":
                # Asset catalogs are leaves: add below and do not descend.
                parent = nodes.get(path.parent)
                if parent is None:
                    continue
                node = Node(path, False)
                parent.children.append(node)
                resources.append(node)
                continue
            nodes[path] = Node(path, True)
        else:
            parent = nodes.get(path.parent)
            if parent is None:
                continue
            node = Node(path, False)
            parent.children.append(node)
            if path.suffix == ".swift":
                swift.append(node)
            elif path.suffix == ".json":
                resources.append(node)

    # Attach child folders to their parents (dict order is shallow-first).
    for path, node in sorted(nodes.items(), key=lambda item: len(item[0].parts)):
        if node is root:
            continue
        parent = nodes.get(path.parent)
        if parent is not None:
            parent.children.append(node)

    # Sort children: folders first, then files, alphabetically.
    def sort(node: Node) -> None:
        node.children.sort(key=lambda child: (not child.is_dir, child.name.lower()))
        for child in node.children:
            if child.is_dir:
                sort(child)

    sort(root)
    return root, swift, resources


def main() -> int:
    root, swift_files, resource_files = build_tree()
    out: list[str] = []
    add = out.append

    add("// !$*UTF8*$!\n")
    add("// Generated by Tools/generate_xcodeproj.py. Run the script after adding/removing files.\n")
    add("{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")

    # ---- PBXBuildFile
    add("\n/* Begin PBXBuildFile section */\n")
    for node in swift_files:
        add(f"\t\t{uid('build', node.rel)} /* {node.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {node.key()} /* {node.name} */; }};\n")
    for node in resource_files:
        add(f"\t\t{uid('build', node.rel)} /* {node.name} in Resources */ = {{isa = PBXBuildFile; fileRef = {node.key()} /* {node.name} */; }};\n")
    add("/* End PBXBuildFile section */\n")

    # ---- PBXFileReference
    add("\n/* Begin PBXFileReference section */\n")
    add(f"\t\t{uid('product')} /* {APP_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
    for node in swift_files:
        add(f"\t\t{node.key()} /* {node.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {node.rel}; sourceTree = SOURCE_ROOT; }};\n")
    for node in resource_files:
        kind = "folder.assetcatalog" if node.path.suffix == ".xcassets" else "text.json"
        add(f"\t\t{node.key()} /* {node.name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {node.rel}; sourceTree = SOURCE_ROOT; }};\n")
    add(f"\t\t{uid('file', 'NexusStore/Info.plist')} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = NexusStore/Info.plist; sourceTree = SOURCE_ROOT; }};\n")
    add("/* End PBXFileReference section */\n")

    # ---- PBXGroup
    add("\n/* Begin PBXGroup section */\n")
    add(f"\t\t{uid('group', 'main')} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{root.key()} /* {root.name} */,\n\t\t\t\t{uid('group', 'Products')} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
    add(f"\t\t{uid('group', 'Products')} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{uid('product')} /* {APP_NAME}.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")

    def emit_group(node: Node) -> None:
        add(f"\t\t{node.key()} /* {node.name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n")
        for child in node.children:
            add(f"\t\t\t\t{child.key()} /* {child.name} */,\n")
        add("\t\t\t);\n")
        if node.path.parent == ROOT:
            add(f"\t\t\tpath = {node.name};\n")
        else:
            add(f"\t\t\tpath = {node.name};\n")
        add("\t\t\tsourceTree = \"<group>\";\n\t\t};\n")
        for child in node.children:
            if child.is_dir:
                emit_group(child)

    emit_group(root)
    add("/* End PBXGroup section */\n")

    # ---- PBXNativeTarget
    add("\n/* Begin PBXNativeTarget section */\n")
    add(f"\t\t{uid('target')} /* {APP_NAME} */ = {{\n\t\t\tisa = PBXNativeTarget;\n")
    add(f"\t\t\tbuildConfigurationList = {uid('configList', 'target')} /* Build configuration list for PBXNativeTarget \"{APP_NAME}\" */;\n")
    add(f"\t\t\tbuildPhases = (\n\t\t\t\t{uid('phase', 'sources')} /* Sources */,\n\t\t\t\t{uid('phase', 'frameworks')} /* Frameworks */,\n\t\t\t\t{uid('phase', 'resources')} /* Resources */,\n\t\t\t);\n")
    add(f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {APP_NAME};\n\t\t\tproductName = {APP_NAME};\n")
    add(f"\t\t\tproductReference = {uid('product')} /* {APP_NAME}.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};\n")
    add("/* End PBXNativeTarget section */\n")

    # ---- PBXProject
    add("\n/* Begin PBXProject section */\n")
    add(f"\t\t{uid('project')} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1500;\n\t\t\t\tLastUpgradeCheck = 1500;\n")
    add(f"\t\t\t\tTargetAttributes = {{\n\t\t\t\t\t{uid('target')} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\t}};\n\t\t\t\t}};\n\t\t\t}};\n")
    add(f"\t\t\tbuildConfigurationList = {uid('configList', 'project')} /* Build configuration list for PBXProject \"{APP_NAME}\" */;\n")
    add("\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = \"pt-BR\";\n\t\t\thasScannedForEncodings = 0;\n")
    add("\t\t\tknownRegions = (\n\t\t\t\t\"pt-BR\",\n\t\t\t\tBase,\n\t\t\t\ten,\n\t\t\t);\n")
    add(f"\t\t\tmainGroup = {uid('group', 'main')};\n\t\t\tproductRefGroup = {uid('group', 'Products')};\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n")
    add(f"\t\t\ttargets = (\n\t\t\t\t{uid('target')} /* {APP_NAME} */,\n\t\t\t);\n\t\t}};\n")
    add("/* End PBXProject section */\n")

    # ---- Build phases
    add("\n/* Begin PBXResourcesBuildPhase section */\n")
    add(f"\t\t{uid('phase', 'resources')} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n")
    for node in resource_files:
        add(f"\t\t\t\t{uid('build', node.rel)} /* {node.name} in Resources */,\n")
    add("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
    add("/* End PBXResourcesBuildPhase section */\n")

    add("\n/* Begin PBXSourcesBuildPhase section */\n")
    add(f"\t\t{uid('phase', 'sources')} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n")
    for node in swift_files:
        add(f"\t\t\t\t{uid('build', node.rel)} /* {node.name} in Sources */,\n")
    add("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
    add("/* End PBXSourcesBuildPhase section */\n")

    add("\n/* Begin PBXFrameworksBuildPhase section */\n")
    add(f"\t\t{uid('phase', 'frameworks')} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    add("/* End PBXFrameworksBuildPhase section */\n")

    # ---- Build configurations
    add("\n/* Begin XCBuildConfiguration section */\n")
    for name in ("Debug", "Release"):
        add(f"\t\t{uid('buildConfig', 'project', name)} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n")
        add(PROJECT_SETTINGS)
        add(f"\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")
        add(f"\t\t{uid('buildConfig', 'target', name)} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n")
        add(TARGET_SETTINGS)
        add(CONFIG_VARIANTS[name])
        add(f"\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")
    add("/* End XCBuildConfiguration section */\n")

    add("\n/* Begin XCConfigurationList section */\n")
    for scope, label in (("project", f'Build configuration list for PBXProject "{APP_NAME}"'),
                         ("target", f'Build configuration list for PBXNativeTarget "{APP_NAME}"')):
        add(f"\t\t{uid('configList', scope)} /* {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n")
        add(f"\t\t\t\t{uid('buildConfig', scope, 'Debug')} /* Debug */,\n\t\t\t\t{uid('buildConfig', scope, 'Release')} /* Release */,\n")
        add("\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n")
    add("/* End XCConfigurationList section */\n")

    add(f"\t}};\n\trootObject = {uid('project')} /* Project object */;\n}}\n")

    project_dir = ROOT / f"{APP_NAME}.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text("".join(out))

    scheme_dir = project_dir / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / f"{APP_NAME}.xcscheme").write_text(SCHEME.replace("__TARGET__", uid("target")))
    print(f"{APP_NAME}.xcodeproj: {len(swift_files)} Swift files, {len(resource_files)} resources")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
