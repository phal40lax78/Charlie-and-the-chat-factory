"""Package the Brain supervisor for release (stdlib only).

    python -I -X utf8 native/brain/tools/package.py

Builds chatq-brain.exe in release mode, zips it with README.md into
target/package/, and writes release-pin.json beside the zip.
Publishing is not part of this: the pin's url stays null.
"""
import hashlib
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

TARGET = "windows-x86_64"
BRAIN = Path(__file__).resolve().parent.parent
OUT = BRAIN / "target" / "package"


def version():
    text = (BRAIN / "Cargo.toml").read_text(encoding="utf-8")
    pkg = text.split("[package]", 1)[1].split("\n[", 1)[0]
    m = re.search(r'^version\s*=\s*"([^"]+)"', pkg, re.M)
    if not m:
        sys.exit("no version in Cargo.toml")
    return m.group(1)


def main():
    ver = version()
    subprocess.run(
        ["cargo", "build", "--release", "--manifest-path", str(BRAIN / "Cargo.toml")],
        check=True,
    )
    exe = BRAIN / "target" / "release" / "chatq-brain.exe"
    if not exe.is_file():
        sys.exit(f"missing {exe}")
    OUT.mkdir(parents=True, exist_ok=True)
    name = f"chatq-brain-{ver}-{TARGET}.zip"
    zpath = OUT / name
    if zpath.exists():
        zpath.unlink()
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for src, arc in ((exe, "chatq-brain.exe"),
                         (BRAIN / "README.md", "README.md")):
            info = zipfile.ZipInfo(arc, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, src.read_bytes())
    data = zpath.read_bytes()
    pin = {
        "target": TARGET,
        "version": ver,
        "file": name,
        "url": None,
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
        "note": "url is filled when the zip is published",
    }
    (OUT / "release-pin.json").write_text(
        json.dumps(pin, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(pin, indent=2))


if __name__ == "__main__":
    main()
