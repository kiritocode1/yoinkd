import copy
import concurrent.futures
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import sysconfig
import tempfile
import unittest
from unittest.mock import patch
import zipfile


sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parent.parent
HELPER = PROJECT / "iYoinks/Resources/Extractor/iyoinks_dependencies.py"


class DependencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native_temporary = tempfile.TemporaryDirectory(prefix="yoinkd-dependency-control-")
        sources = PROJECT / "Packages/YoinksExtractor/Sources"
        files = [sources / "ExtractorBridge/runtime.c"] + [sources / "QuickJS" / name for name in ("quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c")]
        output = Path(cls.native_temporary.name) / "dependency-control.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-O0", "-std=c11", "-D_GNU_SOURCE", "-DQUICKJS_NG_BUILD",
                        "-I" + sysconfig.get_path("include"), "-I" + str(sources / "QuickJS"),
                        "-I" + str(sources / "ExtractorBridge/include"), *map(str, files), "-lm", "-lpthread", "-o", str(output)], check=True)
        cls.bridge = ctypes.CDLL(str(output))
        cls.bridge.iy_dependency_call.argtypes = [ctypes.c_char_p] * 4
        cls.bridge.iy_dependency_call.restype = ctypes.c_void_p
        cls.bridge.iy_free.argtypes = [ctypes.c_void_p]
        cls.native_output = output

    @classmethod
    def tearDownClass(cls):
        cls.native_temporary.cleanup()

    def setUp(self):
        spec = importlib.util.spec_from_file_location("dependency_fixture", HELPER)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)
        self.temporary = tempfile.TemporaryDirectory(prefix="yoinkd-dependencies-")
        self.root = self.helper.root_directory(str(Path(self.temporary.name).resolve()))
        self.paths = list(sys.path)

    def tearDown(self):
        sys.path[:] = self.paths
        self.temporary.cleanup()

    def wheel(self, name, version, edits=None, mode=None, python=">=3.10", requirement="0.8.0"):
        module = self.helper.MODULES[name]
        metadata = module + "-" + version + ".dist-info"
        contents = {
            module + "/__init__.py": "raise RuntimeError('Validation must never import package code')\n",
            metadata + "/WHEEL": "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
            metadata + "/METADATA": f"Name: {name}\nVersion: {version}\nRequires-Python: {python}\n",
        }
        if name == "yt-dlp":
            contents[metadata + "/METADATA"] += f"Requires-Dist: yt-dlp-ejs=={requirement}; extra == 'default'\nRequires-Dist: certifi>=2026.10.19; extra == 'default'\n"
            contents[module + "/YoutubeDL.py"] = "class YoutubeDL: pass\n"
            contents[module + "/extractor/youtube/jsc/_builtin/quickjs.py"] = "class QuickJSJCP:\n    def _run_js_runtime(self, stdin, /): pass\n"
            contents[module + "/utils/_jsruntime.py"] = "class JsRuntimeInfo:\n    name: str\n    path: str\n    version: str\n    version_tuple: tuple\n    supported: bool\nclass QuickJsRuntime:\n    def _info(self): pass\n"
            hashes = {"yt.solver." + kind + ".min.js": hashlib.sha3_512(code.encode()).hexdigest() for kind, code in (("core", "print(2);"), ("lib", "print(1);"))}
            contents[module + "/extractor/youtube/jsc/_builtin/vendor/_info.py"] = "VERSION = '" + requirement + "'\nHASHES = " + repr(hashes) + "\n"
        elif name == "yt-dlp-ejs":
            contents[module + "/yt/solver/core.min.js"] = "print(2);"
            contents[module + "/yt/solver/lib.min.js"] = "print(1);"
            contents[module + "/_version.py"] = "__version__ = version = '" + version + "'\n"
        else:
            contents[module + "/cacert.pem"] = "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----"
        for key, value in (edits or {}).items():
            if value is None:
                contents.pop(key, None)
            else:
                contents[key] = value
        archive = self.root / (module + "-" + version + ".whl")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
            for key, value in contents.items():
                info = zipfile.ZipInfo(key)
                if mode and key in mode:
                    info.external_attr = mode[key] << 16
                output.writestr(info, value)
        payload = archive.read_bytes()
        entry = {"name": name, "version": version, "size": len(payload), "sha256": hashlib.sha256(payload).hexdigest(),
                 "url": f"https://files.pythonhosted.org/packages/fixture/{module}-{version}-py3-none-any.whl"}
        archive.replace(self.root / "downloads" / (entry["sha256"] + ".whl"))
        return entry

    def wheels(self, version="2026.10.26"):
        return [self.wheel("yt-dlp", version), self.wheel("yt-dlp-ejs", "0.8.0"), self.wheel("certifi", "2026.10.23")]

    def install(self, entries=None):
        return self.helper.install(self.root, entries or self.wheels())

    def call(self, action, **values):
        return json.loads(self.helper.run(json.dumps({"action": action, "root": str(self.root), **values})))

    def test_snapshot_creates_private_directory_through_parent_alias(self):
        private = self.root / "private" / "var"
        private.mkdir(parents=True)
        alias = self.root / "var"
        alias.symlink_to(private, target_is_directory=True)
        suffix = Path("Library/Application Support/ExtractorDependencies")
        result = self.call("snapshot", root=str(alias / suffix))
        self.assertTrue(result["ok"], result.get("error"))
        self.assertEqual(self.helper.root_directory(str(alias / suffix)), private / suffix)
        self.assertTrue((private / suffix / "state.json").is_file())
        self.assertTrue((private / suffix / "downloads").is_dir())
        self.assertTrue((private / suffix / "generations").is_dir())

    def test_parent_alias_and_canonical_path_share_generation_and_activation(self):
        alias = self.root / "var"
        alias.symlink_to(self.root, target_is_directory=True)
        self.root = self.helper.root_directory(str(self.root / "ExtractorDependencies"))
        aliased_root = alias / "ExtractorDependencies"
        installed = self.call("install", root=str(aliased_root), entries=self.wheels())
        self.assertTrue(installed["ok"], installed.get("error"))
        identifier = installed["result"]["manifest"]["generation"]
        configured = self.call("configure", root=str(aliased_root))
        self.assertTrue(configured["ok"], configured.get("error"))
        self.assertEqual(Path(configured["result"]["path"]), self.root / "generations" / identifier / "packages")
        self.assertTrue(self.call("begin", root=str(aliased_root))["ok"])
        state = self.call("snapshot")["result"]["state"]
        self.assertEqual(state["trial"], identifier)
        self.assertFalse(state.get("rejected"))
        self.assertTrue(self.call("confirm")["ok"])
        aliased = self.call("snapshot", root=str(aliased_root))
        self.assertEqual(aliased, self.call("snapshot"))
        self.assertEqual(aliased["result"]["state"]["current"], identifier)
        self.assertIsNone(aliased["result"]["state"]["trial"])

    def test_relative_traversing_and_leaf_symlink_roots_are_rejected(self):
        leaf = self.root / "linked-root"
        leaf.symlink_to(self.root, target_is_directory=True)
        broken = self.root / "broken-root"
        broken.symlink_to(self.root / "missing", target_is_directory=True)
        for root in ("", "ExtractorDependencies", "../ExtractorDependencies", str(self.root / ".." / "ExtractorDependencies"), str(leaf), str(broken)):
            with self.subTest(root=root):
                result = self.call("snapshot", root=root)
                self.assertFalse(result["ok"])
                self.assertIn("private absolute directory", result["error"])

    def test_child_symlink_directories_are_rejected_through_parent_alias(self):
        alias = self.root / "var"
        alias.symlink_to(self.root, target_is_directory=True)
        for name in ("downloads", "generations"):
            with self.subTest(name=name):
                directory = self.root / (name + "-root")
                directory.mkdir()
                (directory / name).symlink_to(self.root, target_is_directory=True)
                result = self.call("snapshot", root=str(alias / directory.name))
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"], "Invalid dependency directory.")

    def test_validator_is_stdlib_only_and_does_not_import_downloaded_code(self):
        before = set(sys.modules)
        result = self.install()
        self.assertIsNotNone(result["manifest"])
        self.assertFalse({"yt_dlp", "yt_dlp_ejs", "certifi"} & (set(sys.modules) - before))

    def official_wheels(self):
        entries = json.loads((HELPER.parent / "dependencies.json").read_text())["packages"]
        host = Path(os.environ.get("YOINKD_HOST_PACKAGES", PROJECT / ".cache/native-dependencies/host-packages"))
        cache = Path(os.environ.get("YOINKD_WHEEL_CACHE", host.parent))
        for entry in entries:
            wheel = cache / entry["url"].rsplit("/", 1)[1]
            self.assertTrue(wheel.is_file(), "Prepare the original official wheels before verification")
            payload = wheel.read_bytes()
            self.assertEqual(len(payload), entry["size"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), entry["sha256"])
            (self.root / "downloads" / (entry["sha256"] + ".whl")).write_bytes(payload)
        return entries

    def test_original_official_wheels_install_without_repacking(self):
        entries = self.official_wheels()
        result = self.call("install", entries=entries)
        self.assertTrue(result["ok"], result.get("error"))
        manifest = result["result"]["manifest"]
        self.assertEqual(manifest["packages"], entries)
        self.assertFalse(any(".data/" in name for name in manifest["files"]))
        self.assertIsNotNone(self.helper.configure(self.root)["path"])

    def test_desktop_share_data_is_validated_but_not_installed(self):
        prefix = "yt_dlp-2026.10.26.data/data/share/"
        entry = self.wheel("yt-dlp", "2026.10.26", {prefix + "doc/yt_dlp/README.txt": "documentation"})
        result = self.install([entry, *self.wheels()[1:]])
        self.assertFalse(any(".data/" in name for name in result["manifest"]["files"]))
        packages = self.helper.generation_path(self.root, result["manifest"]["generation"]) / "packages"
        self.assertFalse((packages / "yt_dlp-2026.10.26.data").exists())

    def test_desktop_data_cannot_install_import_roots_or_native_payloads(self):
        prefix = "yt_dlp-2026.10.26.data/"
        for name, value in ((prefix + "purelib/hook.py", "import hook"),
                            (prefix + "platlib/native.so", b"native"),
                            (prefix + "scripts/yt-dlp", "script"),
                            (prefix + "data/share/hook.pth", "import hook"),
                            (prefix + "data/share/native", b"\x7fELFpayload"),
                            (prefix + "data/share/../escape", "unsafe")):
            with self.subTest(name=name):
                entry = self.wheel("yt-dlp", "2026.10.26", {name: value})
                with self.assertRaises(ValueError):
                    self.install([entry, *self.wheels()[1:]])

    def test_desktop_share_symlinks_and_size_limits_are_rejected(self):
        name = "yt_dlp-2026.10.26.data/data/share/doc/link"
        entry = self.wheel("yt-dlp", "2026.10.26", {name: "target"}, mode={name: stat.S_IFLNK | 0o777})
        with self.assertRaises(ValueError):
            self.install([entry, *self.wheels()[1:]])
        entry = self.wheel("yt-dlp", "2026.10.26", {name: "documentation"})
        wheel = self.root / "downloads" / (entry["sha256"] + ".whl")
        with zipfile.ZipFile(wheel) as archive:
            runtime_size = sum(item.file_size for item in archive.infolist() if item.filename != name)
        with patch.object(self.helper, "MAX_EXPANDED", runtime_size):
            with self.assertRaises(ValueError):
                self.install([entry, *self.wheels()[1:]])

    def test_checksum_and_size_are_verified_before_opening_zip(self):
        for key, value in (("sha256", "0" * 64), ("size", 1)):
            with self.subTest(key=key):
                entry = self.wheels()[0]
                altered = {**entry, key: value}
                if key == "sha256":
                    source = self.root / "downloads" / (entry["sha256"] + ".whl")
                    source.replace(self.root / "downloads" / (value + ".whl"))
                with self.assertRaises(ValueError):
                    self.helper.install(self.root, [altered, *self.wheels()[1:]])

    def test_traversal_absolute_and_windows_paths_are_rejected(self):
        for name in ("../escape", "/escape", "yt_dlp/../escape", "yt_dlp//escape", "yt_dlp\\escape", "C:/escape"):
            with self.subTest(name=name):
                entry = self.wheel("yt-dlp", "2026.10.26", {name: "bad"})
                with self.assertRaises(ValueError):
                    self.helper.install(self.root, [entry, *self.wheels()[1:]])

    def test_native_files_import_hooks_and_magic_payloads_are_rejected(self):
        for name, value in (("yt_dlp/native.so", b"x"), ("yt_dlp/native.framework/payload", b"x"),
                            ("yt_dlp/hook.pth", b"import malicious"), ("yt_dlp/data", b"\x7fELFbad"),
                            ("yt_dlp/windows", b"MZbad"), ("yt_dlp/mac", b"\xcf\xfa\xed\xfebad")):
            with self.subTest(name=name):
                entry = self.wheel("yt-dlp", "2026.10.26", {name: value})
                with self.assertRaises(ValueError):
                    self.helper.install(self.root, [entry, *self.wheels()[1:]])

    def test_symlink_and_special_files_are_rejected(self):
        for kind in (stat.S_IFLNK, stat.S_IFIFO):
            entry = self.wheel("yt-dlp", "2026.10.26", {"yt_dlp/link": "target"}, mode={"yt_dlp/link": kind | 0o777})
            with self.assertRaises(ValueError):
                self.helper.install(self.root, [entry, *self.wheels()[1:]])

    def test_wrong_name_version_native_wheel_and_python_are_rejected(self):
        metadata = "yt_dlp-2026.10.26.dist-info/"
        for edits, python in (({metadata + "METADATA": "Name: other\nVersion: 2026.10.26\nRequires-Python: >=3.10\n"}, ">=3.10"),
                              ({metadata + "WHEEL": "Root-Is-Purelib: false\nTag: cp315-ios_arm64\n"}, ">=3.10"),
                              ({}, ">=3.16"), ({}, "~=3.14.0")):
            entry = self.wheel("yt-dlp", "2026.10.26", edits, python=python)
            with self.assertRaises(ValueError):
                self.helper.install(self.root, [entry, *self.wheels()[1:]])

    def test_ejs_pair_and_private_adapter_api_are_validated_without_import(self):
        for edits, requirement in (({}, "0.9.0"), ({"yt_dlp/extractor/youtube/jsc/_builtin/quickjs.py": "class QuickJSJCP: pass\n"}, "0.8.0"),
                                    ({"yt_dlp/utils/_jsruntime.py": "class QuickJsRuntime: pass\n"}, "0.8.0")):
            entry = self.wheel("yt-dlp", "2026.10.26", edits, requirement=requirement)
            with self.assertRaises(ValueError):
                self.helper.install(self.root, [entry, *self.wheels()[1:]])

    def test_ejs_solver_version_and_expected_checksums_are_enforced(self):
        for edits in ({"yt_dlp_ejs/yt/solver/core.min.js": "modified solver"},
                      {"yt_dlp_ejs/_version.py": "version = '0.9.0'\n"}):
            entries = self.wheels()
            entries[1] = self.wheel("yt-dlp-ejs", "0.8.0", edits)
            with self.assertRaises(ValueError):
                self.helper.install(self.root, entries)

    def test_missing_artifacts_and_mandatory_dependencies_are_rejected(self):
        for edits in ({"yt_dlp/YoutubeDL.py": None}, {"yt_dlp-2026.10.26.dist-info/METADATA": "Name: yt-dlp\nVersion: 2026.10.26\nRequires-Python: >=3.10\nRequires-Dist: arbitrary-library>=1.0\n"}):
            entry = self.wheel("yt-dlp", "2026.10.26", edits)
            with self.assertRaises(ValueError):
                self.helper.install(self.root, [entry, *self.wheels()[1:]])

    def test_archive_limits_and_duplicate_entries_are_rejected(self):
        with patch.object(self.helper, "MAX_ENTRIES", 2):
            with self.assertRaises(ValueError):
                self.install()
        with patch.object(self.helper, "MAX_EXPANDED", 2):
            with self.assertRaises(ValueError):
                self.install()
        entries = self.wheels()
        wheel = self.root / "downloads" / (entries[0]["sha256"] + ".whl")
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(wheel, "a") as archive:
                archive.writestr("yt_dlp/__init__.py", "duplicate")
        payload = wheel.read_bytes()
        entries[0]["size"] = len(payload)
        entries[0]["sha256"] = hashlib.sha256(payload).hexdigest()
        wheel.replace(self.root / "downloads" / (entries[0]["sha256"] + ".whl"))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.helper.install(self.root, entries)

    def test_failed_transaction_retains_whole_current_generation(self):
        self.install()
        self.helper.configure(self.root)
        self.helper.activation(self.root, "begin")
        self.helper.activation(self.root, "confirm")
        before = (self.root / "state.json").read_bytes()
        entries = self.wheels("2026.11.01")
        wheel = self.root / "downloads" / (entries[1]["sha256"] + ".whl")
        wheel.write_bytes(b"interrupted transfer")
        with self.assertRaises(ValueError):
            self.helper.install(self.root, entries)
        self.assertEqual(before, (self.root / "state.json").read_bytes())
        self.assertFalse(list((self.root / "generations").glob(".staging-*")))

    def test_runtime_generation_is_immutable_after_update(self):
        original = self.install()
        first_path = self.helper.configure(self.root)["path"]
        self.helper.activation(self.root, "begin")
        self.helper.activation(self.root, "confirm")
        updated = self.install(self.wheels("2026.11.01"))
        self.assertNotEqual(original["manifest"]["generation"], updated["manifest"]["generation"])
        self.assertEqual(first_path, self.helper.configure(self.root)["path"])
        self.assertEqual(updated["state"]["current"], original["manifest"]["generation"])
        self.assertTrue(Path(first_path).is_dir())

    def test_interrupted_activation_rolls_back_without_crash_loop(self):
        initial = self.install()
        self.helper.configure(self.root)
        self.helper.activation(self.root, "begin")
        self.helper.activation(self.root, "confirm")
        candidate = self.install(self.wheels("2026.11.01"))["manifest"]["generation"]
        self.helper._configured = None
        self.helper.configure(self.root)
        self.helper.activation(self.root, "begin")
        self.helper._sessions.clear()
        self.helper._configured = None
        recovered = self.helper.snapshot(self.root)
        self.assertEqual(initial["manifest"]["generation"], recovered["state"]["current"])
        self.assertIsNone(recovered["state"]["pending"])
        self.assertIsNone(recovered["state"]["trial"])
        self.assertNotEqual(candidate, recovered["manifest"]["generation"])

    def test_first_activation_interrupt_leaves_retryable_source_error(self):
        self.install()
        self.helper.configure(self.root)
        self.helper.activation(self.root, "begin")
        self.helper._sessions.clear()
        self.helper._configured = None
        with self.assertRaisesRegex(ValueError, "Connect to the internet and retry"):
            self.helper.configure(self.root)

    def test_rejected_first_install_is_quarantined_until_package_combination_changes(self):
        latest = self.wheels("2026.11.01")
        self.install(latest)
        self.helper.configure(self.root)
        self.helper.activation(self.root, "begin")
        self.helper._sessions.clear()
        self.helper._configured = None
        self.helper.snapshot(self.root)
        with self.assertRaisesRegex(ValueError, "previously failed"):
            self.helper.install(self.root, latest)
        baseline = self.helper.install(self.root, self.wheels("2026.10.26"))
        self.assertIsNotNone(baseline["manifest"])

    def test_confirmed_generation_reactivation_failure_restores_previous(self):
        first = self.install()["manifest"]["generation"]
        self.helper.configure(self.root)
        self.helper.activation(self.root, "begin")
        self.helper.activation(self.root, "confirm")
        self.install(self.wheels("2026.11.01"))
        self.helper._configured = None
        self.helper.configure(self.root)
        self.helper.activation(self.root, "begin")
        self.helper.activation(self.root, "confirm")
        self.helper._configured = None
        self.helper.configure(self.root)
        self.helper.activation(self.root, "begin")
        self.helper.activation(self.root, "reject")
        restored = self.helper.snapshot(self.root)
        self.assertEqual(first, restored["state"]["current"])
        self.assertIsNone(restored["state"]["trial"])
        self.assertTrue(restored["state"]["rejected"])

    def test_inventory_tampering_and_incomplete_generation_are_detected(self):
        result = self.install()
        identifier = result["manifest"]["generation"]
        path = self.helper.generation_path(self.root, identifier) / "packages/yt_dlp/__init__.py"
        path.write_text("tampered")
        with self.assertRaisesRegex(ValueError, "integrity"):
            self.helper.generation(self.root, identifier)
        self.assertIsNone(self.helper.snapshot(self.root)["manifest"])

    def test_failed_atomic_state_publish_retains_previous_state(self):
        self.install()
        before = (self.root / "state.json").read_bytes()
        replace = self.helper.os.replace
        def interrupt(source, destination):
            if Path(destination).name == "state.json":
                raise OSError("fixture interrupted activation")
            return replace(source, destination)
        with patch.object(self.helper.os, "replace", side_effect=interrupt):
            with self.assertRaises(OSError):
                self.install(self.wheels("2026.11.01"))
        self.assertEqual(before, (self.root / "state.json").read_bytes())

    def test_official_metadata_limits_hosts_tags_and_stable_release(self):
        entry = self.wheels()[0]
        data = {"info": {"name": "yt-dlp", "version": entry["version"], "requires_python": ">=3.11"},
                "urls": [{"filename": "yt_dlp-" + entry["version"] + "-py3-none-any.whl", "url": entry["url"],
                          "size": entry["size"], "digests": {"sha256": entry["sha256"]}, "packagetype": "bdist_wheel", "yanked": False}]}
        self.assertEqual(entry, self.helper.release("yt-dlp", data))
        for bad in ("https://evil.example/wheel.whl", "http://files.pythonhosted.org/wheel.whl", "https://files.pythonhosted.org@evil.example/wheel.whl"):
            value = copy.deepcopy(data)
            value["urls"][0]["url"] = bad
            with self.assertRaises(ValueError):
                self.helper.release("yt-dlp", value)
        for field, value in (("version", "2026.11.01rc1"), ("name", "other"), ("requires_python", ">=3.16")):
            altered = copy.deepcopy(data)
            altered["info"][field] = value
            with self.assertRaises(ValueError):
                self.helper.release("yt-dlp", altered)
        data["urls"][0]["yanked"] = True
        with self.assertRaises(ValueError):
            self.helper.release("yt-dlp", data)

    def test_control_endpoint_reports_errors_as_json(self):
        response = self.call("install", entries=[])
        self.assertFalse(response["ok"])
        self.assertIn("complete", response["error"])
        self.assertFalse(self.call("unknown")["ok"])

    def test_corrupt_state_is_retryable_and_does_not_import_a_generation(self):
        for content in ("{interrupted", '["invalid"]', '{"current":"../outside"}'):
            (self.root / "state.json").write_text(content)
            result = self.call("snapshot")
            self.assertTrue(result["ok"])
            self.assertIsNone(result["result"]["manifest"])
            self.assertIn("reinstall", result["result"]["state"]["notice"])

    def test_actual_c_control_endpoint_is_stdlib_only_and_serializes_requests(self):
        sys.path.insert(0, str(HELPER.parent))
        before = set(sys.modules)
        alias = self.root / "var"
        alias.symlink_to(self.root, target_is_directory=True)
        canonical_root = self.root / "ExtractorDependencies"
        aliased_root = alias / "ExtractorDependencies"
        def invoke(action, root=canonical_root):
            encoded = json.dumps({"action": action, "root": str(root)}).encode()
            pointer = self.bridge.iy_dependency_call(b"", str(HELPER.parent).encode(), sys.executable.encode(), encoded)
            self.assertTrue(pointer)
            try:
                return json.loads(ctypes.string_at(pointer))
            finally:
                self.bridge.iy_free(pointer)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(invoke, ["snapshot"] * 8))
        self.assertTrue(all(result["ok"] for result in results))
        self.assertFalse({"yt_dlp", "yt_dlp_ejs", "certifi", "iyoinks_extract"} & (set(sys.modules) - before))
        aliased = invoke("snapshot", aliased_root)
        self.assertTrue(aliased["ok"], aliased.get("error"))
        self.assertEqual(aliased, invoke("snapshot"))
        self.assertFalse(invoke("invalid")["ok"])

    def test_pinned_baseline_agrees_with_native_build_pins(self):
        baseline = json.loads((HELPER.parent / "dependencies.json").read_text())
        pins = json.loads((PROJECT / "scripts/native-dependencies.json").read_text())
        for entry in baseline["packages"]:
            self.helper.wheel_entry(entry)
            pinned = next(item for item in pins["packages"] if item["name"] == entry["name"])
            for key in ("version", "sha256", "url"):
                self.assertEqual(entry[key], pinned[key])

    def test_z_actual_c_activation_smoke_confirms_real_packages_without_network(self):
        entries = self.official_wheels()
        installed = self.helper.install(self.root, entries)
        alias = self.root.parent / (self.root.name + "-alias")
        alias.symlink_to(self.root.parent, target_is_directory=True)
        self.addCleanup(alias.unlink)
        aliased_root = alias / self.root.name
        sys.path.insert(0, str(HELPER.parent))
        spec = importlib.util.spec_from_file_location("_iy_native", self.native_output)
        native = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(native)
        sys.modules["_iy_native"] = native
        def control(action, root=aliased_root):
            encoded = json.dumps({"action": action, "root": str(root)}).encode()
            pointer = self.bridge.iy_dependency_call(b"", str(HELPER.parent).encode(), sys.executable.encode(), encoded)
            try:
                return json.loads(ctypes.string_at(pointer))
            finally:
                self.bridge.iy_free(pointer)
        configured = control("configure")
        self.assertTrue(configured["ok"])
        self.bridge.iy_operation_create.argtypes = [ctypes.c_void_p] * 3
        self.bridge.iy_operation_create.restype = ctypes.c_void_p
        self.bridge.iy_operation_free.argtypes = [ctypes.c_void_p]
        self.bridge.iy_runtime_call.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_char_p]
        self.bridge.iy_runtime_call.restype = ctypes.c_void_p
        operation = self.bridge.iy_operation_create(None, None, None)
        request = json.dumps({"action": "unsupported", "url": "https://fixture.invalid"}).encode()
        pointer = self.bridge.iy_runtime_call(b"", str(HELPER.parent).encode(), sys.executable.encode(), operation, request)
        try:
            response = json.loads(ctypes.string_at(pointer))
            self.assertFalse(response["ok"])
            self.assertIn("Unknown media action", response["error"])
        finally:
            self.bridge.iy_free(pointer)
            self.bridge.iy_operation_free(operation)
        state = control("snapshot")["result"]["state"]
        self.assertEqual(state, control("snapshot", self.root)["result"]["state"])
        self.assertEqual(installed["manifest"]["generation"], state["current"])
        self.assertIsNone(state["pending"])
        self.assertIsNone(state["trial"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
