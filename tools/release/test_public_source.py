#!/usr/bin/env python3
"""Hermetic gate tests: python3 -I tools/release/test_public_source.py -v."""
import copy
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().with_name("public_source.py")
M = runpy.run_path(str(TOOL), run_name="release_gate_tested_module")
# Functions loaded by runpy retain a separate globals dictionary.
G = M["scan"].__globals__
POLICY = M["load_policy"](TOOL.with_name("allowlist.json"))
LICENSE = TOOL.parents[2].joinpath("LICENSE.md").read_bytes()


class PublicSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="public-source-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "source"
        self.root.mkdir()
        self.policy = copy.deepcopy(POLICY)
        self.policy["exceptions"] = []
        for path in self.policy["required_files"]:
            content = b"// public fixture\n"
            if path.endswith((".json", "Package.resolved")):
                content = b"{}\n"
            if path.endswith(".xcscheme"):
                content = b'<Scheme><BuildableReference ReferencedContainer="container:BilibiliLive.xcodeproj"/></Scheme>'
            if path.endswith(".xcworkspacedata"):
                content = b'<Workspace><FileRef location="self:"/></Workspace>'
            if path.endswith(".pbxproj"):
                content = b'{ objects = {}; }\n'
            if path == "LICENSE.md":
                content = LICENSE
            self.put(path, content)
        self.output = self.base / "public"
        self.manifest = self.base / "private-manifest.json"

    def put(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content if isinstance(content, bytes) else content.encode())
        return target

    def audit(self):
        return M["audit"](self.root, self.policy)

    def errors(self, report):
        return [f["rule"] for f in report["findings"] if f["severity"] == "error"]

    def test_valid_minimal_public_source(self):
        report, _ = self.audit()
        self.assertTrue(report["ok"], report["findings"])
        self.assertFalse(report["build_verified"])
        self.assertFalse(report["device_verified"])
        self.assertFalse(report["publication_authorized"])

    def test_default_deny_private_files_and_history(self):
        paths = ["PrivateResources/payment.jpg", "internal/report.md", "AGENTS.md", ".env",
                 ".git/config", ".github/workflows/build.yml", "personal.json", "misc/public.swift",
                 "BilibiliLive/private/report.swift", "BilibiliLive/AGENTS.md",
                 "BilibiliLive/example.sqlite", "BilibiliLive/raw.pdf", "BilibiliLive/phone.udid",
                 "BilibiliLive/.env", "BilibiliLive/signing/certificate.p12",
                 "docs/PRIVATE_NOTES.md", "tools/unknown/tool.py"]
        for path in paths:
            self.put(path, "not public")
        self.put("FamilyCore/Package.swift", "// package")
        self.put("FamilyCore/Sources/CSQLite/module.modulemap", "module CSQLite { header \"shim.h\" }")
        self.put("FamilyCore/Sources/CSQLite/shim.h", "#include <sqlite3.h>")
        self.put("tools/questionbank/main.py", "print('public tool')")
        self.put("tools/textbook-index/main.py", "print('public tool')")
        self.put("QuestionBank/example.json", '{"sample": true}')
        report, blobs = self.audit()
        self.assertTrue(report["ok"], report["findings"])
        for path in paths:
            self.assertNotIn(path, blobs)
        self.assertIn("FamilyCore/Sources/CSQLite/shim.h", blobs)
        M["export_snapshot"](self.root, self.output, self.manifest, report, blobs, {"version": "test", "files": report["files"]})
        self.assertEqual((self.output / "LICENSE.md").read_bytes(), LICENSE)
        exported = {p.relative_to(self.output).as_posix() for p in self.output.rglob("*") if p.is_file()}
        self.assertEqual(exported, set(blobs))
        self.assertNotIn(".git", [p.name for p in self.output.rglob("*")])
        self.assertFalse((self.output / self.manifest.name).exists())
        for item in report["files"]:
            self.assertEqual(M["sha256"]((self.output / item["path"]).read_bytes()), item["sha256"])

    def test_symlink_file_directory_dangling_and_unknown_root_refused(self):
        outside = self.base / "outside"
        outside.write_text("private")
        for name, target in [("BilibiliLive/link.swift", outside), ("BilibiliLive/linkdir", self.base),
                             ("BilibiliLive/missing.swift", self.base / "absent"), ("not-allowed", outside)]:
            with self.subTest(name=name):
                link = self.root / name
                link.symlink_to(target)
                report, _ = self.audit()
                self.assertIn("symlink", self.errors(report))
                link.unlink()

    def test_symlink_source_and_destination_parent_refused(self):
        link = self.base / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(M["GateError"]):
            M["absolute_path"](link)
        with self.assertRaises(M["GateError"]):
            M["validate_outputs"](self.root, link / "out", self.manifest)

    def test_nested_git_refused(self):
        self.put("BilibiliLive/.git/config", "forbidden")
        report, _ = self.audit()
        self.assertIn("unsafe-path", self.errors(report))

    def test_path_traversal_and_absolute_allowlist_refused(self):
        for path in ["../private", "/absolute", "a/../b", "a//b", "a\\b", ".git/config"]:
            with self.subTest(path=path):
                with self.assertRaises(M["GateError"]):
                    M["relative_path"](path)
                policy = copy.deepcopy(self.policy)
                policy["files"].append(path)
                p = self.base / "policy.json"
                p.write_text(json.dumps(policy))
                with self.assertRaises(M["GateError"]):
                    M["load_policy"](p)

    def test_existing_directory_empty_or_nonempty_refused(self):
        self.output.mkdir()
        with self.assertRaises(M["GateError"]):
            M["validate_outputs"](self.root, self.output, self.manifest)
        marker = self.output / "keep.txt"
        marker.write_text("keep")
        with self.assertRaises(M["GateError"]):
            M["validate_outputs"](self.root, self.output, self.manifest)
        self.assertEqual(marker.read_text(), "keep")

    def test_internal_manifest_and_git_destination_refused(self):
        for output, sidecar in [(self.output, self.output / "manifest.json"),
                                (self.output, self.root / "manifest.json"),
                                (self.root / "public", self.manifest),
                                (self.base / ".git" / "public", self.manifest),
                                (self.output, self.output)]:
            with self.subTest(output=output, sidecar=sidecar):
                with self.assertRaises(M["GateError"]):
                    M["validate_outputs"](self.root, output, sidecar)

    def test_missing_asset_blocks_and_creates_nothing(self):
        asset = "BilibiliLive/Supporting Files/Assets.xcassets/Photo.imageset/Contents.json"
        self.put(asset, json.dumps({"images": [{"filename": "missing.png"}]}))
        report, blobs = self.audit()
        self.assertIn("missing-resource", self.errors(report))
        with self.assertRaises(M["GateError"]):
            M["export_snapshot"](self.root, self.output, self.manifest, report, blobs, {})
        self.assertFalse(self.output.exists())
        self.assertFalse(self.manifest.exists())

    def test_resource_traversal_refused(self):
        self.put("BilibiliLive/Supporting Files/Assets.xcassets/X.imageset/Contents.json",
                 json.dumps({"images": [{"filename": "../../../../../private.png"}]}))
        report, _ = self.audit()
        self.assertIn("resource-path", self.errors(report))

    def test_missing_required_lockfile_blocks(self):
        (self.root / "BuildTools/Package.resolved").unlink()
        report, _ = self.audit()
        self.assertIn("missing-resource", self.errors(report))

    def test_missing_plist_and_synchronized_root_blocks(self):
        self.put("BilibiliLive.xcodeproj/project.pbxproj",
                 'INFOPLIST_FILE = "PrivateResources/Info.plist";\n'
                 '{isa = PBXFileSystemSynchronizedRootGroup; path = MissingApp; sourceTree = "<group>";}')
        report, _ = self.audit()
        self.assertGreaterEqual(self.errors(report).count("missing-resource"), 2)

    def test_secret_blocks_and_is_redacted(self):
        value = "gh" + "p_" + "A" * 36
        self.put("BilibiliLive/leak.swift", 'let credential = "' + value + '"')
        report, _ = self.audit()
        self.assertIn("provider-token", self.errors(report))
        self.assertNotIn(value, json.dumps(report))

    def test_literal_credential_blocks(self):
        self.put("QuestionBank/leak.json", json.dumps({"password": "fixture" + "-not-real"}))
        report, _ = self.audit()
        self.assertIn("literal-credential", self.errors(report))

    def test_signing_team_blocks_without_exception(self):
        self.put("BilibiliLive.xcodeproj/project.pbxproj", "DEVELOPMENT_" + "TEAM = A123456789;")
        report, _ = self.audit()
        self.assertIn("signing-configuration", self.errors(report))

    def test_exact_exception_is_reported_and_changes_block(self):
        path = "QuestionBank/fixture.json"
        text = json.dumps({"token": "synthetic" + "-example-only"})
        self.put(path, text)
        self.policy["exceptions"].append({"path": path, "rule": "literal-credential",
                                          "line_sha256": M["sha256"](text.encode()),
                                          "reason": "Explicit test-only fixture"})
        report, _ = self.audit()
        self.assertTrue(report["ok"], report["findings"])
        self.assertTrue(any(f["severity"] == "accepted-exception" for f in report["findings"]))
        self.put(path, text.replace("example", "modified"))
        report, _ = self.audit()
        self.assertIn("literal-credential", self.errors(report))
        self.assertTrue(any(f["rule"] == "unused-exception" for f in report["findings"]))

    def test_private_image_fingerprint_blocks_even_renamed(self):
        image = b"\xff\xd8\xffsynthetic-private-original"
        self.put("BilibiliLive/innocent.jpg", image)
        # Never read/distribute the actual private photograph in tests.
        with mock.patch.dict(G, {"PRIVATE_IMAGE_SHA256": M["sha256"](image)}):
            report, _ = self.audit()
        self.assertIn("private-image-sha256", self.errors(report))
        self.assertEqual(M["PRIVATE_IMAGE_SHA256"], "33c845f8464cba9ab14cc923046865de45ddbdc81a6e0f088aaa90bc6719fc94")

    def test_disguised_pdf_and_sqlite_block(self):
        for data in [b"%PDF-1.7", b"SQLite format 3\x00payload"]:
            with self.subTest(data=data):
                self.put("QuestionBank/renamed.json", data)
                report, _ = self.audit()
                self.assertIn("forbidden-content", self.errors(report))

    def test_license_change_blocks(self):
        self.put("LICENSE.md", LICENSE + b"\n")
        report, _ = self.audit()
        self.assertIn("license-changed", self.errors(report))

    def test_hardlink_refused(self):
        os.link(self.root / "README.md", self.root / "BilibiliLive/hard.swift")
        report, _ = self.audit()
        self.assertIn("special-file", self.errors(report))

    def test_export_uses_scanned_snapshot_not_later_source_bytes(self):
        report, blobs = self.audit()
        original = blobs["README.md"]
        self.put("README.md", "changed after audit")
        M["export_snapshot"](self.root, self.output, self.manifest, report, blobs, {})
        self.assertEqual((self.output / "README.md").read_bytes(), original)

    def test_cli_check_and_dry_run_do_not_write_or_need_git(self):
        for command in ["check", "dry-run"]:
            result = subprocess.run([sys.executable, "-I", str(TOOL), command,
                                     "--source", str(self.root), "--version", "0.0.0-test",
                                     "--output", str(self.output), "--manifest", str(self.manifest)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(json.loads(result.stdout)["exported"])
            self.assertFalse(self.output.exists())
            self.assertFalse(self.manifest.exists())

    def test_export_manifest_has_provenance_without_publishing_it(self):
        commit = "a" * 40
        with mock.patch.dict(G, {"provenance": lambda root: {"source_commit": commit, "source_dirty": True}}):
            with mock.patch("builtins.print") as printed:
                code = M["main"](["export", "--source", str(self.root), "--version", "0.0.0-test",
                                  "--output", str(self.output), "--manifest", str(self.manifest)])
        self.assertEqual(code, 0, printed.call_args)
        manifest = json.loads(self.manifest.read_text())
        self.assertEqual(manifest["source_commit"], commit)
        self.assertEqual(manifest["version"], "0.0.0-test")
        self.assertTrue(manifest["source_dirty"])
        self.assertFalse(manifest["review"]["device_verified"])
        self.assertFalse(any(commit.encode() in p.read_bytes() for p in self.output.rglob("*") if p.is_file()))

    def test_internal_commit_in_public_content_blocks_export(self):
        commit = "a" * 40
        self.put("README.md", "Internal mapping: " + commit)
        with mock.patch.dict(G, {"provenance": lambda root: {"source_commit": commit, "source_dirty": True}}):
            with mock.patch("builtins.print"):
                code = M["main"](["export", "--source", str(self.root), "--version", "0.0.0-test",
                                  "--output", str(self.output), "--manifest", str(self.manifest)])
        self.assertEqual(code, 2)
        self.assertFalse(self.output.exists())

    def test_missing_package_resource_and_module_header_block(self):
        self.put("FamilyCore/Package.swift", 'let resources = [.process("MissingAssets")]')
        self.put("FamilyCore/Sources/CSQLite/module.modulemap", 'module CSQLite { header "missing.h" }')
        report, _ = self.audit()
        self.assertEqual(self.errors(report).count("missing-resource"), 2)

    def test_cli_export_requires_real_provenance_before_writing(self):
        result = subprocess.run([sys.executable, "-I", str(TOOL), "export", "--source", str(self.root),
                                 "--version", "0.0.0-test", "--output", str(self.output),
                                 "--manifest", str(self.manifest)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Git provenance", json.loads(result.stdout)["error"])
        self.assertFalse(self.output.exists())
        self.assertFalse(self.manifest.exists())


if __name__ == "__main__":
    unittest.main()
