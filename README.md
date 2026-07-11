# OPHclinic Espanso

Espanso v2 snippets for ophthalmology outpatient notes and ICD-10-CM code entry.
ICD triggers expand to codes only; diagnosis labels are not inserted into clinical text.

## Files

- `_manifest.yml`: package identity and release version.
- `package.yml`: package entrypoint.
- `match/ophthalmology.yml`: shared clinic templates and ICD-10-CM matches.
- `config/default.yml`: shared global delay and search-bar configuration.
- `UPDATE_OPHCLINIC.cmd`: interactive manual updater for portable Espanso.
- `.ophclinic/Update-OPHclinic.ps1`: release downloader, verifier, installer, and rollback logic.

## Triggers

Template triggers start with `;`, for example `;init`, `;oct`, and `;ded`.
ICD-10-CM triggers start with `;.` and end with `;`. The terminator prevents a
short trigger from expanding before a longer trigger can be typed. Replacements
remain code only:

- `;.ded;` -> `H04.129`
- `;.cata;` -> `H25.9`
- `;.poag;` -> `H40.10X0`
- `;.pdr;` -> `E11.3599`

The date variable expands as `YYYYMMDD`.

## Portable Installation

Extract the release bootstrap ZIP into the portable Espanso directory, beside
`espanso.cmd`. Run:

```powershell
.\UPDATE_OPHCLINIC.cmd
```

Clients currently using v0.1.x must manually extract the v0.2.0 bootstrap once,
because the v0.1.x updater cannot update itself or read the schema 2 release. From
v0.2.0 onward, the updater also verifies and refreshes its own bootstrap files.

The updater discovers the portable directory from its own location, so the drive
letter does not matter. It downloads the latest non-draft GitHub release, verifies
both ZIP checksums and manifests, backs up the managed files, replaces the clinic
match and complete global default configuration, refreshes the bootstrap when
needed, and restarts Espanso. No scheduled task is created.

The default update refuses to overwrite the match or global default configuration
after either has been changed locally. To intentionally restore the GitHub release:

```powershell
powershell -NoProfile -File .\.ophclinic\Update-OPHclinic.ps1 -Force
```

Runtime state, logs, and the five newest transaction backups are stored under
`.ophclinic` in the portable directory. During the v0.2.0 migration, the known old
Notepad-only configuration is backed up and removed. A modified Notepad config is
preserved with a warning.

Updater exit codes:

- `0`: installed successfully or already current.
- `1`: download, validation, installation, or restart failure.
- `2`: local match/default drift detected; use `-Force` only after reviewing it.
- `3`: another updater process is already running.

## Finding Commands

Press `CTRL+ALT+SPACE`, or type `;help`, to open Espanso's Search bar. Search by
trigger or replacement, then choose the desired match. The normal Espanso CLI also
documents this command:

```powershell
.\espanso.cmd match list --only-triggers
```

Some portable Windows builds do not reliably print CLI output, so the Search bar
is the supported primary command browser for this package.

## Publishing

The manifest uses semantic versioning. A tag such as `v0.2.0` must match both the
`version` in `_manifest.yml` and `$script:UpdaterVersion` in the PowerShell updater.
Pushing the tag runs repository validation, Windows updater tests, builds the
managed and bootstrap ZIP files, and creates the GitHub release.

Local validation with the cached CMS file:

```powershell
python .\scripts\validate_config.py --cms-file "C:\path\to\icd10cm_codes_2026.txt"
python .\scripts\build_release.py --tag v0.2.0 --output dist
powershell -NoProfile -File .\tests\Test-Update-OPHclinic.ps1
```

## Injection Compatibility

The multiline `;init` and `;ded` templates use `force_mode: clipboard`. ICD matches
do not force an injection mode. The managed global `config/default.yml` applies a
10 ms key delay to all applications and configures the Search bar shortcuts.

## ICD Source And Safety

The current codes are validated against the CMS April 1, 2026 ICD-10-CM code file,
applicable through September 30, 2026. Clinical staff remain responsible for
confirming that each code and template is appropriate for the encounter.

- CMS: https://www.cms.gov/medicare/coding-billing/icd-10-codes
- CDC: https://www.cdc.gov/nchs/icd/icd-10-cm/files.html

Do not commit patient information, credentials, tokens, or private clinic data to
this public repository.
