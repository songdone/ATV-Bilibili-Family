#!/usr/bin/env python3
"""Build a path-derived book inventory offline from a pinned GitHub Git tree.
No blobs/PDFs are opened. Unknown or ambiguous metadata stays null.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

SHA = re.compile(r"[0-9a-f]{40}\Z")
STAGES = {"小学": "primary", "初中": "junior_secondary", "高中": "senior_secondary",
          "大学": "higher_education", "幼儿园": "preschool", "中职": "vocational",
          "特殊教育": "special_education"}
NUMBERS = {c: i for i, c in enumerate("一二三四五六七八九", 1)}
FIELDS = ("stage", "system", "grade", "semester", "subject", "textbookVersion", "volume")


def load_json(path):
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValueError("Duplicate JSON key: " + key)
            obj[key] = value
        return obj
    return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique)


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def derive(path):
    parts = PurePosixPath(path).parts
    top = parts[0]
    stage = next((v for k, v in STAGES.items() if top == k or top.startswith(k + "（")), None)
    recognized = stage is not None
    # Subject/version values are discovered from actual directory names, not a whitelist.
    subject = parts[1] if recognized and len(parts) >= 3 else None
    version = parts[2] if recognized and len(parts) >= 4 and "版" in parts[2] else None
    compact = re.sub(r"[•·・.－\-—（）()\s]", "", path)
    systems = set()
    if "五四学制" in compact or "五四制" in compact:
        systems.add("5_4")
    if "六三学制" in compact or "六三制" in compact:
        systems.add("6_3")
    system = next(iter(systems)) if len(systems) == 1 else None
    grades = set()
    for value in re.findall(r"([一二三四五六七八九]|[1-9])年级", path):
        grades.add(NUMBERS[value] if value in NUMBERS else int(value))
    # Ranges and multiple grade claims are ambiguous, never a single-grade match.
    grade_range = bool(re.search(r"[一二三四五六七八九1-9]\s*(?:至|到|[-—～~、])\s*[一二三四五六七八九1-9]年级", path))
    grade = next(iter(grades)) if len(grades) == 1 and not grade_range else None
    semesters = set()
    if "上册" in path or "上学期" in path:
        semesters.add("first")
    if "下册" in path or "下学期" in path:
        semesters.add("second")
    if "全一册" in path:
        semesters.add("full_year")
    semester = next(iter(semesters)) if len(semesters) == 1 else None
    volumes = set(re.findall(r"上册|下册|全一册|第[一二三四五六七八九十0-9]+册|必修[一二三四五六七八九0-9]+", path))
    volume = next(iter(volumes)) if len(volumes) == 1 else None
    metadata = dict(stage=stage, system=system, grade=grade, semester=semester,
                    subject=subject, textbookVersion=version, volume=volume)
    flags = ["path_metadata_unverified", "content_not_inspected", "license_needs_review"]
    flags.extend("unknown_" + field for field in FIELDS if metadata[field] is None)
    if len(grades) > 1 or grade_range:
        flags.append("ambiguous_grade")
    if len(semesters) > 1:
        flags.append("ambiguous_semester")
    if len(systems) > 1:
        flags.append("ambiguous_system")
    return metadata, flags


def build(tree, repo, commit):
    if not isinstance(repo, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Invalid repository")
    if not isinstance(commit, str) or not SHA.fullmatch(commit):
        raise ValueError("A full pinned commit SHA is required")
    if not isinstance(tree, dict) or not SHA.fullmatch(str(tree.get("sha", ""))):
        raise ValueError("Missing tree SHA")
    if type(tree.get("truncated")) is not bool or not isinstance(tree.get("tree"), list):
        raise ValueError("Missing tree entries or explicit truncated flag")
    books, seen = [], set()
    blob_count = 0
    for entry in tree["tree"]:
        path = entry.get("path")
        if not isinstance(path, str) or not path or path.startswith("/") or ".." in path.split("/") or "\\" in path:
            raise ValueError("Unsafe or invalid tree path")
        if path in seen:
            raise ValueError("Duplicate tree path: " + path)
        seen.add(path)
        if entry.get("type") != "blob":
            continue
        blob_count += 1
        suffix = PurePosixPath(path).suffix.lower()
        fragment = re.search(r"\.pdf\.([1-9][0-9]*)$", path, re.I)
        if suffix not in (".pdf", ".djvu", ".epub") and not fragment:
            continue
        if not SHA.fullmatch(str(entry.get("sha", ""))):
            raise ValueError("Invalid book blob SHA")
        size = entry.get("size")
        if size is not None and (type(size) is not int or size < 0):
            raise ValueError("Invalid blob size")
        metadata, flags = derive(path)
        if fragment:
            flags.append("split_document_not_reassembled")
        logical_path = path
        if fragment:
            logical_path = path.rsplit(".", 1)[0]
            parent = PurePosixPath(logical_path).parent
            if parent.name.lower().endswith(".pdf_merge_folder"):
                logical_path = str(parent.parent / PurePosixPath(logical_path).name)
        books.append({
            "book_id": hashlib.sha256((repo + "@" + commit + ":" + path).encode()).hexdigest(),
            "repo": repo, "commit": commit, "path": path, "blobsha": entry["sha"],
            "size": size, "format": "pdf_part" if fragment else suffix[1:],
            "part": int(fragment.group(1)) if fragment else None,
            "logicalDocumentPath": logical_path,
            "metadata": metadata, "metadataBasis": "path-derived",
            "rawSegments": list(PurePosixPath(path).parts),
            "reviewStatus": "needs_review", "reviewFlags": flags,
            "officialApproval": None, "licenseStatus": "needs_review",
        })
    books.sort(key=lambda book: book["path"])
    if tree["truncated"]:
        status = "partial_tree"
    elif not books:
        status = "empty_inventory"
    else:
        status = "tree_complete_content_unverified"
    stats = {
        "treeEntries": len(tree["tree"]), "blobEntries": blob_count,
        "indexedBlobs": len(books),
        "logicalDocuments": len({b["logicalDocumentPath"] for b in books}),
        "ignoredBlobs": blob_count - len(books),
        "formats": dict(sorted(Counter(b["format"] for b in books).items())),
        "coverage": {field: dict(sorted(Counter(str(b["metadata"][field]) if b["metadata"][field] is not None else "null" for b in books).items())) for field in FIELDS},
        "unknown": {field: sum(b["metadata"][field] is None for b in books) for field in FIELDS},
        "needsReview": len(books), "verifiedContent": 0, "runtimeQuestions": 0,
        "grade4PathMatches": sum(b["metadata"]["grade"] == 4 for b in books),
    }
    return {"schemaVersion": 1, "repo": repo, "commit": commit,
            "treeSHA": tree["sha"], "treeTruncated": tree["truncated"],
            "status": status, "statistics": stats, "books": books}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.output.resolve() in (args.tree.resolve(), args.manifest.resolve()):
            raise ValueError("Output must not overwrite input evidence")
        manifest = load_json(args.manifest)
        digest = hashlib.sha256(args.tree.read_bytes()).hexdigest()
        if digest != manifest.get("treeSHA256"):
            raise ValueError("Tree SHA256 differs from the source manifest")
        tree = load_json(args.tree)
        if tree.get("sha") != manifest.get("treeSHA") or tree.get("truncated") != manifest.get("treeTruncated"):
            raise ValueError("Tree does not match pinned manifest")
        index = build(tree, manifest["repo"], manifest["commit"])
        write_json(args.output, index)
        manifest.update(status=index["status"], indexArtifact=str(args.output.resolve()),
                        indexSHA256=hashlib.sha256(args.output.read_bytes()).hexdigest(),
                        statistics=index["statistics"])
        write_json(args.manifest, manifest)
        print(json.dumps(index["statistics"], ensure_ascii=False, indent=2))
        return 0 if index["status"] == "tree_complete_content_unverified" else 2
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(2, "Index error: " + str(exc) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
