#!/usr/bin/env python3
"""All data here is synthetic test-only, including in-memory approval claims."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


bank = module("question_bank", Path(__file__).with_name("bank.py"))
indexer = module("book_index", ROOT / "tools/textbook-index/build_index.py")
FIXTURE = ROOT / "QuestionBank/fixtures/synthetic.test-only.json"


def draft():
    return bank.load_json(FIXTURE)


def approved():
    # These forged review flags exercise the gate ONLY in memory, never a real bank.
    value = draft()
    value["testOnly"] = False
    value["licenseStatus"] = "cleared"
    value["questions"][0]["reviewStatus"] = "approved"
    value["reviewEvidence"] = {
        "reviewedBy": "SYNTHETIC TEST REVIEWER (not a real reviewer)",
        "reviewedAt": "2020-01-01T00:00:00Z", "answersVerified": True,
        "provenanceVerified": True, "licenseVerified": True, "notes": "TEST-ONLY in-memory gate simulation",
        "reviewType": "human", "humanReviewed": True, "textbookAlignmentVerified": True,
        "licenseBasis": "SYNTHETIC TEST ONLY, NOT REAL LICENSE CLEARANCE",
        "reviewedQuestionIDs": [q["question_id"] for q in value["questions"]],
        "contentSHA256": bank.content_digest(value),
    }
    return value


def sourced():
    path = "小学（六三学制）/TEST_ONLY_SUBJECT/TEST_ONLY版/一年级/TEST_ONLY上册.pdf"
    index = indexer.build({"sha": "c" * 40, "truncated": False,
                           "tree": [{"path": path, "type": "blob", "sha": "b" * 40, "size": 1}]},
                          "test-only/synthetic", "a" * 40)
    value = approved()
    value["curriculum"] = {"kind": "exact_textbook", "alignment": "exact_textbook", "description": "TEST ONLY exact-source gate simulation"}
    q = value["questions"][0]
    q["textbookVersion"] = "TEST_ONLY版"
    q["sourceBook"] = {key: index["books"][0][key] for key in ("repo", "commit", "path", "blobsha", "book_id")}
    q["sourcePage"] = {"pdfPage": 1, "printedPage": None}
    value["reviewEvidence"]["contentSHA256"] = bank.content_digest(value)
    return value, index


class QuestionBankTests(unittest.TestCase):
    def test_draft_fixture_valid_only_as_draft(self):
        self.assertIs(bank.validate_bank(draft())["testOnly"], True)
        with self.assertRaisesRegex(bank.ValidationError, "test-only"):
            bank.validate_bank(draft(), runtime=True)

    def test_all_question_fields_required(self):
        value = draft()
        for key in list(value["questions"][0]):
            with self.subTest(field=key):
                broken = copy.deepcopy(value)
                del broken["questions"][0][key]
                with self.assertRaisesRegex(bank.ValidationError, "missing required field"):
                    bank.validate_bank(broken)

    def test_all_bank_fields_required(self):
        for key in draft():
            with self.subTest(field=key):
                value = draft()
                del value[key]
                with self.assertRaises(bank.ValidationError):
                    bank.validate_bank(value)

    def test_unknown_fields_rejected(self):
        value = draft()
        value["questions"][0]["officiallyApproved"] = True
        with self.assertRaisesRegex(bank.ValidationError, "unknown fields"):
            bank.validate_bank(value)

    def test_duplicate_question_id_rejected(self):
        value = draft()
        value["questions"].append(copy.deepcopy(value["questions"][0]))
        with self.assertRaisesRegex(bank.ValidationError, "duplicate question_id"):
            bank.validate_bank(value)

    def test_invalid_answer_option_rejected(self):
        for answer in ("C", ["A", "C"]):
            with self.subTest(answer=answer):
                value = draft()
                q = value["questions"][0]
                q["answer"] = answer
                if isinstance(answer, list):
                    q["type"] = "multiple_choice"
                with self.assertRaisesRegex(bank.ValidationError, "answer not in option"):
                    bank.validate_bank(value)

    def test_choice_answer_shapes_rejected(self):
        for kind, answer in (("single_choice", ["A", "B"]), ("multiple_choice", "A"),
                             ("multiple_choice", ["A"]), ("multiple_choice", ["A", "A"]),
                             ("true_false", ["A", "B"]), ("single_choice", True)):
            with self.subTest(kind=kind, answer=answer):
                value = draft()
                value["questions"][0].update(type=kind, answer=answer)
                with self.assertRaises(bank.ValidationError):
                    bank.validate_bank(value)

    def test_valid_multiple_choice(self):
        value = draft()
        value["questions"][0].update(type="multiple_choice", answer=["A", "B"])
        bank.validate_bank(value)

    def test_true_false_requires_explicit_ids(self):
        value = draft()
        q = value["questions"][0]
        q["type"] = "true_false"
        with self.assertRaisesRegex(bank.ValidationError, "true_false"):
            bank.validate_bank(value)
        q.update(options=[{"id": "true", "text": "TEST true"}, {"id": "false", "text": "TEST false"}], answer="true")
        bank.validate_bank(value)

    def test_short_answer_has_no_options(self):
        value = draft()
        q = value["questions"][0]
        q["type"] = "short_answer"
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)
        q["options"] = []
        bank.validate_bank(value)

    def test_duplicate_option_ids_rejected(self):
        value = draft()
        value["questions"][0]["options"][1]["id"] = "A"
        with self.assertRaisesRegex(bank.ValidationError, "duplicate option id"):
            bank.validate_bank(value)

    def test_too_few_options_rejected(self):
        value = draft()
        value["questions"][0]["options"].pop()
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)

    def test_invalid_question_type_rejected(self):
        value = draft()
        value["questions"][0]["type"] = "guess"
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)

    def test_grade_bounds_and_boolean_rejected(self):
        for stage, system, grade in (("primary", "6_3", 7), ("primary", "5_4", 6),
                                     ("junior_secondary", "6_3", 6), ("junior_secondary", "5_4", 5),
                                     ("senior_secondary", "6_3", 9), ("senior_secondary", "6_3", 13),
                                     ("higher_education", "not_applicable", 1),
                                     ("primary", "6_3", True), ("primary", "6_3", 0)):
            with self.subTest(stage=stage, system=system, grade=grade):
                value = draft()
                value["questions"][0].update(stage=stage, system=system, grade=grade)
                with self.assertRaises(bank.ValidationError):
                    bank.validate_bank(value)

    def test_valid_grade_boundaries(self):
        for stage, system, grades in (("primary", "6_3", [1, 6]), ("primary", "5_4", [1, 5]),
                                      ("junior_secondary", "6_3", [7, 9]), ("junior_secondary", "5_4", [6, 9]),
                                      ("senior_secondary", "not_applicable", [10, 12]),
                                      ("higher_education", "not_applicable", [None])):
            for grade in grades:
                with self.subTest(stage=stage, grade=grade):
                    value = draft()
                    value["questions"][0].update(stage=stage, system=system, grade=grade)
                    bank.validate_bank(value)

    def test_unknown_metadata_stays_draft(self):
        value = draft()
        for axis in bank.AXES:
            if axis != "textbookVersion":
                value["questions"][0][axis] = None
        bank.validate_bank(value)
        value["questions"][0]["reviewStatus"] = "approved"
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)

    def test_invalid_review_status_rejected(self):
        value = draft()
        value["questions"][0]["reviewStatus"] = "auto_approved"
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)

    def test_no_unreviewed_runtime_even_mixed_pool(self):
        for status in ("needs_review", "draft", "rejected"):
            with self.subTest(status=status):
                value = approved()
                q = copy.deepcopy(value["questions"][0])
                q.update(question_id="TEST-UNAPPROVED", reviewStatus=status)
                value["questions"].append(q)
                with self.assertRaisesRegex(bank.ValidationError, "unreviewed"):
                    bank.validate_bank(value, runtime=True)

    def test_approval_requires_complete_evidence(self):
        for field in ("answersVerified", "provenanceVerified", "licenseVerified"):
            with self.subTest(field=field):
                value = approved()
                value["reviewEvidence"][field] = False
                with self.assertRaises(bank.ValidationError):
                    bank.validate_bank(value, runtime=True)
        value = approved()
        value["reviewEvidence"] = None
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)

    def test_invalid_review_dates(self):
        for stamp in ("2020-99-01T00:00:00Z", "2020-01-01T00:00:00", "2999-01-01T00:00:00Z"):
            with self.subTest(stamp=stamp):
                value = approved()
                value["reviewEvidence"]["reviewedAt"] = stamp
                with self.assertRaises(bank.ValidationError):
                    bank.validate_bank(value)

    def test_license_gate(self):
        for status in ("needs_review", "denied", "test_only"):
            value = approved()
            value["licenseStatus"] = status
            with self.assertRaises(bank.ValidationError):
                bank.validate_bank(value, runtime=True)

    def test_general_curriculum_cannot_claim_exact(self):
        value = draft()
        value["curriculum"]["alignment"] = "exact_textbook"
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)
        value = draft()
        value["questions"][0]["textbookVersion"] = "TEST pretend textbook"
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)

    def test_valid_exact_source(self):
        value, index = sourced()
        bank.validate_bank(value, index, runtime=True)

    def test_exact_approved_requires_source_and_index(self):
        value, index = sourced()
        with self.assertRaisesRegex(bank.ValidationError, "requires pinned"):
            bank.validate_bank(value)
        value["questions"][0].update(sourceBook=None, sourcePage=None)
        with self.assertRaisesRegex(bank.ValidationError, "needs book and page"):
            bank.validate_bank(value, index)

    def test_source_page_positive_integer(self):
        for page in (0, -1, True, 1.5, "2"):
            with self.subTest(page=page):
                value, index = sourced()
                value["questions"][0]["sourcePage"]["pdfPage"] = page
                with self.assertRaises(bank.ValidationError):
                    bank.validate_bank(value, index)

    def test_source_and_page_paired(self):
        value, index = sourced()
        value["questions"][0]["sourcePage"] = None
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value, index)

    def test_source_blob_mismatch(self):
        value, index = sourced()
        value["questions"][0]["sourceBook"]["blobsha"] = "d" * 40
        with self.assertRaisesRegex(bank.ValidationError, "provenance mismatch"):
            bank.validate_bank(value, index)

    def test_missing_source_no_fallback(self):
        value, index = sourced()
        index["books"] = []
        with self.assertRaisesRegex(bank.ValidationError, "book missing.*no fallback"):
            bank.validate_bank(value, index)

    def test_source_axis_mismatch_rejected(self):
        for axis, replacement in (("grade", 2), ("semester", "second"), ("system", "5_4"),
                                   ("subject", "TEST_OTHER"), ("textbookVersion", "TEST_OTHER版")):
            with self.subTest(axis=axis):
                value, index = sourced()
                value["questions"][0][axis] = replacement
                with self.assertRaisesRegex(bank.ValidationError, "metadata mismatch"):
                    bank.validate_bank(value, index)

    def test_strict_selection_all_six_axes(self):
        value = approved()
        selector = {axis: value["questions"][0][axis] for axis in bank.AXES}
        self.assertEqual(len(bank.select_pool([value], selector, "general_knowledge")), 1)
        alternatives = dict(stage="junior_secondary", system="5_4", grade=2,
                            semester="second", subject="TEST_OTHER", textbookVersion="TEST_OTHER版")
        for axis, other in alternatives.items():
            with self.subTest(axis=axis):
                changed = dict(selector, **{axis: other})
                with self.assertRaises(bank.MissingPoolError):
                    bank.select_pool([value], changed, "general_knowledge")
        with self.assertRaises(bank.MissingPoolError):
            bank.select_pool([value], selector, "exact_textbook")

    def test_multiple_versions_no_fallback(self):
        first, index = sourced()
        second = copy.deepcopy(first)
        second["bankId"] += "-second"
        second["questions"][0]["question_id"] += "-second"
        # Explicit unknown source version permits separate manual version claims.
        index["books"][0]["metadata"]["textbookVersion"] = None
        second["questions"][0]["textbookVersion"] = "TEST_SECOND版"
        second["reviewEvidence"]["contentSHA256"] = bank.content_digest(second)
        second["reviewEvidence"]["reviewedQuestionIDs"] = [q["question_id"] for q in second["questions"]]
        selector = {axis: first["questions"][0][axis] for axis in bank.AXES}
        pool = bank.select_pool([first, second], selector, "exact_textbook", index)
        self.assertEqual([q["question_id"] for q in pool], ["TEST-ONLY-001"])
        selector["textbookVersion"] = "TEST_MISSING版"
        with self.assertRaises(bank.MissingPoolError):
            bank.select_pool([first, second], selector, "exact_textbook", index)

    def test_duplicate_id_across_banks(self):
        value = approved()
        other = copy.deepcopy(value)
        other["bankId"] += "-other"
        selector = {axis: value["questions"][0][axis] for axis in bank.AXES}
        with self.assertRaisesRegex(bank.ValidationError, "duplicate question_id across"):
            bank.select_pool([value, other], selector, "general_knowledge")

    def test_empty_banks_missing_pool(self):
        selector = {axis: approved()["questions"][0][axis] for axis in bank.AXES}
        with self.assertRaises(bank.MissingPoolError):
            bank.select_pool([], selector, "general_knowledge")

    def test_empty_bank_invalid(self):
        value = draft()
        value["questions"] = []
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)

    def test_missing_selector_axis_rejected(self):
        with self.assertRaisesRegex(bank.ValidationError, "six selection axes"):
            bank.select_pool([approved()], {}, "general_knowledge")

    def test_duplicate_json_key_and_nonfinite_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "untrusted.json"
            for text in ('{"a": 1, "a": 2}', '{"a": NaN}', '{"a": Infinity}'):
                path.write_text(text, encoding="utf-8")
                with self.assertRaises(bank.ValidationError):
                    bank.load_json(path)

    def test_blank_strings_rejected(self):
        value = draft()
        value["questions"][0]["prompt"] = "   "
        with self.assertRaises(bank.ValidationError):
            bank.validate_bank(value)

    def test_schema_unsupported_and_remote_ref_fail(self):
        for schema in ({"$ref": "https://invalid.example/schema.json"}, {"format": "date"}):
            with self.assertRaises(bank.ValidationError):
                bank.schema_validate("test", schema)

    def test_cli_isolated_import_and_runtime_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "draft.json"
            command = [sys.executable, "-I", str(Path(__file__).with_name("bank.py"))]
            result = subprocess.run(command + ["import", str(FIXTURE), "--output", str(target)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(command + ["validate", str(target), "--runtime"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("test-only", result.stderr)
            result = subprocess.run(command + ["import", str(FIXTURE), "--output", str(target)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)  # existing data is not overwritten

    def test_cli_missing_bank_explicit(self):
        result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("bank.py")),
                                 "validate", "/nonexistent/TEST_ONLY_missing_bank.json"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("No such file", result.stderr)


class ShippedContentTests(unittest.TestCase):
    """Regression checks after AI review, NOT independent teacher or legal review."""
    def setUp(self):
        self.value = bank.load_json(ROOT / "BilibiliLive/QuestionBank/grade4-general.json")

    def profile(self):
        subjects = ["数学", "语文", "英语", "科学", "道德与法治"]
        return dict(schoolStage="小学", schoolSystem="六三", grade=4, academicYear="2026-2027",
                    semester="全年", subjects=subjects,
                    subjectTextbookVersions={s: "general_knowledge" for s in subjects},
                    learnedChapters={s: ["*"] for s in subjects})

    def test_actual_counts_and_no_all_a_shortcut(self):
        from collections import Counter
        qs = self.value["questions"]
        bank.validate_bank(self.value, runtime=True)
        self.assertEqual(len(qs), 80)
        self.assertEqual(Counter(q["subject"] for q in qs), {"数学": 40, "语文": 10, "英语": 10, "科学": 10, "道德与法治": 10})
        self.assertEqual(Counter(q["answer"] for q in qs), dict.fromkeys("ABCD", 20))
        expected = {"数学": (18, 22), "语文": (10, 0), "英语": (7, 3), "科学": (5, 5), "道德与法治": (6, 4)}
        for subject, counts in expected.items():
            actual = Counter(q["semester"] for q in qs if q["subject"] == subject)
            self.assertEqual((actual["first"], actual["second"]), counts)

    def test_all_eighty_semantic_answers_preserved(self):
        # Independently specified expected answer TEXT, not old answer IDs.
        expected = {
            "M": ["50080000", "十万位和千万位", "246 万", "10000 平方米", "4 公顷", "线段", "钝角", "2000", "1740 元", "两组",
                  "上底和下底", "长方形", "9", "29 余 3", "4 格", "9 分钟", "305000000", "5", "0", "乘法",
                  "3", "1100", "(a+b)+c=a+(b+c)", "35 个", "100 倍", "3.6", "大小相等，计数单位不同", "2 个", "100°", "180°",
                  "4.14", "2", "完全重合", "28", "12 只", "4.2", "百分位", "0.09", "位置", "3 个"],
            "C": ["yá", "苏轼", "因为", "鹅毛大雪", "AABB 式", "我们把教室打扫干净了。", "轮", "叶圣陶", "拟人", "帮助别人，自己也会收获快乐"],
            "E": ["apple", "am", "library", "seven o'clock", "boxes", "What's", "coat", "What's", "去上学", "Yes, it is."],
            "S": ["物体振动产生的", "氧气", "淀粉", "小肠", "铁", "水分", "太阳能", "变大", "一个月", "荤素搭配，按时吃饭"],
            "D": ["人行横道（斑马线）", "119", "120", "有害垃圾", "认真负责地完成任务", "冷静沟通，必要时请老师帮助", "北京", "五星红旗", "坐稳扶好，系好安全带", "珍惜粮食，不浪费食物"],
        }
        actual = {q["question_id"]: next(o["text"] for o in q["options"] if o["id"] == q["answer"]) for q in self.value["questions"]}
        expected = {f"G4{subject}-{i:03d}": text for subject, texts in expected.items() for i, text in enumerate(texts, 1)}
        self.assertEqual(actual, expected)

    def test_balance_is_reproducible_idempotent_and_keeps_text(self):
        original = copy.deepcopy(self.value)
        bank.balance_options(self.value)
        self.assertEqual(self.value, original)
        # Reversing input order does not change each question's option placement.
        self.value["questions"].reverse()
        bank.balance_options(self.value)
        self.assertEqual(sorted(self.value["questions"], key=lambda q: q["question_id"]),
                         sorted(original["questions"], key=lambda q: q["question_id"]))

    def test_honest_ai_disclosures_and_corrections(self):
        e = self.value["reviewEvidence"]
        self.assertEqual(e["reviewType"], "ai")
        self.assertFalse(e["humanReviewed"])
        self.assertFalse(e["licenseVerified"])
        self.assertFalse(e["textbookAlignmentVerified"])
        self.assertEqual(self.value["licenseStatus"], "ai_assessed")
        qs = {q["question_id"]: q for q in self.value["questions"]}
        self.assertIn("镉镍", qs["G4D-004"]["prompt"])
        self.assertIn("无汞碱性干电池通常属于其他垃圾", qs["G4D-004"]["explanation"])
        self.assertIn("并不是纯二氧化碳", qs["G4S-002"]["explanation"])
        self.assertIn("苏轼", e["licenseBasis"])
        self.assertIn("朱用纯", e["licenseBasis"])

    def test_ai_evidence_rejects_unsupported_claims_and_tampering(self):
        for field, value in [("humanReviewed", True), ("textbookAlignmentVerified", True),
                             ("licenseVerified", True), ("reviewedQuestionIDs", ["missing"]),
                             ("notes", "no limitations"), ("contentSHA256", "0" * 64)]:
            changed = copy.deepcopy(self.value); changed["reviewEvidence"][field] = value
            with self.subTest(field=field), self.assertRaises(bank.ValidationError):
                bank.validate_bank(changed, runtime=True)
        self.value["questions"][0]["prompt"] += "changed"
        with self.assertRaisesRegex(bank.ValidationError, "digest mismatch"):
            bank.validate_bank(self.value, runtime=True)

    def test_profile_config_no_fallback_and_whole_year(self):
        p = self.profile()
        self.assertEqual(len(bank.select_profile([self.value], p, 5)), 80)
        for subject, count in [("数学", 40), ("语文", 10), ("科学", 10), ("英语", 10), ("道德与法治", 10)]:
            p["subjects"] = [subject]
            self.assertEqual(len(bank.select_profile([self.value], p, 5)), count)
        p["subjects"] = ["数学"]
        for semester, count in [("上", 18), ("下", 22)]:
            p["semester"] = semester
            self.assertEqual(len(bank.select_profile([self.value], p, 5)), count)
        p["subjectTextbookVersions"]["数学"] = "精确教材不存在"
        with self.assertRaises(bank.MissingPoolError):
            bank.select_profile([self.value], p, 5)

    def test_empty_config_is_not_all(self):
        for field, value in [("subjects", []), ("semester", "待设置"), ("academicYear", ""),
                             ("subjectTextbookVersions", {}), ("learnedChapters", {})]:
            p = self.profile(); p[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(bank.ValidationError, "MISSING_CONFIG"):
                bank.select_profile([self.value], p, 5)
        p = self.profile(); p["learnedChapters"]["数学"] = ["*", "大数的认识"]
        with self.assertRaisesRegex(bank.ValidationError, "MISSING_CONFIG"):
            bank.select_profile([self.value], p, 5)

    def test_chapter_pool_insufficient_never_shortens_round(self):
        p = self.profile(); p["subjects"] = ["数学"]
        p["learnedChapters"]["数学"] = ["公顷和平方千米"]
        self.assertEqual(len(bank.select_profile([self.value], p, 2)), 2)
        with self.assertRaisesRegex(bank.MissingPoolError, "INSUFFICIENT_POOL"):
            bank.select_profile([self.value], p, 5)
        p["learnedChapters"]["数学"] = ["尚不存在的章节"]
        with self.assertRaises(bank.MissingPoolError):
            bank.select_profile([self.value], p, 1)

    def test_paths_deduplicated_but_ids_not_silently_dropped(self):
        path = ROOT / "BilibiliLive/QuestionBank/grade4-general.json"
        self.assertEqual(len(bank.load_banks([path, path])), 1)
        b = copy.deepcopy(self.value); b["bankId"] += "-other"
        with self.assertRaisesRegex(bank.ValidationError, "duplicate question_id across"):
            bank.select_profile([self.value, b], self.profile(), 5)

    def test_exact_full_year_does_not_merge_semesters(self):
        value, index = sourced()
        selector = {axis: value["questions"][0][axis] for axis in bank.AXES}
        selector["semester"] = "full_year"
        with self.assertRaises(bank.MissingPoolError):
            bank.select_pool([value], selector, "exact_textbook", index)


if __name__ == "__main__":
    unittest.main()
