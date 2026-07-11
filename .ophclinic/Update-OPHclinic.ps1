[CmdletBinding()]
param(
    [switch]$Force,
    [string]$PortableRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ReleaseApiUrl = "https://api.github.com/repos/eyeduck-ai/OPHclinic-espanso/releases/latest",
    [string]$ReleaseMetadataPath,
    [switch]$SkipRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:UpdaterVersion = [Version]"0.3.0"
$script:StateDirectory = $null
$script:LogPath = $null
$script:EspansoCommand = $null
$script:StageDirectory = $null
$script:TransactionBackupDirectory = $null
$script:DeploymentRecords = @()
$script:DeploymentStarted = $false
$script:LockStream = $null

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $childPath = (Get-NormalizedPath -Path $Child) + [System.IO.Path]::DirectorySeparatorChar
    $parentPath = (Get-NormalizedPath -Path $Parent) + [System.IO.Path]::DirectorySeparatorChar
    return $childPath.StartsWith($parentPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-UpdateLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $line = "{0} [{1}] {2}" -f ([DateTime]::UtcNow.ToString("o")), $Level, $Message
    Write-Host $line
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Copy-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return
    }

    $uri = [Uri]$Source
    if ($uri.IsFile) {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $Destination -Force
        return
    }

    Invoke-WebRequest `
        -Uri $uri.AbsoluteUri `
        -Headers @{ "User-Agent" = "OPHclinic-espanso-updater/2.0"; "Accept" = "application/octet-stream" } `
        -UseBasicParsing `
        -TimeoutSec 60 `
        -OutFile $Destination
}

function Get-LatestRelease {
    if ($ReleaseMetadataPath) {
        if (-not (Test-Path -LiteralPath $ReleaseMetadataPath -PathType Leaf)) {
            throw "Release metadata file not found: $ReleaseMetadataPath"
        }
        return Get-Content -LiteralPath $ReleaseMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    return Invoke-RestMethod `
        -Uri $ReleaseApiUrl `
        -Headers @{
            "User-Agent" = "OPHclinic-espanso-updater/2.0"
            "Accept" = "application/vnd.github+json"
            "X-GitHub-Api-Version" = "2022-11-28"
        } `
        -TimeoutSec 60
}

function Get-AssetUrl {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $asset = @($Release.assets | Where-Object { $_.name -eq $Name })
    if ($asset.Count -ne 1) {
        throw "Release must contain exactly one asset named $Name"
    }
    return [string]$asset[0].browser_download_url
}

function Write-StateAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$State
    )
    $temporaryPath = "$Path.new.$([Guid]::NewGuid().ToString('N'))"
    $replaceBackup = "$Path.replace-backup.$([Guid]::NewGuid().ToString('N'))"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $Path, $replaceBackup, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $replaceBackup -PathType Leaf) {
            Remove-Item -LiteralPath $replaceBackup -Force
        }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Replace-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $destinationDirectory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    $temporaryPath = Join-Path $destinationDirectory ("{0}.new.{1}" -f (Split-Path -Leaf $Destination), [Guid]::NewGuid().ToString("N"))
    $replaceBackup = Join-Path $destinationDirectory ("{0}.replace-backup.{1}" -f (Split-Path -Leaf $Destination), [Guid]::NewGuid().ToString("N"))
    Copy-Item -LiteralPath $Source -Destination $temporaryPath -Force
    try {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $Destination, $replaceBackup, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $Destination)
        }
    } finally {
        if (Test-Path -LiteralPath $replaceBackup -PathType Leaf) {
            Remove-Item -LiteralPath $replaceBackup -Force
        }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Invoke-EspansoCli {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("restart", "status")]
        [string]$Verb,
        [int]$TimeoutSeconds = 30
    )
    $arguments = '/d /s /c ""{0}" {1}"' -f $script:EspansoCommand, $Verb
    $process = Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -PassThru
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "Espanso $Verb timed out after $TimeoutSeconds seconds"
        }
        $process.Refresh()
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Invoke-EspansoRestart {
    if ($SkipRestart) {
        Write-UpdateLog "Espanso restart skipped by test option."
        return
    }
    if (-not (Test-Path -LiteralPath $script:EspansoCommand -PathType Leaf)) {
        throw "Portable espanso.cmd not found: $script:EspansoCommand"
    }

    $restartExit = Invoke-EspansoCli -Verb "restart"
    if ($restartExit -ne 0) {
        throw "Espanso restart returned exit code $restartExit"
    }
    Start-Sleep -Seconds 2
    $statusExit = Invoke-EspansoCli -Verb "status"
    if ($statusExit -ne 0) {
        throw "Espanso status returned exit code $statusExit after restart"
    }
}

function Add-DeploymentRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$BackupName
    )
    $originalExisted = Test-Path -LiteralPath $Destination -PathType Leaf
    $backupPath = $null
    if ($originalExisted) {
        $backupPath = Join-Path $script:TransactionBackupDirectory $BackupName
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-Item -LiteralPath $Destination -Destination $backupPath
    }
    $script:DeploymentRecords += [pscustomobject]@{
        Destination = $Destination
        OriginalExisted = $originalExisted
        BackupPath = $backupPath
    }
}

function Install-FileTransactional {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$BackupName
    )
    Add-DeploymentRecord -Destination $Destination -BackupName $BackupName
    Replace-FileAtomically -Source $Source -Destination $Destination
}

function Remove-FileTransactional {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$BackupName
    )
    Add-DeploymentRecord -Destination $Destination -BackupName $BackupName
    Remove-Item -LiteralPath $Destination -Force
}

function Restore-Deployment {
    if (-not $script:DeploymentStarted) {
        return
    }

    try {
        for ($index = $script:DeploymentRecords.Count - 1; $index -ge 0; $index--) {
            $record = $script:DeploymentRecords[$index]
            if ($record.OriginalExisted -and $record.BackupPath -and (Test-Path -LiteralPath $record.BackupPath -PathType Leaf)) {
                Replace-FileAtomically -Source $record.BackupPath -Destination $record.Destination
            } elseif (-not $record.OriginalExisted -and (Test-Path -LiteralPath $record.Destination -PathType Leaf)) {
                Remove-Item -LiteralPath $record.Destination -Force
            }
        }
        Write-UpdateLog "Restored all files from the failed update transaction." "WARN"

        if (-not $SkipRestart -and (Test-Path -LiteralPath $script:EspansoCommand -PathType Leaf)) {
            $rollbackRestartExit = Invoke-EspansoCli -Verb "restart"
            if ($rollbackRestartExit -ne 0) {
                Write-UpdateLog "Espanso restart failed after rollback with exit code $rollbackRestartExit" "ERROR"
            }
        }
    } catch {
        Write-UpdateLog "Rollback failed: $($_.Exception.Message)" "ERROR"
    }
}

function Remove-SafeStageDirectory {
    if (-not $script:StageDirectory -or -not (Test-Path -LiteralPath $script:StageDirectory)) {
        return
    }
    $stagingRoot = Join-Path $script:StateDirectory "staging"
    if (-not (Test-PathInside -Child $script:StageDirectory -Parent $stagingRoot)) {
        Write-UpdateLog "Refusing to remove unexpected staging path: $script:StageDirectory" "ERROR"
        return
    }
    Remove-Item -LiteralPath $script:StageDirectory -Recurse -Force
}

function Rotate-Backups {
    param([Parameter(Mandatory = $true)][string]$BackupDirectory)
    if (-not (Test-PathInside -Child $BackupDirectory -Parent $script:StateDirectory)) {
        throw "Backup directory is outside updater state: $BackupDirectory"
    }
    $expired = @(
        Get-ChildItem -LiteralPath $BackupDirectory -Directory |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 5
    )
    foreach ($directory in $expired) {
        if (-not (Test-PathInside -Child $directory.FullName -Parent $BackupDirectory)) {
            throw "Refusing to remove unexpected backup path: $($directory.FullName)"
        }
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force
    }
}

function Save-VerifiedReleaseZip {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$ZipName,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )
    $checksumName = "$ZipName.sha256"
    $zipPath = Join-Path $DestinationDirectory $ZipName
    $checksumPath = Join-Path $DestinationDirectory $checksumName
    Copy-ReleaseAsset -Source (Get-AssetUrl -Release $Release -Name $ZipName) -Destination $zipPath
    Copy-ReleaseAsset -Source (Get-AssetUrl -Release $Release -Name $checksumName) -Destination $checksumPath

    $checksumLine = (Get-Content -LiteralPath $checksumPath -Raw -Encoding ASCII).Trim()
    if ($checksumLine -notmatch '^(?<hash>[0-9a-fA-F]{64})\s+\*?(?<name>\S+)$') {
        throw "Invalid checksum file format for $ZipName"
    }
    if ($Matches.name -ne $ZipName) {
        throw "Checksum file references unexpected asset: $($Matches.name)"
    }
    if ((Get-FileSha256 -Path $zipPath) -ne $Matches.hash.ToLowerInvariant()) {
        throw "Release ZIP SHA-256 mismatch: $ZipName"
    }
    return $zipPath
}

function Get-RelativeFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Directory
    )
    return @(
        Get-ChildItem -LiteralPath $Directory -Recurse -File |
            ForEach-Object {
                $_.FullName.Substring($Directory.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
            } |
            Sort-Object
    )
}

function Assert-ExactFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Expected
    )
    $actual = @(Get-RelativeFiles -Directory $Directory)
    $sortedExpected = @($Expected | Sort-Object)
    if (($actual -join "|") -ne ($sortedExpected -join "|")) {
        throw "Archive contains unexpected files: $($actual -join ', ')"
    }
}

function Get-ManifestFileRecord {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    if (-not ($Manifest.PSObject.Properties.Name -contains "files")) {
        throw "Manifest does not contain a files object"
    }
    $property = @($Manifest.files.PSObject.Properties | Where-Object { $_.Name -eq $RelativePath })
    if ($property.Count -ne 1) {
        throw "Manifest must contain exactly one record for $RelativePath"
    }
    return $property[0].Value
}

function Assert-ManifestFile {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$FilePath
    )
    $record = Get-ManifestFileRecord -Manifest $Manifest -RelativePath $RelativePath
    $info = Get-Item -LiteralPath $FilePath
    if ([int64]$record.size -ne $info.Length) {
        throw "Manifest size mismatch for $RelativePath"
    }
    $hash = Get-FileSha256 -Path $FilePath
    if ($hash -ne ([string]$record.sha256).ToLowerInvariant()) {
        throw "Manifest SHA-256 mismatch for $RelativePath"
    }
    return $hash
}

function Get-StateFileHash {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    if ([int]$State.schema_version -eq 1) {
        if ($RelativePath -eq "match/ophthalmology.yml") {
            return ([string]$State.match_sha256).ToLowerInvariant()
        }
        return $null
    }
    $record = Get-ManifestFileRecord -Manifest $State -RelativePath $RelativePath
    return ([string]$record.sha256).ToLowerInvariant()
}

function Test-KnownLegacyNotepad {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n").TrimEnd([char[]]@("`r", "`n"))
    return $text -eq "filter_exec: '(?i)notepad\.exe$'`nkey_delay: 10"
}

function Invoke-Update {
    $root = Get-NormalizedPath -Path $PortableRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Portable root does not exist: $root"
    }

    $script:StateDirectory = Join-Path $root ".ophclinic"
    $script:LogPath = Join-Path $script:StateDirectory "update.log"
    $script:EspansoCommand = Join-Path $root "espanso.cmd"
    $statePath = Join-Path $script:StateDirectory "state.json"
    $lockPath = Join-Path $script:StateDirectory "update.lock"
    $backupDirectory = Join-Path $script:StateDirectory "backups"
    $stagingRoot = Join-Path $script:StateDirectory "staging"
    $destinations = [ordered]@{
        "config/default.yml" = Join-Path $root ".espanso\config\default.yml"
        "match/ophthalmology.yml" = Join-Path $root ".espanso\match\ophthalmology.yml"
    }

    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $destinations["config/default.yml"]) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $destinations["match/ophthalmology.yml"]) -Force | Out-Null

    try {
        $script:LockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        Write-UpdateLog "Another updater process is already running." "ERROR"
        return 3
    }

    Write-UpdateLog "Checking the latest OPHclinic Espanso release."
    $release = Get-LatestRelease
    if ($release.draft -eq $true -or $release.prerelease -eq $true) {
        throw "Latest release metadata points to a draft or prerelease"
    }

    $tag = [string]$release.tag_name
    if ($tag -notmatch '^v(?<version>(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*))$') {
        throw "Release tag is not semantic versioning: $tag"
    }
    $versionText = $Matches.version
    $releaseVersion = [Version]$versionText

    $state = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$state.schema_version -notin @(1, 2)) {
            throw "Unsupported updater state schema"
        }
    }

    $drift = @()
    if ($state) {
        $stateVersion = [Version]([string]$state.version)
        foreach ($relativePath in $destinations.Keys) {
            $managedHash = Get-StateFileHash -State $state -RelativePath $relativePath
            if ($managedHash) {
                $destination = $destinations[$relativePath]
                if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
                    (Get-FileSha256 -Path $destination) -ne $managedHash) {
                    $drift += $relativePath
                }
            }
        }

        if ($drift.Count -gt 0 -and -not $Force) {
            Write-UpdateLog "Local managed-file drift detected: $($drift -join ', '). Review it, then rerun with -Force to overwrite." "WARN"
            return 2
        }
        if ($releaseVersion -lt $stateVersion) {
            throw "Latest release $releaseVersion is older than installed version $stateVersion"
        }
        if ($releaseVersion -eq $stateVersion -and [int]$state.schema_version -eq 2 -and $drift.Count -eq 0 -and -not $Force) {
            Write-UpdateLog "Already current at $tag."
            return 0
        }
    }

    $script:StageDirectory = Join-Path $stagingRoot ([Guid]::NewGuid().ToString("N"))
    $managedExtract = Join-Path $script:StageDirectory "managed"
    $bootstrapExtract = Join-Path $script:StageDirectory "bootstrap"
    New-Item -ItemType Directory -Path $managedExtract -Force | Out-Null
    New-Item -ItemType Directory -Path $bootstrapExtract -Force | Out-Null

    $managedName = "OPHclinic-espanso-$tag.zip"
    $bootstrapName = "OPHclinic-espanso-bootstrap-$tag.zip"
    $managedZip = Save-VerifiedReleaseZip -Release $release -ZipName $managedName -DestinationDirectory $script:StageDirectory
    $bootstrapZip = Save-VerifiedReleaseZip -Release $release -ZipName $bootstrapName -DestinationDirectory $script:StageDirectory
    Expand-Archive -LiteralPath $managedZip -DestinationPath $managedExtract -Force
    Expand-Archive -LiteralPath $bootstrapZip -DestinationPath $bootstrapExtract -Force

    $managedPaths = @("config/default.yml", "match/ophthalmology.yml")
    $bootstrapPaths = @(".ophclinic/Update-OPHclinic.ps1", "OPHCLINIC-BOOTSTRAP.txt", "UPDATE_OPHCLINIC.cmd")
    Assert-ExactFiles -Directory $managedExtract -Expected @($managedPaths + "release-manifest.json")
    Assert-ExactFiles -Directory $bootstrapExtract -Expected @($bootstrapPaths + "bootstrap-manifest.json")

    $releaseManifest = Get-Content -LiteralPath (Join-Path $managedExtract "release-manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$releaseManifest.schema_version -ne 2 -or
        [string]$releaseManifest.package -ne "ophthalmology-clinic" -or
        [string]$releaseManifest.repository -ne "eyeduck-ai/OPHclinic-espanso" -or
        [string]$releaseManifest.version -ne $versionText -or
        [string]$releaseManifest.tag -ne $tag -or
        @($releaseManifest.files.PSObject.Properties).Count -ne $managedPaths.Count) {
        throw "Release manifest metadata is invalid"
    }

    $bootstrapManifest = Get-Content -LiteralPath (Join-Path $bootstrapExtract "bootstrap-manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$bootstrapManifest.schema_version -ne 1 -or
        [string]$bootstrapManifest.repository -ne "eyeduck-ai/OPHclinic-espanso" -or
        [string]$bootstrapManifest.version -ne $versionText -or
        [string]$bootstrapManifest.tag -ne $tag -or
        @($bootstrapManifest.files.PSObject.Properties).Count -ne $bootstrapPaths.Count) {
        throw "Bootstrap manifest metadata is invalid"
    }

    $managedHashes = [ordered]@{}
    foreach ($relativePath in $managedPaths) {
        $filePath = Join-Path $managedExtract ($relativePath.Replace('/', '\'))
        $managedHashes[$relativePath] = Assert-ManifestFile -Manifest $releaseManifest -RelativePath $relativePath -FilePath $filePath
    }
    $bootstrapHashes = [ordered]@{}
    foreach ($relativePath in $bootstrapPaths) {
        $filePath = Join-Path $bootstrapExtract ($relativePath.Replace('/', '\'))
        $bootstrapHashes[$relativePath] = Assert-ManifestFile -Manifest $bootstrapManifest -RelativePath $relativePath -FilePath $filePath
    }

    $releasedMatch = Join-Path $managedExtract "match\ophthalmology.yml"
    $releasedDefault = Join-Path $managedExtract "config\default.yml"
    $releasedText = Get-Content -LiteralPath $releasedMatch -Raw -Encoding UTF8
    if ($releasedText -notmatch '(?m)^matches:\s*$' -or
        $releasedText -notmatch 'trigger:\s*";\.ded;"' -or
        $releasedText -notmatch 'replace:\s*"H04\.129"') {
        throw "Released match failed basic content checks"
    }
    $defaultText = [System.IO.File]::ReadAllText($releasedDefault).Replace("`r`n", "`n")
    $expectedDefault = "key_delay: 10`nsearch_shortcut: CTRL+ALT+SPACE`nsearch_trigger: `";help`"`n"
    if ($defaultText -ne $expectedDefault) {
        throw "Released default configuration is not the approved global configuration"
    }

    $timestamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
    $script:TransactionBackupDirectory = Join-Path $backupDirectory ("{0}-{1}-{2}" -f $timestamp, $tag, [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TransactionBackupDirectory -Force | Out-Null
    $script:DeploymentStarted = $true

    Install-FileTransactional `
        -Source $releasedMatch `
        -Destination $destinations["match/ophthalmology.yml"] `
        -BackupName "managed\match\ophthalmology.yml"
    Install-FileTransactional `
        -Source $releasedDefault `
        -Destination $destinations["config/default.yml"] `
        -BackupName "managed\config\default.yml"

    $legacyNotepad = Join-Path $root ".espanso\config\notepad.yml"
    if (Test-Path -LiteralPath $legacyNotepad -PathType Leaf) {
        if (Test-KnownLegacyNotepad -Path $legacyNotepad) {
            Remove-FileTransactional -Destination $legacyNotepad -BackupName "legacy\config\notepad.yml"
            Write-UpdateLog "Removed the known legacy Notepad-only configuration after backing it up."
        } else {
            Write-UpdateLog "Preserved modified legacy Notepad configuration: $legacyNotepad" "WARN"
        }
    }

    Invoke-EspansoRestart

    $bootstrapDestinations = [ordered]@{
        ".ophclinic/Update-OPHclinic.ps1" = Join-Path $root ".ophclinic\Update-OPHclinic.ps1"
        "OPHCLINIC-BOOTSTRAP.txt" = Join-Path $root "OPHCLINIC-BOOTSTRAP.txt"
        "UPDATE_OPHCLINIC.cmd" = Join-Path $root "UPDATE_OPHCLINIC.cmd"
    }
    foreach ($relativePath in $bootstrapPaths) {
        $source = Join-Path $bootstrapExtract ($relativePath.Replace('/', '\'))
        $destination = $bootstrapDestinations[$relativePath]
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
            (Get-FileSha256 -Path $destination) -ne $bootstrapHashes[$relativePath]) {
            Install-FileTransactional `
                -Source $source `
                -Destination $destination `
                -BackupName ("bootstrap\" + $relativePath.Replace('/', '\'))
        }
    }

    $stateFiles = [ordered]@{}
    foreach ($relativePath in $managedPaths) {
        $source = Join-Path $managedExtract ($relativePath.Replace('/', '\'))
        $stateFiles[$relativePath] = [ordered]@{
            sha256 = $managedHashes[$relativePath]
            size = (Get-Item -LiteralPath $source).Length
        }
    }
    $stateBootstrap = [ordered]@{}
    foreach ($relativePath in $bootstrapPaths) {
        $source = Join-Path $bootstrapExtract ($relativePath.Replace('/', '\'))
        $stateBootstrap[$relativePath] = [ordered]@{
            sha256 = $bootstrapHashes[$relativePath]
            size = (Get-Item -LiteralPath $source).Length
        }
    }
    $newState = [ordered]@{
        schema_version = 2
        version = $versionText
        tag = $tag
        files = $stateFiles
        updater_version = $versionText
        bootstrap_files = $stateBootstrap
        installed_at_utc = [DateTime]::UtcNow.ToString("o")
        release_url = if ($release.PSObject.Properties.Name -contains "html_url") { [string]$release.html_url } else { "" }
    }
    Write-StateAtomically -Path $statePath -State $newState
    Rotate-Backups -BackupDirectory $backupDirectory
    $script:DeploymentStarted = $false
    Write-UpdateLog "Installed $tag successfully."
    return 0
}

$exitCode = 1
try {
    if ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) {
        # TLS 1.2 is already enabled.
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $exitCode = Invoke-Update
} catch {
    Write-UpdateLog $_.Exception.Message "ERROR"
    Restore-Deployment
    $exitCode = 1
} finally {
    Remove-SafeStageDirectory
    if ($script:LockStream) {
        $script:LockStream.Dispose()
    }
}

exit $exitCode
