#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Source = "https://raw.githubusercontent.com/kody-w/rapp-refresh/main/rapp-refresh.ps1",

    [string]$Destination = (Join-Path $env:USERPROFILE ".rapp-refresh"),

    [switch]$KeepPath
)

& {
$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # TLS 1.2 is already the platform default when this legacy switch is unavailable.
}

$installHome = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Destination))
$bin = Join-Path $installHome "bin"
$scriptPath = Join-Path $installHome "rapp-refresh.ps1"
$launcherPath = Join-Path $bin "rapp-refresh.cmd"
$stagedScript = Join-Path $env:TEMP "rapp-refresh-$PID.ps1"

function Get-FullPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
}

function Test-PathEntry {
    param([string]$Entry, [string]$Target)
    if ([string]::IsNullOrWhiteSpace($Entry)) {
        return $false
    }
    try {
        $left = (Get-FullPath $Entry.Trim().Trim('"')).TrimEnd("\")
        $right = (Get-FullPath $Target).TrimEnd("\")
        return [string]::Equals($left, $right, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

try {
    Write-Host ""
    Write-Host "  RAPP Refresh" -ForegroundColor Cyan
    Write-Host "  Installing the safe Brainstem reset command" -ForegroundColor Gray
    Write-Host ""

    New-Item -ItemType Directory -Force -Path $installHome, $bin | Out-Null
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Copy-Item -LiteralPath $Source -Destination $stagedScript -Force
    } else {
        if ($Source -notmatch "^https://") {
            throw "Source must be a local file or an HTTPS URL."
        }
        Invoke-WebRequest -Uri $Source -OutFile $stagedScript -UseBasicParsing -TimeoutSec 120
    }

    if ((Get-Item -LiteralPath $stagedScript).Length -lt 1000) {
        throw "Downloaded RAPP Refresh script is unexpectedly small."
    }
    Move-Item -LiteralPath $stagedScript -Destination $scriptPath -Force

    $launcher = @"
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\rapp-refresh.ps1" %*
"@
    [IO.File]::WriteAllText($launcherPath, $launcher, (New-Object Text.ASCIIEncoding))

    if (-not $KeepPath) {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $hasBin = $false
        foreach ($entry in @($userPath -split ";")) {
            if (Test-PathEntry -Entry $entry -Target $bin) {
                $hasBin = $true
                break
            }
        }
        if (-not $hasBin) {
            $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $bin } else { "$bin;$userPath" }
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        }
        if (-not (($env:Path -split ";") | Where-Object { Test-PathEntry -Entry $_ -Target $bin })) {
            $env:Path = "$bin;$env:Path"
        }
    }

    Write-Host "  [OK] Installed: $launcherPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Run a safe factory reinstall:" -ForegroundColor White
    Write-Host "    rapp-refresh" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Preview without changing anything:" -ForegroundColor White
    Write-Host "    rapp-refresh -WhatIf" -ForegroundColor Cyan
    Write-Host ""
} catch {
    Remove-Item -LiteralPath $stagedScript -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "  [X] RAPP Refresh installation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    if ($PSCommandPath) {
        exit 1
    }
    throw
}
}
