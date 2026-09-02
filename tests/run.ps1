#requires -Version 5.1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repo "rapp-refresh.ps1"
$bootstrap = Join-Path $repo "install.ps1"
$fakeInstaller = Join-Path $PSScriptRoot "fixtures\fake-install.ps1"
$failingInstaller = Join-Path $PSScriptRoot "fixtures\failing-install.ps1"
$testRoot = Join-Path $repo ".test-work"
$passed = 0
$failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Content {
    param([string]$Path, [string]$Expected)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "Missing file: $Path"
    $actual = (Get-Content -LiteralPath $Path -Raw).Trim()
    if ($actual -ne $Expected) {
        throw "Assertion failed for '$Path'. Expected '$Expected'; got '$actual'."
    }
}

function New-TestLayout {
    param([string]$Name)

    $root = Join-Path $testRoot $Name
    $testProfile = Join-Path $root "profile"
    $installRoot = Join-Path $testProfile ".brainstem"
    $state = Join-Path $testProfile ".rapp-refresh"
    $bin = Join-Path $testProfile ".local\bin"
    $runtime = Join-Path $installRoot "src\rapp_brainstem"
    New-Item -ItemType Directory -Force -Path `
        (Join-Path $runtime "agents"), `
        (Join-Path $runtime "identity"), `
        (Join-Path $runtime "private-agents"), `
        (Join-Path $runtime ".brainstem_data\shared_memories"), `
        (Join-Path $installRoot "venv\Scripts"), `
        $bin | Out-Null

    Set-Content -LiteralPath (Join-Path $runtime "VERSION") -Value "1.2.3"
    Set-Content -LiteralPath (Join-Path $runtime "brainstem.py") -Value "# old runtime"
    Set-Content -LiteralPath (Join-Path $runtime "requirements.txt") -Value "old"
    Set-Content -LiteralPath (Join-Path $runtime "soul.md") -Value "my soul"
    Set-Content -LiteralPath (Join-Path $runtime ".env") -Value @(
        "PORT=9999",
        "SOUL_PATH=./identity/private.md",
        "AGENTS_PATH=./private-agents"
    )
    Set-Content -LiteralPath (Join-Path $runtime ".brainstem_secret") -Value "secret"
    Set-Content -LiteralPath (Join-Path $runtime ".copilot_session") -Value '{"token":"test"}'
    Set-Content -LiteralPath (Join-Path $runtime ".brainstem_data\shared_memories\memory.json") -Value '{"remember":true}'
    Set-Content -LiteralPath (Join-Path $runtime "agents\custom_agent.py") -Value "# custom"
    Set-Content -LiteralPath (Join-Path $runtime "agents\built_in_agent.py") -Value "# locally modified"
    Set-Content -LiteralPath (Join-Path $runtime "identity\private.md") -Value "my private soul"
    Set-Content -LiteralPath (Join-Path $runtime "private-agents\private_agent.py") -Value "# private agent"
    Set-Content -LiteralPath (Join-Path $installRoot "venv\Scripts\python.exe") -Value "old interpreter"
    Set-Content -LiteralPath (Join-Path $bin "brainstem.cmd") -Value "@echo old"
    Set-Content -LiteralPath (Join-Path $bin "brainstem.ps1") -Value "Write-Output old"

    return [pscustomobject]@{
        Root = $root
        Home = $installRoot
        State = $state
        Bin = $bin
        Runtime = $runtime
    }
}

function Invoke-RefreshProcess {
    param(
        [string[]]$Arguments,
        [int]$ExpectedExit = 0
    )

    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $all = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script) + $Arguments
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $powershell @all 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    if ($exitCode -ne $ExpectedExit) {
        throw "Expected exit $ExpectedExit, got $exitCode.`n$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

Invoke-Test "fresh reinstall restores data and keeps snapshot" {
    $layout = New-TestLayout "success"
    $source = Join-Path $layout.Home "src"
    $builtIn = Join-Path $layout.Runtime "agents\built_in_agent.py"
    Set-Content -LiteralPath $builtIn -Value "# original built-in"
    & git -C $source init --quiet
    & git -C $source config user.name "RAPP Refresh Tests"
    & git -C $source config user.email "tests@example.invalid"
    & git -C $source add rapp_brainstem/agents/built_in_agent.py rapp_brainstem/agents/custom_agent.py
    & git -C $source commit --quiet -m "fixture baseline"
    Set-Content -LiteralPath $builtIn -Value "# staged local change"
    & git -C $source add rapp_brainstem/agents/built_in_agent.py

    Invoke-RefreshProcess @(
        "-Action", "Refresh",
        "-BrainstemHome", $layout.Home,
        "-StateHome", $layout.State,
        "-BrainstemBin", $layout.Bin,
        "-InstallerPath", $fakeInstaller,
        "-KeepPath",
        "-NoLaunch",
        "-Yes"
    ) | Out-Null

    Assert-Content (Join-Path $layout.Runtime "VERSION") "9.9.9"
    Assert-Content (Join-Path $layout.Runtime "soul.md") "my soul"
    Assert-True ((Get-Content -LiteralPath (Join-Path $layout.Runtime ".env") -Raw) -match "PORT=9999") "Custom .env was not restored."
    Assert-Content (Join-Path $layout.Runtime ".brainstem_secret") "secret"
    Assert-Content (Join-Path $layout.Runtime ".copilot_session") '{"token":"test"}'
    Assert-Content (Join-Path $layout.Runtime ".brainstem_data\shared_memories\memory.json") '{"remember":true}'
    Assert-Content (Join-Path $layout.Runtime "agents\custom_agent.py") "# custom"
    Assert-Content (Join-Path $layout.Runtime "agents\built_in_agent.py") "# fresh built-in"
    Assert-Content (Join-Path $layout.Runtime "identity\private.md") "my private soul"
    Assert-Content (Join-Path $layout.Runtime "private-agents\private_agent.py") "# private agent"

    $backup = Get-ChildItem -LiteralPath (Join-Path $layout.State "backups") -Directory | Select-Object -First 1
    Assert-True ($null -ne $backup) "Expected a backup directory."
    Assert-Content (Join-Path $backup.FullName "brainstem\src\rapp_brainstem\soul.md") "my soul"
    Assert-Content `
        (Join-Path $layout.Home "recovery\rapp-refresh-$($backup.Name)\agents\built_in_agent.py") `
        "# staged local change"
    $manifest = Get-Content -LiteralPath (Join-Path $backup.FullName "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($manifest.status -eq "refreshed") "Expected refreshed manifest status."
    Assert-True ($manifest.installerSha256 -match "^[0-9a-f]{64}$") "Installer hash must be a scalar SHA-256 value."
}

Invoke-Test "authentication reset leaves token only in snapshot" {
    $layout = New-TestLayout "reset-auth"
    Invoke-RefreshProcess @(
        "-Action", "Refresh",
        "-BrainstemHome", $layout.Home,
        "-StateHome", $layout.State,
        "-BrainstemBin", $layout.Bin,
        "-InstallerPath", $fakeInstaller,
        "-KeepPath",
        "-NoLaunch",
        "-ResetAuthentication",
        "-Yes"
    ) | Out-Null

    Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.Runtime ".copilot_session"))) "Token should not be restored."
    $backup = Get-ChildItem -LiteralPath (Join-Path $layout.State "backups") -Directory | Select-Object -First 1
    Assert-Content (Join-Path $backup.FullName "brainstem\src\rapp_brainstem\.copilot_session") '{"token":"test"}'
}

Invoke-Test "absolute in-install soul and agent paths are restored" {
    $layout = New-TestLayout "absolute-config"
    $absoluteSoul = Join-Path $layout.Runtime "identity\absolute.md"
    $absoluteAgents = Join-Path $layout.Runtime "absolute-agents"
    New-Item -ItemType Directory -Force -Path $absoluteAgents | Out-Null
    Set-Content -LiteralPath $absoluteSoul -Value "absolute soul"
    Set-Content -LiteralPath (Join-Path $absoluteAgents "absolute_agent.py") -Value "# absolute agent"
    Set-Content -LiteralPath (Join-Path $layout.Runtime ".env") -Value @(
        "PORT=9999",
        "SOUL_PATH=$absoluteSoul",
        "AGENTS_PATH=$absoluteAgents"
    )

    Invoke-RefreshProcess @(
        "-Action", "Refresh",
        "-BrainstemHome", $layout.Home,
        "-StateHome", $layout.State,
        "-BrainstemBin", $layout.Bin,
        "-InstallerPath", $fakeInstaller,
        "-KeepPath",
        "-NoLaunch",
        "-Yes"
    ) | Out-Null

    Assert-Content $absoluteSoul "absolute soul"
    Assert-Content (Join-Path $absoluteAgents "absolute_agent.py") "# absolute agent"
}

Invoke-Test "broad AGENTS_PATH cannot overwrite the fresh runtime" {
    $layout = New-TestLayout "broad-agents"
    Set-Content -LiteralPath (Join-Path $layout.Runtime ".env") -Value @(
        "PORT=9999",
        "SOUL_PATH=./soul.md",
        "AGENTS_PATH=."
    )
    Set-Content -LiteralPath (Join-Path $layout.Runtime "root_agent.py") -Value "# root custom agent"

    Invoke-RefreshProcess @(
        "-Action", "Refresh",
        "-BrainstemHome", $layout.Home,
        "-StateHome", $layout.State,
        "-BrainstemBin", $layout.Bin,
        "-InstallerPath", $fakeInstaller,
        "-KeepPath",
        "-NoLaunch",
        "-Yes"
    ) | Out-Null

    Assert-Content (Join-Path $layout.Runtime "brainstem.py") "# fresh runtime"
    Assert-Content (Join-Path $layout.Runtime "root_agent.py") "# root custom agent"
}

Invoke-Test "durable file-to-directory collision rolls back" {
    $layout = New-TestLayout "state-type-collision"
    $env:RAPP_REFRESH_TEST_STATE_DIRECTORY_COLLISION = "1"
    try {
        Invoke-RefreshProcess @(
            "-Action", "Refresh",
            "-BrainstemHome", $layout.Home,
            "-StateHome", $layout.State,
            "-BrainstemBin", $layout.Bin,
            "-InstallerPath", $fakeInstaller,
            "-KeepPath",
            "-NoLaunch",
            "-Yes"
        ) 1 | Out-Null
    } finally {
        Remove-Item Env:\RAPP_REFRESH_TEST_STATE_DIRECTORY_COLLISION -ErrorAction SilentlyContinue
    }
    Assert-Content (Join-Path $layout.Runtime ".brainstem_secret") "secret"
    Assert-Content (Join-Path $layout.Runtime "VERSION") "1.2.3"
}

Invoke-Test "configured soul file-to-directory collision rolls back" {
    $layout = New-TestLayout "soul-type-collision"
    $env:RAPP_REFRESH_TEST_SOUL_DIRECTORY_COLLISION = "1"
    try {
        Invoke-RefreshProcess @(
            "-Action", "Refresh",
            "-BrainstemHome", $layout.Home,
            "-StateHome", $layout.State,
            "-BrainstemBin", $layout.Bin,
            "-InstallerPath", $fakeInstaller,
            "-KeepPath",
            "-NoLaunch",
            "-Yes"
        ) 1 | Out-Null
    } finally {
        Remove-Item Env:\RAPP_REFRESH_TEST_SOUL_DIRECTORY_COLLISION -ErrorAction SilentlyContinue
    }
    Assert-Content (Join-Path $layout.Runtime "identity\private.md") "my private soul"
    Assert-Content (Join-Path $layout.Runtime "VERSION") "1.2.3"
}

Invoke-Test "durable directory-to-file collision rolls back" {
    $layout = New-TestLayout "state-directory-collision"
    $env:RAPP_REFRESH_TEST_STATE_FILE_COLLISION = "1"
    try {
        Invoke-RefreshProcess @(
            "-Action", "Refresh",
            "-BrainstemHome", $layout.Home,
            "-StateHome", $layout.State,
            "-BrainstemBin", $layout.Bin,
            "-InstallerPath", $fakeInstaller,
            "-KeepPath",
            "-NoLaunch",
            "-Yes"
        ) 1 | Out-Null
    } finally {
        Remove-Item Env:\RAPP_REFRESH_TEST_STATE_FILE_COLLISION -ErrorAction SilentlyContinue
    }
    Assert-Content (Join-Path $layout.Runtime ".brainstem_data\shared_memories\memory.json") '{"remember":true}'
    Assert-Content (Join-Path $layout.Runtime "VERSION") "1.2.3"
}

Invoke-Test "installer failure restores old installation" {
    $layout = New-TestLayout "rollback"
    Invoke-RefreshProcess @(
        "-Action", "Refresh",
        "-BrainstemHome", $layout.Home,
        "-StateHome", $layout.State,
        "-BrainstemBin", $layout.Bin,
        "-InstallerPath", $failingInstaller,
        "-KeepPath",
        "-NoLaunch",
        "-Yes"
    ) 1 | Out-Null

    Assert-Content (Join-Path $layout.Runtime "VERSION") "1.2.3"
    Assert-Content (Join-Path $layout.Runtime "soul.md") "my soul"
    Assert-Content (Join-Path $layout.Bin "brainstem.cmd") "@echo old"
    $backup = Get-ChildItem -LiteralPath (Join-Path $layout.State "backups") -Directory | Select-Object -First 1
    $manifest = Get-Content -LiteralPath (Join-Path $backup.FullName "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($manifest.status -eq "failed-rolled-back") "Expected rolled-back manifest status."
}

Invoke-Test "safe uninstall and restore round trip" {
    $layout = New-TestLayout "uninstall"
    Invoke-RefreshProcess @(
        "-Action", "Uninstall",
        "-BrainstemHome", $layout.Home,
        "-StateHome", $layout.State,
        "-BrainstemBin", $layout.Bin,
        "-KeepPath",
        "-Yes"
    ) | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $layout.Home)) "Brainstem should be absent after uninstall."

    $backup = Get-ChildItem -LiteralPath (Join-Path $layout.State "backups") -Directory | Select-Object -First 1
    Invoke-RefreshProcess @(
        "-Action", "Restore",
        "-Backup", $backup.Name,
        "-BrainstemHome", $layout.Home,
        "-StateHome", $layout.State,
        "-BrainstemBin", $layout.Bin,
        "-KeepPath",
        "-Yes"
    ) | Out-Null
    Assert-Content (Join-Path $layout.Runtime "soul.md") "my soul"
    Assert-Content (Join-Path $layout.Bin "brainstem.cmd") "@echo old"
}

Invoke-Test "restore rejects a backup from another layout" {
    $layout = New-TestLayout "layout-source"
    Invoke-RefreshProcess @(
        "-Action", "Uninstall",
        "-BrainstemHome", $layout.Home,
        "-StateHome", $layout.State,
        "-BrainstemBin", $layout.Bin,
        "-KeepPath",
        "-Yes"
    ) | Out-Null
    $backup = Get-ChildItem -LiteralPath (Join-Path $layout.State "backups") -Directory | Select-Object -First 1

    $otherHome = Join-Path $layout.Root "other\.brainstem"
    $otherBin = Join-Path $layout.Root "other\.local\bin"
    $output = Invoke-RefreshProcess @(
        "-Action", "Restore",
        "-Backup", $backup.Name,
        "-BrainstemHome", $otherHome,
        "-StateHome", $layout.State,
        "-BrainstemBin", $otherBin,
        "-KeepPath",
        "-Yes"
    ) 1
    Assert-True (($output -join "`n") -match "belongs to a different BrainstemHome") "Expected layout mismatch error."
    Assert-True (Test-Path -LiteralPath (Join-Path $backup.FullName "brainstem")) "Rejected snapshot must remain in its backup."
}

Invoke-Test "path guard rejects a non-brainstem target" {
    $unsafe = Join-Path $testRoot "not-brainstem"
    New-Item -ItemType Directory -Force -Path $unsafe | Out-Null
    $output = Invoke-RefreshProcess @(
        "-Action", "Uninstall",
        "-BrainstemHome", $unsafe,
        "-StateHome", (Join-Path $testRoot "state"),
        "-BrainstemBin", (Join-Path $testRoot "bin"),
        "-KeepPath",
        "-Yes"
    ) 1
    Assert-True (($output -join "`n") -match "must end in '.brainstem'") "Expected the path safety error."
    Assert-True (Test-Path -LiteralPath $unsafe) "Unsafe target must remain untouched."
}

Invoke-Test "path guard rejects Brainstem inside its bin" {
    $bin = Join-Path $testRoot "unsafe-bin"
    $installRoot = Join-Path $bin ".brainstem"
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    $output = Invoke-RefreshProcess @(
        "-Action", "Uninstall",
        "-BrainstemHome", $installRoot,
        "-StateHome", (Join-Path $testRoot "unsafe-state"),
        "-BrainstemBin", $bin,
        "-KeepPath",
        "-Yes"
    ) 1
    Assert-True (($output -join "`n") -match "cannot be inside BrainstemBin") "Expected containment safety error."
    Assert-True (Test-Path -LiteralPath $installRoot) "Contained install must remain untouched."
}

Invoke-Test "path guard rejects cross-volume backup state" {
    $output = Invoke-RefreshProcess @(
        "-Action", "Uninstall",
        "-BrainstemHome", "C:\rapp-refresh-test\.brainstem",
        "-StateHome", "D:\rapp-refresh-test\.rapp-refresh",
        "-BrainstemBin", "C:\rapp-refresh-test\.local\bin",
        "-KeepPath",
        "-Yes"
    ) 1
    Assert-True (($output -join "`n") -match "must be on the same volume") "Expected cross-volume safety error."
}

Invoke-Test "concurrent operation is rejected before mutation" {
    $layout = New-TestLayout "locked"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
        $hash = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
    } finally {
        $sha.Dispose()
    }

    $mutex = New-Object Threading.Mutex($false, "Global\RappRefresh-$hash")
    Assert-True ($mutex.WaitOne(0)) "Test could not acquire the operation lock."
    try {
        $output = Invoke-RefreshProcess @(
            "-Action", "Uninstall",
            "-BrainstemHome", $layout.Home,
            "-StateHome", $layout.State,
            "-BrainstemBin", $layout.Bin,
            "-KeepPath",
            "-Yes"
        ) 1
        Assert-True (($output -join "`n") -match "Another RAPP Refresh operation") "Expected lock conflict was not reported."
        Assert-Content (Join-Path $layout.Runtime "soul.md") "my soul"
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

Invoke-Test "PATH token restoration preserves order duplicates and empties" {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $script,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($name in @(
        "Get-FullPath",
        "Test-PathEntry",
        "Remove-PathEntryFromValue",
        "Get-MatchingPathEntries",
        "Restore-PathEntriesToValue"
    )) {
        $definition = $ast.FindAll(
            {
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $name
            },
            $true
        ) | Select-Object -First 1
        Assert-True ($null -ne $definition) "Could not load function $name for the PATH test."
        Invoke-Expression $definition.Extent.Text
    }

    $bin = "C:\Users\test\.local\bin"
    $original = "C:\trusted;;$bin;C:\other;$bin;"
    $saved = @(Get-MatchingPathEntries -Value $original -Target $bin)
    $removed = Remove-PathEntryFromValue -Value $original -Target $bin
    $restored = Restore-PathEntriesToValue `
        -Value $removed `
        -Target $bin `
        -SavedEntries $saved `
        -OriginalTokenCount @([regex]::Split($original, ";")).Count
    Assert-True ($restored -eq $original) "PATH tokens were not restored exactly."
}

Invoke-Test "launch verifies the owned process port and health" {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $script,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($name in @(
        "Write-Step",
        "Write-Ok",
        "Write-Warn",
        "Get-FullPath",
        "Test-SamePath",
        "Test-PathWithin",
        "Test-CommandLinePath",
        "Test-OwnedBrainstemProcess",
        "Open-StableProcess",
        "Get-DotEnvValue",
        "Start-Brainstem"
    )) {
        $definition = $ast.FindAll(
            {
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $name
            },
            $true
        ) | Select-Object -First 1
        Assert-True ($null -ne $definition) "Could not load function $name for the launch test."
        Invoke-Expression $definition.Extent.Text
    }

    $launchSegment = "launch"
    $installRoot = Join-Path $testRoot "$launchSegment\.brainstem"
    $runtime = Join-Path $installRoot "src\rapp_brainstem"
    $venvScripts = Join-Path $installRoot "venv\Scripts"
    $bin = Join-Path $testRoot "$launchSegment\.local\bin"
    New-Item -ItemType Directory -Force -Path $runtime, $venvScripts, $bin | Out-Null

    $portProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()

    Set-Content -LiteralPath (Join-Path $runtime ".env") -Value "PORT=$port"
    Set-Content -LiteralPath (Join-Path $runtime "brainstem.py") -Value "# launch identity marker"

    $serverSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

public static class RappRefreshHealthServer
{
    public static int Main(string[] args)
    {
        int port = 7071;
        foreach (string line in File.ReadAllLines(".env"))
        {
            if (line.StartsWith("PORT=", StringComparison.Ordinal))
            {
                port = Int32.Parse(line.Substring(5));
            }
        }

        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        while (true)
        {
            using (TcpClient client = listener.AcceptTcpClient())
            using (NetworkStream stream = client.GetStream())
            using (StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true))
            {
                string line;
                while (!String.IsNullOrEmpty(line = reader.ReadLine()))
                {
                }
                byte[] body = Encoding.UTF8.GetBytes("{\"status\":\"ok\"}");
                string headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
                    body.Length + "\r\nConnection: close\r\n\r\n";
                byte[] prefix = Encoding.ASCII.GetBytes(headers);
                stream.Write(prefix, 0, prefix.Length);
                stream.Write(body, 0, body.Length);
            }
        }
    }
}
'@
    $serverExe = Join-Path $venvScripts "python.exe"
    Add-Type `
        -TypeDefinition $serverSource `
        -Language CSharp `
        -OutputAssembly $serverExe `
        -OutputType ConsoleApplication | Out-Null

    $launcher = Join-Path $bin "brainstem.cmd"
    $serverLog = Join-Path $installRoot "server.log"
    $launcherContent = "@echo off`r`ncd /d `"$runtime`"`r`n`"$serverExe`" brainstem.py > `"$serverLog`" 2>&1`r`n"
    [IO.File]::WriteAllText($launcher, $launcherContent, (New-Object Text.ASCIIEncoding))

    try {
        try {
            Start-Brainstem -InstallRoot $installRoot -Bin $bin -SkipBrowser
        } catch {
            $details = if (Test-Path -LiteralPath $serverLog) {
                Get-Content -LiteralPath $serverLog -Raw
            } else {
                "server log was not created"
            }
            throw "$($_.Exception.Message) Server output: $details"
        }
        $listeners = @(
            Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { [int]$_.LocalPort -eq $port }
        )
        Assert-True ($listeners.Count -eq 1) "Expected exactly one verified test server listener."
    } finally {
        foreach ($listener in @(
            Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { [int]$_.LocalPort -eq $port }
        )) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction SilentlyContinue
            if ($process -and (Test-OwnedBrainstemProcess -Process $process -InstallRoot $installRoot)) {
                Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Invoke-Test "bootstrap installs a working command without touching PATH" {
    $unicodeSegment = "Jos$([char]0x00e9)-$([char]0x5de5)"
    $destination = Join-Path $testRoot "bootstrap\$unicodeSegment\.rapp-refresh"
    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    & $powershell `
        -NoLogo `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $bootstrap `
        -Source $script `
        -Destination $destination `
        -KeepPath
    Assert-True ($LASTEXITCODE -eq 0) "Bootstrap should exit successfully."
    Assert-True (Test-Path -LiteralPath (Join-Path $destination "rapp-refresh.ps1")) "Core script was not installed."
    $launcher = Join-Path $destination "bin\rapp-refresh.cmd"
    Assert-True (Test-Path -LiteralPath $launcher) "Command launcher was not installed."

    $listHome = Join-Path $testRoot "bootstrap-profile\.brainstem"
    $listState = Join-Path $testRoot "bootstrap-profile\.rapp-refresh"
    $listBin = Join-Path $testRoot "bootstrap-profile\.local\bin"
    & $launcher `
        -Action List `
        -BrainstemHome $listHome `
        -StateHome $listState `
        -BrainstemBin $listBin
    Assert-True ($LASTEXITCODE -eq 0) "Installed launcher should execute from a non-ASCII path."
}

Invoke-Test "dynamic one-liner invocation reports failure" {
    $testProfile = Join-Path $testRoot "iex-profile"
    $installRoot = Join-Path $testProfile ".brainstem"
    $state = Join-Path $testProfile ".rapp-refresh"
    $bin = Join-Path $testProfile ".local\bin"
    $escapedScript = $script.Replace("'", "''")
    $escapedRoot = $installRoot.Replace("'", "''")
    $escapedState = $state.Replace("'", "''")
    $escapedBin = $bin.Replace("'", "''")
    $command = @"
`$block = [scriptblock]::Create([IO.File]::ReadAllText('$escapedScript'))
& `$block -Action Restore -BrainstemHome '$escapedRoot' -StateHome '$escapedState' -BrainstemBin '$escapedBin' -Yes
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $powershell -NoLogo -NoProfile -EncodedCommand $encoded 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    Assert-True ($exitCode -ne 0) "Dynamic invocation must return a failing process status."
    Assert-True (($output -join "`n") -match "No RAPP Refresh backups exist") "Expected restore failure was not reported."
}

Write-Host ""
Write-Host "$passed passed, $failed failed"

$result = $failed
if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

if ($result -gt 0) {
    exit 1
}
