#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [ValidateSet("Refresh", "Uninstall", "Restore", "List")]
    [string]$Action = "Refresh",

    [string]$Backup,

    [ValidatePattern("^https://")]
    [string]$InstallerUri = "https://raw.githubusercontent.com/microsoft/aibast-agents-library/main/install.ps1",

    [string]$InstallerPath,

    [string]$Version,

    [switch]$NoLaunch,

    [switch]$NoBrowser,

    [switch]$ResetAuthentication,

    [switch]$KeepPath,

    [switch]$Yes,

    [string]$BrainstemHome = (Join-Path $env:USERPROFILE ".brainstem"),

    [string]$StateHome = (Join-Path $env:USERPROFILE ".rapp-refresh"),

    [string]$BrainstemBin = (Join-Path $env:USERPROFILE ".local\bin")
)

& {
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # TLS 1.2 is already the platform default when this legacy switch is unavailable.
}

function Write-Step {
    param([string]$Message)
    Write-Host "  [..] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Enter-OperationLock {
    param([string]$InstallRoot)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
        $hash = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
    } finally {
        $sha.Dispose()
    }

    $mutex = New-Object Threading.Mutex($false, "Global\RappRefresh-$hash")
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Another RAPP Refresh operation is already using '$InstallRoot'."
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-OperationLock {
    param([Threading.Mutex]$Mutex)

    if ($null -eq $Mutex) {
        return
    }
    try {
        $Mutex.ReleaseMutex()
    } finally {
        $Mutex.Dispose()
    }
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $full = [IO.Path]::GetFullPath($expanded)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        return $full.TrimEnd("\")
    }
    return $full
}

function Test-SamePath {
    param([string]$Left, [string]$Right)
    return [string]::Equals(
        (Get-FullPath $Left),
        (Get-FullPath $Right),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Test-PathWithin {
    param([string]$Candidate, [string]$Parent)

    $candidatePath = (Get-FullPath $Candidate).TrimEnd("\") + "\"
    $parentPath = (Get-FullPath $Parent).TrimEnd("\") + "\"
    return $candidatePath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeLayout {
    param([string]$InstallRoot, [string]$State, [string]$Bin)

    $homePath = Get-FullPath $InstallRoot
    $statePath = Get-FullPath $State
    $binPath = Get-FullPath $Bin
    $homeRoot = [IO.Path]::GetPathRoot($homePath)

    if (Test-SamePath $homePath $homeRoot) {
        throw "Refusing to operate on a drive root: $homePath"
    }
    if ((Split-Path -Leaf $homePath) -ne ".brainstem") {
        throw "BrainstemHome must end in '.brainstem'; got '$homePath'."
    }
    if (Test-SamePath $homePath $statePath) {
        throw "StateHome must be separate from BrainstemHome."
    }
    if ((Test-PathWithin $statePath $homePath) -or (Test-PathWithin $homePath $statePath)) {
        throw "StateHome and BrainstemHome cannot contain one another."
    }
    if ((Test-SamePath $binPath $homePath) -or (Test-PathWithin $binPath $homePath)) {
        throw "BrainstemBin cannot be inside BrainstemHome."
    }
    if (Test-PathWithin $homePath $binPath) {
        throw "BrainstemHome cannot be inside BrainstemBin."
    }
    if (
        -not [string]::Equals(
            [IO.Path]::GetPathRoot($homePath),
            [IO.Path]::GetPathRoot($statePath),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "StateHome and BrainstemHome must be on the same volume for an atomic, rollback-safe snapshot."
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $json = $Value | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-TreeSummary {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Files = 0; Bytes = 0 }
    }

    $files = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction Stop)
    $bytes = 0L
    foreach ($file in $files) {
        $bytes += $file.Length
    }
    return [pscustomobject]@{ Files = $files.Count; Bytes = $bytes }
}

function Get-BrainstemVersion {
    param([string]$InstallRoot)

    $versionFile = Join-Path $InstallRoot "src\rapp_brainstem\VERSION"
    if (Test-Path -LiteralPath $versionFile) {
        return (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }
    return ""
}

function Set-ManifestStatus {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Message = "",
        [hashtable]$Additional = @{}
    )

    $manifestPath = Join-Path $BackupRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.status = $Status
    $manifest.updatedUtc = [DateTime]::UtcNow.ToString("o")
    $manifest.message = $Message
    foreach ($name in $Additional.Keys) {
        $manifest | Add-Member -NotePropertyName $name -NotePropertyValue $Additional[$name] -Force
    }
    Write-JsonFile -Value $manifest -Path $manifestPath
}

function Get-UserPath {
    return [Environment]::GetEnvironmentVariable("Path", "User")
}

function Test-PathEntry {
    param([string]$Entry, [string]$Target)

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        return $false
    }
    $entryPath = $Entry.Trim().Trim('"').TrimEnd("\")
    $targetPath = (Get-FullPath $Target).TrimEnd("\")
    try {
        $entryPath = (Get-FullPath $entryPath).TrimEnd("\")
    } catch {
        return $false
    }
    return [string]::Equals($entryPath, $targetPath, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-PathEntryFromValue {
    param(
        [AllowNull()][string]$Value,
        [string]$Target
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return ""
    }
    $kept = New-Object "Collections.Generic.List[string]"
    foreach ($entry in @([regex]::Split($Value, ";"))) {
        if (-not (Test-PathEntry -Entry $entry -Target $Target)) {
            $kept.Add($entry)
        }
    }
    return [string]::Join(";", $kept.ToArray())
}

function Get-MatchingPathEntries {
    param(
        [AllowNull()][string]$Value,
        [string]$Target
    )

    $matchingEntries = @()
    if ($null -eq $Value) {
        return $matchingEntries
    }
    $tokens = @([regex]::Split($Value, ";"))
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if (Test-PathEntry -Entry $tokens[$index] -Target $Target) {
            $matchingEntries += [pscustomobject]@{
                index = $index
                value = $tokens[$index]
            }
        }
    }
    return $matchingEntries
}

function Restore-PathEntriesToValue {
    param(
        [AllowNull()][string]$Value,
        [string]$Target,
        [object[]]$SavedEntries,
        [int]$OriginalTokenCount
    )

    $withoutTarget = Remove-PathEntryFromValue -Value $Value -Target $Target
    $tokens = New-Object "Collections.Generic.List[string]"
    $expectedOriginalNonTargets = [Math]::Max(0, $OriginalTokenCount - @($SavedEntries).Count)
    if ($withoutTarget -ne "" -or $expectedOriginalNonTargets -gt 0) {
        foreach ($entry in @([regex]::Split([string]$withoutTarget, ";"))) {
            [void]$tokens.Add($entry)
        }
    }

    foreach ($saved in @($SavedEntries | Sort-Object { [int]$_.index })) {
        $index = [Math]::Max(0, [Math]::Min([int]$saved.index, $tokens.Count))
        $tokens.Insert($index, [string]$saved.value)
    }
    return [string]::Join(";", $tokens.ToArray())
}

function Get-BrainstemPathState {
    param([string]$Bin)

    $userPath = Get-UserPath
    $processPath = $env:Path
    $userTokenCount = if ($null -eq $userPath) { 0 } else { @([regex]::Split($userPath, ";")).Count }
    $processTokenCount = if ($null -eq $processPath) { 0 } else { @([regex]::Split($processPath, ";")).Count }
    return [ordered]@{
        userTokenCount = $userTokenCount
        userEntries = @(Get-MatchingPathEntries -Value $userPath -Target $Bin)
        processTokenCount = $processTokenCount
        processEntries = @(Get-MatchingPathEntries -Value $processPath -Target $Bin)
    }
}

function Set-BrainstemPathState {
    param(
        [string]$Bin,
        [object[]]$UserEntries,
        [int]$UserTokenCount,
        [object[]]$ProcessEntries,
        [int]$ProcessTokenCount
    )

    $userPath = Restore-PathEntriesToValue `
        -Value (Get-UserPath) `
        -Target $Bin `
        -SavedEntries $UserEntries `
        -OriginalTokenCount $UserTokenCount
    $processPath = Restore-PathEntriesToValue `
        -Value $env:Path `
        -Target $Bin `
        -SavedEntries $ProcessEntries `
        -OriginalTokenCount $ProcessTokenCount
    [Environment]::SetEnvironmentVariable("Path", $userPath, "User")
    $env:Path = $processPath
}

function Remove-BrainstemPathEntry {
    param([string]$Bin)

    $userPath = Remove-PathEntryFromValue -Value (Get-UserPath) -Target $Bin
    $processPath = Remove-PathEntryFromValue -Value $env:Path -Target $Bin
    [Environment]::SetEnvironmentVariable("Path", $userPath, "User")
    $env:Path = $processPath
}

function Test-CommandLinePath {
    param(
        [string]$CommandLine,
        [string]$Path
    )

    if (-not $CommandLine) {
        return $false
    }

    $start = 0
    while ($start -lt $CommandLine.Length) {
        $index = $CommandLine.IndexOf($Path, $start, [StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 0) {
            return $false
        }

        $end = $index + $Path.Length
        $validBefore = (
            $index -eq 0 -or
            [char]::IsWhiteSpace($CommandLine[$index - 1]) -or
            $CommandLine[$index - 1] -eq '"' -or
            $CommandLine[$index - 1] -eq "'"
        )
        $validAfter = (
            $end -eq $CommandLine.Length -or
            [char]::IsWhiteSpace($CommandLine[$end]) -or
            $CommandLine[$end] -eq '"' -or
            $CommandLine[$end] -eq "'"
        )
        if ($validBefore -and $validAfter) {
            return $true
        }
        $start = $index + 1
    }
    return $false
}

function Test-OwnedBrainstemProcess {
    param(
        $Process,
        [string]$InstallRoot
    )

    $commandLine = [string]$Process.CommandLine
    if (-not $commandLine) {
        return $false
    }

    $executablePath = [string]$Process.ExecutablePath
    $venvPython = Join-Path $InstallRoot "venv\Scripts\python.exe"
    if (
        $executablePath -and
        (Test-SamePath $executablePath $venvPython) -and
        (Test-CommandLinePath -CommandLine $commandLine -Path "brainstem.py")
    ) {
        return $true
    }

    if (-not $executablePath -or (Split-Path -Leaf $executablePath) -notmatch "^python(?:3(?:\.\d+)?)?\.exe$") {
        return $false
    }
    $runtimeScript = Join-Path $InstallRoot "src\rapp_brainstem\brainstem.py"
    return Test-CommandLinePath -CommandLine $commandLine -Path $runtimeScript
}

function Open-StableProcess {
    param($CimProcess)

    $liveProcess = $null
    try {
        $liveProcess = [Diagnostics.Process]::GetProcessById([int]$CimProcess.ProcessId)
        $null = $liveProcess.Handle
        $liveStart = $liveProcess.StartTime.ToUniversalTime()
        $cimStart = ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
        if ([Math]::Abs(($liveStart - $cimStart).TotalSeconds) -gt 2) {
            $liveProcess.Dispose()
            return $null
        }
        return $liveProcess
    } catch {
        if ($liveProcess) {
            $liveProcess.Dispose()
        }
        return $null
    }
}

function Stop-BrainstemProcesses {
    param([string]$InstallRoot)

    $homePath = Get-FullPath $InstallRoot
    $processesToStop = @{}

    try {
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            if (
                ([int]$process.ProcessId) -gt 0 -and
                (Test-OwnedBrainstemProcess -Process $process -InstallRoot $homePath)
            ) {
                $stableProcess = Open-StableProcess $process
                if ($stableProcess) {
                    $processesToStop[[int]$process.ProcessId] = $stableProcess
                }
            }
        }
    } catch {
        throw "Could not inspect running processes: $($_.Exception.Message)"
    }

    try {
        foreach ($listener in @(Get-NetTCPConnection -LocalPort 7071 -State Listen -ErrorAction SilentlyContinue)) {
            $ownerPid = [int]$listener.OwningProcess
            if ($ownerPid -le 0 -or $processesToStop.ContainsKey($ownerPid)) {
                continue
            }
            $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
            if ($process -and ([string]$process.CommandLine) -match "brainstem\.py") {
                if (Test-OwnedBrainstemProcess -Process $process -InstallRoot $homePath) {
                    $stableProcess = Open-StableProcess $process
                    if ($stableProcess) {
                        $processesToStop[$ownerPid] = $stableProcess
                    }
                } else {
                    throw "Port 7071 is used by a Brainstem process outside '$homePath' (PID $ownerPid). Stop it before refreshing this installation."
                }
            }
        }
    } catch {
        if ($_.Exception.Message -like "Port 7071 is used by a Brainstem process outside*") {
            throw
        }
        # Process discovery by installation path above is sufficient when
        # Get-NetTCPConnection is unavailable.
    }

    try {
        foreach ($entry in $processesToStop.GetEnumerator()) {
            $processId = [int]$entry.Key
            $process = [Diagnostics.Process]$entry.Value
            if ($processId -le 0 -or $processId -eq $PID -or $process.HasExited) {
                continue
            }
            Write-Step "Stopping Brainstem process $processId..."
            try {
                $process.Kill()
            } catch [InvalidOperationException] {
                continue
            }
            if (-not $process.WaitForExit(10000)) {
                throw "Brainstem process $processId did not stop within 10 seconds."
            }
        }
    } finally {
        foreach ($process in $processesToStop.Values) {
            $process.Dispose()
        }
    }
}

function New-BackupContext {
    param(
        [string]$InstallRoot,
        [string]$State,
        [string]$Bin
    )

    $backupParent = Join-Path $State "backups"
    New-Item -ItemType Directory -Force -Path $backupParent | Out-Null

    $id = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID"
    $backupRoot = Join-Path $backupParent $id
    while (Test-Path -LiteralPath $backupRoot) {
        $id = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID-$(Get-Random -Minimum 1000 -Maximum 9999)"
        $backupRoot = Join-Path $backupParent $id
    }

    $metadata = Join-Path $backupRoot "metadata"
    $snapshot = Join-Path $backupRoot "brainstem"
    New-Item -ItemType Directory -Force -Path $metadata | Out-Null

    Write-JsonFile `
        -Value (Get-BrainstemPathState $Bin) `
        -Path (Join-Path $metadata "brainstem-path.json")

    $launcherBackup = Join-Path $metadata "launchers"
    foreach ($name in @("brainstem.cmd", "brainstem.ps1")) {
        $launcher = Join-Path $Bin $name
        if (Test-Path -LiteralPath $launcher) {
            New-Item -ItemType Directory -Force -Path $launcherBackup | Out-Null
            Copy-Item -LiteralPath $launcher -Destination (Join-Path $launcherBackup $name) -Force
        }
    }

    $version = Get-BrainstemVersion $InstallRoot
    $manifest = [ordered]@{
        schemaVersion = 2
        id = $id
        status = "preparing"
        createdUtc = [DateTime]::UtcNow.ToString("o")
        updatedUtc = [DateTime]::UtcNow.ToString("o")
        sourcePath = (Get-FullPath $InstallRoot)
        snapshotPath = $snapshot
        version = $version
        files = 0
        bytes = 0
        message = ""
        binPath = (Get-FullPath $Bin)
    }
    $manifestPath = Join-Path $backupRoot "manifest.json"
    Write-JsonFile -Value $manifest -Path $manifestPath

    $moved = $false
    try {
        if (Test-Path -LiteralPath $InstallRoot) {
            Write-Step "Quarantining the complete Brainstem installation..."
            Move-Item -LiteralPath $InstallRoot -Destination $snapshot
            $moved = $true
        }

        $summary = Get-TreeSummary $snapshot
        $manifest.status = "quarantined"
        $manifest.updatedUtc = [DateTime]::UtcNow.ToString("o")
        $manifest.files = $summary.Files
        $manifest.bytes = $summary.Bytes
        Write-JsonFile -Value $manifest -Path $manifestPath
    } catch {
        $failure = $_.Exception.Message
        if ($moved -and (Test-Path -LiteralPath $snapshot) -and -not (Test-Path -LiteralPath $InstallRoot)) {
            try {
                Move-Item -LiteralPath $snapshot -Destination $InstallRoot
            } catch {
                throw "Backup preparation failed and automatic rollback also failed. The complete installation remains at '$snapshot'. Original error: $failure"
            }
        }
        throw $failure
    }

    return [pscustomobject]@{
        Id = $id
        Root = $backupRoot
        Snapshot = $snapshot
        Metadata = $metadata
        HadInstall = (Test-Path -LiteralPath $snapshot)
    }
}

function Remove-BrainstemEntryPoints {
    param(
        [string]$Bin,
        [switch]$PreservePath
    )

    foreach ($name in @("brainstem.cmd", "brainstem.ps1")) {
        $launcher = Join-Path $Bin $name
        if (Test-Path -LiteralPath $launcher) {
            Remove-Item -LiteralPath $launcher -Force
        }
    }

    if ((Test-Path -LiteralPath $Bin) -and @(Get-ChildItem -LiteralPath $Bin -Force).Count -eq 0) {
        Remove-Item -LiteralPath $Bin -Force
    }

    if (-not $PreservePath) {
        Remove-BrainstemPathEntry $Bin
    }
}

function Restore-EntryPoints {
    param(
        [string]$BackupRoot,
        [string]$Bin,
        [string]$PathBackupRoot = $BackupRoot,
        [switch]$PreservePath
    )

    foreach ($name in @("brainstem.cmd", "brainstem.ps1")) {
        $current = Join-Path $Bin $name
        if (Test-Path -LiteralPath $current) {
            Remove-Item -LiteralPath $current -Force
        }
    }

    $launcherBackup = Join-Path $BackupRoot "metadata\launchers"
    if (Test-Path -LiteralPath $launcherBackup) {
        New-Item -ItemType Directory -Force -Path $Bin | Out-Null
        foreach ($launcher in @(Get-ChildItem -LiteralPath $launcherBackup -File -Force)) {
            Copy-Item -LiteralPath $launcher.FullName -Destination (Join-Path $Bin $launcher.Name) -Force
        }
    }

    if (-not $PreservePath) {
        $pathBackup = Join-Path $PathBackupRoot "metadata\brainstem-path.json"
        if (Test-Path -LiteralPath $pathBackup) {
            $pathState = Get-Content -LiteralPath $pathBackup -Raw -Encoding UTF8 | ConvertFrom-Json
            Set-BrainstemPathState `
                -Bin $Bin `
                -UserEntries @($pathState.userEntries) `
                -UserTokenCount ([int]$pathState.userTokenCount) `
                -ProcessEntries @($pathState.processEntries) `
                -ProcessTokenCount ([int]$pathState.processTokenCount)
        }
    }
}

function Set-BrainstemPathAfterInstall {
    param(
        [string]$BackupRoot,
        [string]$Bin
    )

    $pathBackup = Join-Path $BackupRoot "metadata\brainstem-path.json"
    if (-not (Test-Path -LiteralPath $pathBackup -PathType Leaf)) {
        throw "PATH metadata is missing from '$BackupRoot'."
    }

    $pathState = Get-Content -LiteralPath $pathBackup -Raw -Encoding UTF8 | ConvertFrom-Json
    $userEntries = @($pathState.userEntries)
    $processEntries = @($pathState.processEntries)
    $userTokenCount = [int]$pathState.userTokenCount
    $processTokenCount = [int]$pathState.processTokenCount

    if ($userEntries.Count -eq 0) {
        $userEntries = @([pscustomobject]@{ index = 0; value = $Bin })
        $userTokenCount++
    }
    if ($processEntries.Count -eq 0) {
        $processEntries = @([pscustomobject]@{ index = 0; value = $Bin })
        $processTokenCount++
    }

    Set-BrainstemPathState `
        -Bin $Bin `
        -UserEntries $userEntries `
        -UserTokenCount $userTokenCount `
        -ProcessEntries $processEntries `
        -ProcessTokenCount $processTokenCount
}

function Invoke-Rollback {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$InstallRoot,
        [string]$Bin,
        [switch]$PreservePath,
        [string]$Reason
    )

    Write-Warn "The operation failed; restoring the previous installation."
    try {
        Stop-BrainstemProcesses $InstallRoot
    } catch {
        Write-Warn "Could not stop every partial-install process: $($_.Exception.Message)"
    }

    $hadSnapshot = Test-Path -LiteralPath $Context.Snapshot
    try {
        if (Test-Path -LiteralPath $InstallRoot) {
            $failedInstall = Join-Path $Context.Root "failed-install"
            if (Test-Path -LiteralPath $failedInstall) {
                $failedInstall = Join-Path $Context.Root "failed-install-$(Get-Date -Format 'HHmmss')"
            }
            Move-Item -LiteralPath $InstallRoot -Destination $failedInstall
        }

        if ($hadSnapshot) {
            Move-Item -LiteralPath $Context.Snapshot -Destination $InstallRoot
            if (
                -not (Test-Path -LiteralPath $InstallRoot -PathType Container) -or
                (Test-Path -LiteralPath $Context.Snapshot)
            ) {
                throw "The prior installation did not return to '$InstallRoot'."
            }
        }
        Restore-EntryPoints -BackupRoot $Context.Root -Bin $Bin -PreservePath:$PreservePath
    } catch {
        throw "Automatic rollback failed: $($_.Exception.Message). The preserved snapshot or failed install remains under '$($Context.Root)'. Original error: $Reason"
    }

    $rollbackStatus = if ($hadSnapshot) { "failed-rolled-back" } else { "failed-no-prior-install" }
    try {
        Set-ManifestStatus -BackupRoot $Context.Root -Status $rollbackStatus -Message $Reason
    } catch {
        Write-Warn "Rollback succeeded, but its manifest could not be updated: $($_.Exception.Message)"
    }
    if ($hadSnapshot) {
        Write-Ok "Previous Brainstem installation restored."
    } else {
        Write-Ok "Partial install quarantined; there was no previous installation to restore."
    }
}

function Get-FileHashValue {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AgentFiles {
    param([string]$OldSource)

    $oldAgents = Join-Path $OldSource "rapp_brainstem\agents"
    if (-not (Test-Path -LiteralPath $oldAgents)) {
        return @()
    }

    $allAgents = @(
        Get-ChildItem -LiteralPath $oldAgents -Force -Recurse -File |
            Where-Object {
                $_.Extension -eq ".py" -and
                $_.FullName -notmatch "[\\/]__pycache__[\\/]"
            }
    )

    $result = @()
    foreach ($file in $allAgents) {
        $relative = $file.FullName.Substring($oldAgents.Length).TrimStart("\")
        $result += [pscustomobject]@{ File = $file; Relative = $relative }
    }
    return $result
}

function Get-DotEnvValue {
    param(
        [string]$EnvFile,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
        return $null
    }

    $value = $null
    $pattern = "^\s*(?:export\s+)?$([regex]::Escape($Name))\s*=\s*(.*)$"
    foreach ($line in @(Get-Content -LiteralPath $EnvFile -Encoding UTF8)) {
        if ($line -notmatch $pattern) {
            continue
        }
        $candidate = $Matches[1].Trim()
        if (
            $candidate.Length -ge 2 -and
            (
                ($candidate[0] -eq '"' -and $candidate[$candidate.Length - 1] -eq '"') -or
                ($candidate[0] -eq "'" -and $candidate[$candidate.Length - 1] -eq "'")
            )
        ) {
            $candidate = $candidate.Substring(1, $candidate.Length - 2)
        } else {
            $candidate = ($candidate -replace "\s+#.*$", "").Trim()
        }
        $value = $candidate
    }
    return $value
}

function Resolve-ConfiguredPath {
    param(
        [string]$Runtime,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if ([IO.Path]::IsPathRooted($expanded)) {
        return Get-FullPath $expanded
    }
    return Get-FullPath (Join-Path $Runtime $expanded)
}

function Restore-ConfiguredDataPaths {
    param(
        [string]$Snapshot,
        [string]$InstallRoot,
        [string]$BackupId
    )

    $oldRuntime = Join-Path $Snapshot "src\rapp_brainstem"
    $newRuntime = Join-Path $InstallRoot "src\rapp_brainstem"
    $envFile = Join-Path $oldRuntime ".env"
    $restored = 0

    foreach ($setting in @(
        [pscustomobject]@{ Name = "SOUL_PATH"; Default = "soul.md"; Kind = "file" },
        [pscustomobject]@{ Name = "AGENTS_PATH"; Default = "agents"; Kind = "directory" }
    )) {
        $configuredValue = Get-DotEnvValue -EnvFile $envFile -Name $setting.Name
        $resolvedPath = Resolve-ConfiguredPath -Runtime $oldRuntime -Value $configuredValue
        if (-not $resolvedPath) {
            continue
        }

        if (Test-PathWithin $resolvedPath $InstallRoot) {
            $relative = $resolvedPath.Substring($InstallRoot.Length).TrimStart("\")
            $oldPath = if ($relative) { Join-Path $Snapshot $relative } else { $Snapshot }
            $newPath = $resolvedPath
        } elseif (Test-PathWithin $resolvedPath $Snapshot) {
            $relative = $resolvedPath.Substring($Snapshot.Length).TrimStart("\")
            $oldPath = $resolvedPath
            $newPath = if ($relative) { Join-Path $InstallRoot $relative } else { $InstallRoot }
        } else {
            continue
        }

        $defaultNewPath = Get-FullPath (Join-Path $newRuntime $setting.Default)
        if (Test-SamePath $newPath $defaultNewPath) {
            continue
        }
        if (-not (Test-Path -LiteralPath $oldPath)) {
            Write-Warn "$($setting.Name) points to a missing path retained in .env: $configuredValue"
            continue
        }

        if ($setting.Kind -eq "file") {
            if (-not (Test-Path -LiteralPath $oldPath -PathType Leaf)) {
                throw "$($setting.Name) must point to a file, but '$oldPath' is not a file."
            }
            if (Test-Path -LiteralPath $newPath -PathType Container) {
                throw "$($setting.Name) cannot be restored because the fresh install has a directory at '$newPath'."
            }
            if (
                (Test-Path -LiteralPath $newPath -PathType Leaf) -and
                (Get-FileHashValue $oldPath) -ne (Get-FileHashValue $newPath)
            ) {
                $collision = Join-Path $InstallRoot "recovery\rapp-refresh-$BackupId\configured-soul"
                New-Item -ItemType Directory -Force -Path $collision | Out-Null
                Copy-Item -LiteralPath $oldPath -Destination (Join-Path $collision (Split-Path -Leaf $oldPath)) -Force
                throw "$($setting.Name) collides with a fresh runtime file at '$newPath'. The prior file was preserved under '$collision'."
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $newPath) | Out-Null
            Copy-Item -LiteralPath $oldPath -Destination $newPath -Force
        } else {
            if (-not (Test-Path -LiteralPath $oldPath -PathType Container)) {
                throw "$($setting.Name) must point to a directory, but '$oldPath' is not a directory."
            }
            if (Test-Path -LiteralPath $newPath -PathType Leaf) {
                throw "$($setting.Name) cannot be restored because the fresh install has a file at '$newPath'."
            }

            New-Item -ItemType Directory -Force -Path $newPath | Out-Null
            $unsafeBroadPath = (
                (Test-PathWithin $newRuntime $newPath) -or
                (Test-PathWithin (Join-Path $InstallRoot "venv") $newPath)
            )
            $configuredFiles = if ($unsafeBroadPath) {
                @(Get-ChildItem -LiteralPath $oldPath -Force -File -Filter "*_agent.py")
            } else {
                @(Get-ChildItem -LiteralPath $oldPath -Force -Recurse -File)
            }
            foreach ($file in $configuredFiles) {
                $relativeFile = $file.FullName.Substring($oldPath.Length).TrimStart("\")
                $destination = Join-Path $newPath $relativeFile
                if (-not (Test-Path -LiteralPath $destination)) {
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
                } elseif ((Get-FileHashValue $file.FullName) -ne (Get-FileHashValue $destination)) {
                    $collision = Join-Path $InstallRoot "recovery\rapp-refresh-$BackupId\configured-agents\$relativeFile"
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $collision) | Out-Null
                    Copy-Item -LiteralPath $file.FullName -Destination $collision -Force
                }
            }
        }
        $restored++
    }
    return $restored
}

function Restore-DurableData {
    param(
        [string]$Snapshot,
        [string]$InstallRoot,
        [string]$BackupId,
        [switch]$WithoutAuthentication
    )

    $oldRuntime = Join-Path $Snapshot "src\rapp_brainstem"
    $newRuntime = Join-Path $InstallRoot "src\rapp_brainstem"
    if (-not (Test-Path -LiteralPath $oldRuntime)) {
        return [pscustomobject]@{ Restored = 0; AgentCollisions = 0 }
    }
    if (-not (Test-Path -LiteralPath $newRuntime)) {
        throw "Fresh Brainstem runtime is missing; cannot restore data."
    }

    Write-Step "Restoring identity, memories, configuration, and custom agents..."
    $restored = 0
    $names = @(
        ".brainstem_data",
        ".brainstem_book.json",
        ".brainstem_model",
        ".brainstem_secret",
        ".env",
        "soul.md",
        "voice.zip"
    )
    if (-not $WithoutAuthentication) {
        $names += @(".copilot_token", ".copilot_session", ".copilot_pending")
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $oldRuntime -Force -ErrorAction SilentlyContinue)) {
        if (
            $item.Name -like ".brainstem_*" -or
            ((-not $WithoutAuthentication) -and $item.Name -like ".copilot_*") -or
            $item.Name -like "soul.md.bak-*"
        ) {
            $names += $item.Name
        }
    }

    foreach ($name in @($names | Sort-Object -Unique)) {
        $source = Join-Path $oldRuntime $name
        if (-not (Test-Path -LiteralPath $source)) {
            continue
        }
        $destination = Join-Path $newRuntime $name
        if ((Get-Item -LiteralPath $source -Force).PSIsContainer) {
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                throw "Cannot restore directory '$source' because the fresh install has a file at '$destination'."
            }
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            foreach ($child in @(Get-ChildItem -LiteralPath $source -Force)) {
                Copy-Item -LiteralPath $child.FullName -Destination $destination -Recurse -Force
            }
        } else {
            if (Test-Path -LiteralPath $destination -PathType Container) {
                throw "Cannot restore file '$source' because the fresh install has a directory at '$destination'."
            }
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        $restored++
    }

    $restored += Restore-ConfiguredDataPaths `
        -Snapshot $Snapshot `
        -InstallRoot $InstallRoot `
        -BackupId $BackupId

    $oldRecovery = Join-Path $Snapshot "recovery"
    $newRecovery = Join-Path $InstallRoot "recovery"
    if (Test-Path -LiteralPath $oldRecovery) {
        New-Item -ItemType Directory -Force -Path $newRecovery | Out-Null
        foreach ($child in @(Get-ChildItem -LiteralPath $oldRecovery -Force)) {
            Copy-Item -LiteralPath $child.FullName -Destination $newRecovery -Recurse -Force
        }
        $restored++
    }

    $oldSource = Join-Path $Snapshot "src"
    $newAgents = Join-Path $newRuntime "agents"
    $collisionRoot = Join-Path $InstallRoot "recovery\rapp-refresh-$BackupId\agents"
    $collisions = 0
    foreach ($agent in @(Get-AgentFiles $oldSource)) {
        $destination = Join-Path $newAgents $agent.Relative
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destination)) {
            New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
            Copy-Item -LiteralPath $agent.File.FullName -Destination $destination -Force
            $restored++
            continue
        }

        if ((Get-FileHashValue $agent.File.FullName) -eq (Get-FileHashValue $destination)) {
            continue
        }

        $collision = Join-Path $collisionRoot $agent.Relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $collision) | Out-Null
        Copy-Item -LiteralPath $agent.File.FullName -Destination $collision -Force
        $collisions++
    }

    return [pscustomobject]@{
        Restored = $restored
        AgentCollisions = $collisions
    }
}

function Get-InstallerScript {
    param(
        [string]$Uri,
        [string]$LocalPath,
        [string]$State
    )

    $downloads = Join-Path $State "downloads"
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    $download = Join-Path $downloads "brainstem-install-$PID.ps1"
    if (Test-Path -LiteralPath $download) {
        Remove-Item -LiteralPath $download -Force
    }

    if ($LocalPath) {
        $resolved = Get-FullPath $LocalPath
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "InstallerPath does not exist: $resolved"
        }
        Copy-Item -LiteralPath $resolved -Destination $download -Force
    } else {
        Write-Step "Downloading the upstream Brainstem installer..."
        Invoke-WebRequest -Uri $Uri -OutFile $download -UseBasicParsing -TimeoutSec 120
    }

    if ((Get-Item -LiteralPath $download).Length -lt 100) {
        throw "Downloaded installer is unexpectedly small."
    }
    return $download
}

function Invoke-FreshInstall {
    param(
        [string]$Uri,
        [string]$LocalPath,
        [string]$TargetVersion,
        [string]$InstallRoot,
        [string]$Bin,
        [string]$State
    )

    $installer = Get-InstallerScript -Uri $Uri -LocalPath $LocalPath -State $State
    $installerHash = Get-FileHashValue $installer
    Write-Host "  Installer SHA-256: $installerHash" -ForegroundColor DarkGray

    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $installer,
        "--no-launch"
    )
    if ($TargetVersion) {
        $arguments += @("--version", $TargetVersion)
    }

    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powershell)) {
        throw "Windows PowerShell 5.1 was not found at $powershell."
    }

    $oldTestHome = $env:RAPP_REFRESH_BRAINSTEM_HOME
    $oldTestBin = $env:RAPP_REFRESH_BRAINSTEM_BIN
    $previousPreference = $ErrorActionPreference
    $installerExit = -1
    $env:RAPP_REFRESH_BRAINSTEM_HOME = $InstallRoot
    $env:RAPP_REFRESH_BRAINSTEM_BIN = $Bin
    try {
        Write-Step "Running the complete Brainstem installer..."
        $ErrorActionPreference = "Continue"
        & $powershell @arguments 2>&1 | ForEach-Object { Write-Host "$_" }
        $installerExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        $env:RAPP_REFRESH_BRAINSTEM_HOME = $oldTestHome
        $env:RAPP_REFRESH_BRAINSTEM_BIN = $oldTestBin
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }

    if ($installerExit -ne 0) {
        throw "The Brainstem installer exited with code $installerExit."
    }
    return $installerHash
}

function Assert-FreshInstall {
    param([string]$InstallRoot, [string]$Bin)

    $required = @(
        (Join-Path $InstallRoot "src\rapp_brainstem\brainstem.py"),
        (Join-Path $InstallRoot "src\rapp_brainstem\requirements.txt"),
        (Join-Path $InstallRoot "src\rapp_brainstem\VERSION"),
        (Join-Path $InstallRoot "venv\Scripts\python.exe"),
        (Join-Path $Bin "brainstem.cmd"),
        (Join-Path $Bin "brainstem.ps1")
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) {
        throw "Fresh install is incomplete. Missing: $($missing -join ', ')"
    }
}

function Get-BackupRoot {
    param([string]$Requested, [string]$State)

    $backupParent = Join-Path $State "backups"
    if (-not (Test-Path -LiteralPath $backupParent)) {
        throw "No RAPP Refresh backups exist."
    }

    if ($Requested) {
        $candidate = if ([IO.Path]::IsPathRooted($Requested)) {
            Get-FullPath $Requested
        } else {
            Get-FullPath (Join-Path $backupParent $Requested)
        }
    } else {
        $candidate = Get-ChildItem -LiteralPath $backupParent -Directory -Force |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "brainstem") } |
            Sort-Object Name -Descending |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $candidate) {
            throw "No backup with a complete Brainstem snapshot exists."
        }
    }

    if (-not (Test-PathWithin $candidate $backupParent)) {
        throw "Backup must be inside '$backupParent'."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $candidate "manifest.json") -PathType Leaf)) {
        throw "Backup manifest is missing: $candidate"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $candidate "brainstem") -PathType Container)) {
        throw "Backup no longer contains a restorable Brainstem snapshot: $candidate"
    }
    return $candidate
}

function Assert-BackupLayout {
    param(
        [string]$BackupRoot,
        [string]$InstallRoot,
        [string]$Bin
    )

    $manifestPath = Join-Path $BackupRoot "manifest.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest.sourcePath -or -not (Test-SamePath ([string]$manifest.sourcePath) $InstallRoot)) {
        throw "Backup '$BackupRoot' belongs to a different BrainstemHome ('$($manifest.sourcePath)')."
    }
    if (-not $manifest.binPath -or -not (Test-SamePath ([string]$manifest.binPath) $Bin)) {
        throw "Backup '$BackupRoot' belongs to a different BrainstemBin ('$($manifest.binPath)')."
    }
}

function Show-Backups {
    param([string]$State)

    $backupParent = Join-Path $State "backups"
    if (-not (Test-Path -LiteralPath $backupParent)) {
        Write-Host "No RAPP Refresh backups found."
        return
    }

    $records = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $backupParent -Directory -Force | Sort-Object Name -Descending)) {
        $manifestPath = Join-Path $directory.FullName "manifest.json"
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            continue
        }
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $records += [pscustomobject]@{
                Id = $manifest.id
                Status = $manifest.status
                Version = $manifest.version
                GiB = [Math]::Round(([double]$manifest.bytes / 1GB), 2)
                Restorable = Test-Path -LiteralPath (Join-Path $directory.FullName "brainstem")
                Created = $manifest.createdUtc
                Path = $directory.FullName
            }
        } catch {
            Write-Warn "Could not read manifest: $manifestPath"
        }
    }

    if ($records.Count -eq 0) {
        Write-Host "No RAPP Refresh backups found."
        return
    }
    $records | Format-Table Id, Status, Version, GiB, Restorable, Created -AutoSize
}

function Invoke-RestoreSnapshot {
    param(
        [string]$RequestedBackup,
        [string]$InstallRoot,
        [string]$State,
        [string]$Bin,
        [switch]$PreservePath
    )

    $selectedRoot = Get-BackupRoot -Requested $RequestedBackup -State $State
    Assert-BackupLayout -BackupRoot $selectedRoot -InstallRoot $InstallRoot -Bin $Bin
    $selectedSnapshot = Join-Path $selectedRoot "brainstem"
    $currentContext = $null
    $selectedActivated = $false

    try {
        Stop-BrainstemProcesses $InstallRoot
        $currentContext = New-BackupContext -InstallRoot $InstallRoot -State $State -Bin $Bin
        Remove-BrainstemEntryPoints -Bin $Bin -PreservePath:$PreservePath

        Move-Item -LiteralPath $selectedSnapshot -Destination $InstallRoot
        $selectedActivated = $true
        $pathBackupRoot = $currentContext.Root
        if (-not $currentContext.HadInstall) {
            $currentPathFile = Join-Path $currentContext.Root "metadata\brainstem-path.json"
            $currentPathState = Get-Content -LiteralPath $currentPathFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $currentHasBrainstemPath = (
                @($currentPathState.userEntries).Count -gt 0 -or
                @($currentPathState.processEntries).Count -gt 0
            )
            if (-not $currentHasBrainstemPath) {
                $pathBackupRoot = $selectedRoot
            }
        }
        Restore-EntryPoints `
            -BackupRoot $selectedRoot `
            -PathBackupRoot $pathBackupRoot `
            -Bin $Bin `
            -PreservePath:$PreservePath
        Set-ManifestStatus -BackupRoot $selectedRoot -Status "restored" -Message "Snapshot restored to $InstallRoot."
        if ($currentContext) {
            Set-ManifestStatus -BackupRoot $currentContext.Root -Status "replaced-by-restore" -Message "Active install was quarantined before restoring $($selectedRoot)."
        }
        Write-Ok "Restored Brainstem snapshot '$((Split-Path -Leaf $selectedRoot))'."
        if ($currentContext) {
            Write-Host "  Replaced installation backup: $($currentContext.Root)" -ForegroundColor Cyan
        }
    } catch {
        $failure = $_.Exception.Message
        Write-Warn "Restore failed; putting snapshots back where they started."
        $rollbackProblems = @()
        $selectedReturned = -not $selectedActivated

        if ($selectedActivated -and (Test-Path -LiteralPath $InstallRoot)) {
            try {
                if (Test-Path -LiteralPath $selectedSnapshot) {
                    throw "Selected snapshot destination already exists: $selectedSnapshot"
                }
                Move-Item -LiteralPath $InstallRoot -Destination $selectedSnapshot
                if ((Test-Path -LiteralPath $InstallRoot) -or -not (Test-Path -LiteralPath $selectedSnapshot)) {
                    throw "Selected snapshot did not return to '$selectedSnapshot'."
                }
                $selectedReturned = $true
            } catch {
                $rollbackProblems += $_.Exception.Message
            }
        }

        if ($currentContext -and $selectedReturned) {
            try {
                if ($currentContext.HadInstall) {
                    if (Test-Path -LiteralPath $InstallRoot) {
                        throw "Install root is occupied; cannot restore the previously active snapshot."
                    }
                    if (-not (Test-Path -LiteralPath $currentContext.Snapshot)) {
                        throw "Previously active snapshot is missing: $($currentContext.Snapshot)"
                    }
                    Move-Item -LiteralPath $currentContext.Snapshot -Destination $InstallRoot
                    if (-not (Test-Path -LiteralPath $InstallRoot)) {
                        throw "Previously active installation did not return to '$InstallRoot'."
                    }
                }
                Restore-EntryPoints -BackupRoot $currentContext.Root -Bin $Bin -PreservePath:$PreservePath
            } catch {
                $rollbackProblems += $_.Exception.Message
            }
        } elseif ($currentContext) {
            $rollbackProblems += "Previously active snapshot was not restored because the selected snapshot could not be returned safely."
        }

        if ($rollbackProblems.Count -gt 0) {
            throw "Restore failed: $failure. Rollback also failed: $($rollbackProblems -join ' | '). Inspect '$selectedRoot' and '$($currentContext.Root)' before making further changes."
        }
        throw $failure
    }
}

function Invoke-Refresh {
    param(
        [string]$InstallRoot,
        [string]$State,
        [string]$Bin,
        [string]$Uri,
        [string]$LocalInstaller,
        [string]$TargetVersion,
        [switch]$WithoutAuthentication,
        [switch]$PreservePath
    )

    Stop-BrainstemProcesses $InstallRoot
    $context = New-BackupContext -InstallRoot $InstallRoot -State $State -Bin $Bin
    $transactionComplete = $false

    try {
        Remove-BrainstemEntryPoints -Bin $Bin -PreservePath:$PreservePath
        $installerHash = Invoke-FreshInstall `
            -Uri $Uri `
            -LocalPath $LocalInstaller `
            -TargetVersion $TargetVersion `
            -InstallRoot $InstallRoot `
            -Bin $Bin `
            -State $State
        Assert-FreshInstall -InstallRoot $InstallRoot -Bin $Bin
        if (-not $PreservePath) {
            Set-BrainstemPathAfterInstall -BackupRoot $context.Root -Bin $Bin
        }

        $restore = Restore-DurableData `
            -Snapshot $context.Snapshot `
            -InstallRoot $InstallRoot `
            -BackupId $context.Id `
            -WithoutAuthentication:$WithoutAuthentication

        $installedVersion = Get-BrainstemVersion $InstallRoot
        Set-ManifestStatus `
            -BackupRoot $context.Root `
            -Status "refreshed" `
            -Message "Fresh install completed and durable data restored." `
            -Additional @{
                installedVersion = $installedVersion
                installerSha256 = $installerHash
                restoredItems = $restore.Restored
                agentCollisions = $restore.AgentCollisions
            }
        $transactionComplete = $true

        Write-Host ""
        Write-Ok "Factory install completed (Brainstem v$installedVersion)."
        Write-Ok "Durable data restored; complete prior install retained."
        if ($restore.AgentCollisions -gt 0) {
            Write-Warn "$($restore.AgentCollisions) modified agent file(s) collided with fresh built-ins."
            Write-Host "      Preserved under $InstallRoot\recovery\rapp-refresh-$($context.Id)" -ForegroundColor Gray
        }
        if ($WithoutAuthentication) {
            Write-Warn "Authentication was reset; prior tokens remain only in the backup."
        }
        Write-Host "  Backup: $($context.Root)" -ForegroundColor Cyan
    } catch {
        $reason = $_.Exception.Message
        if (-not $transactionComplete) {
            Invoke-Rollback `
                -Context $context `
                -InstallRoot $InstallRoot `
                -Bin $Bin `
                -PreservePath:$PreservePath `
                -Reason $reason
        }
        throw
    }

}

function Start-Brainstem {
    param(
        [string]$InstallRoot,
        [string]$Bin,
        [switch]$SkipBrowser
    )

    $launcher = Join-Path $Bin "brainstem.cmd"
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Brainstem launcher is missing: $launcher"
    }

    $port = 7071
    $envFile = Join-Path $InstallRoot "src\rapp_brainstem\.env"
    $configuredPort = Get-DotEnvValue -EnvFile $envFile -Name "PORT"
    if ($configuredPort) {
        $parsedPort = 0
        if (-not [int]::TryParse($configuredPort, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) {
            throw "Brainstem PORT in .env is invalid: '$configuredPort'."
        }
        $port = $parsedPort
    }

    try {
        $existingListeners = @(
            Get-NetTCPConnection -State Listen -ErrorAction Stop |
                Where-Object { [int]$_.LocalPort -eq $port }
        )
    } catch {
        throw "Could not verify whether port $port is available: $($_.Exception.Message)"
    }
    if ($existingListeners.Count -gt 0) {
        $owners = @($existingListeners | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique)
        throw "Port $port is already in use by process ID(s): $($owners -join ', ')."
    }

    Write-Step "Launching Brainstem..."
    $launchStarted = [DateTime]::UtcNow
    $launcherProcess = $null
    $brainstemProcess = $null
    $healthy = $false

    try {
        $launcherProcess = Start-Process `
            -FilePath $launcher `
            -WindowStyle Hidden `
            -PassThru

        for ($attempt = 0; $attempt -lt 150; $attempt++) {
            foreach ($cimProcess in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
                if (Test-OwnedBrainstemProcess -Process $cimProcess -InstallRoot $InstallRoot) {
                    $candidate = Open-StableProcess $cimProcess
                    if ($candidate) {
                        if ($candidate.StartTime.ToUniversalTime() -ge $launchStarted.AddSeconds(-2)) {
                            $brainstemProcess = $candidate
                            break
                        }
                        $candidate.Dispose()
                    }
                }
            }
            if ($brainstemProcess) {
                break
            }
            if ($launcherProcess.HasExited) {
                throw "Brainstem launcher exited with code $($launcherProcess.ExitCode) before the server started."
            }
            Start-Sleep -Milliseconds 200
        }

        if (-not $brainstemProcess) {
            throw "Brainstem did not start an owned server process within 30 seconds."
        }

        $url = "http://127.0.0.1:$port"
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            if ($brainstemProcess.HasExited) {
                throw "Brainstem process $($brainstemProcess.Id) exited before becoming healthy."
            }

            $ownsPort = @(
                Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                    Where-Object {
                        [int]$_.LocalPort -eq $port -and
                        [int]$_.OwningProcess -eq $brainstemProcess.Id
                    }
            ).Count -gt 0
            if ($ownsPort) {
                try {
                    Invoke-WebRequest -Uri "$url/health" -UseBasicParsing -TimeoutSec 1 | Out-Null
                    $healthy = $true
                    break
                } catch {
                    # The owned server may still be completing startup.
                }
            }
            Start-Sleep -Seconds 1
        }
        if (-not $healthy) {
            throw "Brainstem process $($brainstemProcess.Id) did not own a healthy port $port within 60 seconds."
        }
    } catch {
        if ($brainstemProcess -and -not $brainstemProcess.HasExited) {
            $brainstemProcess.Kill()
            [void]$brainstemProcess.WaitForExit(10000)
        } elseif ($launcherProcess -and -not $launcherProcess.HasExited) {
            $launcherProcess.Kill()
            [void]$launcherProcess.WaitForExit(10000)
        }
        throw
    } finally {
        if ($brainstemProcess) {
            $brainstemProcess.Dispose()
        }
        if ($launcherProcess) {
            $launcherProcess.Dispose()
        }
    }

    if (-not $SkipBrowser) {
        try {
            Start-Process $url
        } catch {
            Write-Warn "Brainstem is healthy, but the browser could not be opened: $($_.Exception.Message)"
        }
    }
    Write-Ok "Brainstem is running at $url"
}

$BrainstemHome = Get-FullPath $BrainstemHome
$StateHome = Get-FullPath $StateHome
$BrainstemBin = Get-FullPath $BrainstemBin
Assert-SafeLayout -InstallRoot $BrainstemHome -State $StateHome -Bin $BrainstemBin

$defaultBrainstemHome = Get-FullPath (Join-Path $env:USERPROFILE ".brainstem")
$defaultBrainstemBin = Get-FullPath (Join-Path $env:USERPROFILE ".local\bin")
if (
    $Action -eq "Refresh" -and
    -not $InstallerPath -and
    (
        -not (Test-SamePath $BrainstemHome $defaultBrainstemHome) -or
        -not (Test-SamePath $BrainstemBin $defaultBrainstemBin)
    )
) {
    throw "The upstream installer only supports the default user-profile paths. Custom paths require -InstallerPath."
}

Write-Host ""
Write-Host "  RAPP Refresh" -ForegroundColor Cyan
Write-Host "  Safe factory resets for RAPP Brainstem" -ForegroundColor Gray
Write-Host ""

$operationLock = $null
$operationFailure = $null

try {
    if ($Action -eq "List") {
        Show-Backups $StateHome
    } elseif ($Action -eq "Refresh") {
        if ($Yes) {
            $ConfirmPreference = "None"
        }
        $description = "Quarantine '$BrainstemHome', run the upstream factory installer, and restore durable data"
        if ($PSCmdlet.ShouldProcess($BrainstemHome, $description)) {
            $operationLock = Enter-OperationLock $BrainstemHome
            Invoke-Refresh `
                -InstallRoot $BrainstemHome `
                -State $StateHome `
                -Bin $BrainstemBin `
                -Uri $InstallerUri `
                -LocalInstaller $InstallerPath `
                -TargetVersion $Version `
                -WithoutAuthentication:$ResetAuthentication `
                -PreservePath:$KeepPath
            if (-not $NoLaunch) {
                Start-Brainstem `
                    -InstallRoot $BrainstemHome `
                    -Bin $BrainstemBin `
                    -SkipBrowser:$NoBrowser
            }
        }
    } elseif ($Action -eq "Uninstall") {
        if ($Yes) {
            $ConfirmPreference = "None"
        }
        $description = "Quarantine '$BrainstemHome' and remove only Brainstem launchers and its PATH entry"
        if ($PSCmdlet.ShouldProcess($BrainstemHome, $description)) {
            $operationLock = Enter-OperationLock $BrainstemHome
            Stop-BrainstemProcesses $BrainstemHome
            $context = New-BackupContext -InstallRoot $BrainstemHome -State $StateHome -Bin $BrainstemBin
            try {
                Remove-BrainstemEntryPoints -Bin $BrainstemBin -PreservePath:$KeepPath
                Set-ManifestStatus -BackupRoot $context.Root -Status "uninstalled" -Message "Brainstem safely uninstalled; full snapshot retained."
            } catch {
                $uninstallFailure = $_.Exception.Message
                try {
                    Invoke-Rollback `
                        -Context $context `
                        -InstallRoot $BrainstemHome `
                        -Bin $BrainstemBin `
                        -PreservePath:$KeepPath `
                        -Reason $uninstallFailure
                } catch {
                    throw "Uninstall failed: $uninstallFailure. $($_.Exception.Message)"
                }
                throw $uninstallFailure
            }
            Write-Ok "Brainstem uninstalled without deleting its data."
            Write-Host "  Backup: $($context.Root)" -ForegroundColor Cyan
            Write-Host "  Restore: rapp-refresh -Action Restore -Backup $($context.Id)" -ForegroundColor Gray
        }
    } elseif ($Action -eq "Restore") {
        if ($Yes) {
            $ConfirmPreference = "None"
        }
        $target = if ($Backup) { $Backup } else { "the newest restorable backup" }
        if ($PSCmdlet.ShouldProcess($BrainstemHome, "Replace the active install with $target")) {
            $operationLock = Enter-OperationLock $BrainstemHome
            Invoke-RestoreSnapshot `
                -RequestedBackup $Backup `
                -InstallRoot $BrainstemHome `
                -State $StateHome `
                -Bin $BrainstemBin `
                -PreservePath:$KeepPath
        }
    }
} catch {
    $operationFailure = $_
} finally {
    if ($operationLock) {
        try {
            Exit-OperationLock $operationLock
        } catch {
            if (-not $operationFailure) {
                $operationFailure = $_
            }
        }
    }
}

if ($operationFailure) {
    Write-Host ""
    Write-Host "  [X] RAPP Refresh failed: $($operationFailure.Exception.Message)" -ForegroundColor Red
    Write-Host "      Existing data was not deleted." -ForegroundColor Yellow
    Write-Host ""
    if ($PSCommandPath) {
        exit 1
    }
    throw $operationFailure
}

}
