#!/usr/bin/env python3
"""Reject credential/session artifacts without printing matching secret values."""
import argparse
import io
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import zipfile

PATTERNS = [
    re.compile(rb"tg://login\?token=[A-Za-z0-9_-]{16,}={0,2}"),
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{12,}|sk-[A-Za-z0-9_-]{25,})"),
    re.compile(rb'''(?i)(?:api[_-]?hash)[\s\"']*[:=][\s\"']*([a-f0-9]{32})\b'''),
    re.compile(rb'''(?i)(?:bot[_-]?token)[\s\"']*[:=][\s\"']*\d{6,}:[A-Za-z0-9_-]{20,}'''),
]
PRIVATE_PARTS = {"credentials", "secrets", "tdlib-data", "telegram-data", "app-backups"}
PRIVATE_SUFFIXES = {".db", ".sqlite", ".sqlite3", ".session", ".log", ".key", ".p12", ".pfx"}

def violations(name, data, inspect_archive=True):
    path = PurePosixPath(name)
    issues = []
    if (set(path.parts) & PRIVATE_PARTS or "build" in path.parts or path.suffix in PRIVATE_SUFFIXES
        or path.name.startswith((".env", "codex-clipboard-")) and path.name != ".env.example"
        or re.search(r"\.(?:db|sqlite3?|session)-(?:wal|shm|journal)$", name)
        or path.name.endswith(".local.json")):
        issues.append("private file type or location")
    for pattern in PATTERNS:
        for match in pattern.finditer(data):
            if match.lastindex and match.group(1) == b"0" * 32:
                continue  # Explicitly synthetic test credentials only.
            issues.append("possible credential literal")
            break
    if inspect_archive and path.suffix == ".zip":
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for entry in archive.infolist():
                    if not entry.is_dir():
                        if entry.file_size > 20 * 1024 * 1024:
                            issues.append("oversized source archive member")
                        elif violations(entry.filename, archive.read(entry), False):
                            issues.append("private data inside source archive")
        except zipfile.BadZipFile:
            issues.append("unreadable source archive")
    return sorted(set(issues))

def git(*args):
    return subprocess.check_output(["git", *args])

def scan_tree(tree):
    issues = []
    args = ["ls-files", "--stage", "-z"] if tree is None else ["ls-tree", "-r", "-z", tree]
    for entry in git(*args).split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        parts = metadata.split()
        blob = parts[1] if tree is None else parts[2]
        name = raw_name.decode("utf-8", "replace")
        for issue in violations(name, git("cat-file", "blob", blob.decode())):
            issues.append((name, issue))
    return issues

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tree")
    parser.add_argument("--working", action="store_true")
    parser.add_argument("--pre-push", action="store_true")
    args = parser.parse_args()
    issues = []
    if args.working:
        names = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
        for raw in names:
            if not raw:
                continue
            name = raw.decode()
            path = Path(name)
            if path.is_file():
                issues.extend((name, issue) for issue in violations(name, path.read_bytes()))
    elif args.pre_push:
        commits = set()
        for line in sys.stdin:
            _, local, _, remote = line.split()
            if set(local) == {"0"}:
                continue
            exclusions = ["--not", "--remotes"] if set(remote) == {"0"} else ["^" + remote]
            commits.update(git("rev-list", local, *exclusions).decode().splitlines())
        for commit in commits:
            issues.extend(scan_tree(commit))
    else:
        issues = scan_tree(args.tree)
    if issues:
        for name, issue in sorted(set(issues)):
            print("BLOCKED:", name, "—", issue, file=sys.stderr)
        return 1
    print("Sensitive-file check passed; matching values are never printed.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
