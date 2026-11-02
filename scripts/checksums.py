#!/usr/bin/env python3
"""Generate checksums for downloadable ZIP archives, never for personal app state."""
import argparse
import hashlib
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument("--label", default="")
a = p.parse_args()
root = Path(__file__).resolve().parent.parent / "dist"
lines = []
for file in sorted(root.glob("FloatingReader-*.zip")):
    with file.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()
    lines.append(f"{digest}  {file.name}")
if not lines:
    raise SystemExit("No release ZIP archives found")
name = "SHA256SUMS" + ("-" + a.label if a.label else "") + ".txt"
(root / name).write_text("\n".join(lines) + "\n", encoding="utf-8")
print(root / name)
