#!/usr/bin/env python3
"""Strict offline question-bank import and exact runtime selection (Python 3 -I).
Only the standard library is used. No network, dynamic input imports, or fallback.
"""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import sys

SCHEMA = Path(__file__).resolve().parents[2] / "QuestionBank" / "question.schema.json"
AXES = ("stage", "system", "grade", "semester", "subject", "textbookVersion")


class ValidationError(ValueError):
    pass


class MissingPoolError(ValidationError):
    pass


def load_json(path):
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValidationError("duplicate JSON key: " + key)
            obj[key] = value
        return obj
    def nonfinite(value):
        raise ValidationError("non-finite JSON number: " + value)
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique,
                          parse_constant=nonfinite)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(str(exc)) from exc


def json_equal(a, b):
    # JSON booleans are never equal to integers (unlike Python True == 1).
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(json_equal(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(json_equal(x, y) for x, y in zip(a, b))
    return a == b


def schema_validate(value, schema, root=None, at="$"):
    """Validate the explicitly supported local JSON Schema subset, fail closed.
    This is not a general-purpose draft-2020-12 implementation. The shipped
    schemas use only these keywords; remote references are never resolved.
    """
    root = schema if root is None else root
    supported = {"$schema", "$id", "title", "description", "$defs", "$ref", "type", "const",
                 "enum", "required", "properties", "additionalProperties", "items", "minItems",
                 "maxItems", "uniqueItems", "minLength", "pattern", "minimum", "maximum",
                 "allOf", "anyOf", "oneOf", "if", "then", "else"}
    unknown = set(schema) - supported
    if unknown:
        raise ValidationError(at + ": unsupported schema keyword " + str(sorted(unknown)))
    def fail(message):
        raise ValidationError(at + ": " + message)
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/"):
            fail("only local schema references are supported")
        target = root
        try:
            for segment in ref[2:].split("/"):
                target = target[segment.replace("~1", "/").replace("~0", "~")]
        except (KeyError, TypeError):
            fail("unresolved local schema reference")
        schema_validate(value, target, root, at)
    if "type" in schema:
        kinds = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        matches = {"null": value is None, "object": type(value) is dict,
                   "array": type(value) is list, "string": type(value) is str,
                   "integer": type(value) is int, "boolean": type(value) is bool,
                   "number": type(value) in (int, float) and math.isfinite(value)}
        if not any(matches.get(kind, False) for kind in kinds):
            fail("expected " + str(kinds))
    if "const" in schema and not json_equal(value, schema["const"]):
        fail("unexpected constant")
    if "enum" in schema and not any(json_equal(value, option) for option in schema["enum"]):
        fail("value outside enum")
    if type(value) is dict:
        for field in schema.get("required", []):
            if field not in value:
                fail("missing required field " + field)
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False and set(value) - set(props):
            fail("unknown fields: " + str(sorted(set(value) - set(props))))
        for key in value:
            if key in props:
                schema_validate(value[key], props[key], root, at + "." + key)
    if type(value) is list:
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", len(value)):
            fail("invalid array length")
        if schema.get("uniqueItems") and any(json_equal(value[i], value[j]) for i in range(len(value)) for j in range(i)):
            fail("duplicate array item")
        if "items" in schema:
            for i, item in enumerate(value):
                schema_validate(item, schema["items"], root, at + "[" + str(i) + "]")
    if type(value) is str:
        if len(value) < schema.get("minLength", 0):
            fail("string too short")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            fail("string pattern mismatch")
    if type(value) in (int, float):
        if value < schema.get("minimum", value) or value > schema.get("maximum", value):
            fail("number out of bounds")
    for child in schema.get("allOf", []):
        schema_validate(value, child, root, at)
    for keyword in ("anyOf", "oneOf"):
        if keyword in schema:
            count = 0
            for child in schema[keyword]:
                try:
                    schema_validate(value, child, root, at)
                    count += 1
                except ValidationError:
                    pass
            if count == 0 or (keyword == "oneOf" and count != 1):
                fail(keyword + " does not match")
    if "if" in schema:
        try:
            schema_validate(value, schema["if"], root, at)
            branch = "then"
        except ValidationError:
            branch = "else"
        if branch in schema:
            schema_validate(value, schema[branch], root, at)


def ensure(condition, message):
    if not condition:
        raise ValidationError(message)


def validate_grade(question):
    stage, system, grade = (question[key] for key in ("stage", "system", "grade"))
    if stage in ("primary", "junior_secondary"):
        ensure(system in (None, "6_3", "5_4"), "K12 stage requires 6_3 or 5_4 system")
    if grade is None:
        return
    if stage == "primary":
        ensure(1 <= grade <= (5 if system == "5_4" else 6), "primary grade out of bounds")
    elif stage == "junior_secondary":
        lower = 6 if system in ("5_4", None) else 7
        ensure(lower <= grade <= 9, "junior grade out of bounds")
    elif stage == "senior_secondary":
        ensure(10 <= grade <= 12, "senior grade must use absolute years 10..12")
    elif stage in ("preschool", "higher_education", "vocational", "special_education", "other"):
        ensure(False, "non-K12 grade uses null, not an inferred K12 year")


def content_digest(bank):
    """Integrity binding, NOT a signature or proof of review/rights."""
    payload = {k: bank[k] for k in ("curriculum", "questions")}
    return hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":")).encode("utf-8")).hexdigest()


def review_evidence(bank):
    evidence = bank["reviewEvidence"]
    ensure(evidence is not None, "approved content requires reviewEvidence")
    ensure(evidence["answersVerified"] and evidence["provenanceVerified"],
           "answer/provenance review incomplete")
    ensure(set(evidence["reviewedQuestionIDs"]) == {q["question_id"] for q in bank["questions"]},
           "review evidence must cover every question")
    ensure(evidence["contentSHA256"] == content_digest(bank), "review evidence content digest mismatch")
    if evidence["reviewType"] == "ai":
        ensure(not evidence["humanReviewed"] and not evidence["textbookAlignmentVerified"],
               "AI review must not claim human/textbook review")
        ensure(not evidence["licenseVerified"] and bank["licenseStatus"] == "ai_assessed",
               "AI assessment is not legal license clearance")
        ensure(bank["curriculum"]["kind"] == "general_knowledge", "AI-only release is general knowledge only")
        ensure("AI" in evidence["reviewedBy"], "AI reviewer must be identified explicitly")
        ensure(all(text in evidence["notes"] for text in ("AI核对+结构校验", "非教师/出版社审定", "未逐教材匹配")),
               "AI review must disclose limitations")
    else:
        ensure(evidence["humanReviewed"] and evidence["licenseVerified"] and bank["licenseStatus"] == "cleared",
               "human approval requires human review and license clearance")
        if bank["curriculum"]["kind"] == "exact_textbook":
            ensure(evidence["textbookAlignmentVerified"], "exact textbook requires verified alignment")
    try:
        stamp = datetime.datetime.fromisoformat(evidence["reviewedAt"].replace("Z", "+00:00"))
        ensure(stamp.tzinfo is not None, "reviewedAt needs timezone")
        ensure(stamp <= datetime.datetime.now(datetime.timezone.utc), "review cannot be future-dated")
    except ValueError as exc:
        raise ValidationError("invalid reviewedAt timestamp") from exc


def validate_bank(bank, index=None, runtime=False):
    schema_validate(bank, load_json(SCHEMA))
    # Reject whitespace-only human text, including nested options/evidence.
    def strings(value):
        if type(value) is str:
            ensure(bool(value.strip()), "blank text is not allowed")
        elif type(value) is dict:
            for child in value.values():
                strings(child)
        elif type(value) is list:
            for child in value:
                strings(child)
    strings(bank)
    if runtime:
        ensure(not bank["testOnly"], "test-only fixture cannot be a runtime pool")
        ensure(all(q["reviewStatus"] == "approved" for q in bank["questions"]),
               "runtime pool contains unreviewed or rejected content")
        ensure(all(q["type"] in ("single_choice", "true_false") for q in bank["questions"]),
               "runtime supports single_choice/true_false only")
    indexed = {}
    if index is not None:
        index_schema = SCHEMA.parents[1] / "tools" / "textbook-index" / "book-index.schema.json"
        schema_validate(index, load_json(index_schema))
        for book in index["books"]:
            ensure(book["book_id"] not in indexed, "duplicate book_id in index")
            ensure(book["repo"] == index["repo"] and book["commit"] == index["commit"], "book/index provenance mismatch")
            expected_id = hashlib.sha256((book["repo"] + "@" + book["commit"] + ":" + book["path"]).encode()).hexdigest()
            ensure(book["book_id"] == expected_id, "invalid index book_id")
            indexed[book["book_id"]] = book
    seen = set()
    for q in bank["questions"]:
        qid = q["question_id"]
        ensure(qid not in seen, "duplicate question_id: " + qid)
        seen.add(qid)
        validate_grade(q)
        ids = [o["id"] for o in q["options"]]
        ensure(len(ids) == len(set(ids)), qid + ": duplicate option id")
        ensure(len({o["text"].strip() for o in q["options"]}) == len(ids), qid + ": duplicate option text")
        if q["type"] == "true_false":
            ensure(set(ids) == {"true", "false"}, qid + ": true_false requires true/false option ids")
        if q["type"] != "short_answer":
            answers = q["answer"] if type(q["answer"]) is list else [q["answer"]]
            ensure(all(a in ids for a in answers), qid + ": answer not in option ids")
        approved = q["reviewStatus"] == "approved"
        if bank["curriculum"]["kind"] == "general_knowledge":
            ensure(q["textbookVersion"] == "general_knowledge", qid + ": general knowledge is not an exact textbook version")
        else:
            ensure(q["textbookVersion"] != "general_knowledge", qid + ": exact curriculum cannot use general_knowledge")
        source, page = q["sourceBook"], q["sourcePage"]
        ensure((source is None) == (page is None), qid + ": sourceBook and sourcePage must be paired")
        if source is not None:
            path = source["path"]
            ensure(not path.startswith("/") and ".." not in path.split("/") and "\\" not in path, qid + ": unsafe source path")
            expected_id = hashlib.sha256((source["repo"] + "@" + source["commit"] + ":" + path).encode()).hexdigest()
            ensure(source["book_id"] == expected_id, qid + ": source book_id mismatch")
            if index is not None:
                ensure(source["book_id"] in indexed, qid + ": book missing from index; no fallback")
                book = indexed[source["book_id"]]
                ensure(all(source[k] == book[k] for k in source), qid + ": source provenance mismatch")
                if approved:
                    ensure(book["format"] != "pdf_part", qid + ": split PDF needs manual reassembly provenance")
                    for axis in AXES:
                        known = book["metadata"][axis]
                        ensure(known is None or known == q[axis], qid + ": source metadata mismatch on " + axis)
            elif approved:
                ensure(False, qid + ": approved sourced question requires pinned --index")
        if approved:
            ensure(q["stage"] not in (None, "other"), qid + ": unresolved approved stage")
            for axis in ("system", "semester", "subject", "textbookVersion", "chapter"):
                ensure(q[axis] is not None, qid + ": unresolved approved " + axis)
            ensure(q["system"] != "other", qid + ": unresolved approved system")
            if q["stage"] in ("primary", "junior_secondary", "senior_secondary"):
                ensure(q["grade"] is not None, qid + ": approved K12 question needs grade")
            if bank["curriculum"]["kind"] == "exact_textbook":
                ensure(source is not None, qid + ": exact textbook approval needs book and page")
    if runtime or any(q["reviewStatus"] == "approved" for q in bank["questions"]):
        review_evidence(bank)
    return bank


def semester_matches(actual, selected, curriculum):
    return actual == selected or (curriculum == "general_knowledge" and selected == "full_year"
                                  and actual in ("first", "second", "full_year"))


def require_config(value, field):
    ensure(isinstance(value, str) and value.strip() and value not in ("待设置", "未设置", "unknown", "other"),
           "MISSING_CONFIG: " + field)


def select_pool(banks, selector, curriculum, index=None):
    ensure(set(selector) == set(AXES), "all six selection axes are mandatory")
    ensure(curriculum in ("general_knowledge", "exact_textbook"), "invalid curriculum selector")
    for axis in AXES:
        if axis != "grade":
            require_config(selector[axis], axis)
    ensure(type(selector["grade"]) is int and 1 <= selector["grade"] <= 12, "MISSING_CONFIG: grade")
    seen, bank_ids, matches = set(), set(), []
    for bank in banks:
        validate_bank(bank, index=index, runtime=True)
        ensure(bank["bankId"] not in bank_ids, "duplicate bankId across banks")
        bank_ids.add(bank["bankId"])
        for q in bank["questions"]:
            ensure(q["question_id"] not in seen, "duplicate question_id across banks: " + q["question_id"])
            seen.add(q["question_id"])
            if (bank["curriculum"]["kind"] == curriculum
                    and all(json_equal(q[key], selector[key]) for key in AXES if key != "semester")
                    and semester_matches(q["semester"], selector["semester"], curriculum)):
                matches.append(q)
    if not matches:
        raise MissingPoolError("MISSING_POOL: exact selection has no approved questions; no grade/version/curriculum fallback")
    return sorted(matches, key=lambda q: q["question_id"])


def select_profile(banks, profile, per_round, index=None):
    """App profile contract. Empty chapters are missing config, never 'all'."""
    ensure(type(per_round) is int and 1 <= per_round <= 10, "MISSING_CONFIG: questionsPerRound (1..10)")
    require_config(profile.get("academicYear"), "academicYear")
    subjects = profile.get("subjects", [])
    ensure(isinstance(subjects, list) and subjects and len(set(subjects)) == len(subjects),
           "MISSING_CONFIG: subjects")
    stage = {"小学": "primary", "初中": "junior_secondary", "高中": "senior_secondary"}.get(
        profile.get("schoolStage"), profile.get("schoolStage"))
    system = {"六三": "6_3", "六三制": "6_3", "五四": "5_4", "五四制": "5_4"}.get(
        profile.get("schoolSystem"), profile.get("schoolSystem"))
    semester = {"上": "first", "下": "second", "上学期": "first", "下学期": "second", "全年": "full_year", "全学年": "full_year"}.get(
        profile.get("semester"), profile.get("semester"))
    pool = []
    for subject in subjects:
        require_config(subject, "subjects")
        version = profile.get("subjectTextbookVersions", {}).get(subject)
        require_config(version, "subjectTextbookVersions." + subject)
        if version == "通用知识版":
            version = "general_knowledge"
        curriculum = "general_knowledge" if version == "general_knowledge" else "exact_textbook"
        chapters = profile.get("learnedChapters", {}).get(subject, [])
        ensure(isinstance(chapters, list) and chapters and len(set(chapters)) == len(chapters),
               "MISSING_CONFIG: learnedChapters." + subject)
        for chapter in chapters:
            require_config(chapter, "learnedChapters." + subject)
        ensure("*" not in chapters or chapters == ["*"], "MISSING_CONFIG: wildcard must stand alone")
        selector = dict(stage=stage, system=system, grade=profile.get("grade"), semester=semester,
                        subject=subject, textbookVersion=version)
        selected = [q for q in select_pool(banks, selector, curriculum, index)
                    if chapters == ["*"] or q["chapter"] in chapters]
        if not selected:
            raise MissingPoolError("MISSING_POOL: no learned chapters for " + subject)
        pool.extend(selected)
    if len(pool) < per_round:
        raise MissingPoolError(f"INSUFFICIENT_POOL: need {per_round}, available {len(pool)}; never reduce round size")
    return sorted(pool, key=lambda q: q["question_id"])


def load_banks(paths):
    # Same physical path discovered twice is read once; different banks may not share IDs.
    return [load_json(p) for p in sorted({Path(p).resolve() for p in paths})]


def balance_options(bank, seed="ATV-G4-options-v1"):
    """Deterministic, idempotent relabeling. Preserves answer text, not old IDs.
    Hash-rank within subject/semester; assign next least-used label globally.
    Not randomness for security and not a substitute for learning/ledger controls.
    """
    counts = dict.fromkeys("ABCD", 0)
    groups = sorted({(q["subject"], q["semester"]) for q in bank["questions"]})
    for group in groups:
        questions = [q for q in bank["questions"] if (q["subject"], q["semester"]) == group]
        questions.sort(key=lambda q: hashlib.sha256((seed + q["question_id"]).encode()).hexdigest())
        for q in questions:
            ensure(q["type"] == "single_choice" and len(q["options"]) == 4, "balance requires 4-option single choice")
            answer = next(o["text"] for o in q["options"] if o["id"] == q["answer"])
            label = min(counts, key=lambda k: (counts[k], hashlib.sha256((seed + q["question_id"] + k).encode()).hexdigest()))
            counts[label] += 1
            distractors = sorted((o["text"] for o in q["options"] if o["id"] != q["answer"]),
                                 key=lambda t: hashlib.sha256((seed + q["question_id"] + t).encode()).hexdigest())
            q["options"] = [{"id": k, "text": answer if k == label else distractors.pop(0)} for k in "ABCD"]
            q["answer"] = label
    return bank


def write_new_json(path, value):
    # Never overwrite an existing bank or last known-good pool on failure.
    with Path(path).open("x", encoding="utf-8") as output:
        output.write(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate")
    validate.add_argument("bank", type=Path)
    validate.add_argument("--index", type=Path)
    validate.add_argument("--runtime", action="store_true")
    import_cmd = sub.add_parser("import", help="validated copy; never implicitly approves")
    import_cmd.add_argument("bank", type=Path)
    import_cmd.add_argument("--index", type=Path)
    import_cmd.add_argument("--runtime", action="store_true")
    import_cmd.add_argument("--output", type=Path, required=True)
    select = sub.add_parser("select")
    select.add_argument("banks", type=Path, nargs="+")
    select.add_argument("--index", type=Path)
    select.add_argument("--curriculum", choices=["general_knowledge", "exact_textbook"], required=True)
    for axis in AXES:
        select.add_argument("--" + axis, required=True,
                            type=(lambda v: None if v == "null" else int(v)) if axis == "grade" else str)
    select.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        index = load_json(args.index) if args.index else None
        if args.command in ("validate", "import"):
            bank = validate_bank(load_json(args.bank), index, args.runtime)
            if args.command == "import":
                write_new_json(args.output, bank)
            print(json.dumps({"valid": True, "questions": len(bank["questions"]),
                              "runtimeValidated": args.runtime, "testOnly": bank["testOnly"]}))
        else:
            banks = load_banks(args.banks)
            selector = {axis: getattr(args, axis) for axis in AXES}
            pool = select_pool(banks, selector, args.curriculum, index)
            result = {"schemaVersion": 1, "runtimeValidated": True, "curriculum": args.curriculum,
                      "selector": selector, "questions": pool}
            if args.output:
                write_new_json(args.output, result)
            else:
                print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValidationError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 3 if isinstance(exc, MissingPoolError) else 2


if __name__ == "__main__":
    raise SystemExit(main())
