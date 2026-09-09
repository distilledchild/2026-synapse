#!/usr/bin/env python3
"""Bundle the pinned TDLib runtime and its non-system dependencies."""
import json
import hashlib
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
prefix = Path(os.environ.get("SYNAPSE_TDLIB_PREFIX", "/opt/homebrew/opt/tdlib"))
expected = "d1085f9cebc5a62379991ae1652673954f229c1f"
receipt = prefix / "INSTALL_RECEIPT.json"
marker = prefix / ".synapse-tdlib-revision"
revision = marker.read_text().strip() if marker.exists() else (json.loads(receipt.read_text()).get("source", {}).get("scm_revision") if receipt.exists() else None)
if revision != expected:
    raise SystemExit("Build requires the pinned TDLib revision documented in native/TELEGRAM.md.")
frameworks = app / "Contents/Frameworks"
frameworks.mkdir(parents=True, exist_ok=True)
libraries = {}

def dependencies(path):
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    return [line.strip().split(" (", 1)[0] for line in output.splitlines()[2:]]

def bundle(source, name=None):
    source = Path(source).resolve()
    if source in libraries:
        return libraries[source]
    destination = frameworks / (name or source.name)
    libraries[source] = destination
    shutil.copyfile(source, destination)
    destination.chmod(0o755)
    for dependency in dependencies(source):
        if dependency.startswith(("/System/", "/usr/lib/")):
            continue
        if not dependency.startswith(("/opt/homebrew/", "/usr/local/")):
            raise SystemExit("Unexpected dynamic-library dependency; inspect it before packaging.")
        child = bundle(dependency)
        subprocess.run(["install_name_tool", "-change", dependency, "@loader_path/" + child.name, str(destination)], check=True)
    subprocess.run(["install_name_tool", "-id", "@rpath/" + destination.name, str(destination)], check=True)
    return destination

bundle(prefix / "lib/libtdjson.dylib", "libtdjson.dylib")
for destination in libraries.values():
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(destination)], check=True)
    for dependency in dependencies(destination):
        if not dependency.startswith(("@loader_path/", "/System/", "/usr/lib/")):
            raise SystemExit("A bundled library still depends on this development machine.")
manifest = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in libraries.values()}
(app / "Contents/Resources/TelegramLibraries.plist").write_bytes(plistlib.dumps(manifest))
licenses = app / "Contents/Resources/Licenses"
licenses.mkdir(parents=True, exist_ok=True)
source_root = Path(__file__).resolve().parents[1]
for license_file in (source_root / "Resources/Licenses").glob("*.txt"):
    shutil.copyfile(license_file, licenses / license_file.name)
print("Bundled Telegram runtime and", len(libraries) - 1, "dependencies; no account data included.")
