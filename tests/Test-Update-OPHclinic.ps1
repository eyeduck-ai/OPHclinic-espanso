[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$updater = Join-Path $repoRoot ".ophclinic\Update-OPHclinic.ps1"
$sourceMatch = Join-Path $repoRoot "match\ophthalmology.yml"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ophclinic-updater-tests-" + [Guid]::NewGuid().ToString("N"))
$testsPassed = 0

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

function New-FakePortable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$MatchContent = "matches:`r`n  - trigger: `";old`"`r`n    replace: `"old`"`r`n",
        [int]$EspansoExitCode = 0
    )
    $root = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $root ".espanso\match") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root ".espanso\config") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root ".espanso\match\ophthalmology.yml") -Value $MatchContent -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root ".espanso\config\notepad.yml") -Value "local-notepad-sentinel" -Encoding UTF8
    @"
@echo off
exit /b $EspansoExitCode
"@ | Set-Content -LiteralPath (Join-Path $root "espanso.cmd") -Encoding ASCII
    return $root
}

function New-ReleaseFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$BadChecksum,
        [switch]$UnexpectedFile
    )
    $fixtureRoot = Join-Path $testRoot $Name
    $stage = Join-Path $fixtureRoot "stage"
    New-Item -ItemType Directory -Path (Join-Path $stage "match") -Force | Out-Null
    Copy-Item -LiteralPath $sourceMatch -Destination (Join-Path $stage "match\ophthalmology.yml")
    $matchHash = Get-TestHash -Path (Join-Path $stage "match\ophthalmology.yml")
    $releaseManifest = [ordered]@{
        schema_version = 1
        package = "ophthalmology-clinic"
        repository = "eyeduck-ai/OPHclinic-espanso"
        version = "0.1.0"
        tag = "v0.1.0"
        match_path = "match/ophthalmology.yml"
        match_sha256 = $matchHash
    }
    $releaseManifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage "release-manifest.json") -Encoding UTF8
    if ($UnexpectedFile) {
        Set-Content -LiteralPath (Join-Path $stage "unexpected.txt") -Value "unexpected" -Encoding ASCII
    }

    $zipName = "OPHclinic-espanso-v0.1.0.zip"
    $zipPath = Join-Path $fixtureRoot $zipName
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal
    $zipHash = Get-TestHash -Path $zipPath
    if ($BadChecksum) {
        $replacementPrefix = if ($zipHash[0] -eq '0') { '1' } else { '0' }
        $zipHash = $replacementPrefix + $zipHash.Substring(1)
    }
    $checksumPath = "$zipPath.sha256"
    Set-Content -LiteralPath $checksumPath -Value "$zipHash  $zipName" -Encoding ASCII

    $metadata = [ordered]@{
        tag_name = "v0.1.0"
        draft = $false
        prerelease = $false
        html_url = "https://example.invalid/release/v0.1.0"
        assets = @(
            [ordered]@{ name = $zipName; browser_download_url = ([Uri]$zipPath).AbsoluteUri },
            [ordered]@{ name = "$zipName.sha256"; browser_download_url = ([Uri]$checksumPath).AbsoluteUri }
        )
    }
    $metadataPath = Join-Path $fixtureRoot "release.json"
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
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
    $validMetadata = New-ReleaseFixture -Name "valid-release"
    $releaseHash = Get-TestHash -Path $sourceMatch

    $managedRoot = New-FakePortable -Name "managed-client"
    $notepadPath = Join-Path $managedRoot ".espanso\config\notepad.yml"
    $notepadHash = Get-TestHash -Path $notepadPath
    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 0) "Initial install failed: $($result.Output)"
    Assert-True ((Get-TestHash -Path (Join-Path $managedRoot ".espanso\match\ophthalmology.yml")) -eq $releaseHash) "Initial install did not deploy release match"
    Assert-True ((Get-TestHash -Path $notepadPath) -eq $notepadHash) "Initial install changed Notepad config"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $managedRoot ".ophclinic\backups") -File).Count -eq 1) "Initial install did not create one backup"
    Pass-Test "initial install and local config preservation"

    $backupCount = @(Get-ChildItem -LiteralPath (Join-Path $managedRoot ".ophclinic\backups") -File).Count
    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 0) "No-op update failed: $($result.Output)"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $managedRoot ".ophclinic\backups") -File).Count -eq $backupCount) "No-op update created a backup"
    Pass-Test "already-current no-op"

    $managedMatch = Join-Path $managedRoot ".espanso\match\ophthalmology.yml"
    Add-Content -LiteralPath $managedMatch -Value "# local drift" -Encoding UTF8
    $driftHash = Get-TestHash -Path $managedMatch
    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 2) "Local drift did not return exit code 2: $($result.Output)"
    Assert-True ((Get-TestHash -Path $managedMatch) -eq $driftHash) "Drift check modified the local match"
    Pass-Test "local drift protection"

    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $validMetadata -SkipRestart -Force
    Assert-True ($result.ExitCode -eq 0) "Forced restore failed: $($result.Output)"
    Assert-True ((Get-TestHash -Path $managedMatch) -eq $releaseHash) "Forced restore did not deploy release match"
    Pass-Test "forced restore"

    $beforeOfflineHash = Get-TestHash -Path $managedMatch
    $missingMetadata = Join-Path $testRoot "missing-release.json"
    $result = Invoke-TestUpdater -PortableRoot $managedRoot -MetadataPath $missingMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 1) "Missing release metadata did not fail"
    Assert-True ((Get-TestHash -Path $managedMatch) -eq $beforeOfflineHash) "Metadata failure changed the match"
    Pass-Test "offline or metadata failure preservation"

    $badChecksumMetadata = New-ReleaseFixture -Name "bad-checksum-release" -BadChecksum
    $checksumRoot = New-FakePortable -Name "checksum-client"
    $checksumOriginal = Get-TestHash -Path (Join-Path $checksumRoot ".espanso\match\ophthalmology.yml")
    $result = Invoke-TestUpdater -PortableRoot $checksumRoot -MetadataPath $badChecksumMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 1) "Bad checksum did not fail"
    Assert-True ((Get-TestHash -Path (Join-Path $checksumRoot ".espanso\match\ophthalmology.yml")) -eq $checksumOriginal) "Bad checksum changed the match"
    Pass-Test "checksum failure preservation"

    $invalidMetadata = New-ReleaseFixture -Name "invalid-release" -UnexpectedFile
    $invalidRoot = New-FakePortable -Name "invalid-client"
    $invalidOriginal = Get-TestHash -Path (Join-Path $invalidRoot ".espanso\match\ophthalmology.yml")
    $result = Invoke-TestUpdater -PortableRoot $invalidRoot -MetadataPath $invalidMetadata -SkipRestart
    Assert-True ($result.ExitCode -eq 1) "Unexpected archive file did not fail"
    Assert-True ((Get-TestHash -Path (Join-Path $invalidRoot ".espanso\match\ophthalmology.yml")) -eq $invalidOriginal) "Invalid archive changed the match"
    Pass-Test "invalid archive preservation"

    $restartRoot = New-FakePortable -Name "restart-client" -EspansoExitCode 1
    $restartMatch = Join-Path $restartRoot ".espanso\match\ophthalmology.yml"
    $restartOriginal = Get-TestHash -Path $restartMatch
    $result = Invoke-TestUpdater -PortableRoot $restartRoot -MetadataPath $validMetadata
    Assert-True ($result.ExitCode -eq 1) "Restart failure did not fail"
    Assert-True ((Get-TestHash -Path $restartMatch) -eq $restartOriginal) "Restart failure did not roll back the match"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $restartRoot ".ophclinic\state.json"))) "Restart failure wrote managed state"
    Pass-Test "restart failure rollback"

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
