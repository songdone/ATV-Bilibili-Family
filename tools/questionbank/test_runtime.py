#!/usr/bin/env python3
"""Compile the actual Foundation-only app loader against the actual Core models.
No simulator, UIKit or Core package edits/build directory. Requires macOS Swift.
Generated inputs and binaries are separated, and never executed as scripts.
"""
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
import unittest
import importlib.util

ROOT = Path(__file__).resolve().parents[2]
BANK = ROOT / "BilibiliLive/QuestionBank/grade4-general.json"
spec = importlib.util.spec_from_file_location("bank_tool", Path(__file__).with_name("bank.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

MAIN = r'''
import Foundation
import FamilyCore
@main struct Probe {
    static func main() throws {
        let args = CommandLine.arguments
        do {
            let indexURL = args[3] == "-" ? nil : URL(fileURLWithPath: args[3])
            let bank = try FamilyQuestionBank.load(urls: args[4...].map { URL(fileURLWithPath: $0) }, indexURL: indexURL)
            if args[1] == "validate" {
                print(bank.questions.count)
            } else {
                let curriculum = try JSONDecoder().decode(CurriculumProfile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                let profile = ViewerProfile(displayName: "TEST ONLY", curriculum: curriculum, dailyLimitMilliseconds: 600000)
                if args[1] == "catalog" {
                    print(String(data: try JSONEncoder().encode(bank.catalog), encoding: .utf8)!)
                } else if args[1] == "round" {
                    let round = try bank.makeRound(for: profile, perRound: 5)
                    precondition(round.count == 5 && Set(round.map(\.id)).count == 5)
                    precondition(round.allSatisfy { q in q.options.contains { $0.id == q.answerID } && q.sourceMetadata != nil })
                    print(round.count)
                } else {
                    print(try bank.questions(for: profile).count)
                }
            }
        } catch {
            print(error.localizedDescription)
            exit(2)
        }
    }
}
'''


def profile():
    subjects = ["数学", "语文", "英语", "科学", "道德与法治"]
    return dict(schemaVersion=1, schoolStage="小学", schoolSystem="六三", grade=4,
                academicYear="2026-2027", semester="全年", subjects=subjects,
                subjectTextbookVersions={s: "general_knowledge" for s in subjects},
                learnedChapters={s: ["*"] for s in subjects}, chapterProgress={})


def semester_bank(semester, exact=False):
    """Synthetic runtime-only fixtures; review declarations are not real approvals."""
    value = tool.load_json(BANK)
    value["bankId"] = "TEST_ONLY-semester-gate"
    value["questions"] = [value["questions"][0]]
    question = value["questions"][0]
    question.update(question_id="TEST_ONLY-semester-question", semester=semester)
    index = None
    if exact:
        value["curriculum"] = dict(kind="exact_textbook", alignment="exact_textbook",
                                   description="SYNTHETIC TEST ONLY, not a real textbook")
        question["textbookVersion"] = "TEST_ONLY版"
        repo, commit, path = "test-only/synthetic", "a" * 40, "TEST_ONLY.pdf"
        source = dict(repo=repo, commit=commit, path=path, blobsha="b" * 40,
                      book_id=hashlib.sha256(f"{repo}@{commit}:{path}".encode()).hexdigest())
        question.update(sourceBook=source, sourcePage=dict(pdfPage=1, printedPage=None))
        metadata = {key: question[key] for key in ("stage", "system", "grade", "semester", "subject", "textbookVersion")}
        index = dict(repo=repo, commit=commit, books=[dict(source, format="pdf", metadata=metadata)])
    # Exercise the real loader's review/hash checks with explicit synthetic evidence.
    value["licenseStatus"] = "cleared"
    value["reviewEvidence"].update(
        reviewedBy="SYNTHETIC TEST ONLY", reviewedAt="2020-01-01T00:00:00Z",
        answersVerified=True, provenanceVerified=True, licenseVerified=True,
        reviewType="human", humanReviewed=True, textbookAlignmentVerified=exact,
        notes="SYNTHETIC TEST ONLY, not a real human review",
        licenseBasis="SYNTHETIC TEST ONLY, not a real license",
        reviewedQuestionIDs=[question["question_id"]], contentSHA256=tool.content_digest(value))
    return value, index


class RuntimeLoaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="questionbank-runtime-")
        cls.work = Path(cls.temp.name)
        source = cls.work / "scripts"; source.mkdir()
        build = cls.work / "build"; build.mkdir()
        # Compile the real public models only, not a fake FamilyCore or ledger.
        cmd = ["swiftc", "-swift-version", "5", "-emit-library", "-emit-module", "-module-name", "FamilyCore",
               str(ROOT / "FamilyCore/Sources/FamilyCore/Quiz/QuizModels.swift"),
               str(ROOT / "FamilyCore/Sources/FamilyCore/Models/LedgerModels.swift"),
               "-o", str(build / "libFamilyCore.dylib"), "-emit-module-path", str(build / "FamilyCore.swiftmodule")]
        result = subprocess.run(cmd, cwd=source, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        (source / "main.swift").write_text(MAIN)
        cls.exe = build / "probe"
        result = subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(build),
                                 "-L", str(build), "-lFamilyCore", "-Xlinker", "-rpath", "-Xlinker", str(build),
                                 str(ROOT / "BilibiliLive/FamilyControl/FamilyQuestionBank.swift"),
                                 str(source / "main.swift"), "-o", str(cls.exe)], cwd=source, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_probe(self, mode="select", config=None, paths=None, data=None, raw=None, index=None):
        with tempfile.TemporaryDirectory(dir=self.work, prefix="inputs-") as directory:
            inputs = Path(directory)
            p = inputs / "profile.json"; p.write_text(json.dumps(config or profile(), ensure_ascii=False))
            if data is not None or raw is not None:
                q = inputs / "bank.json"
                q.write_text(raw if raw is not None else json.dumps(data, ensure_ascii=False))
                paths = [q]
            index_path = "-"
            if index is not None:
                index_file = inputs / "book-index.json"
                index_file.write_text(json.dumps(index, ensure_ascii=False))
                index_path = str(index_file)
            result = subprocess.run([str(self.exe), mode, str(p), index_path] + [str(q) for q in (paths if paths is not None else [BANK])],
                                    cwd=self.work / "scripts", capture_output=True, text=True)
            return result.returncode, result.stdout.strip()

    def test_real_80_and_repeated_path(self):
        self.assertEqual(self.run_probe("validate", paths=[BANK, BANK]), (0, "80"))
        self.assertEqual(self.run_probe(), (0, "80"))
        self.assertEqual(self.run_probe("round"), (0, "5"))

    def test_catalog(self):
        code, output = self.run_probe("catalog")
        self.assertEqual(code, 0, output)
        self.assertEqual(len(json.loads(output)), 9)

    def test_missing_or_malformed_is_not_skipped(self):
        for paths in ([], [Path("/nonexistent/missing-bank.json")]):
            self.assertEqual(self.run_probe("validate", paths=paths)[0], 2)
        self.assertEqual(self.run_probe("validate", raw="{broken")[0], 2)

    def test_fail_closed_banks(self):
        mutations = [lambda b: b.update(testOnly=True), lambda b: b.update(reviewEvidence=None),
                     lambda b: b.update(licenseStatus="cleared"),
                     lambda b: b["reviewEvidence"].update(humanReviewed=True),
                     lambda b: b["reviewEvidence"].update(reviewedAt="2999-01-01T00:00:00Z"),
                     lambda b: b["reviewEvidence"].update(reviewedQuestionIDs=["missing"]),
                     lambda b: b["questions"][0].update(answer="Z"),
                     lambda b: b["questions"][0].update(reviewStatus="draft"),
                     lambda b: b["questions"][0].update(prompt="changed without review"),
                     lambda b: b["questions"][0].update(grade=True),
                     lambda b: b["questions"][0].update(grade=4.5),
                     lambda b: b["questions"][0].update(unexpected="field"),
                     lambda b: b["questions"][0]["options"][0].update(text="  ")]
        for mutate in mutations:
            b = tool.load_json(BANK); mutate(b)
            with self.subTest(mutate=mutate):
                self.assertEqual(self.run_probe("validate", data=b)[0], 2)
        b = tool.load_json(BANK); b["questions"].append(b["questions"][0])
        b["reviewEvidence"]["contentSHA256"] = tool.content_digest(b)
        self.assertEqual(self.run_probe("validate", data=b)[0], 2)

    def test_duplicate_json_keys_and_global_ids(self):
        raw = BANK.read_text().replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1', 1)
        self.assertIn("重复键", self.run_probe("validate", raw=raw)[1])
        with tempfile.TemporaryDirectory(dir=self.work) as directory:
            path = Path(directory) / "other.json"
            b = tool.load_json(BANK); b["bankId"] += "-other"
            path.write_text(json.dumps(b, ensure_ascii=False))
            self.assertIn("全局重复", self.run_probe("validate", paths=[BANK, path])[1])

    def test_profile_missing_config_and_no_fallback(self):
        for field, value in [("subjects", []), ("semester", ""),
                             ("schoolStage", "待设置"), ("subjectTextbookVersions", {}), ("learnedChapters", {})]:
            p = profile(); p[field] = value
            self.assertIn("MISSING_CONFIG", self.run_probe(config=p)[1])
        for field, value in [("grade", 3), ("schoolStage", "初中"), ("schoolSystem", "五四")]:
            p = profile(); p[field] = value
            self.assertIn("MISSING_POOL", self.run_probe(config=p)[1])
        p = profile(); p["subjectTextbookVersions"]["数学"] = "不存在的精确教材版"
        self.assertIn("MISSING_POOL", self.run_probe(config=p)[1])

    def test_academic_year_is_optional_legacy_information(self):
        for year in ("", "  ", "待设置", "1999-2000"):
            p = profile(); p["academicYear"] = year
            with self.subTest(year=year):
                self.assertEqual(self.run_probe(config=p), (0, "80"))
                self.assertEqual(self.run_probe("round", config=p), (0, "5"))

    def test_general_full_year_entries_apply_to_both_terms(self):
        bank, _ = semester_bank("full_year")
        p = profile(); p["subjects"] = [bank["questions"][0]["subject"]]
        for semester in ("上", "下", "全年", "first", "second", "full_year", "上学期", "下学期"):
            p["semester"] = semester
            with self.subTest(semester=semester):
                self.assertEqual(self.run_probe(config=p, data=bank), (0, "1"))
        for field, value, reason in (("grade", 3, "MISSING_POOL"),
                                     ("subjectTextbookVersions", {"数学": "错误版本"}, "MISSING_POOL"),
                                     ("learnedChapters", {"数学": []}, "MISSING_CONFIG"),
                                     ("semester", "unknown-term", "MISSING_POOL")):
            invalid = dict(p); invalid[field] = value
            with self.subTest(field=field):
                code, message = self.run_probe(config=invalid, data=bank)
                self.assertEqual(code, 2, message)
                self.assertIn(reason, message)

    def test_general_term_specific_entries_never_fill_opposite_term(self):
        p = profile(); p["subjects"] = ["数学"]
        for bank_term, matching, opposite in (("first", "上", "下"), ("second", "下", "上")):
            bank, _ = semester_bank(bank_term)
            p["semester"] = matching
            self.assertEqual(self.run_probe(config=p, data=bank), (0, "1"))
            p["semester"] = opposite
            code, message = self.run_probe(config=p, data=bank)
            self.assertEqual(code, 2, message)
            self.assertIn("MISSING_POOL", message)
            p["semester"] = "全年"
            self.assertEqual(self.run_probe(config=p, data=bank), (0, "1"))

    def test_exact_textbook_semesters_remain_strict(self):
        p = profile(); p["subjects"] = ["数学"]
        p["subjectTextbookVersions"]["数学"] = "TEST_ONLY版"
        for bank_term in ("first", "second", "full_year"):
            bank, index = semester_bank(bank_term, exact=True)
            for profile_term in ("first", "second", "full_year"):
                p["semester"] = profile_term
                with self.subTest(bank_term=bank_term, profile_term=profile_term):
                    result = self.run_probe(config=p, data=bank, index=index)
                    if profile_term == bank_term:
                        self.assertEqual(result, (0, "1"))
                    else:
                        self.assertEqual(result[0], 2, result[1])
                        self.assertIn("MISSING_POOL", result[1])

    def test_semesters_chapters_and_short_round(self):
        p = profile(); p["subjects"] = ["数学"]
        for semester, count in [("上", "18"), ("下", "22"), ("全年", "40")]:
            p["semester"] = semester
            self.assertEqual(self.run_probe(config=p), (0, count))
        p["learnedChapters"]["数学"] = ["公顷和平方千米"]
        self.assertEqual(self.run_probe(config=p), (0, "2"))
        self.assertIn("INSUFFICIENT_POOL", self.run_probe("round", config=p)[1])
        p["learnedChapters"]["数学"] = []
        self.assertIn("MISSING_CONFIG", self.run_probe(config=p)[1])
        p["learnedChapters"]["数学"] = ["*", "大数的认识"]
        self.assertIn("MISSING_CONFIG", self.run_probe(config=p)[1])


if __name__ == "__main__":
    unittest.main()
