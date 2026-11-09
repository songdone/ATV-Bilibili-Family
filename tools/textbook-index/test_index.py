#!/usr/bin/env python3
"""Offline tests: synthetic trees and mocked gh only; never network calls."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


indexer = module("indexer", Path(__file__).with_name("build_index.py"))
fetcher = module("fetcher", Path(__file__).with_name("fetch_tree.py"))
validator = module("validator", ROOT / "tools/questionbank/bank.py")


def tree(paths, truncated=False):
    return {"sha": "c" * 40, "truncated": truncated,
            "tree": [{"path": path, "sha": "b" * 40, "type": "blob", "size": 123} for path in paths]}


def build(paths, truncated=False):
    return indexer.build(tree(paths, truncated), "test-only/synthetic", "a" * 40)


class IndexTests(unittest.TestCase):
    def test_dynamic_subject_version(self):
        result = build(["小学/TEST_NEW科目/TEST_NEW版/四年级/TEST上册.pdf"])
        book = result["books"][0]
        self.assertEqual(book["metadata"]["subject"], "TEST_NEW科目")
        self.assertEqual(book["metadata"]["textbookVersion"], "TEST_NEW版")
        self.assertEqual(book["metadata"]["grade"], 4)
        self.assertEqual(book["metadata"]["semester"], "first")
        self.assertIsNone(book["metadata"]["system"])
        self.assertEqual(book["reviewStatus"], "needs_review")
        self.assertIsNone(book["officialApproval"])
        validator.schema_validate(result, indexer.load_json(Path(__file__).with_name("book-index.schema.json")))

    def test_explicit_systems_only(self):
        for name, expected in (("小学（五•四学制）", "5_4"), ("初中（六三学制）", "6_3"), ("小学", None)):
            with self.subTest(name=name):
                metadata, _ = indexer.derive(name + "/TEST科目/TEST版/一年级/TEST.pdf")
                self.assertEqual(metadata["system"], expected)

    def test_unknown_top_level_keeps_raw_path(self):
        result = build(["TEST_UNKNOWN/TEST/TEST.pdf"])
        book = result["books"][0]
        self.assertIsNone(book["metadata"]["stage"])
        self.assertIsNone(book["metadata"]["subject"])
        self.assertIn("unknown_stage", book["reviewFlags"])
        self.assertEqual(book["rawSegments"], ["TEST_UNKNOWN", "TEST", "TEST.pdf"])

    def test_higher_education_not_invented_grade_or_version(self):
        metadata, _ = indexer.derive("大学/TEST高等数学/TEST第一册.pdf")
        self.assertEqual(metadata["stage"], "higher_education")
        self.assertEqual(metadata["subject"], "TEST高等数学")
        self.assertIsNone(metadata["grade"])
        self.assertIsNone(metadata["textbookVersion"])
        self.assertIsNone(metadata["semester"])
        self.assertEqual(metadata["volume"], "第一册")

    def test_all_stage_structures(self):
        for name, expected in indexer.STAGES.items():
            with self.subTest(name=name):
                metadata, _ = indexer.derive(name + "/TEST科目/TEST.pdf")
                self.assertEqual(metadata["stage"], expected)

    def test_grade_ranges_ambiguous(self):
        for name in ("1至2年级", "一至二年级", "一、二年级", "一年级二年级"):
            with self.subTest(name=name):
                metadata, flags = indexer.derive("小学/TEST/TEST版/TEST" + name + "全一册.pdf")
                self.assertIsNone(metadata["grade"])
                self.assertIn("ambiguous_grade", flags)

    def test_conflicting_semester(self):
        metadata, flags = indexer.derive("小学/TEST/TEST版/一年级/TEST上册下册.pdf")
        self.assertIsNone(metadata["semester"])
        self.assertIn("ambiguous_semester", flags)

    def test_split_pdf_preserves_blob_provenance(self):
        paths = ["小学/TEST/TEST版/一年级/TEST.pdf_merge_folder/TEST.pdf." + str(i) for i in (1, 2)]
        result = build(paths)
        self.assertEqual(result["statistics"]["logicalDocuments"], 1)
        self.assertEqual(result["statistics"]["indexedBlobs"], 2)
        self.assertEqual([b["part"] for b in result["books"]], [1, 2])
        self.assertTrue(all(b["blobsha"] == "b" * 40 for b in result["books"]))
        self.assertTrue(all("split_document_not_reassembled" in b["reviewFlags"] for b in result["books"]))

    def test_sibling_split_books_are_not_collapsed(self):
        result = build(["TEST/bookA.pdf.1", "TEST/bookA.pdf.2", "TEST/bookB.pdf.1", "TEST/bookB.pdf.2"])
        self.assertEqual(result["statistics"]["logicalDocuments"], 2)
        self.assertEqual({b["logicalDocumentPath"] for b in result["books"]}, {"TEST/bookA.pdf", "TEST/bookB.pdf"})

    def test_non_books_excluded_not_executed(self):
        result = build(["TEST/readme.md", "TEST/payload.exe", "TEST/json.py", "TEST/book.PDF", "TEST/book.djvu"])
        self.assertEqual(result["statistics"]["indexedBlobs"], 2)
        self.assertEqual(result["statistics"]["ignoredBlobs"], 3)

    def test_empty_not_complete(self):
        self.assertEqual(build([])["status"], "empty_inventory")

    def test_truncated_not_complete(self):
        result = build(["TEST/test.pdf"], truncated=True)
        self.assertEqual(result["status"], "partial_tree")

    def test_explicit_truncated_required(self):
        value = tree([])
        del value["truncated"]
        with self.assertRaises(ValueError):
            indexer.build(value, "test-only/synthetic", "a" * 40)

    def test_pinned_sha_required(self):
        for sha in ("HEAD", "main", "a" * 39):
            with self.assertRaises(ValueError):
                indexer.build(tree([]), "test-only/synthetic", sha)

    def test_bad_blob_sha(self):
        value = tree(["TEST.pdf"])
        value["tree"][0]["sha"] = "bad"
        with self.assertRaises(ValueError):
            indexer.build(value, "test-only/synthetic", "a" * 40)

    def test_duplicate_paths_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate tree path"):
            build(["TEST.pdf", "TEST.pdf"])

    def test_unsafe_paths_rejected(self):
        for path in ("../TEST.pdf", "/TEST.pdf", "x/../TEST.pdf", "x\\TEST.pdf"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                build([path])

    def test_deterministic_and_provenance_sensitive(self):
        paths = ["TEST/b.pdf", "TEST/a.pdf"]
        first = build(paths)
        self.assertEqual(first, build(list(reversed(paths))))
        changed = indexer.build(tree(paths), "test-only/synthetic", "d" * 40)
        self.assertNotEqual(first["books"][0]["book_id"], changed["books"][0]["book_id"])

    def test_fetch_exactly_two_mocked_metadata_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest_path = Path(directory) / "manifest.json"
            calls = []
            def fake_run(command, **kwargs):
                calls.append(command)
                if len(calls) == 1:
                    return subprocess.CompletedProcess(command, 0, json.dumps({"commit": "a" * 40, "tree": "c" * 40}), "")
                kwargs["stdout"].write(json.dumps(tree(["TEST.pdf"])).encode())
                return subprocess.CompletedProcess(command, 0)
            with patch.object(fetcher.subprocess, "run", side_effect=fake_run), patch("builtins.print"):
                self.assertEqual(fetcher.fetch(directory, manifest_path), 0)
            manifest = indexer.load_json(manifest_path)
            self.assertEqual(manifest["networkAttempts"], 2)
            self.assertEqual(len(calls), 2)
            self.assertIn("git/trees/" + "c" * 40 + "?recursive=1", calls[1][-1])
            self.assertTrue(Path(manifest["treeArtifact"]).is_file())
            self.assertFalse(manifest["pdfDownloaded"])

    def test_network_failure_does_not_retry_or_claim_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            with patch.object(fetcher.subprocess, "run", side_effect=OSError("TEST network unavailable")) as run, patch("builtins.print"):
                self.assertEqual(fetcher.fetch(directory, manifest), 2)
                self.assertEqual(run.call_count, 1)
            result = indexer.load_json(manifest)
            self.assertEqual(result["status"], "blocked")
            self.assertIsNone(result["statistics"])
            self.assertIsNone(result["commit"])

    def test_second_call_failure_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            first = subprocess.CompletedProcess([], 0, json.dumps({"commit": "a" * 40, "tree": "c" * 40}), "")
            with patch.object(fetcher.subprocess, "run", side_effect=[first, OSError("TEST blocked")]) as run, patch("builtins.print"):
                self.assertEqual(fetcher.fetch(directory, manifest), 2)
                self.assertEqual(run.call_count, 2)
            result = indexer.load_json(manifest)
            self.assertEqual(result["commit"], "a" * 40)
            self.assertEqual(result["status"], "blocked")
            self.assertIsNone(result["treeArtifact"])

    def test_fetch_rejects_project_download_destination(self):
        with patch.object(fetcher.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "outside the project"):
                fetcher.fetch(ROOT / "tools/textbook-index", ROOT / "TEST_NOT_WRITTEN.json")
            run.assert_not_called()

    def test_tree_hash_tampering_cli_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tree_path, manifest, output = root / "tree.json", root / "manifest.json", root / "index.json"
            indexer.write_json(tree_path, tree([]))
            indexer.write_json(manifest, {"treeSHA256": "0" * 64})
            result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("build_index.py")),
                                     "--tree", str(tree_path), "--manifest", str(manifest), "--output", str(output)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("SHA256", result.stderr)
            self.assertFalse(output.exists())

    def test_real_artifact_when_available(self):
        # Optional local evidence check; portable suite never downloads to satisfy it.
        manifest = indexer.load_json(Path(__file__).with_name("sources.json"))
        artifact_dir = os.environ.get("TEXTBOOK_ARTIFACT_DIR")
        if not artifact_dir:
            self.skipTest("set TEXTBOOK_ARTIFACT_DIR for real tree verification; no network fallback")
        artifact = Path(artifact_dir) / "downloads" / "tree.json"
        self.assertTrue(artifact.is_file(), "TEXTBOOK_ARTIFACT_DIR does not contain downloads/tree.json")
        raw = artifact.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), manifest["treeSHA256"])
        result = indexer.build(json.loads(raw), manifest["repo"], manifest["commit"])
        self.assertEqual(result["statistics"], manifest["statistics"])
        validator.schema_validate(result, indexer.load_json(Path(__file__).with_name("book-index.schema.json")))
        self.assertGreater(result["statistics"]["indexedBlobs"], 0)
        self.assertTrue(all(b["officialApproval"] is None for b in result["books"]))


if __name__ == "__main__":
    unittest.main()
