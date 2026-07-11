#!/usr/bin/env python3
"""Build the deterministic manual-install Espanso release archive."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import zipfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ZIP_TIMESTAMP = (2020, 1, 1, 0, 0, 0)
RELEASE_FILES = {
    ".espanso/config/default.yml": ROOT / "config" / "default.yml",
    ".espanso/match/ophthalmology.yml": ROOT / "match" / "ophthalmology.yml",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def add_file(archive: zipfile.ZipFile, archive_name: str, source: Path) -> None:
    info = zipfile.ZipInfo(archive_name, date_time=ZIP_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    archive.writestr(info, source.read_bytes())


def write_checksum(path: Path) -> Path:
    checksum_path = path.with_name(path.name + ".sha256")
    checksum_path.write_text(f"{sha256_file(path)}  {path.name}\n", encoding="ascii")
    return checksum_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True, help="Release tag, for example v1.0.0")
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

    missing_files = [name for name, path in RELEASE_FILES.items() if not path.is_file()]
    if missing_files:
        raise SystemExit(f"Missing release files: {missing_files}")

    archive_name = f"OPHclinic-espanso-{args.tag}.zip"
    archive_path = output / archive_name
    with zipfile.ZipFile(archive_path, "w") as archive:
        for archive_member, source in sorted(RELEASE_FILES.items()):
            add_file(archive, archive_member, source)

    with zipfile.ZipFile(archive_path) as archive:
        actual_names = sorted(archive.namelist())
    expected_names = sorted(RELEASE_FILES)
    if actual_names != expected_names:
        raise SystemExit(f"Unexpected release archive contents: {actual_names}")

    checksum_path = write_checksum(archive_path)
    print(f"BUILT {archive_path.name} sha256={sha256_file(archive_path)}")
    print(f"BUILT {checksum_path.name} sha256={sha256_file(checksum_path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
