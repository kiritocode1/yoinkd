"""Check project references and shared build settings without an Apple toolchain."""

import json
import plistlib
import re
import struct
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parent.parent


def parse_openstep(source):
    pattern = re.compile(
        r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[A-Za-z0-9_./$<>:+-]+'
    )
    tokens = []
    position = 0
    while position < len(source):
        match = pattern.match(source, position)
        if match is None:
            raise ValueError(f"Unexpected project syntax at offset {position}")
        token = match.group()
        position = match.end()
        if not token.isspace() and not token.startswith(("//", "/*")):
            tokens.append(token)

    index = 0

    def consume(expected):
        nonlocal index
        if index >= len(tokens) or tokens[index] != expected:
            raise ValueError(f"Expected {expected} at token {index}")
        index += 1

    def value():
        nonlocal index
        token = tokens[index]
        if token == "{":
            consume("{")
            result = {}
            while tokens[index] != "}":
                key = value()
                if not isinstance(key, str) or key in result:
                    raise ValueError(f"Invalid or duplicate project key {key}")
                consume("=")
                result[key] = value()
                consume(";")
            consume("}")
            return result
        if token == "(":
            consume("(")
            result = []
            while tokens[index] != ")":
                result.append(value())
                if tokens[index] == ")":
                    break
                consume(",")
            consume(")")
            return result
        index += 1
        if token.startswith('"'):
            return json.loads(token)
        if token.isdigit():
            return int(token)
        if token in "{}()=;,":
            raise ValueError(f"Unexpected delimiter {token}")
        return token

    result = value()
    if index != len(tokens):
        raise ValueError("Unconsumed project tokens")
    return result


def check():
    project = parse_openstep((ROOT / "iYoinks.xcodeproj/project.pbxproj").read_text())
    objects = project["objects"]
    single_refs = {
        "fileRef", "productRef", "package", "buildConfigurationList", "productReference",
        "mainGroup", "productRefGroup",
    }
    list_refs = {
        "children", "buildPhases", "dependencies", "buildConfigurations",
        "packageReferences", "packageProductDependencies", "files", "targets",
    }

    def references(obj):
        for key, value in obj.items():
            if key in single_refs:
                yield value
            elif key in list_refs:
                yield from value

    for identifier, obj in objects.items():
        assert re.fullmatch(r"[A-F0-9]{24}", identifier), identifier
        for reference in references(obj):
            assert reference in objects, f"{identifier} references missing object {reference}"

    visited = set()

    def visit(identifier):
        if identifier not in visited:
            visited.add(identifier)
            for reference in references(objects[identifier]):
                visit(reference)

    visit(project["rootObject"])
    assert visited == set(objects), f"Unreachable objects: {set(objects) - visited}"
    pbxproject = objects[project["rootObject"]]
    assert pbxproject["isa"] == "PBXProject"
    assert len(pbxproject["targets"]) == 1
    target_id = pbxproject["targets"][0]
    target = objects[target_id]
    assert target["productType"] == "com.apple.product-type.application"

    for obj in objects.values():
        if obj["isa"] == "PBXFileReference" and obj["sourceTree"] == "<group>":
            assert (ROOT / obj["path"]).exists(), obj["path"]

    phases = [objects[identifier] for identifier in target["buildPhases"]]
    sources_phase = next(phase for phase in phases if phase["isa"] == "PBXSourcesBuildPhase")
    source_paths = [
        objects[objects[identifier]["fileRef"]]["path"]
        for identifier in sources_phase["files"]
    ]
    app_sources = sorted(str(path.relative_to(ROOT)) for path in (ROOT / "iYoinks").rglob("*.swift"))
    assert sorted(source_paths) == app_sources
    assert len(source_paths) == len(set(source_paths))

    dependencies = target["packageProductDependencies"]
    expected = {"YoinksCore": "Packages/YoinksCore", "ExtractorBridge": "Packages/YoinksExtractor", "SwiftFFmpeg": "Vendor/SwiftFFmpeg-iOS"}
    assert len(dependencies) == len(expected)
    frameworks = next(phase for phase in phases if phase["isa"] == "PBXFrameworksBuildPhase")
    for identifier in dependencies:
        dependency = objects[identifier]
        package = objects[dependency["package"]]
        assert package["relativePath"] == expected[dependency["productName"]]
        assert (ROOT / package["relativePath"] / "Package.swift").is_file()
        assert any(objects[build].get("productRef") == identifier for build in frameworks["files"])
    assert any(phase.get("name") == "Package Python runtime" for phase in phases)

    scheme = ElementTree.parse(ROOT / "iYoinks.xcodeproj/xcshareddata/xcschemes/iYoinks.xcscheme")
    for reference in scheme.findall(".//BuildableReference"):
        assert reference.attrib["BlueprintIdentifier"] == target_id
        assert reference.attrib["ReferencedContainer"] == "container:iYoinks.xcodeproj"
    workspace = ElementTree.parse(ROOT / "iYoinks.xcodeproj/project.xcworkspace/contents.xcworkspacedata")
    assert workspace.find("FileRef").attrib["location"] == "self:"

    config = {}
    for line in (ROOT / "xtool.yml").read_text().splitlines():
        key, separator, value = line.partition(":")
        assert separator and key not in config, line
        config[key] = value.strip()
    assert config["version"] == "1"
    assert config["product"] == target["name"]
    with (ROOT / config["infoPath"]).open("rb") as file:
        info = plistlib.load(file)
    assert "UIDesignRequiresCompatibility" not in info
    icon_path = ROOT / config["iconPath"]
    icon_set = json.loads((icon_path.parent / "Contents.json").read_text())
    assert icon_set["images"] == [{
        "filename": icon_path.name,
        "idiom": "universal",
        "platform": "ios",
        "size": "1024x1024",
    }]
    icon_data = icon_path.read_bytes()
    assert icon_data[:8] == b"\x89PNG\r\n\x1a\n"
    assert struct.unpack(">II", icon_data[16:24]) == (1024, 1024)
    resources = next(phase for phase in phases if phase["isa"] == "PBXResourcesBuildPhase")
    resource_files = [objects[objects[identifier]["fileRef"]] for identifier in resources["files"]]
    assert any(
        obj["lastKnownFileType"] == "folder.assetcatalog" and ROOT / obj["path"] == icon_path.parents[1]
        for obj in resource_files
    )
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    for identifier in configurations:
        settings = objects[identifier]["buildSettings"]
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == config["bundleID"]
        assert settings["SWIFT_VERSION"] == "6.0"
        assert settings["IPHONEOS_DEPLOYMENT_TARGET"] == info["MinimumOSVersion"]
        assert settings["MARKETING_VERSION"] == info["CFBundleShortVersionString"]
        assert settings["CURRENT_PROJECT_VERSION"] == info["CFBundleVersion"]
        assert settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == icon_path.parent.stem
        assert settings["INFOPLIST_KEY_CFBundleDisplayName"] == info["CFBundleDisplayName"]
        assert [int(family) for family in settings["TARGETED_DEVICE_FAMILY"].split(",")] == info["UIDeviceFamily"]
        assert settings["INFOPLIST_KEY_UISupportedInterfaceOrientations"].split() == info["UISupportedInterfaceOrientations"]

    return {
        "openstep_syntax": "passed",
        "object_references": "passed",
        "object_count": len(objects),
        "app_source_inclusion": "passed",
        "app_source_count": len(app_sources),
        "local_package_linkage": "passed",
        "scheme_and_workspace_xml": "passed",
        "xcode_xtool_bundle_settings": "passed",
        "app_icon_assets": "passed",
        "swift_compilation": "not_checked_by_this_script",
        "native_ui": "not_checked_by_this_script",
    }


if __name__ == "__main__":
    print(json.dumps(check(), indent=2))
