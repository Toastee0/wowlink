"""Upload an addon zip to CurseForge. Standard library only; run by .github/workflows/curseforge.yml.

  CF_API_KEY=... python tools/cf_upload.py ZIP --version v1.2.0 [--changelog FILE] [--dry-run]

The project ID comes from "## X-Curse-Project-ID:" in WowLink/WowLink.toc, and the game
versions from its "## Interface:" line (11509 -> 1.15.9, 120105 -> 12.1.5, ...).
"""
import argparse
import json
import os
import re
import sys
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOC = ROOT / "WowLink" / "WowLink.toc"
API = "https://wow.curseforge.com/api"


def toc_field(name):
    m = re.search(rf"^## {re.escape(name)}:\s*(.+)$", TOC.read_text(encoding="utf-8"), re.M)
    return m.group(1).strip() if m else None


def interface_to_version(n):
    n = int(n)
    return f"{n // 10000}.{(n // 100) % 100}.{n % 100}"


def request(method, url, token, data=None, headers=None):
    req = urllib.request.Request(url, data=data, method=method, headers={"X-Api-Token": token, **(headers or {})})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("zip")
    ap.add_argument("--version", required=True)
    ap.add_argument("--changelog")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    project = toc_field("X-Curse-Project-ID")
    if not project:
        print("No X-Curse-Project-ID in the TOC yet; skipping the CurseForge upload.")
        return
    token = os.environ.get("CF_API_KEY")
    if not token:
        sys.exit("CF_API_KEY is not set (add it as a GitHub Actions secret).")

    wanted = [interface_to_version(x) for x in re.split(r"[,\s]+", toc_field("Interface")) if x]
    versions = request("GET", f"{API}/game/versions", token)
    by_name = {}
    for v in versions:
        by_name.setdefault(v["name"], v["id"])
    ids = [by_name[w] for w in wanted if w in by_name]
    print("Game versions:", ", ".join(f"{w}{'' if w in by_name else ' (not on CurseForge, skipped)'}" for w in wanted))
    if not ids:
        sys.exit("None of the TOC's game versions exist on CurseForge.")

    changelog = Path(a.changelog).read_text(encoding="utf-8") if a.changelog else f"WowLink {a.version}"
    metadata = {"changelog": changelog or f"WowLink {a.version}", "changelogType": "markdown",
                "displayName": f"WowLink {a.version}", "gameVersions": ids, "releaseType": "release"}
    if a.dry_run:
        print(json.dumps(metadata, indent=2))
        return

    boundary = uuid.uuid4().hex
    zip_path = Path(a.zip)
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"metadata\"\r\n"
            f"Content-Type: application/json\r\n\r\n{json.dumps(metadata)}\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{zip_path.name}\"\r\n"
            f"Content-Type: application/zip\r\n\r\n").encode("utf-8") + zip_path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    r = request("POST", f"{API}/projects/{project}/upload-file", token, body,
                {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    print(f"Uploaded to CurseForge project {project}: file id {r.get('id')}")


if __name__ == "__main__":
    main()
