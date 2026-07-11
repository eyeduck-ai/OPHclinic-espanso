[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$updater = Join-Path $repoRoot ".ophclinic\Update-OPHclinic.ps1"
$sourceMatch = Join-Path $repoRoot "match\ophthalmology.yml"
$sourceDefault = Join-Path $repoRoot "config\default.yml"
$sourceUpdater = Join-Path $repoRoot ".ophclinic\Update-OPHclinic.ps1"
$sourceCmd = Join-Path $repoRoot "UPDATE_OPHCLINIC.cmd"
$manifestText = Get-Content -LiteralPath (Join-Path $repoRoot "_manifest.yml") -Raw -Encoding UTF8
if ($manifestText -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$') {
    throw "Manifest version is missing or invalid"
}
$releaseVersion = $Matches[1]
$releaseTag = "v$releaseVersion"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ophclinic updater tests " + [Guid]::NewGuid().ToString("N"))
$testsPassed = 0
$knownNotepad = "filter_exec: '(?i)notepad\.exe$'`nkey_delay: 10`n"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Get-TestHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-FileRecord {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [ordered]@{
        sha256 = Get-TestHash -Path $Path
        size = (Get-Item -LiteralPath $Path).Length
    }
}

function New-FakePortable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$MatchContent = "matches:`r`n  - trigger: `";old`"`r`n    replace: `"old`"`r`n",
        [string]$DefaultContent = "show_icon: false`r`n",
        [ValidateSet("Known", "Modified", "Missing")][string]$NotepadMode = "Known",
        [int]$EspansoExitCode = 0
    )
    $root = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $root ".espanso\match") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root ".espanso\config") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root ".ophclinic") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root ".espanso\match\ophthalmology.yml") -Value $MatchContent -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root ".espanso\config\default.yml") -Value $DefaultContent -Encoding UTF8
    if ($NotepadMode -eq "Known") {
        [System.IO.File]::WriteAllText(
            (Join-Path $root ".espanso\config\notepad.yml"),
            $knownNotepad,
            (New-Object System.Text.UTF8Encoding($false))
        )
    } elseif ($NotepadMode -eq "Modified") {
        Set-Content -LiteralPath (Join-Path $root ".espanso\config\notepad.yml") -Value "filter_exec: custom.exe`r`nkey_delay: 20" -Encoding UTF8
    }
    @"
@echo off
exit /b $EspansoExitCode
"@ | Set-Content -LiteralPath (Join-Path $root "espanso.cmd") -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root "UPDATE_OPHCLINIC.cmd") -Value "@echo old updater" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root ".ophclinic\Update-OPHclinic.ps1") -Value "# old updater" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root "OPHCLINIC-BOOTSTRAP.txt") -Value "old bootstrap" -Encoding ASCII
    return $root
}

function New-ReleaseFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$BadManagedChecksum,
        [switch]$BadBootstrapChecksum,
        [switch]$UnexpectedFile
    )
    $fixtureRoot = Join-Path $testRoot $Name
    $managedStage = Join-Path $fixtureRoot "managed-stage"
    $bootstrapStage = Join-Path $fixtureRoot "bootstrap-stage"
    New-Item -ItemType Directory -Path (Join-Path $managedStage "match") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $managedStage "config") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bootstrapStage ".ophclinic") -Force | Out-Null
    Copy-Item -LiteralPath $sourceMatch -Destination (Join-Path $managedStage "match\ophthalmology.yml")
    Copy-Item -LiteralPath $sourceDefault -Destination (Join-Path $managedStage "config\default.yml")
    Copy-Item -LiteralPath $sourceUpdater -Destination (Join-Path $bootstrapStage ".ophclinic\Update-OPHclinic.ps1")
    Copy-Item -LiteralPath $sourceCmd -Destination (Join-Path $bootstrapStage "UPDATE_OPHCLINIC.cmd")
    Set-Content -LiteralPath (Join-Path $bootstrapStage "OPHCLINIC-BOOTSTRAP.txt") -Value "fixture bootstrap $releaseTag" -Encoding ASCII

    $managedFiles = [ordered]@{
        "config/default.yml" = New-FileRecord -Path (Join-Path $managedStage "config\default.yml")
        "match/ophthalmology.yml" = New-FileRecord -Path (Join-Path $managedStage "match\ophthalmology.yml")
    }
    $releaseManifest = [ordered]@{
        schema_version = 2
        package = "ophthalmology-clinic"
        repository = "eyeduck-ai/OPHclinic-espanso"
        version = $releaseVersion
        tag = $releaseTag
        files = $managedFiles
    }
    $releaseManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $managedStage "release-manifest.json") -Encoding UTF8

    $bootstrapFiles = [ordered]@{
        ".ophclinic/Update-OPHclinic.ps1" = New-FileRecord -Path (Join-Path $bootstrapStage ".ophclinic\Update-OPHclinic.ps1")
        "OPHCLINIC-BOOTSTRAP.txt" = New-FileRecord -Path (Join-Path $bootstrapStage "OPHCLINIC-BOOTSTRAP.txt")
        "UPDATE_OPHCLINIC.cmd" = New-FileRecord -Path (Join-Path $bootstrapStage "UPDATE_OPHCLINIC.cmd")
    }
    $bootstrapManifest = [ordered]@{
        schema_version = 1
        repository = "eyeduck-ai/OPHclinic-espanso"
        version = $releaseVersion
        tag = $releaseTag
        files = $bootstrapFiles
    }
    $bootstrapManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $bootstrapStage "bootstrap-manifest.json") -Encoding UTF8

    if ($UnexpectedFile) {
        Set-Content -LiteralPath (Join-Path $managedStage "unexpected.txt") -Value "unexpected" -Encoding ASCII
    }

    $managedName = "OPHclinic-espanso-$releaseTag.zip"
    $managedZip = Join-Path $fixtureRoot $managedName
    Compress-Archive -Path (Join-Path $managedStage "*") -DestinationPath $managedZip -CompressionLevel Optimal
    $managedHash = Get-TestHash -Path $managedZip
    if ($BadManagedChecksum) {
        $replacementPrefix = if ($managedHash[0] -eq '0') { '1' } else { '0' }
        $managedHash = $replacementPrefix + $managedHash.Substring(1)
    }
    Set-Content -LiteralPath "$managedZip.sha256" -Value "$managedHash  $managedName" -Encoding ASCII

    $bootstrapName = "OPHclinic-espanso-bootstrap-$releaseTag.zip"
    $bootstrapZip = Join-Path $fixtureRoot $bootstrapName
    Compress-Archive -Path (Join-Path $bootstrapStage "*") -DestinationPath $bootstrapZip -CompressionLevel Optimal
    $bootstrapHash = Get-TestHash -Path $bootstrapZip
    if ($BadBootstrapChecksum) {
        $replacementPrefix = if ($bootstrapHash[0] -eq '0') { '1' } else { '0' }
        $bootstrapHash = $replacementPrefix + $bootstrapHash.Substring(1)
    }
    Set-Content -LiteralPath "$bootstrapZip.sha256" -Value "$bootstrapHash  $bootstrapName" -Encoding ASCII

    $metadata = [ordered]@{
        tag_name = $releaseTag
        draft = $false
        prerelease = $false
        html_url = "https://example.invalid/release/$releaseTag"
        assets = @(
            [ordered]@{ name = $managedName; browser_download_url = ([Uri]$managedZip).AbsoluteUri },
            [ordered]@{ name = "$managedName.sha256"; browser_download_url = ([Uri]"$managedZip.sha256").AbsoluteUri },
            [ordered]@{ name = $bootstrapName; browser_download_url = ([Uri]$bootstrapZip).AbsoluteUri },
            [ordered]@{ name = "$bootstrapName.sha256"; browser_download_url = ([Uri]"$bootstrapZip.sha256").AbsoluteUri }
        )
    }
    $metadataPath = Join-Path $fixtureRoot "release.json"
    $metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    return $metadataPath
}

function Invoke-TestUpdater {
    param(
        [Parameter(Mandatory = $true)][string]$PortableRoot,
        [Parameter(Mandatory = $true)][string]$MetadataPath,
        [switch]$Force,
        [switch]$SkipRestart
    )
    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $updater,
        "-PortableRoot", $PortableRoot,
        "-ReleaseMetadataPath", $MetadataPath
    )
    if ($Force) { $arguments += "-Force" }
    if ($SkipRestart) { $arguments += "-SkipRestart" }
    $output = & powershell.exe @arguments 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Output = ($output -join [Environment]::NewLine) }
}

function Pass-Test {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:testsPassed += 1
    Write-Host "PASS: $Name"
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $cmdText = Get-Content -LiteralPath $sourceCmd -Raw -Encoding ASCII
    Assert-True ($cmdText.Contains('-PortableRoot "%~dp0."')) "CMD updater passes a root path with a trailing backslash"
    Pass-Test "CMD updater portable-root quoting"

    $validMetadata = New-ReleaseFixture -Name "valid-release"
    $releaseMatchHash = Get-TestHash -Path $sourceMatch
    $releaseDefaultHash = Get-TestHash -Path $sourceDefault
    $releaseUpdaterHash = Get-TestHash -Path $sourceUpdater
    $releaseCmdHash = Get-TestHash -Path $sourceCmd

    $managedRoot = New-FakePortable -Name "managed client"
    $managedMatch = Join-Path $managedRoot ".espanso\match\ophthalmology.yml"
    $managedDefault = Join-Path $managedRoot ".espanso\config\default.yml"
    $managedNotepad = Join-Path $managedRoot ".espanso\config\notepad.yml"
    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 0) "Initial install failed: $($result.Output)"
    Assert-True ((Get-TestHash -Path $managedMatch) -eq $releaseMatchHash) "Initial install did not deploy release match"
    Assert-True ((Get-TestHash -Path $managedDefault) -eq $releaseDefaultHash) "Initial install did not deploy global default"
    Assert-True (-not (Test-Path -LiteralPath $managedNotepad)) "Known legacy Notepad config was not removed"
    Assert-True ((Get-TestHash -Path (Join-Path $managedRoot ".ophclinic\Update-OPHclinic.ps1")) -eq $releaseUpdaterHash) "Updater did not self-update"
    Assert-True ((Get-TestHash -Path (Join-Path $managedRoot "UPDATE_OPHCLINIC.cmd")) -eq $releaseCmdHash) "CMD bootstrap did not self-update"
    $state = Get-Content -LiteralPath (Join-Path $managedRoot ".ophclinic\state.json") -Raw | ConvertFrom-Json
    Assert-True ([int]$state.schema_version -eq 2) "Initial install did not write schema 2 state"
    $transaction = @(Get-ChildItem -LiteralPath (Join-Path $managedRoot ".ophclinic\backups") -Directory)
    Assert-True ($transaction.Count -eq 1) "Initial install did not create one transaction backup"
    Assert-True (Test-Path -LiteralPath (Join-Path $transaction[0].FullName "managed\match\ophthalmology.yml")) "Match backup is missing"
    Assert-True (Test-Path -LiteralPath (Join-Path $transaction[0].FullName "managed\config\default.yml")) "Default backup is missing"
    Assert-True (Test-Path -LiteralPath (Join-Path $transaction[0].FullName "legacy\config\notepad.yml")) "Legacy Notepad backup is missing"
    Pass-Test "initial install, global config, migration, and bootstrap self-update"

    $backupCount = @(Get-ChildItem -LiteralPath (Join-Path $managedRoot ".ophclinic\backups") -Directory).Count
    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 0) "No-op update failed: $($result.Output)"
    Assert-True ($result.Output -match [regex]::Escape("Already current at $releaseTag")) "No-op did not report current version"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $managedRoot ".ophclinic\backups") -Directory).Count -eq $backupCount) "No-op update created a backup"
    Pass-Test "already-current no-op"

    Add-Content -LiteralPath $managedMatch -Value "# local match drift" -Encoding UTF8
    $matchDriftHash = Get-TestHash -Path $managedMatch
    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 2) "Match drift did not return exit code 2"
    Assert-True ((Get-TestHash -Path $managedMatch) -eq $matchDriftHash) "Match drift check changed the file"
    Pass-Test "match drift protection"

    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart -Force
    Assert-True ($result.ExitCode -eq 0) "Force did not restore match: $($result.Output)"
    Add-Content -LiteralPath $managedDefault -Value "# local default drift" -Encoding UTF8
    $defaultDriftHash = Get-TestHash -Path $managedDefault
    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 2) "Default drift did not return exit code 2"
    Assert-True ((Get-TestHash -Path $managedDefault) -eq $defaultDriftHash) "Default drift check changed the file"
    Pass-Test "default drift protection"

    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart -Force
    Assert-True ($result.ExitCode -eq 0) "Force did not restore default: $($result.Output)"
    Assert-True ((Get-TestHash -Path $managedMatch) -eq $releaseMatchHash) "Force did not restore release match"
    Assert-True ((Get-TestHash -Path $managedDefault) -eq $releaseDefaultHash) "Force did not restore release default"
    Pass-Test "forced restore of all managed files"

    $schema1Root = New-FakePortable -Name "schema1 migration"
    $schema1Match = Join-Path $schema1Root ".espanso\match\ophthalmology.yml"
    $schema1State = [ordered]@{
        schema_version = 1
        version = "0.1.1"
        tag = "v0.1.1"
        match_sha256 = Get-TestHash -Path $schema1Match
    }
    $schema1State | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $schema1Root ".ophclinic\state.json") -Encoding UTF8
    $result = Invoke-TestUpdater -PortableRoot $schema1Root -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 0) "Schema 1 migration failed: $($result.Output)"
    $migratedState = Get-Content -LiteralPath (Join-Path $schema1Root ".ophclinic\state.json") -Raw | ConvertFrom-Json
    Assert-True ([int]$migratedState.schema_version -eq 2) "Schema 1 state was not migrated"
    Assert-True ((Get-TestHash -Path (Join-Path $schema1Root ".espanso\config\default.yml")) -eq $releaseDefaultHash) "Schema 1 migration did not install default"
    Pass-Test "schema 1 to schema 2 migration"

    $modifiedNotepadRoot = New-FakePortable -Name "modified notepad" -NotepadMode Modified
    $modifiedNotepadPath = Join-Path $modifiedNotepadRoot ".espanso\config\notepad.yml"
    $modifiedNotepadHash = Get-TestHash -Path $modifiedNotepadPath
    $result = Invoke-TestUpdater -PortableRoot $modifiedNotepadRoot -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 0) "Modified Notepad install failed: $($result.Output)"
    Assert-True ((Get-TestHash -Path $modifiedNotepadPath) -eq $modifiedNotepadHash) "Modified Notepad config was changed"
    Assert-True ($result.Output -match "Preserved modified legacy Notepad") "Modified Notepad preservation was not reported"
    Pass-Test "modified legacy Notepad preservation"

    $offlineRoot = New-FakePortable -Name "offline client"
    $offlineMatch = Join-Path $offlineRoot ".espanso\match\ophthalmology.yml"
    $offlineDefault = Join-Path $offlineRoot ".espanso\config\default.yml"
    $offlineMatchHash = Get-TestHash -Path $offlineMatch
    $offlineDefaultHash = Get-TestHash -Path $offlineDefault
    $result = Invoke-TestUpdater -PortableRoot $offlineRoot -MetadataPath (Join-Path $testRoot "missing-release.json") -SkipRestart
    Assert-True ($result.ExitCode -eq 1) "Missing metadata did not fail"
    Assert-True ((Get-TestHash -Path $offlineMatch) -eq $offlineMatchHash -and (Get-TestHash -Path $offlineDefault) -eq $offlineDefaultHash) "Metadata failure changed managed files"
    Pass-Test "offline or metadata failure preservation"

    $badManagedMetadata = New-ReleaseFixture -Name "bad managed checksum" -BadManagedChecksum
    $badManagedRoot = New-FakePortable -Name "bad managed client"
    $badManagedOriginal = Get-TestHash -Path (Join-Path $badManagedRoot ".espanso\match\ophthalmology.yml")
    $result = Invoke-TestUpdater -PortableRoot $badManagedRoot -MetadataPath $badManagedMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 1) "Bad managed checksum did not fail"
    Assert-True ((Get-TestHash -Path (Join-Path $badManagedRoot ".espanso\match\ophthalmology.yml")) -eq $badManagedOriginal) "Bad managed checksum changed match"
    Pass-Test "managed checksum failure preservation"

    $badBootstrapMetadata = New-ReleaseFixture -Name "bad bootstrap checksum" -BadBootstrapChecksum
    $badBootstrapRoot = New-FakePortable -Name "bad bootstrap client"
    $badBootstrapOriginal = Get-TestHash -Path (Join-Path $badBootstrapRoot ".espanso\config\default.yml")
    $result = Invoke-TestUpdater -PortableRoot $badBootstrapRoot -MetadataPath $badBootstrapMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 1) "Bad bootstrap checksum did not fail"
    Assert-True ((Get-TestHash -Path (Join-Path $badBootstrapRoot ".espanso\config\default.yml")) -eq $badBootstrapOriginal) "Bad bootstrap checksum changed default"
    Pass-Test "bootstrap checksum failure preservation"

    $invalidMetadata = New-ReleaseFixture -Name "unexpected archive" -UnexpectedFile
    $invalidRoot = New-FakePortable -Name "invalid archive client"
    $invalidOriginal = Get-TestHash -Path (Join-Path $invalidRoot ".espanso\match\ophthalmology.yml")
    $result = Invoke-TestUpdater -PortableRoot $invalidRoot -MetadataPath $invalidMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 1) "Unexpected archive file did not fail"
    Assert-True ((Get-TestHash -Path (Join-Path $invalidRoot ".espanso\match\ophthalmology.yml")) -eq $invalidOriginal) "Invalid archive changed match"
    Pass-Test "invalid archive preservation"

    $restartRoot = New-FakePortable -Name "restart rollback client" -EspansoExitCode 1
    $restartMatch = Join-Path $restartRoot ".espanso\match\ophthalmology.yml"
    $restartDefault = Join-Path $restartRoot ".espanso\config\default.yml"
    $restartNotepad = Join-Path $restartRoot ".espanso\config\notepad.yml"
    $restartMatchHash = Get-TestHash -Path $restartMatch
    $restartDefaultHash = Get-TestHash -Path $restartDefault
    $restartNotepadHash = Get-TestHash -Path $restartNotepad
    $result = Invoke-TestUpdater -PortableRoot $restartRoot -MetadataPath $validMetadata
    Assert-True ($result.ExitCode -eq 1) "Restart failure did not fail"
    Assert-True ((Get-TestHash -Path $restartMatch) -eq $restartMatchHash) "Restart rollback did not restore match"
    Assert-True ((Get-TestHash -Path $restartDefault) -eq $restartDefaultHash) "Restart rollback did not restore default"
    Assert-True ((Get-TestHash -Path $restartNotepad) -eq $restartNotepadHash) "Restart rollback did not restore Notepad config"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $restartRoot ".ophclinic\state.json"))) "Restart failure wrote managed state"
    Pass-Test "multi-file restart failure rollback"

    Assert-True ($managedRoot -notmatch '^E:\\') "Test portable root unexpectedly used E drive"
    Pass-Test "portable-relative path"

    Write-Host "UPDATER TESTS OK: $testsPassed tests passed"
} finally {
    $normalizedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $normalizedTest = [System.IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    if ($normalizedTest.StartsWith($normalizedTemp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

exit 0
