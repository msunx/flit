"""Ignore a duplicate legacy SwiftBridging map for this build without changing the installed toolchain."""
import json
import re
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
compiler = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
headers = compiler.parent.parent / "include" / "swift"
legacy = headers / "module.modulemap"
current = headers / "bridging.modulemap"
def definitions(path):
    return re.sub(r"\s+", " ", re.sub(r"//[^\n]*", "", path.read_text())).strip()


if legacy.exists() and current.exists() and "module SwiftBridging" in legacy.read_text() and definitions(legacy) == definitions(current):
    directory = root / "build" / "toolchain-compat"
    directory.mkdir(parents=True, exist_ok=True)
    replacement = directory / "empty.modulemap"
    replacement.write_text("// Legacy duplicate omitted by Flit's compiler VFS overlay.\n")
    overlay = directory / "overlay.json"
    overlay.write_text(json.dumps({"version": 0, "roots": [{"type": "file", "name": str(legacy), "external-contents": str(replacement)}]}))
    print(overlay)
