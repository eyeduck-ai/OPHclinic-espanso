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

$script:StateDirectory = $null
$script:LogPath = $null
$script:DestinationMatch = $null
$script:EspansoCommand = $null
$script:StageDirectory = $null
$script:BackupPath = $null
$script:OriginalExisted = $false
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
        -Headers @{ "User-Agent" = "OPHclinic-espanso-updater/1.0"; "Accept" = "application/octet-stream" } `
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
            "User-Agent" = "OPHclinic-espanso-updater/1.0"
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
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
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

function Restore-PreviousMatch {
    if (-not $script:DeploymentStarted) {
        return
    }

    try {
        if ($script:OriginalExisted -and $script:BackupPath -and (Test-Path -LiteralPath $script:BackupPath -PathType Leaf)) {
            Replace-FileAtomically -Source $script:BackupPath -Destination $script:DestinationMatch
            Write-UpdateLog "Restored the previous match from $script:BackupPath" "WARN"
        } elseif (-not $script:OriginalExisted -and (Test-Path -LiteralPath $script:DestinationMatch -PathType Leaf)) {
            Remove-Item -LiteralPath $script:DestinationMatch -Force
            Write-UpdateLog "Removed the newly installed match during rollback." "WARN"
        }

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
        Get-ChildItem -LiteralPath $BackupDirectory -Filter "ophthalmology-*.yml" -File |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 5
    )
    foreach ($file in $expired) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
}

function Invoke-Update {
    $root = Get-NormalizedPath -Path $PortableRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Portable root does not exist: $root"
    }

    $script:StateDirectory = Join-Path $root ".ophclinic"
    $script:LogPath = Join-Path $script:StateDirectory "update.log"
    $script:DestinationMatch = Join-Path $root ".espanso\match\ophthalmology.yml"
    $script:EspansoCommand = Join-Path $root "espanso.cmd"
    $statePath = Join-Path $script:StateDirectory "state.json"
    $lockPath = Join-Path $script:StateDirectory "update.lock"
    $backupDirectory = Join-Path $script:StateDirectory "backups"
    $stagingRoot = Join-Path $script:StateDirectory "staging"

    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:DestinationMatch) -Force | Out-Null

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
        if ([int]$state.schema_version -ne 1) {
            throw "Unsupported updater state schema"
        }
    }

    $currentHash = $null
    if (Test-Path -LiteralPath $script:DestinationMatch -PathType Leaf) {
        $currentHash = Get-FileSha256 -Path $script:DestinationMatch
    }

    if ($state) {
        $stateVersion = [Version]([string]$state.version)
        $managedHash = ([string]$state.match_sha256).ToLowerInvariant()
        $hasDrift = -not $currentHash -or $currentHash -ne $managedHash

        if ($hasDrift -and -not $Force) {
            Write-UpdateLog "Local match drift detected. Review it, then rerun with -Force to overwrite." "WARN"
            return 2
        }
        if ($releaseVersion -lt $stateVersion) {
            throw "Latest release $releaseVersion is older than installed version $stateVersion"
        }
        if ($releaseVersion -eq $stateVersion -and -not $hasDrift -and -not $Force) {
            Write-UpdateLog "Already current at $tag."
            return 0
        }
    }

    $zipName = "OPHclinic-espanso-$tag.zip"
    $checksumName = "$zipName.sha256"
    $zipUrl = Get-AssetUrl -Release $release -Name $zipName
    $checksumUrl = Get-AssetUrl -Release $release -Name $checksumName

    $script:StageDirectory = Join-Path $stagingRoot ([Guid]::NewGuid().ToString("N"))
    $extractDirectory = Join-Path $script:StageDirectory "extract"
    New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null
    $zipPath = Join-Path $script:StageDirectory $zipName
    $checksumPath = Join-Path $script:StageDirectory $checksumName

    Copy-ReleaseAsset -Source $zipUrl -Destination $zipPath
    Copy-ReleaseAsset -Source $checksumUrl -Destination $checksumPath

    $checksumLine = (Get-Content -LiteralPath $checksumPath -Raw -Encoding ASCII).Trim()
    if ($checksumLine -notmatch '^(?<hash>[0-9a-fA-F]{64})\s+\*?(?<name>\S+)$') {
        throw "Invalid checksum file format"
    }
    if ($Matches.name -ne $zipName) {
        throw "Checksum file references unexpected asset: $($Matches.name)"
    }
    $expectedZipHash = $Matches.hash.ToLowerInvariant()
    $actualZipHash = Get-FileSha256 -Path $zipPath
    if ($actualZipHash -ne $expectedZipHash) {
        throw "Release ZIP SHA-256 mismatch"
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDirectory -Force
    $relativeFiles = @(
        Get-ChildItem -LiteralPath $extractDirectory -Recurse -File |
            ForEach-Object {
                $_.FullName.Substring($extractDirectory.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
            } |
            Sort-Object
    )
    $expectedFiles = @("match/ophthalmology.yml", "release-manifest.json") | Sort-Object
    if (($relativeFiles -join "|") -ne ($expectedFiles -join "|")) {
        throw "Release ZIP contains unexpected files: $($relativeFiles -join ', ')"
    }

    $releaseManifestPath = Join-Path $extractDirectory "release-manifest.json"
    $releasedMatch = Join-Path $extractDirectory "match\ophthalmology.yml"
    $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$releaseManifest.schema_version -ne 1 -or
        [string]$releaseManifest.repository -ne "eyeduck-ai/OPHclinic-espanso" -or
        [string]$releaseManifest.version -ne $versionText -or
        [string]$releaseManifest.tag -ne $tag -or
        [string]$releaseManifest.match_path -ne "match/ophthalmology.yml") {
        throw "Release manifest metadata is invalid"
    }

    $releasedMatchHash = Get-FileSha256 -Path $releasedMatch
    if ($releasedMatchHash -ne ([string]$releaseManifest.match_sha256).ToLowerInvariant()) {
        throw "Released match SHA-256 does not match release manifest"
    }
    $releasedMatchInfo = Get-Item -LiteralPath $releasedMatch
    if ($releasedMatchInfo.Length -lt 100 -or $releasedMatchInfo.Length -gt 2MB) {
        throw "Released match has an unexpected size"
    }
    $releasedText = Get-Content -LiteralPath $releasedMatch -Raw -Encoding UTF8
    if ($releasedText -notmatch '(?m)^matches:\s*$' -or
        $releasedText -notmatch 'trigger:\s*";\.ded"' -or
        $releasedText -notmatch 'replace:\s*"H04\.129"') {
        throw "Released match failed basic content checks"
    }

    $script:OriginalExisted = Test-Path -LiteralPath $script:DestinationMatch -PathType Leaf
    if ($script:OriginalExisted) {
        $timestamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
        $previousVersion = if ($state) { [string]$state.version } else { "unmanaged" }
        $script:BackupPath = Join-Path $backupDirectory "ophthalmology-$previousVersion-$timestamp.yml"
        Copy-Item -LiteralPath $script:DestinationMatch -Destination $script:BackupPath
        Write-UpdateLog "Backed up the current match to $script:BackupPath"
    }

    $script:DeploymentStarted = $true
    Replace-FileAtomically -Source $releasedMatch -Destination $script:DestinationMatch
    Invoke-EspansoRestart

    $newState = [ordered]@{
        schema_version = 1
        version = $versionText
        tag = $tag
        match_sha256 = $releasedMatchHash
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
    Restore-PreviousMatch
    $exitCode = 1
} finally {
    Remove-SafeStageDirectory
    if ($script:LockStream) {
        $script:LockStream.Dispose()
    }
}

exit $exitCode
