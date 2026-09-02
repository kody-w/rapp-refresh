param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$ErrorActionPreference = "Stop"
Write-Output "fake installer output"
$installRoot = $env:RAPP_REFRESH_BRAINSTEM_HOME
$bin = $env:RAPP_REFRESH_BRAINSTEM_BIN
if (-not $installRoot -or -not $bin) {
    throw "RAPP Refresh test paths were not supplied."
}

$runtime = Join-Path $installRoot "src\rapp_brainstem"
$venv = Join-Path $installRoot "venv\Scripts"
New-Item -ItemType Directory -Force -Path $runtime, (Join-Path $runtime "agents"), $venv, $bin | Out-Null
if ($env:RAPP_REFRESH_TEST_STATE_DIRECTORY_COLLISION -eq "1") {
    New-Item -ItemType Directory -Force -Path (Join-Path $runtime ".brainstem_secret") | Out-Null
}
if ($env:RAPP_REFRESH_TEST_SOUL_DIRECTORY_COLLISION -eq "1") {
    New-Item -ItemType Directory -Force -Path (Join-Path $runtime "identity\private.md") | Out-Null
}
if ($env:RAPP_REFRESH_TEST_STATE_FILE_COLLISION -eq "1") {
    Set-Content -LiteralPath (Join-Path $runtime ".brainstem_data") -Value "fresh file collision"
}

Set-Content -LiteralPath (Join-Path $runtime "brainstem.py") -Value "# fresh runtime"
Set-Content -LiteralPath (Join-Path $runtime "requirements.txt") -Value "requests"
Set-Content -LiteralPath (Join-Path $runtime "VERSION") -Value "9.9.9"
Set-Content -LiteralPath (Join-Path $runtime "soul.md") -Value "fresh default soul"
Set-Content -LiteralPath (Join-Path $runtime ".env") -Value "PORT=7071"
Set-Content -LiteralPath (Join-Path $runtime "agents\built_in_agent.py") -Value "# fresh built-in"
Set-Content -LiteralPath (Join-Path $venv "python.exe") -Value "test interpreter"
Set-Content -LiteralPath (Join-Path $bin "brainstem.cmd") -Value "@echo off"
Set-Content -LiteralPath (Join-Path $bin "brainstem.ps1") -Value "Write-Output brainstem"
