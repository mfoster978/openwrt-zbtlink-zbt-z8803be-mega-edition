"""Verify embedded source bytes locally without executing or contacting the router."""
import hashlib
import base64
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / "staged-sim2/manifest.json").read_text())
payload = Path(sys.argv[1]).read_bytes()
blocks = re.findall(
    rb'cat > "\$work/([0-9]+)" <<\'(SIM2_[a-f0-9]+)\'\n(.*?)\n\2\n',
    payload, re.S)
encoded_blocks = re.findall(
    rb'base64 -d > "\$work/([0-9]+)" <<\'(SIM2_[a-f0-9]+)\'\n(.*?)\n\2\n',
    payload, re.S)
encoded = bool(encoded_blocks)
if encoded:
    assert payload.isascii(), "Non-ASCII transport"
    blocks = encoded_blocks
assert len(blocks) == len(manifest), "Missing source payload"
for (number, marker, body), (name, entry) in zip(blocks, manifest.items()):
    data = base64.b64decode(body, validate=True) if encoded else body + b"\n"
    digest = hashlib.sha256(data).hexdigest()
    print(f"{name}: hash_match={digest == entry['staged_sha256']} non_ascii_bytes={sum(c > 127 for c in data)}")
    assert digest == entry["staged_sha256"], "Local embedded source mismatch"
print("PASS: all embedded payload hashes match the staged manifest")
if encoded:
    print("PASS: ASCII-only transport and validated base64 round-trip preserve exact bytes")
