import ast
import email.parser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import threading
import urllib.parse
import uuid
import zipfile


MODULES = {"yt-dlp": "yt_dlp", "yt-dlp-ejs": "yt_dlp_ejs", "certifi": "certifi"}
MAX_WHEEL = 20 * 1024 * 1024
MAX_EXPANDED = 64 * 1024 * 1024
MAX_ENTRIES = 6000
_lock = threading.RLock()
_sessions = set()
_configured = None
_frozen = False
_runtime_root = None


def normalized(value):
    return re.sub(r"[-_.]+", "-", value).lower()


def stable_version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){1,3}", value) or len(value) > 40:
        raise ValueError("This release version is unsupported. An app update may be required.")
    return tuple(int(part) for part in value.split("."))


def satisfies(version, requirement):
    actual = stable_version(version)
    for clause in requirement.split(","):
        match = re.fullmatch(r"\s*(>=|<=|==|!=|>|<|~=)\s*(\d+(?:\.\d+){0,3})(\.\*)?\s*", clause)
        if not match:
            raise ValueError("The release uses unsupported compatibility metadata. An app update is required.")
        operator, number, wildcard = match.groups()
        wanted = tuple(int(part) for part in number.split("."))
        width = max(len(actual), len(wanted))
        left, right = actual + (0,) * (width - len(actual)), wanted + (0,) * (width - len(wanted))
        if wildcard:
            if operator not in ("==", "!="):
                raise ValueError("Invalid compatibility range.")
            equal = actual[:len(wanted)] == wanted
            valid = equal if operator == "==" else not equal
        elif operator == "~=":
            if len(wanted) < 2:
                raise ValueError("Invalid compatible release range.")
            valid = left >= right and actual[:len(wanted) - 1] == wanted[:-1]
        else:
            valid = {">=": left >= right, "<=": left <= right, "==": left == right,
                     "!=": left != right, ">": left > right, "<": left < right}[operator]
        if not valid:
            return False
    return True


def wheel_entry(entry):
    name = entry.get("name")
    if name not in MODULES:
        raise ValueError("Only yt-dlp, yt-dlp-ejs and certifi can be updated.")
    stable_version(entry.get("version"))
    url = urllib.parse.urlsplit(entry.get("url", ""))
    if url.scheme != "https" or url.hostname != "files.pythonhosted.org" or url.port not in (None, 443) or url.username or url.password or url.fragment or url.query:
        raise ValueError("The package URL is not an official wheel URL.")
    filename = url.path.rsplit("/", 1)[-1]
    expected = MODULES[name] + "-" + entry["version"] + "-py3-none-any.whl"
    if filename != expected:
        raise ValueError("Only universal pure-Python wheels are supported.")
    size = entry.get("size")
    if type(size) is not int or not 0 < size <= MAX_WHEEL:
        raise ValueError("The package exceeds the download limit.")
    if not re.fullmatch(r"[a-f0-9]{64}", entry.get("sha256", "")):
        raise ValueError("The package checksum is missing or invalid.")
    return {key: entry[key] for key in ("name", "version", "url", "sha256", "size")}


def release(name, data):
    if name not in MODULES or normalized(data.get("info", {}).get("name", "")) != name:
        raise ValueError("The release metadata belongs to another package.")
    version = data["info"].get("version")
    stable_version(version)
    python = data["info"].get("requires_python")
    if not python or not satisfies("3.15.0", python):
        raise ValueError("This release requires a different Python runtime. An app update is required.")
    files = data.get("urls", [])
    for item in files:
        if item.get("yanked") or item.get("packagetype") != "bdist_wheel":
            continue
        if item.get("filename") != MODULES[name] + "-" + version + "-py3-none-any.whl":
            continue
        return wheel_entry({"name": name, "version": version, "url": item["url"],
                            "size": item["size"], "sha256": item["digests"]["sha256"]})
    raise ValueError("No supported, non-yanked universal wheel is available. An app update may be required.")


def read_json(path, limit=2 * 1024 * 1024):
    if path.is_symlink() or path.stat().st_size > limit:
        raise ValueError("Invalid dependency state file.")
    with path.open("rb") as source:
        return json.load(source)


def atomic_json(path, value):
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    try:
        with temporary.open("x", encoding="utf-8") as target:
            json.dump(value, target, separators=(",", ":"), allow_nan=False)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def root_directory(value):
    root = Path(value)
    if not root.is_absolute() or root.is_symlink() or ".." in root.parts:
        raise ValueError("The dependency directory must be a private absolute directory.")
    root = root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    for name in ("downloads", "generations"):
        directory = root / name
        if directory.is_symlink():
            raise ValueError("Invalid dependency directory.")
        directory.mkdir(exist_ok=True)
    return root


def generation_path(root, identifier):
    if not isinstance(identifier, str) or not re.fullmatch(r"[a-f0-9]{32}", identifier):
        raise ValueError("Invalid package generation.")
    path = root / "generations" / identifier
    if path.is_symlink():
        raise ValueError("Invalid package generation directory.")
    return path


def state_for(root):
    path = root / "state.json"
    empty = {"current": None, "previous": None, "pending": None, "trial": None}
    try:
        state = read_json(path) if path.exists() else empty.copy()
        if not isinstance(state, dict) or any(state.get(key) is not None and (not isinstance(state[key], str) or not re.fullmatch(r"[a-f0-9]{32}", state[key])) for key in empty):
            raise ValueError("Invalid dependency state.")
    except (ValueError, OSError, TypeError):
        state = empty.copy()
        state["notice"] = "Dependency state could not be read. Check for updates to reinstall source packages."
        atomic_json(path, state)
    if str(root) not in _sessions:
        if state.get("trial"):
            rejected = state["trial"]
            remember_rejection(root, state, rejected)
            if state.get("current") == rejected:
                state["current"] = state.get("previous")
                state["previous"] = None
            if state.get("pending") == rejected:
                state["pending"] = None
            state["trial"] = None
            state["notice"] = "The last dependency activation was interrupted. The previous complete version is retained."
            atomic_json(path, state)
        _sessions.add(str(root))
    return state


def generation(root, identifier):
    path = generation_path(root, identifier)
    manifest = read_json(path / "manifest.json")
    if manifest.get("adapter") != 1 or manifest.get("generation") != identifier:
        raise ValueError("This generation requires another app version.")
    entries = [wheel_entry(entry) for entry in manifest["packages"]]
    if len(entries) != 3 or {entry["name"] for entry in entries} != set(MODULES):
        raise ValueError("The dependency generation is incomplete.")
    files = manifest.get("files", {})
    if not files or len(files) > MAX_ENTRIES or (path / "packages").is_symlink():
        raise ValueError("The dependency generation has no valid inventory.")
    for relative, checksum in files.items():
        target = safe_target(path / "packages", relative)
        if target.is_symlink() or not target.is_file() or target.stat().st_size > MAX_WHEEL:
            raise ValueError("An installed dependency file is missing or invalid.")
        with target.open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != checksum:
                raise ValueError("An installed dependency failed its integrity check. Retry the update.")
    actual = {str(item.relative_to(path / "packages")) for item in (path / "packages").rglob("*") if item.is_file() or item.is_symlink()}
    if actual != set(files):
        raise ValueError("The installed package inventory has changed.")
    validate_packages(path / "packages", entries)
    return manifest


def snapshot(root):
    state = state_for(root)
    installed = None
    for key in ("pending", "current", "previous"):
        identifier = state.get(key)
        if not identifier:
            continue
        try:
            manifest = generation(root, identifier)
        except (ValueError, OSError, KeyError):
            state[key] = None
            state["notice"] = "An incomplete dependency installation was discarded. Check for updates to retry."
            continue
        if key == "previous" and not state.get("current"):
            state["current"], state["previous"] = identifier, None
        if installed is None:
            installed = manifest
    atomic_json(root / "state.json", state)
    return {"state": state, "manifest": installed, "configured": _configured, "frozen": _frozen}


def safe_target(root, name):
    if not name or "\\" in name or ":" in name or "\x00" in name or name.startswith("/") or any(part in ("", ".", "..") for part in name.rstrip("/").split("/")):
        raise ValueError("The archive contains an unsafe path.")
    target = root.joinpath(*PurePosixPath(name).parts)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError("The archive path escapes its destination.")
    return target


def unpack_wheel(entry, wheel, destination):
    entry = wheel_entry(entry)
    if wheel.is_symlink() or wheel.stat().st_size != entry["size"]:
        raise ValueError("The downloaded wheel size does not match release metadata.")
    with wheel.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != entry["sha256"]:
            raise ValueError("The downloaded wheel checksum does not match release metadata.")
    module = MODULES[entry["name"]]
    metadata = module + "-" + entry["version"] + ".dist-info"
    share_parts = (module + "-" + entry["version"] + ".data", "data", "share")
    with zipfile.ZipFile(wheel) as archive:
        items = archive.infolist()
        if len(items) > MAX_ENTRIES or sum(item.file_size for item in items) > MAX_EXPANDED:
            raise ValueError("The package archive exceeds its extraction limit.")
        seen = set()
        for item in items:
            target = safe_target(destination, item.filename)
            parts = PurePosixPath(item.filename).parts
            ancillary = parts[:3] == share_parts or (item.is_dir() and share_parts[:len(parts)] == parts)
            if item.filename in seen or (parts[0] not in (module, metadata) and not ancillary):
                raise ValueError("The wheel contains duplicate files or unexpected modules.")
            seen.add(item.filename)
            mode = item.external_attr >> 16
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR) or item.flag_bits & 1:
                raise ValueError("Links, special files and encrypted archives are unsupported.")
            if item.file_size > MAX_WHEEL or item.file_size / max(1, item.compress_size) > 500:
                raise ValueError("The package exceeds its expanded file limit.")
            if item.is_dir():
                if not ancillary:
                    target.mkdir(parents=True, exist_ok=True)
                continue
            if target.suffix.lower() in (".so", ".dylib", ".dll", ".exe", ".a", ".o", ".pth", ".fwork", ".pyc", ".pyo") or any(part.endswith(".framework") for part in target.parts):
                raise ValueError("Downloaded native code and import hooks are not allowed.")
            payload = archive.read(item)
            if payload[:4] in (b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
                               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca") or payload[:2] == b"MZ":
                raise ValueError("The wheel contains a native executable payload.")
            if ancillary:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
        wheel_metadata = email.parser.Parser().parsestr((destination / metadata / "WHEEL").read_text())
        if wheel_metadata.get("Root-Is-Purelib", "").lower() != "true" or wheel_metadata.get_all("Tag") != ["py3-none-any"]:
            raise ValueError("The wheel is not a supported universal pure-Python package.")


def package_metadata(packages, entry):
    directory = packages / (MODULES[entry["name"]] + "-" + entry["version"] + ".dist-info")
    data = email.parser.Parser().parsestr((directory / "METADATA").read_text())
    if len(data.get_all("Name", [])) != 1 or len(data.get_all("Version", [])) != 1 or normalized(data.get("Name", "")) != entry["name"] or data.get("Version") != entry["version"]:
        raise ValueError("The wheel name or version differs from release metadata.")
    if not data.get("Requires-Python") or not satisfies("3.15.0", data["Requires-Python"]):
        raise ValueError("The package requires another Python version. An app update is required.")
    for dependency in data.get_all("Requires-Dist", []):
        if ";" not in dependency or "extra" not in dependency.split(";", 1)[1]:
            raise ValueError("The package requires unbundled dependencies. An app update is required.")
    return data


def validate_packages(packages, entries):
    by_name = {entry["name"]: entry for entry in entries}
    metadata = {name: package_metadata(packages, entry) for name, entry in by_name.items()}
    requirements = []
    for dependency in metadata["yt-dlp"].get_all("Requires-Dist", []):
        match = re.match(r"yt-dlp-ejs\s*([^;]+);.*extra\s*==\s*['\"]default['\"]", dependency)
        if match:
            requirements.append(match.group(1).strip().strip("()"))
    if len(requirements) != 1 or not satisfies(by_name["yt-dlp-ejs"]["version"], requirements[0]):
        raise ValueError("yt-dlp and EJS are incompatible. Update them together.")
    for dependency in metadata["yt-dlp"].get_all("Requires-Dist", []):
        match = re.match(r"certifi\s*([^;]+);.*extra\s*==\s*['\"]default['\"]", dependency)
        if match and not satisfies(by_name["certifi"]["version"], match.group(1).strip().strip("()")):
            raise ValueError("The certificate package does not satisfy yt-dlp. Update all packages together.")
    quickjs = ast.parse((packages / "yt_dlp/extractor/youtube/jsc/_builtin/quickjs.py").read_text())
    runtime = ast.parse((packages / "yt_dlp/utils/_jsruntime.py").read_text())
    def class_named(tree, name):
        return next((node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == name), None)
    provider = class_named(quickjs, "QuickJSJCP")
    js_runtime = class_named(runtime, "QuickJsRuntime")
    info = class_named(runtime, "JsRuntimeInfo")
    def method_matches(node, name, arguments):
        if not node:
            return False
        method = next((value for value in node.body if isinstance(value, ast.FunctionDef) and value.name == name), None)
        return bool(method and [value.arg for value in method.args.posonlyargs + method.args.args] == arguments and not method.args.vararg and not method.args.kwarg)
    fields = {node.target.id for node in info.body if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name)} if info else set()
    if not method_matches(provider, "_run_js_runtime", ["self", "stdin"]) or not method_matches(js_runtime, "_info", ["self"]) or not {"name", "path", "version", "version_tuple", "supported"}.issubset(fields):
        raise ValueError("The QuickJS adapter API changed. An app update is required.")
    for relative in ("yt_dlp/__init__.py", "yt_dlp/YoutubeDL.py", "yt_dlp_ejs/__init__.py", "yt_dlp_ejs/yt/solver/core.min.js", "yt_dlp_ejs/yt/solver/lib.min.js", "certifi/__init__.py", "certifi/cacert.pem"):
        if not (packages / relative).is_file() or not (packages / relative).stat().st_size:
            raise ValueError("The package is missing a required runtime file.")
    vendor = literal_assignments(packages / "yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py", {"VERSION", "HASHES"})
    version = literal_assignments(packages / "yt_dlp_ejs/_version.py", {"version", "__version__"})
    if vendor.get("VERSION") != by_name["yt-dlp-ejs"]["version"] or version.get("version") != vendor.get("VERSION"):
        raise ValueError("The EJS solver version differs from the adapter's expected version.")
    for kind in ("core", "lib"):
        code = (packages / ("yt_dlp_ejs/yt/solver/" + kind + ".min.js")).read_text(encoding="utf-8")
        expected = vendor.get("HASHES", {}).get("yt.solver." + kind + ".min.js")
        if not expected or hashlib.sha3_512(code.encode()).hexdigest() != expected:
            raise ValueError("The EJS solver checksum differs from yt-dlp's expected solver.")
    if b"-----BEGIN CERTIFICATE-----" not in (packages / "certifi/cacert.pem").read_bytes():
        raise ValueError("The certificate bundle is invalid.")


def literal_assignments(path, wanted):
    result = {}
    for node in ast.parse(path.read_text()).body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id in wanted:
                result[target.id] = ast.literal_eval(node.value)
    return result


def install(root, entries):
    if len(entries) != 3 or {entry["name"] for entry in entries} != set(MODULES):
        raise ValueError("An update must produce a complete three-package generation.")
    entries = [wheel_entry(entry) for entry in entries]
    state = state_for(root)
    if generation_signature(entries) in state.get("rejected", []):
        raise ValueError("This package combination previously failed to activate. Try a newer release or an app update.")
    identifier = uuid.uuid4().hex
    staging = root / "generations" / (".staging-" + identifier)
    staging.mkdir()
    packages = staging / "packages"
    packages.mkdir()
    try:
        entries = [wheel_entry(entry) for entry in entries]
        for entry in entries:
            unpack_wheel(entry, root / "downloads" / (entry["sha256"] + ".whl"), packages)
        validate_packages(packages, entries)
        inventory = {}
        for file in sorted(packages.rglob("*")):
            if file.is_file():
                with file.open("rb") as source:
                    inventory[str(file.relative_to(packages))] = hashlib.file_digest(source, "sha256").hexdigest()
        if len(inventory) > MAX_ENTRIES:
            raise ValueError("The combined package inventory exceeds its limit.")
        manifest = {"adapter": 1, "generation": identifier, "packages": entries, "files": inventory}
        atomic_json(staging / "manifest.json", manifest)
        os.replace(staging, generation_path(root, identifier))
        state = state_for(root)
        state["pending"] = identifier
        state.pop("notice", None)
        atomic_json(root / "state.json", state)
        cleanup(root, state)
        return snapshot(root)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def configure(root):
    global _configured, _runtime_root
    result = snapshot(root)
    if _configured:
        result["path"] = str(generation_path(root, _configured) / "packages")
        return result
    manifest = result["manifest"]
    if not manifest:
        raise ValueError("Source downloads need extraction packages. Connect to the internet and retry.")
    _configured = manifest["generation"]
    _runtime_root = root
    path = str(generation_path(root, _configured) / "packages")
    sys.path.insert(0, path)
    result.update(configured=_configured, path=path)
    return result


def activation(root, action):
    global _frozen
    if not _configured:
        return
    state = state_for(root)
    if action == "begin":
        _frozen = True
        state["trial"] = _configured
    elif action == "confirm":
        if state.get("current") != _configured:
            state["previous"] = state.get("current")
            state["current"] = _configured
        if state.get("pending") == _configured:
            state["pending"] = None
        state["trial"] = None
    elif action == "reject":
        remember_rejection(root, state, _configured)
        if state.get("current") == _configured:
            state["current"] = state.get("previous")
            state["previous"] = None
        if state.get("pending") == _configured:
            state["pending"] = None
        state["trial"] = None
        state["notice"] = "The downloaded version could not start. Reopen the app to use the previous version, or retry the update."
    atomic_json(root / "state.json", state)
    cleanup(root, state)


def generation_signature(entries):
    payload = json.dumps({"adapter": 1, "packages": sorted((entry["name"], entry["sha256"]) for entry in entries)}, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def remember_rejection(root, state, identifier):
    try:
        manifest = read_json(generation_path(root, identifier) / "manifest.json")
        signature = generation_signature([wheel_entry(entry) for entry in manifest["packages"]])
    except (OSError, ValueError, KeyError, TypeError):
        return
    rejected = state.get("rejected", [])
    if not isinstance(rejected, list):
        rejected = []
    state["rejected"] = [signature] + [value for value in rejected if isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value) and value != signature][:7]


def cleanup(root, state):
    retained = {value for value in (state.get("current"), state.get("previous"), state.get("pending"), _configured) if value}
    checksums = set()
    for path in (root / "generations").iterdir():
        if path.name not in retained:
            if path.is_symlink() or path.is_file():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
        else:
            manifest = read_json(path / "manifest.json")
            checksums.update(entry["sha256"] + ".whl" for entry in manifest["packages"])
    for path in (root / "downloads").iterdir():
        if path.name not in checksums and (path.is_file() or path.is_symlink()):
            path.unlink()


def runtime_activation(action):
    with _lock:
        if _runtime_root:
            activation(_runtime_root, action)


def run(request):
    with _lock:
        try:
            data = json.loads(request)
            action = data["action"]
            if action == "metadata":
                result = release(data["name"], data["metadata"])
            elif action == "ejsRequirement":
                entry = wheel_entry(data["entry"])
                if entry["name"] != "yt-dlp":
                    raise ValueError("Only yt-dlp declares an EJS requirement.")
                root = root_directory(data["root"])
                wheel = root / "downloads" / (entry["sha256"] + ".whl")
                with wheel.open("rb") as source:
                    checksum = hashlib.file_digest(source, "sha256").hexdigest()
                if wheel.stat().st_size != entry["size"] or checksum != entry["sha256"]:
                    raise ValueError("The downloaded wheel failed its integrity check.")
                with zipfile.ZipFile(wheel) as archive:
                    name = "yt_dlp-" + entry["version"] + ".dist-info/METADATA"
                    info = archive.getinfo(name)
                    if info.file_size > 1024 * 1024:
                        raise ValueError("Package metadata exceeds its limit.")
                    metadata = email.parser.Parser().parsestr(archive.read(name).decode())
                requirements = []
                for dependency in metadata.get_all("Requires-Dist", []):
                    match = re.fullmatch(r"yt-dlp-ejs\s*==\s*(\d+(?:\.\d+){1,3})\s*;.*extra\s*==\s*['\"]default['\"]", dependency)
                    if match:
                        requirements.append(match.group(1))
                if len(requirements) != 1:
                    raise ValueError("The EJS compatibility requirement changed. An app update is required.")
                result = requirements[0]
                stable_version(result)
            else:
                root = root_directory(data["root"])
                if action == "snapshot":
                    result = snapshot(root)
                elif action == "install":
                    result = install(root, data["entries"])
                elif action == "configure":
                    result = configure(root)
                elif action in ("begin", "confirm", "reject"):
                    result = activation(root, action)
                else:
                    raise ValueError("Unknown dependency operation.")
            return json.dumps({"ok": True, "result": result}, allow_nan=False)
        except Exception as error:
            return json.dumps({"ok": False, "error": str(error)[:600]})
