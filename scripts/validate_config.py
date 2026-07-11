#!/usr/bin/env python3
"""Validate Espanso settings and the generated ICD-10-CM reference."""

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
EXPECTED_ICD_COUNT = 219
EXPECTED_MATCH_COUNT = 253
ICD_REFERENCE_PATH = ROOT / "ICD-10-CM.md"
SEMVER_PATTERN = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
ICD_PATTERN = re.compile(r"^[A-Z][0-9A-Z]{2}(?:\.[0-9A-Z]{1,7})?$")

EXPECTED_SINGLE_LINE_TEMPLATES = {
    ";date": "{{today}}",
    ";ntdil": "- arrange dilated exam NT",
    ";ntcata": "- arrange CATA survey NT",
    ";ntgs": "- arrange VF 24-2/30-2$|$ NT",
    ";ntvf": "- arrange VF 24-2/30-2? NT",
    ";ntfag": "- arrange FAG NT",
    ";nticg": "- arrange FAG+ICG NT",
    ";acata": "- APPLY Cataract (OD/OS/OU)? {{today}}",
    ";ablue": "- APPLY Trypan blue (OD/OS/OU)? {{today}}",
    ";aivi": "- APPLY IVI-(E2/E8/V/L/O)? {{today}}",
    ";vt": "- arrange VT on {{today}}",
    ";mp": "- arrange VT+MP(sharkskin+TWIN) on {{today}}",
    ";pvd": (
        "- Explain warning signs of retinal tear/detachment. Return to OPD/ER "
        "immediately if flashes, floaters, or visual field defect worsen."
    ),
    ";dr": "- Suggest blood sugar and blood pressure control.",
}

EXPECTED_CATA_FIRST_LINES = {
    ";cataod": "- arrange CATA (please explain NHI/EDOF/Trifocal) OD on {{today}}?. TEL: $|$",
    ";cataos": "- arrange CATA (please explain NHI/EDOF/Trifocal) OS on {{today}}?. TEL: $|$",
    ";cataou": "- arrange CATA (please explain NHI/EDOF/Trifocal) OU on {{today}}?. TEL: $|$",
    ";lensxod": "- arrange LenSx+CATA (please explain NHI/EDOF/Trifocal) OD on {{today}}?. TEL: $|$",
    ";lensxos": "- arrange LenSx+CATA (please explain NHI/EDOF/Trifocal) OS on {{today}}?. TEL: $|$",
    ";lensxou": "- arrange LenSx+CATA (please explain NHI/EDOF/Trifocal) OU on {{today}}?. TEL: $|$",
}
CATA_SECOND_LINE = "- GL before? driving? night driving? bus? TV? computer? cellphone? book?"

EXPECTED_IVI_TEMPLATES = {
    ";iviod": ", IVI-$|$ OD {{today}}",
    ";ivios": ", IVI-$|$ OS {{today}}",
    ";iviou": ", IVI-$|$ OU {{today}}",
}

EXPECTED_RVO_ICD_MATCHES = {
    ";.crvo;": "H34.8190",
    ";.crvood;": "H34.8110",
    ";.crvoos;": "H34.8120",
    ";.crvoou;": "H34.8130",
    ";.brvo;": "H34.8390",
    ";.brvood;": "H34.8310",
    ";.brvoos;": "H34.8320",
    ";.brvoou;": "H34.8330",
}
EXPECTED_EYELID_ICD_MATCHES = {
    ";.entroru;": "H02.001",
    ";.entrorl;": "H02.002",
    ";.entrolu;": "H02.004",
    ";.entroll;": "H02.005",
    ";.entroou;": "H02.009",
    ";.ectroru;": "H02.101",
    ";.ectrorl;": "H02.102",
    ";.ectrolu;": "H02.104",
    ";.ectroll;": "H02.105",
    ";.ectroou;": "H02.109",
    ";.trichiru;": "H02.051",
    ";.trichirl;": "H02.052",
    ";.trichilu;": "H02.054",
    ";.trichill;": "H02.055",
    ";.trichiou;": "H02.059",
    ";.ptosisod;": "H02.401",
    ";.ptosisos;": "H02.402",
    ";.ptosisou;": "H02.403",
}
RETIRED_RVO_TRIGGERS = {
    ";.crvodme;",
    ";.crvodmeod;",
    ";.crvodmeos;",
    ";.crvodmeou;",
    ";.brvodme;",
    ";.brvodmeod;",
    ";.brvodmeos;",
    ";.brvodmeou;",
}

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


def normalized_code(code: str) -> str:
    return code.replace(".", "").upper()


def load_yaml(relative_path: str):
    path = ROOT / relative_path
    require(path.is_file(), f"Missing required file: {relative_path}")
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as error:
        raise ValidationError(f"Invalid YAML in {relative_path}: {error}") from error


def load_cms_descriptions(cms_file: Path | None) -> dict[str, str]:
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

    descriptions: dict[str, str] = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(maxsplit=1)
        require(len(parts) == 2, f"CMS code entry has no description: {line!r}")
        code, description = parts
        descriptions[code.upper()] = " ".join(description.split())
    require(len(descriptions) > 70_000, f"CMS code list is unexpectedly small: {len(descriptions)}")
    return descriptions


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


def render_icd_reference(
    icd_items: dict[str, dict], cms_descriptions: dict[str, str]
) -> str:
    lines = [
        "# ICD-10-CM Reference",
        "",
        "This table is for review only. Espanso ICD triggers insert the code only.",
        "The diagnosis description is never inserted into clinical text.",
        "",
        "Source: CMS April 1, 2026 ICD-10-CM code descriptions.",
        "Applicable through September 30, 2026.",
        "",
        "| Trigger | ICD-10-CM code | Official CMS description |",
        "| --- | --- | --- |",
    ]
    for trigger in sorted(icd_items):
        code = icd_items[trigger]["replace"]
        description = cms_descriptions[normalized_code(code)].replace("|", "\\|")
        lines.append(f"| `{trigger}` | `{code}` | {description} |")
    return "\n".join(lines) + "\n"


def validate_repository(cms_file: Path | None, write_icd_reference: bool) -> dict[str, int | str]:
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
    require(
        len(trigger_map) == EXPECTED_MATCH_COUNT,
        f"Expected {EXPECTED_MATCH_COUNT} triggers, found {len(trigger_map)}",
    )
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
    expected_force_modes = {
        ";init": "clipboard",
        ";ded": "clipboard",
        **{trigger: "clipboard" for trigger in EXPECTED_CATA_FIRST_LINES},
    }
    require(force_modes == expected_force_modes, f"Unexpected force_mode entries: {force_modes}")
    require(
        trigger_map[";ded"].get("replace", "").splitlines()
        == [
            "- try ONSD/AT + fox TID OU + ery/vidisc/dura HS OU",
            "- suggest warm compression BID OU",
        ],
        ";ded multiline replacement changed unexpectedly",
    )
    init_lines = trigger_map[";init"].get("replace", "").splitlines()
    require(
        len(init_lines) == 9 and init_lines[0] == "VA:" and init_lines[-1] == "OCT: flat macula OU",
        ";init multiline replacement is incomplete",
    )

    for trigger in (";dilate", ";cataNT", ";cataop"):
        require(trigger not in trigger_map, f"Retired template trigger remains: {trigger}")
    for trigger, replacement in EXPECTED_SINGLE_LINE_TEMPLATES.items():
        require(
            trigger_map.get(trigger, {}).get("replace") == replacement,
            f"Unexpected replacement for {trigger}",
        )
    for trigger, replacement in EXPECTED_IVI_TEMPLATES.items():
        require(
            trigger_map.get(trigger, {}).get("replace") == replacement,
            f"Unexpected replacement for {trigger}",
        )
    for trigger, first_line in EXPECTED_CATA_FIRST_LINES.items():
        require(
            trigger_map.get(trigger, {}).get("replace", "").splitlines()
            == [first_line, CATA_SECOND_LINE],
            f"Unexpected multiline replacement for {trigger}",
        )

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
    for trigger, expected_code in EXPECTED_RVO_ICD_MATCHES.items():
        require(trigger in icd_items, f"RVO ICD trigger is missing: {trigger}")
        require(icd_items[trigger].get("replace") == expected_code, f"RVO ICD mapping changed: {trigger}")
    for trigger, expected_code in EXPECTED_EYELID_ICD_MATCHES.items():
        require(trigger in icd_items, f"Eyelid ICD trigger is missing: {trigger}")
        require(
            icd_items[trigger].get("replace") == expected_code,
            f"Eyelid ICD mapping changed: {trigger}",
        )
    for trigger in RETIRED_RVO_TRIGGERS:
        require(trigger not in trigger_map, f"Retired RVO ICD trigger remains: {trigger}")

    cms_descriptions = load_cms_descriptions(cms_file)
    missing_codes = sorted(
        (trigger, item["replace"])
        for trigger, item in icd_items.items()
        if normalized_code(item["replace"]) not in cms_descriptions
    )
    require(not missing_codes, f"ICD codes absent from CMS FY2026: {missing_codes[:10]}")

    reference = render_icd_reference(icd_items, cms_descriptions)
    if write_icd_reference:
        ICD_REFERENCE_PATH.write_text(reference, encoding="utf-8")
    else:
        require(ICD_REFERENCE_PATH.is_file(), "Missing ICD-10-CM.md; run with --write-icd-reference")
        require(
            ICD_REFERENCE_PATH.read_text(encoding="utf-8") == reference,
            "ICD-10-CM.md is out of date; run with --write-icd-reference",
        )

    require(
        default_config
        == {
            "key_delay": 10,
            "search_shortcut": "CTRL+ALT+SPACE",
            "search_trigger": ";help",
        },
        "config/default.yml is not the approved global configuration",
    )

    sensitive_patterns = {
        "GitHub token": re.compile(r"\b(?:gho|ghp|github_pat)_[A-Za-z0-9_]+"),
        "private key": re.compile(r"-----BEGIN (?:RSA |OPENSSH )?PRIVATE KEY-----"),
        "password assignment": re.compile(r"(?im)^\s*(?:password|passwd|api[_-]?key|secret|token)\s*[:=]\s*\S+"),
    }
    scanned_suffixes = {".yml", ".yaml", ".md", ".py", ".txt"}
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
        "cms_codes": len(cms_descriptions),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--cms-file",
        type=Path,
        help="Use an already extracted CMS icd10cm_codes_2026.txt file",
    )
    parser.add_argument(
        "--write-icd-reference",
        action="store_true",
        help="Regenerate ICD-10-CM.md from the current matches and CMS descriptions",
    )
    args = parser.parse_args()
    try:
        summary = validate_repository(args.cms_file, args.write_icd_reference)
    except ValidationError as error:
        print(f"VALIDATION FAILED: {error}", file=sys.stderr)
        return 1

    if args.write_icd_reference:
        print("WROTE ICD-10-CM.md")
    print(
        "VALIDATION OK: "
        f"version={summary['version']} matches={summary['matches']} "
        f"icd_triggers={summary['icd_triggers']} cms_codes={summary['cms_codes']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
