"""Check project references and shared build settings without an Apple toolchain."""

import json
import hashlib
import importlib.util
import plistlib
import re
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parent.parent
ICON_SPEC = importlib.util.spec_from_file_location("package_icons", ROOT / "scripts/package-icons.py")
PACKAGE_ICONS = importlib.util.module_from_spec(ICON_SPEC)
ICON_SPEC.loader.exec_module(PACKAGE_ICONS)


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
        "mainGroup", "productRefGroup", "target", "targetProxy",
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
    targets = {objects[identifier]["name"]: identifier for identifier in pbxproject["targets"]}
    assert sorted(targets) == ["YoinkActivity", "YoinkShare", "iYoinks"], sorted(targets)
    target_id = targets["iYoinks"]
    target = objects[target_id]
    assert target["productType"] == "com.apple.product-type.application"
    share_id = targets["YoinkShare"]
    share = objects[share_id]
    activity_id = targets["YoinkActivity"]
    activity = objects[activity_id]
    assert share["productType"] == activity["productType"] == "com.apple.product-type.app-extension"

    for obj in objects.values():
        if obj["isa"] == "PBXFileReference" and obj["sourceTree"] == "<group>":
            assert (ROOT / obj["path"]).exists(), obj["path"]

    phases = [objects[identifier] for identifier in target["buildPhases"]]
    sources_phase = next(phase for phase in phases if phase["isa"] == "PBXSourcesBuildPhase")
    source_paths = [
        objects[objects[identifier]["fileRef"]]["path"]
        for identifier in sources_phase["files"]
    ]
    shared_sources = sorted(str(path.relative_to(ROOT)) for path in (ROOT / "Shared").rglob("*.swift"))
    app_sources = sorted([str(path.relative_to(ROOT)) for path in (ROOT / "iYoinks").rglob("*.swift")] + shared_sources)
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
    assert PACKAGE_ICONS.FALLBACK_KEY not in info, "The icon fallback flag is xtool-only"
    assert "CFBundleIcons" not in info, "Let Xcode generate its icon metadata"
    icon_path = ROOT / config["iconPath"]
    icon_set = json.loads((icon_path.parent / "Contents.json").read_text())
    light_entry = {
        "filename": icon_path.name,
        "idiom": "universal",
        "platform": "ios",
        "size": "1024x1024",
    }
    dark_entry = dict(light_entry, filename="AppIconDark.png", appearances=[{
        "appearance": "luminosity", "value": "dark",
    }])
    assert icon_set["images"] == [light_entry, dark_entry]
    icon_data = icon_path.read_bytes()
    PACKAGE_ICONS.check_png(icon_data, 1024, opaque=True)
    dark_data = (icon_path.parent / "AppIconDark.png").read_bytes()
    PACKAGE_ICONS.check_png(dark_data, 1024, opaque=True)
    assert hashlib.sha256(dark_data).hexdigest() == "7adfb93cec69085eef621bce785d330d54411f6ec4153904cbeb3ab2f4f13987", "Original dark artwork changed"
    assert icon_data != dark_data
    alternate_path = icon_path.parents[1] / "AppIconDark.appiconset"
    alternate_set = json.loads((alternate_path / "Contents.json").read_text())
    assert alternate_set["images"] == [dict(light_entry, filename="AppIconDark.png")]
    assert (alternate_path / "AppIconDark.png").read_bytes() == dark_data
    for name in ("BrandMark.png", "BrandMarkLight.png"):
        PACKAGE_ICONS.check_png((ROOT / "iYoinks/AppResources" / name).read_bytes(), 512)
    assert (ROOT / "iYoinks/AppResources/BrandMarkLight.png").read_bytes() != (ROOT / "iYoinks/AppResources/BrandMark.png").read_bytes()
    assert hashlib.sha256((ROOT / "iYoinks/AppResources/BrandMark.png").read_bytes()).hexdigest() == "13c247c6f3a23bff4a5c33d6830b3442dc585b2b498c1edc0bd52d50cc6952c5", "Original dark brand changed"
    resources = next(phase for phase in phases if phase["isa"] == "PBXResourcesBuildPhase")
    resource_files = [objects[objects[identifier]["fileRef"]] for identifier in resources["files"]]
    assert any(
        obj["lastKnownFileType"] == "folder.assetcatalog" and ROOT / obj["path"] == icon_path.parents[1]
        for obj in resource_files
    )
    assert any(
        obj["lastKnownFileType"] == "folder" and obj["path"] == "iYoinks/AppResources"
        for obj in resource_files
    ), "Register the AppResources folder for both brand images in Xcode"
    extractor = ROOT / "iYoinks/AppResources/Extractor"
    assert (extractor / "iyoinks_dependencies.py").is_file()
    baseline = json.loads((extractor / "dependencies.json").read_text())
    assert baseline["adapter"] == 1
    assert {entry["name"] for entry in baseline["packages"]} == {"yt-dlp", "yt-dlp-ejs", "certifi"}
    pins = json.loads((ROOT / "scripts/native-dependencies.json").read_text())
    for entry in pins["packages"]:
        runtime = next(item for item in baseline["packages"] if item["name"] == entry["name"])
        assert all(runtime[key] == entry[key] for key in ("version", "url", "sha256"))
        assert 0 < runtime["size"] <= 20 * 1024 * 1024
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    for identifier in configurations:
        settings = objects[identifier]["buildSettings"]
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == config["bundleID"]
        assert settings["SWIFT_VERSION"] == "6.0"
        assert settings["IPHONEOS_DEPLOYMENT_TARGET"] == info["MinimumOSVersion"]
        assert settings["MARKETING_VERSION"] == info["CFBundleShortVersionString"]
        assert settings["CURRENT_PROJECT_VERSION"] == info["CFBundleVersion"]
        assert settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == icon_path.parent.stem
        alternate_names = settings.get("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES", "")
        if isinstance(alternate_names, str):
            alternate_names = alternate_names.split()
        assert PACKAGE_ICONS.ALTERNATE_NAME in alternate_names, "Register AppIconDark in Xcode's alternate app icon sets"
        assert settings["INFOPLIST_KEY_CFBundleDisplayName"] == info["CFBundleDisplayName"]
        assert [int(family) for family in settings["TARGETED_DEVICE_FAMILY"].split(",")] == info["UIDeviceFamily"]
        assert settings["INFOPLIST_KEY_UISupportedInterfaceOrientations"].split() == info["UISupportedInterfaceOrientations"]
        assert settings["CODE_SIGN_ENTITLEMENTS"] == "iYoinks/iYoinks.entitlements"

    # The share extension: its own sources, YoinksCore for the capture inbox, embedded in the app,
    # versioned with it, and in the same App Group.
    share_phases = [objects[identifier] for identifier in share["buildPhases"]]
    share_sources = next(phase for phase in share_phases if phase["isa"] == "PBXSourcesBuildPhase")
    share_paths = sorted(objects[objects[identifier]["fileRef"]]["path"] for identifier in share_sources["files"])
    assert share_paths == sorted(str(path.relative_to(ROOT)) for path in (ROOT / "YoinkShare").rglob("*.swift"))
    share_frameworks = next(phase for phase in share_phases if phase["isa"] == "PBXFrameworksBuildPhase")
    share_packages = [objects[identifier]["productName"] for identifier in share["packageProductDependencies"]]
    assert share_packages == ["YoinksCore"], "The extension links only YoinksCore; Python and FFmpeg don't fit it"
    assert all(any(objects[build].get("productRef") == identifier for build in share_frameworks["files"])
               for identifier in share["packageProductDependencies"])
    embed = next(phase for phase in phases if phase.get("name") == "Embed Foundation Extensions")
    assert embed["dstSubfolderSpec"] == 13
    assert sorted(objects[identifier]["fileRef"] for identifier in embed["files"]) == sorted([share["productReference"], activity["productReference"]])
    for extension_id in (share_id, activity_id):
        assert any(objects[dependency]["target"] == extension_id for dependency in target["dependencies"])
    # The Live Activity widget: the shared attributes plus its own views, versioned with the app.
    activity_sources = next(objects[i] for i in activity["buildPhases"] if objects[i]["isa"] == "PBXSourcesBuildPhase")
    activity_paths = sorted(objects[objects[i]["fileRef"]]["path"] for i in activity_sources["files"])
    assert activity_paths == sorted(shared_sources + [str(p.relative_to(ROOT)) for p in (ROOT / "YoinkActivity").rglob("*.swift")])
    assert not activity["packageProductDependencies"]
    assert info.get("NSSupportsLiveActivities") is True
    for identifier in objects[activity["buildConfigurationList"]]["buildConfigurations"]:
        settings = objects[identifier]["buildSettings"]
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == config["bundleID"] + ".activity"
        assert settings["MARKETING_VERSION"] == info["CFBundleShortVersionString"]
        assert settings["CURRENT_PROJECT_VERSION"] == info["CFBundleVersion"]
        widget_info = plistlib.loads((ROOT / settings["INFOPLIST_FILE"]).read_bytes())
        assert widget_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
    group = "group.com.maynkudu.iyoinks"
    for identifier in objects[share["buildConfigurationList"]]["buildConfigurations"]:
        settings = objects[identifier]["buildSettings"]
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == config["bundleID"] + ".share"
        assert settings["MARKETING_VERSION"] == info["CFBundleShortVersionString"]
        assert settings["CURRENT_PROJECT_VERSION"] == info["CFBundleVersion"]
        assert settings["IPHONEOS_DEPLOYMENT_TARGET"] == info["MinimumOSVersion"]
        assert settings["SWIFT_VERSION"] == "6.0"
        share_info = plistlib.loads((ROOT / settings["INFOPLIST_FILE"]).read_bytes())
        assert share_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.share-services"
        for path in (settings["CODE_SIGN_ENTITLEMENTS"], "iYoinks/iYoinks.entitlements"):
            entitlements = plistlib.loads((ROOT / path).read_bytes())
            assert entitlements["com.apple.security.application-groups"] == [group], path
    assert f'appGroup = "{group}"' in (ROOT / "Packages/YoinksCore/Sources/YoinksCore/CaptureInbox.swift").read_text()

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
        "app_icon_alternate_name": PACKAGE_ICONS.ALTERNATE_NAME,
        "app_icon_dark_luminosity_slot": "passed",
        "original_dark_artwork": "preserved",
        "in_app_brand_assets": "passed",
        "share_extension": "passed; embedded, YoinksCore only, versioned with the app, same App Group",
        "live_activity_widget": "passed; embedded, shared attributes, versioned with the app",
        "swift_compilation": "not_checked_by_this_script",
        "native_ui": "not_checked_by_this_script",
    }


if __name__ == "__main__":
    print(json.dumps(check(), indent=2))
