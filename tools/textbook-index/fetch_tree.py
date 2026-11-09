#!/usr/bin/env python3
"""Metadata only: pin HEAD and fetch one recursive Git tree, never book blobs.
Run with python3 -I; no dependencies or imports from the input directory.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

REPO = "TapXWorld/ChinaTextbook"


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def fetch(artifact_parent, manifest_path):
    # Downloaded data is kept outside both the project and trusted script directory.
    artifact_parent = Path(artifact_parent).resolve()
    project = Path(__file__).resolve().parents[2]
    if artifact_parent == project or project in artifact_parent.parents:
        raise ValueError("artifact-parent must be outside the project")
    # Each invocation is explicitly at most two API calls, with no retry/clone/blob API.
    root = Path(tempfile.mkdtemp(prefix="china-textbook-", dir=artifact_parent)).resolve()
    downloads = root / "downloads"
    downloads.mkdir()
    (root / "derived").mkdir()
    manifest = {
        "schemaVersion": 1, "repo": REPO,
        "requestedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "commit": None, "treeSHA": None, "status": "blocked",
        "networkAttempts": 0, "artifactDirectory": str(root),
        "treeArtifact": None, "treeSHA256": None, "treeTruncated": None,
        "indexArtifact": None, "indexSHA256": None, "statistics": None,
        "metadataOnly": True, "pdfDownloaded": False,
        "contentVerified": False, "officialApproval": None,
        "licenseStatus": "needs_review", "error": None,
    }
    try:
        manifest["networkAttempts"] += 1
        result = subprocess.run(
            ["gh", "api", "--hostname", "github.com", f"repos/{REPO}/commits/HEAD",
             "--jq", "{commit: .sha, tree: .commit.tree.sha}"],
            check=True, capture_output=True, text=True, timeout=90)
        pinned = json.loads(result.stdout)
        for key in ("commit", "tree"):
            value = pinned[key]
            if not isinstance(value, str) or len(value) != 40 or any(c not in "0123456789abcdef" for c in value):
                raise ValueError("GitHub returned an invalid pinned SHA")
        manifest.update(commit=pinned["commit"], treeSHA=pinned["tree"])
        manifest["networkAttempts"] += 1
        tree_path = downloads / "tree.json"
        with tree_path.open("xb") as output:
            subprocess.run(
                ["gh", "api", "--hostname", "github.com",
                 f"repos/{REPO}/git/trees/{pinned['tree']}?recursive=1"],
                check=True, stdout=output, stderr=subprocess.PIPE, timeout=90)
        tree = json.loads(tree_path.read_text(encoding="utf-8"))
        if tree.get("sha") != pinned["tree"] or not isinstance(tree.get("tree"), list):
            raise ValueError("Tree response does not match the pinned commit tree")
        if type(tree.get("truncated")) is not bool:
            raise ValueError("Tree response missing explicit truncated flag")
        manifest.update(
            status="partial" if tree["truncated"] else "tree_acquired",
            treeArtifact=str(tree_path),
            treeSHA256=hashlib.sha256(tree_path.read_bytes()).hexdigest(),
            treeTruncated=tree["truncated"])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        # No credentials or API response body enter the public manifest.
        manifest["error"] = type(exc).__name__ + ": metadata acquisition failed; no retry attempted"
    write_json(manifest_path, manifest)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0 if manifest["status"] == "tree_acquired" else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-parent", type=Path, default=Path(tempfile.gettempdir()))
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    return fetch(args.artifact_parent, args.manifest)


if __name__ == "__main__":
    raise SystemExit(main())
