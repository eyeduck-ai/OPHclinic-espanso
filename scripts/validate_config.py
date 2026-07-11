#!/usr/bin/env python3
"""Validate the Espanso package and its ICD-10-CM invariants."""

from __future__ import annotations

import argparse
import hashlib
import io
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
CMS_URL = (
    "https://www.cms.gov/files/zip/"
    "april-1-2026-code-descriptions-tabular-order.zip"
)
CMS_ZIP_SHA256 = "4fd9d8b37f02ab42827c7e7be30595c005b0cc3a6bae7a515e3f4c86b6918688"
EXPECTED_ICD_COUNT = 201
SEMVER_PATTERN = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
ICD_PATTERN = re.compile(r"^[A-Z][0-9A-Z]{2}(?:\.[0-9A-Z]{1,7})?$")

ORIGINAL_ICD_MATCHES = {
    ";.ded;": "H04.129",
    ";.asth;": "H53.149",
    ";.cata;": "H25.9",
    ";.iol;": "Z96.1",
    ";.sch;": "H11.30",
    ";.punctate;": "H16.149",
    ";.conj;": "H10.9",
    ";.blephconj;": "H10.509",
    ";.vo;": "H43.399",
    ";.poag;": "H40.10X0",
    ";.dm;": "E11.8",
    ";.pdr;": "E11.3599",
}


class ValidationError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_yaml(relative_path: str):
    path = ROOT / relative_path
    require(path.is_file(), f"Missing required file: {relative_path}")
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as error:
        raise ValidationError(f"Invalid YAML in {relative_path}: {error}") from error


def load_cms_codes(cms_file: Path | None) -> set[str]:
    if cms_file is not None:
        require(cms_file.is_file(), f"CMS code file not found: {cms_file}")
        content = cms_file.read_bytes()
    else:
        request = urllib.request.Request(
            CMS_URL,
            headers={"User-Agent": "OPHclinic-espanso-validator/1.0"},
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                archive = response.read()
        except Exception as error:
            raise ValidationError(f"Unable to download CMS code archive: {error}") from error

        actual_hash = sha256_bytes(archive)
        require(
            actual_hash == CMS_ZIP_SHA256,
            "CMS archive SHA-256 changed; review the official source before updating "
            f"the pinned hash (expected {CMS_ZIP_SHA256}, got {actual_hash})",
        )
        try:
            with zipfile.ZipFile(io.BytesIO(archive)) as cms_zip:
                members = [
                    name
                    for name in cms_zip.namelist()
                    if name.replace("\\", "/").endswith("/icd10cm_codes_2026.txt")
                    or name == "icd10cm_codes_2026.txt"
                ]
                require(len(members) == 1, "CMS archive does not contain one code file")
                content = cms_zip.read(members[0])
        except (zipfile.BadZipFile, KeyError) as error:
            raise ValidationError(f"Unable to read CMS code archive: {error}") from error

    try:
        lines = content.decode("utf-8-sig").splitlines()
    except UnicodeDecodeError as error:
        raise ValidationError(f"CMS code file is not UTF-8: {error}") from error

    codes = {line.split()[0].upper() for line in lines if line.strip()}
    require(len(codes) > 70_000, f"CMS code list is unexpectedly small: {len(codes)}")
    return codes


def collect_trigger_map(matches: list[dict]) -> dict[str, dict]:
    trigger_map: dict[str, dict] = {}
    for index, item in enumerate(matches):
        require(isinstance(item, dict), f"Match #{index + 1} is not an object")
        triggers = []
        if "trigger" in item:
            triggers.append(item["trigger"])
        if "triggers" in item:
            require(isinstance(item["triggers"], list), f"Match #{index + 1} triggers is not a list")
            triggers.extend(item["triggers"])
        require(triggers, f"Match #{index + 1} has no trigger")
        for trigger in triggers:
            require(isinstance(trigger, str) and trigger, f"Match #{index + 1} has an invalid trigger")
            require(trigger not in trigger_map, f"Duplicate trigger: {trigger}")
            trigger_map[trigger] = item
    return trigger_map


def validate_repository(cms_file: Path | None) -> dict[str, int | str]:
    manifest = load_yaml("_manifest.yml")
    package = load_yaml("package.yml")
    match_config = load_yaml("match/ophthalmology.yml")
    default_config = load_yaml("config/default.yml")

    require(isinstance(manifest, dict), "_manifest.yml must contain an object")
    require(manifest.get("name") == "ophthalmology-clinic", "Unexpected package name")
    version = manifest.get("version")
    require(isinstance(version, str) and SEMVER_PATTERN.fullmatch(version), "Manifest version is not SemVer")
    require(
        manifest.get("homepage") == "https://github.com/eyeduck-ai/OPHclinic-espanso",
        "Manifest homepage must point to the GitHub repository",
    )
    updater_text = (ROOT / ".ophclinic" / "Update-OPHclinic.ps1").read_text(encoding="utf-8")
    updater_version = re.search(
        r'^\$script:UpdaterVersion\s*=\s*\[Version\]"([^"]+)"$',
        updater_text,
        re.MULTILINE,
    )
    require(updater_version is not None, "Updater version declaration is missing")
    require(updater_version.group(1) == version, "Updater version does not match manifest version")
    require(package == {"imports": ["match/ophthalmology.yml"]}, "Unexpected package.yml imports")

    require(isinstance(match_config, dict), "match/ophthalmology.yml must contain an object")
    global_vars = match_config.get("global_vars")
    require(isinstance(global_vars, list), "global_vars must be a list")
    today_vars = [item for item in global_vars if item.get("name") == "today"]
    require(len(today_vars) == 1, "Expected exactly one today variable")
    require(today_vars[0].get("params", {}).get("format") == "%Y%m%d", "Unexpected date format")

    matches = match_config.get("matches")
    require(isinstance(matches, list), "matches must be a list")
    trigger_map = collect_trigger_map(matches)
    prefix_pairs = sorted(
        (shorter, longer)
        for shorter in trigger_map
        for longer in trigger_map
        if shorter != longer and longer.startswith(shorter)
    )
    require(not prefix_pairs, f"Trigger prefix conflicts remain: {prefix_pairs[:10]}")

    force_modes = {
        trigger: item.get("force_mode")
        for trigger, item in trigger_map.items()
        if "force_mode" in item
    }
    require(
        force_modes == {";init": "clipboard", ";ded": "clipboard"},
        f"Unexpected force_mode entries: {force_modes}",
    )
    require(
        trigger_map[";ded"].get("replace", "").splitlines()
        == [
            "- try ONSD/AT + fox TID OU + ery/vidisc/dura HS OU",
            "- suggest warm compression BID OU",
        ],
        ";ded multiline replacement changed unexpectedly",
    )
    init_lines = trigger_map[";init"].get("replace", "").splitlines()
    require(len(init_lines) == 9 and init_lines[0] == "VA:" and init_lines[-1] == "OCT: flat macula OU", ";init multiline replacement is incomplete")

    icd_items = {
        trigger: item
        for trigger, item in trigger_map.items()
        if trigger.startswith(";.")
    }
    require(
        len(icd_items) == EXPECTED_ICD_COUNT,
        f"Expected {EXPECTED_ICD_COUNT} ICD triggers, found {len(icd_items)}",
    )
    for trigger, item in icd_items.items():
        require(trigger.endswith(";"), f"ICD trigger must end with a semicolon: {trigger}")
        replacement = item.get("replace")
        require(isinstance(replacement, str), f"{trigger} replacement is not text")
        require(ICD_PATTERN.fullmatch(replacement) is not None, f"{trigger} is not code-only: {replacement!r}")
        require("force_mode" not in item, f"ICD trigger {trigger} must not set force_mode")

    for trigger, expected_code in ORIGINAL_ICD_MATCHES.items():
        require(trigger in icd_items, f"Original ICD trigger is missing: {trigger}")
        require(icd_items[trigger].get("replace") == expected_code, f"Original ICD mapping changed: {trigger}")

    cms_codes = load_cms_codes(cms_file)
    missing_codes = sorted(
        (trigger, item["replace"])
        for trigger, item in icd_items.items()
        if item["replace"].replace(".", "").upper() not in cms_codes
    )
    require(not missing_codes, f"ICD codes absent from CMS FY2026: {missing_codes[:10]}")

    require(
        default_config
        == {
            "key_delay": 10,
            "search_shortcut": "CTRL+ALT+SPACE",
            "search_trigger": ";help",
        },
        "config/default.yml is not the approved global configuration",
    )
    require(not (ROOT / "config" / "notepad.yml").exists(), "Legacy config/notepad.yml must be removed")

    sensitive_patterns = {
        "GitHub token": re.compile(r"\b(?:gho|ghp|github_pat)_[A-Za-z0-9_]+"),
        "private key": re.compile(r"-----BEGIN (?:RSA |OPENSSH )?PRIVATE KEY-----"),
        "password assignment": re.compile(r"(?im)^\s*(?:password|passwd|api[_-]?key|secret|token)\s*[:=]\s*\S+"),
    }
    scanned_suffixes = {".yml", ".yaml", ".md", ".py", ".ps1", ".cmd", ".txt"}
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in scanned_suffixes:
            continue
        if any(part in {".git", "dist"} for part in path.parts):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for label, pattern in sensitive_patterns.items():
            require(pattern.search(text) is None, f"Potential {label} in {path.relative_to(ROOT)}")

    return {
        "version": version,
        "matches": len(trigger_map),
        "icd_triggers": len(icd_items),
        "cms_codes": len(cms_codes),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--cms-file",
        type=Path,
        help="Use an already extracted CMS icd10cm_codes_2026.txt file",
    )
    args = parser.parse_args()
    try:
        summary = validate_repository(args.cms_file)
    except ValidationError as error:
        print(f"VALIDATION FAILED: {error}", file=sys.stderr)
        return 1

    print(
        "VALIDATION OK: "
        f"version={summary['version']} matches={summary['matches']} "
        f"icd_triggers={summary['icd_triggers']} cms_codes={summary['cms_codes']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
