#!/usr/bin/env python3
"""Local-only public source gate. Run with python3 -I; never publishes or builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET

TOOL_VERSION = "1.0.0"
PRIVATE_IMAGE_SHA256 = "33c845f8464cba9ab14cc923046865de45ddbdc81a6e0f088aaa90bc6719fc94"
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg"}
DENIED_SUFFIXES = {
    ".pdf", ".sqlite", ".sqlite3", ".db", ".p12", ".pfx", ".pem", ".key",
    ".p8", ".cer", ".crt", ".der", ".mobileprovision", ".provisionprofile",
    ".keychain", ".keychain-db", ".ipa", ".app", ".xcarchive", ".dmg", ".zip",
    ".tar", ".gz", ".7z", ".log", ".pyc", ".xcuserstate", ".entitlements",
}
DENIED_NAMES = {
    "private", "privateresources", "internal", "agents.md", "claude.md",
    "xcuserdata", "userdata", "credentials", "credentials.json", "secrets",
    "secrets.json", "cookies", "cookies.json", "id_rsa", "id_ed25519",
    "signing", "signingmaterials", "provisioning", "deriveddata", "node_modules",
    "__pycache__", "personal", "local", "devices.txt", "devices.json",
}
# 'Personal' is the existing public app module, not a blanket exemption elsewhere.
PUBLIC_PERSONAL_MODULE = "BilibiliLive/Module/Personal"
RULES = [
    ("private-key", re.compile(r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")),
    ("provider-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{12,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,})\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("literal-credential", re.compile(r'''(?ix)\b(?:[a-z_]*(?:token|secret|password|passwd|api_?key|access_?key|appkey|appsec|sessdata|bili_jct|authorization|cookie))\b["']?\s*(?::\s*(?:String|str)\s*)?[:=]\s*["'][^"'\r\n]{4,}["']''')),
    ("unquoted-credential", re.compile(r"(?m)^\s*(?:export\s+)?(?:[A-Z_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|ACCESS_KEY|SESSDATA|BILI_JCT))\s*[:=]\s*[A-Za-z0-9/+_.-]{8,}\s*;?\s*$")),
    ("yaml-credential", re.compile(r"(?im)^\s*(?:token|secret|password|passwd|api_key|access_key|sessdata|bili_jct)\s*:\s*[A-Za-z0-9/+_-]{8,}\s*$")),
    ("url-credential", re.compile(r"(?i)https?://[^\s/:]+:[^\s/@]+@|[?&](?:access_token|refresh_token|token|secret|password|sessdata|bili_jct)=[A-Za-z0-9%._-]{6,}")),
    ("authorization", re.compile(r"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/-]{16,}")),
    ("personal-path", re.compile(r"(?:/Users/[A-Za-z0-9_. -]+/|/home/[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9_. -]+\\)")),
    ("signing-configuration", re.compile(r'''\b(?:DEVELOPMENT_TEAM|PROVISIONING_PROFILE(?:_SPECIFIER)?)\s*=\s*(?!["']?\s*;)(?:["']?[A-Za-z0-9][^;\r\n]*);''')),
    ("device-identifier", re.compile(r"(?i)\b(?:udid|device_identifier|device_id)\b[\"']?\s*[:=]\s*[\"']?[0-9a-f-]{16,}|\b[0-9a-f]{8}-[0-9a-f]{16}\b")),
]


class GateError(Exception):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def relative_path(value):
    if not isinstance(value, str) or not value or "\\" in value:
        raise GateError("Invalid relative path")
    parts = value.split("/")
    if any(p in ("", ".", "..") or any(ord(c) < 32 for c in p) for p in parts):
        raise GateError("Absolute, traversal or control-character path refused")
    if any(p.casefold() == ".git" for p in parts):
        raise GateError(".git is never an export path")
    return value


def absolute_path(value):
    raw = os.fspath(value)
    if ".." in Path(raw).parts:
        raise GateError("Path traversal refused")
    p = Path(os.path.abspath(raw))
    for part in [p, *p.parents]:
        if part.is_symlink():
            raise GateError("Symlink path or ancestor refused")
        if part.name.casefold() == ".git":
            raise GateError(".git destination or ancestor refused")
    return p


def inside(path, parent):
    return path == parent or parent in path.parents


def forbidden(path):
    parts = PurePosixPath(path).parts
    for index, part in enumerate(parts):
        low = part.casefold()
        if low == "personal" and "/".join(parts[:index + 1]) == PUBLIC_PERSONAL_MODULE:
            continue
        if low.startswith(".") or low in DENIED_NAMES:
            return "private, personal or hidden path"
        if re.search(r"(?i)(?:^|[-_.])(?:private|internal|secret|credentials?|udids?|personal|local)(?:[-_.]|$)", part):
            return "sensitive path name"
        if low.startswith("agents.") or low.endswith((".sqlite-wal", ".sqlite-shm", ".db-wal", ".db-shm")):
            return "agent instructions or database sidecar"
        if PurePosixPath(low).suffix in DENIED_SUFFIXES:
            return "forbidden artifact or signing material"
    return None


def load_policy(path):
    policy = json.loads(path.read_text(encoding="utf-8"))
    if policy.get("schema_version") != 1:
        raise GateError("Unsupported allowlist schema")
    if not re.fullmatch(r"[0-9a-f]{64}", policy.get("license_sha256", "")):
        raise GateError("License must have a pinned SHA256")
    for value in policy["files"] + policy["required_files"]:
        relative_path(value)
        if forbidden(value):
            raise GateError("Allowlist attempts to permit a forbidden file")
    for entry in policy["directories"]:
        relative_path(entry["path"])
        if forbidden(entry["path"]) or not entry["suffixes"]:
            raise GateError("Unsafe directory allowlist")
        if any(not re.fullmatch(r"\.[a-z0-9]+", s) or s in DENIED_SUFFIXES for s in entry["suffixes"]):
            raise GateError("Unsafe suffix in allowlist")
        for name in entry["names"]:
            relative_path(name)
            if "/" in name or forbidden(name):
                raise GateError("Unsafe allowed basename")
    for entry in policy["exceptions"]:
        relative_path(entry["path"])
        if not entry.get("reason") or not re.fullmatch(r"[0-9a-f]{64}", entry["line_sha256"]):
            raise GateError("Exceptions need an exact line fingerprint and reason")
        if entry["rule"] != "literal-credential":
            raise GateError("Only exact literal-credential false positives may be exempted; signing and other detectors always block")
    return policy


def selected(path, policy):
    if path in policy["files"]:
        return True
    p = PurePosixPath(path)
    return any(path.startswith(e["path"] + "/") and
               (p.suffix.lower() in e["suffixes"] or p.name in e["names"])
               for e in policy["directories"])


def candidate_directory(path, policy):
    targets = policy["files"] + [e["path"] for e in policy["directories"]]
    return any(t == path or t.startswith(path + "/") for t in targets) or any(
        path.startswith(e["path"] + "/") for e in policy["directories"])


def finding(report, severity, rule, path, detail, line=None):
    item = {"severity": severity, "rule": rule, "path": path, "detail": detail}
    if line is not None:
        item["line"] = line
    report["findings"].append(item)


def collect(root, policy, report):
    """Descriptor-relative traversal, no links, no file metadata/xattrs copied."""
    blobs = {}
    total = 0
    identities = set()
    nofollow = os.O_NOFOLLOW | os.O_CLOEXEC

    def walk(fd, prefix):
        nonlocal total
        for name in sorted(os.listdir(fd)):
            path = prefix + name
            # Root Git metadata belongs to the private source; never enter it.
            if not prefix and name == ".git":
                report["excluded"].append({"path": path, "reason": "source Git metadata; never traversed"})
                continue
            try:
                relative_path(path)
            except GateError as exc:
                finding(report, "error", "unsafe-path", path, str(exc))
                continue
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                finding(report, "error", "symlink", path, "Symlink refused; target never read")
                continue
            reason = forbidden(path)
            if reason:
                report["excluded"].append({"path": path, "reason": reason})
                continue
            if stat.S_ISDIR(st.st_mode):
                if not candidate_directory(path, policy):
                    report["excluded"].append({"path": path + "/", "reason": "not allowlisted; subtree not read"})
                    continue
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=fd)
                try:
                    walk(child, path + "/")
                finally:
                    os.close(child)
            elif selected(path, policy):
                if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                    finding(report, "error", "special-file", path, "Only regular, non-hardlinked files are accepted")
                    continue
                if st.st_size > MAX_FILE_BYTES or total + st.st_size > MAX_TOTAL_BYTES:
                    finding(report, "error", "size-limit", path, "Snapshot size bound exceeded; manual review required")
                    continue
                with os.fdopen(os.open(name, os.O_RDONLY | nofollow, dir_fd=fd), "rb") as stream:
                    now = os.fstat(stream.fileno())
                    if (now.st_dev, now.st_ino, now.st_size, now.st_mtime_ns) != (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns):
                        raise GateError("Source changed during scan; freeze writers and retry")
                    data = stream.read(MAX_FILE_BYTES + 1)
                    after = os.fstat(stream.fileno())
                    if after.st_mtime_ns != now.st_mtime_ns or len(data) != now.st_size:
                        raise GateError("Source changed during read; freeze writers and retry")
                identity = path.casefold()
                if identity in identities:
                    raise GateError("Case-insensitive output collision")
                identities.add(identity)
                blobs[path] = data
                total += len(data)
            else:
                report["excluded"].append({"path": path, "reason": "not allowlisted"})

    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | nofollow)
    try:
        walk(fd, "")
    finally:
        os.close(fd)
    return blobs


def scan(blobs, policy, report):
    used = set()
    for path, data in sorted(blobs.items()):
        if sha256(data) == PRIVATE_IMAGE_SHA256:
            finding(report, "error", "private-image-sha256", path, "Known private original image; no exception permitted")
        if data.startswith((b"%PDF-", b"SQLite format 3\x00", b"PK\x03\x04", b"\x1f\x8b")):
            finding(report, "error", "forbidden-content", path, "PDF/database/archive content regardless of extension")
        suffix = PurePosixPath(path).suffix.lower()
        if suffix in BINARY_SUFFIXES:
            valid = data.startswith(b"\x89PNG\r\n\x1a\n") if suffix == ".png" else data.startswith(b"\xff\xd8\xff")
            if not valid:
                finding(report, "error", "invalid-image", path, "Image extension does not match file signature")
            text = data.decode("latin-1")
        else:
            try:
                text = data.decode("utf-8")
                if "\x00" in text:
                    raise UnicodeError("NUL")
            except UnicodeError:
                finding(report, "error", "unreviewed-binary", path, "Expected UTF-8 text; binary not accepted")
                text = data.decode("latin-1")
        for number, line in enumerate(text.splitlines(), 1):
            for rule, pattern in RULES:
                if not pattern.search(line):
                    continue
                exceptions = [(i, e) for i, e in enumerate(policy["exceptions"])
                              if e["path"] == path and e["rule"] == rule and
                              e["line_sha256"] == sha256(line.strip().encode("utf-8"))]
                if exceptions:
                    i, exception = exceptions[0]
                    used.add(i)
                    finding(report, "accepted-exception", rule, path, exception["reason"], number)
                else:
                    finding(report, "error", rule, path, "Potential sensitive content; value redacted; review exact source line", number)
    for index, exception in enumerate(policy["exceptions"]):
        if index not in used:
            finding(report, "warning", "unused-exception", exception["path"], "No match for pinned exception; review/remove stale entry")


def check_prerequisites(blobs, policy, report):
    def require(path, origin):
        try:
            relative_path(path)
        except GateError:
            finding(report, "error", "resource-path", origin, "Resource reference escapes public source")
            return
        if path not in blobs and not any(p.startswith(path + "/") for p in blobs):
            finding(report, "error", "missing-resource", origin, "Required public resource is absent or excluded: " + path)

    for path in policy["required_files"]:
        require(path, "allowlist required_files")
    if "LICENSE.md" in blobs and sha256(blobs["LICENSE.md"]) != policy["license_sha256"]:
        finding(report, "error", "license-changed", "LICENSE.md", "GPL license must be preserved byte-for-byte")
    for path, data in blobs.items():
        if path.endswith("/Contents.json") and ".xcassets/" in path:
            try:
                obj = json.loads(data)
                def visit(value):
                    if isinstance(value, dict):
                        for key, val in value.items():
                            if key == "filename" and isinstance(val, str):
                                require(str(PurePosixPath(path).parent / val), path)
                            else:
                                visit(val)
                    elif isinstance(value, list):
                        for val in value:
                            visit(val)
                visit(obj)
            except (ValueError, UnicodeError):
                finding(report, "error", "invalid-resource-json", path, "Cannot parse asset catalog")
        if path.endswith((".xcscheme", ".xcworkspacedata")):
            try:
                tree = ET.fromstring(data)
                for element in tree.iter():
                    ref = element.get("ReferencedContainer") or element.get("location")
                    if ref and ref != "self:":
                        if ref.startswith(("container:", "group:")):
                            require(ref.split(":", 1)[1], path)
                        else:
                            finding(report, "error", "workspace-reference", path, "Unsupported or absolute workspace reference")
            except ET.ParseError:
                finding(report, "error", "invalid-xml", path, "Cannot parse Xcode XML")
    project = "BilibiliLive.xcodeproj/project.pbxproj"
    text = blobs.get(project, b"").decode("utf-8", errors="replace")
    for root_match in re.finditer(r'isa = PBXFileSystemSynchronizedRootGroup;(?:(?!\bisa =).)*?\bpath\s*=\s*"?([^";]+)', text, re.S):
        require(root_match.group(1).strip(), project)
    for match in re.finditer(r'\b(?:INFOPLIST_FILE|CODE_SIGN_ENTITLEMENTS|SWIFT_OBJC_BRIDGING_HEADER|GCC_PREFIX_HEADER)\s*=\s*"?([^";]+)"?;', text):
        ref = match.group(1).strip()
        for variable in ("$(SRCROOT)/", "$(PROJECT_DIR)/", "${SRCROOT}/", "${PROJECT_DIR}/"):
            ref = ref.removeprefix(variable)
        require(ref, project)
    # Current project uses synchronized roots. Conventional PBXFileReference groups
    # need a real resolver; fail closed instead of pretending to cover them.
    for block in re.findall(r"\{[^{}]*isa = PBXFileReference;[^{}]*\}", text):
        if "sourceTree = BUILT_PRODUCTS_DIR" not in block and "sourceTree = SDKROOT" not in block:
            finding(report, "error", "unsupported-xcode-reference", project, "New file reference requires explicit static resolver review")
    for block in re.findall(r"\{[^{}]*isa = XCLocalSwiftPackageReference;[^{}]*\}", text):
        match = re.search(r'relativePath\s*=\s*"?([^";]+)', block)
        if match:
            require(match.group(1).strip() + "/Package.swift", project)
        else:
            finding(report, "error", "local-package-reference", project, "Unresolved local package")
    for name in re.findall(r'ASSETCATALOG_COMPILER_(?:APPICON|GLOBAL_ACCENT_COLOR)_NAME\s*=\s*"?([^";]+)', text):
        if not any(PurePosixPath(p).parent.name in {name.strip() + ".brandassets", name.strip() + ".appiconset", name.strip() + ".colorset"} for p in blobs if p.endswith("/Contents.json")):
            finding(report, "error", "missing-resource", project, "Named asset catalog absent: " + name.strip())
    for path, data in blobs.items():
        if path.endswith("/Package.swift"):
            text = data.decode("utf-8", errors="replace")
            for ref in re.findall(r'\.package\s*\(\s*path:\s*"([^"]+)"', text):
                require(str(PurePosixPath(path).parent / ref / "Package.swift"), path)
            for ref in re.findall(r'\.(?:copy|process)\s*\(\s*"([^"]+)"', text):
                try:
                    relative_path(ref)
                except GateError:
                    finding(report, "error", "resource-path", path, "Unsafe package resource reference")
                    continue
                package_prefix = str(PurePosixPath(path).parent) + "/"
                if not any(p.startswith(package_prefix) and (p.endswith("/" + ref) or "/" + ref + "/" in p) for p in blobs):
                    finding(report, "error", "missing-resource", path, "Literal package resource absent: " + ref)
        if path.endswith(".modulemap"):
            for ref in re.findall(r'\bheader\s+"([^"]+)"', data.decode("utf-8", errors="replace")):
                require(str(PurePosixPath(path).parent / ref), path)
        if path.endswith(".swift"):
            text = data.decode("utf-8", errors="replace")
            # Literal Bundle resources can be verified without running application code.
            for name, extension in re.findall(r'(?:url|path)\(forResource:\s*"([^"]+)"\s*,\s*withExtension:\s*"([^"]+)"', text):
                if not any(PurePosixPath(p).name == name + "." + extension for p in blobs):
                    finding(report, "error", "missing-resource", path, "Literal Bundle resource absent: " + name + "." + extension)
    for entry in report["excluded"]:
        if entry["path"].startswith(("BilibiliLive/", "FamilyCore/")) and not entry["path"].endswith("/"):
            finding(report, "warning", "excluded-build-tree-entry", entry["path"], "Review exclusion from synchronized source/package tree")


def audit(root, policy):
    report = {"tool_version": TOOL_VERSION, "policy_version": policy["policy_version"],
              "ok": False, "findings": [], "excluded": [],
              "build_verified": False, "device_verified": False,
              "publication_authorized": False,
              "limitations": ["Static prerequisite checks only; no Xcode or network execution",
                              "No guarantee against unknown secrets, re-encoded images or dynamic resource paths",
                              "Git HEAD is provenance, not proof of clean history or human approval"]}
    blobs = collect(root, policy, report)
    scan(blobs, policy, report)
    check_prerequisites(blobs, policy, report)
    report["files"] = [{"path": p, "sha256": sha256(data), "bytes": len(data)} for p, data in sorted(blobs.items())]
    report["ok"] = not any(f["severity"] == "error" for f in report["findings"])
    return report, blobs


def provenance(root):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    command = ["git", "-c", "core.fsmonitor=false", "-C", str(root)]
    def run(arguments):
        result = subprocess.run(command + arguments, env=env, capture_output=True, timeout=30, check=False)
        if result.returncode:
            raise GateError("Cannot read source Git provenance; export requires a local repository")
        return result.stdout.decode("utf-8", errors="replace").strip()
    if Path(run(["rev-parse", "--show-toplevel"])).resolve() != root:
        raise GateError("Source must be the Git worktree root")
    commit = run(["rev-parse", "--verify", "HEAD"])
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        raise GateError("Invalid source commit")
    dirty = bool(run(["status", "--porcelain", "--untracked-files=normal"]))
    return {"source_commit": commit, "source_dirty": dirty,
            "snapshot": "reviewed working-tree bytes, not necessarily identical to HEAD"}


def validate_outputs(root, destination, manifest_path):
    destination = absolute_path(destination)
    manifest_path = absolute_path(manifest_path)
    if destination.exists():
        raise GateError("Destination must be new and nonexistent (even an existing empty directory is refused)")
    if manifest_path.exists():
        raise GateError("Manifest must be new; never overwrite")
    if inside(destination, root) or inside(root, destination):
        raise GateError("Export destination must be separate from source")
    if inside(manifest_path, destination) or inside(manifest_path, root) or manifest_path == destination:
        raise GateError("Internal provenance manifest must be outside public output and source")
    for p in (destination.parent, manifest_path.parent):
        if not p.is_dir():
            raise GateError("Output parents must already exist")
    return destination, manifest_path


def exclusive_write(parent_fd, name, data):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)


def export_snapshot(root, destination, manifest_path, report, blobs, manifest):
    if not report["ok"]:
        raise GateError("Audit blocked; no output created")
    destination, manifest_path = validate_outputs(root, destination, manifest_path)
    # Audit and copy use the very same immutable byte snapshot, not a second read.
    parent_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.mkdir(destination.name, mode=0o700, dir_fd=parent_fd)
        output_fd = os.open(destination.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            for path, data in sorted(blobs.items()):
                relative_path(path)
                fd = os.dup(output_fd)
                try:
                    parts = path.split("/")
                    for part in parts[:-1]:
                        try:
                            os.mkdir(part, mode=0o755, dir_fd=fd)
                        except FileExistsError:
                            pass
                        next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                        os.close(fd)
                        fd = next_fd
                    exclusive_write(fd, parts[-1], data)
                finally:
                    os.close(fd)
        finally:
            os.close(output_fd)
    finally:
        os.close(parent_fd)
    fd = os.open(manifest_path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        exclusive_write(fd, manifest_path.name, (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "dry-run", "export"))
    parser.add_argument("--source", required=True, help="Local repository worktree root")
    parser.add_argument("--version", required=True, help="Proposed version label, not a release declaration")
    parser.add_argument("--output", help="New directory outside source; never a Git checkout")
    parser.add_argument("--manifest", help="New private JSON sidecar outside output/source")
    args = parser.parse_args(argv)
    try:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,79}", args.version):
            raise GateError("Unsafe version label")
        root = absolute_path(args.source)
        if not root.is_dir():
            raise GateError("Source directory does not exist")
        policy_path = absolute_path(Path(__file__).parent / "allowlist.json")
        policy = load_policy(policy_path)
        if args.command == "export" and not (args.output and args.manifest):
            raise GateError("export requires --output and an external --manifest")
        if bool(args.output) != bool(args.manifest):
            raise GateError("Supply --output and --manifest together")
        if args.output:
            validate_outputs(root, args.output, args.manifest)
        report, blobs = audit(root, policy)
        report["command"] = args.command
        report["version"] = args.version
        report["policy_sha256"] = sha256(policy_path.read_bytes())
        if report["ok"] and args.command == "export":
            source = provenance(root)
            manifest = {"manifest_version": 1, "version": args.version,
                        "tool_version": TOOL_VERSION, "policy_version": policy["policy_version"],
                        "policy_sha256": report["policy_sha256"], **source,
                        "files": report["files"], "review": report,
                        "classification": "PRIVATE provenance; never include in public source"}
            commit_bytes = source["source_commit"].encode("ascii")
            if any(commit_bytes in data for data in blobs.values()):
                raise GateError("Internal source commit appears in selected content; remove mapping before export")
            export_snapshot(root, args.output, args.manifest, report, blobs, manifest)
            report["exported"] = True
        else:
            report["exported"] = False
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0 if report["ok"] else 1
    except (GateError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        # Never print file contents, subprocess stderr or credentials.
        print(json.dumps({"ok": False, "exported": False, "error": str(exc),
                          "device_verified": False, "publication_authorized": False,
                          "note": "No publication attempted. If an I/O error interrupted copying, quarantine partial output."}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    sys.exit(main())
