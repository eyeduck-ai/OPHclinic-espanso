#!/usr/bin/env python3
"""Build deterministic managed and bootstrap release archives."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "eyeduck-ai/OPHclinic-espanso"
ZIP_TIMESTAMP = (2020, 1, 1, 0, 0, 0)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def add_bytes(archive: zipfile.ZipFile, name: str, content: bytes) -> None:
    info = zipfile.ZipInfo(name, date_time=ZIP_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    archive.writestr(info, content)


def write_checksum(path: Path) -> Path:
    checksum_path = path.with_name(path.name + ".sha256")
    checksum_path.write_text(f"{sha256_file(path)}  {path.name}\n", encoding="ascii")
    return checksum_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True, help="Release tag, for example v0.1.0")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()

    manifest = yaml.safe_load((ROOT / "_manifest.yml").read_text(encoding="utf-8"))
    version = str(manifest["version"])
    expected_tag = f"v{version}"
    if args.tag != expected_tag:
        raise SystemExit(f"Tag {args.tag!r} does not match manifest version {version!r}")

    output = args.output.resolve()
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    match_path = ROOT / "match" / "ophthalmology.yml"
    match_bytes = match_path.read_bytes()
    match_hash = hashlib.sha256(match_bytes).hexdigest()
    release_manifest = {
        "schema_version": 1,
        "package": "ophthalmology-clinic",
        "repository": REPOSITORY,
        "version": version,
        "tag": args.tag,
        "match_path": "match/ophthalmology.yml",
        "match_sha256": match_hash,
    }
    release_manifest_bytes = (
        json.dumps(release_manifest, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")

    managed_name = f"OPHclinic-espanso-{args.tag}.zip"
    managed_path = output / managed_name
    with zipfile.ZipFile(managed_path, "w") as archive:
        add_bytes(archive, "match/ophthalmology.yml", match_bytes)
        add_bytes(archive, "release-manifest.json", release_manifest_bytes)
    managed_checksum = write_checksum(managed_path)

    bootstrap_name = f"OPHclinic-espanso-bootstrap-{args.tag}.zip"
    bootstrap_path = output / bootstrap_name
    bootstrap_readme = (
        "OPHclinic Espanso portable updater\r\n"
        "\r\n"
        "1. Extract this ZIP into the portable Espanso directory beside espanso.cmd.\r\n"
        "2. Run UPDATE_OPHCLINIC.cmd.\r\n"
        "3. The updater installs only .espanso\\match\\ophthalmology.yml.\r\n"
        "4. Machine-local files under .espanso\\config are not changed.\r\n"
    ).encode("ascii")
    with zipfile.ZipFile(bootstrap_path, "w") as archive:
        add_bytes(archive, "UPDATE_OPHCLINIC.cmd", (ROOT / "UPDATE_OPHCLINIC.cmd").read_bytes())
        add_bytes(
            archive,
            ".ophclinic/Update-OPHclinic.ps1",
            (ROOT / ".ophclinic" / "Update-OPHclinic.ps1").read_bytes(),
        )
        add_bytes(archive, "OPHCLINIC-BOOTSTRAP.txt", bootstrap_readme)
    bootstrap_checksum = write_checksum(bootstrap_path)

    for path in (managed_path, managed_checksum, bootstrap_path, bootstrap_checksum):
        print(f"BUILT {path.name} sha256={sha256_file(path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
