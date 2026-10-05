# Hermetic tests for install.ps1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\install_ps1_test.ps1
#   pwsh -NoProfile -File tests\install_ps1_test.ps1 -Shell pwsh
#
# Each case runs the real installer in a fresh PowerShell process (-Shell)
# with LOCALAPPDATA pointed at a scratch directory, downloads served from a
# local fixture release tree, and the user PATH written to a throwaway
# registry key (KUROGANE_TEST_ENV_KEY) instead of HKCU\Environment.
param(
    [string]$Shell = 'powershell'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'install.ps1'
$runner = Join-Path $PSScriptRoot 'support\run_install_ps1.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('kurogane-ps1-test-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $work 'fixture'
$regRoot = 'HKCU:\Software\KuroganeInstallerTest'
$script:pass = 0
$script:fail = 0
$script:failed = @()

New-Item -ItemType Directory -Path $fixture | Out-Null

# Fake kurogane.exe: prints `kurogane <version>`; `--hold` keeps it running.
function New-FakeExe([string]$Path, [string]$Line, [int]$ExitCode = 0) {
    $src = @"
public static class Program {
    public static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "--hold") { System.Threading.Thread.Sleep(30000); return 0; }
        if ("$Line".Length > 0) System.Console.WriteLine("$Line");
        return $ExitCode;
    }
}
"@
    # Compiled by Windows PowerShell: PowerShell 7 cannot emit executables.
    $srcFile = "$Path.cs"
    Set-Content -LiteralPath $srcFile -Value $src
    & powershell -NoProfile -Command "Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath '$srcFile') -OutputAssembly '$Path' -OutputType ConsoleApplication" | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) { throw "could not build $Path" }
}

function New-Release([string]$Version, [string]$Triple, [string]$Line = "kurogane $Version", [int]$ExitCode = 0, [switch]$Nested) {
    $stage = Join-Path $work "stage\$Version\$Triple"
    $exeDir = if ($Nested) { Join-Path $stage "kurogane-cli-$Triple" } else { $stage }
    New-Item -ItemType Directory -Force -Path $exeDir | Out-Null
    New-FakeExe (Join-Path $exeDir 'kurogane.exe') $Line $ExitCode
    $out = Join-Path $fixture "releases\download\v$Version"
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $zip = Join-Path $out "kurogane-cli-$Triple.zip"
    $item = if ($Nested) { $exeDir } else { Join-Path $exeDir 'kurogane.exe' }
    Compress-Archive -LiteralPath $item -DestinationPath $zip -Force
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$zip.sha256" -Value "$hash *kurogane-cli-$Triple.zip" -NoNewline
}

# The version the fixture's "latest" release reports.
$LatestVersion = '0.0.6'
# What the installer picks on this machine without KUROGANE_ARCH (x64 or ARM64 runner).
$nativeArch = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
$hostTriple = if ($nativeArch -eq 'ARM64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }

Write-Host 'building fixtures...'
foreach ($t in 'x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc') {
    New-Release '0.0.5' $t
    New-Release $LatestVersion $t
}
$latest = Join-Path $fixture 'releases\latest\download'
New-Item -ItemType Directory -Force -Path (Split-Path $latest) | Out-Null
Copy-Item -Recurse (Join-Path $fixture "releases\download\v$LatestVersion") $latest
# The failure fixtures exist only for this machine's triple.
New-Release '0.0.7' $hostTriple
Set-Content -LiteralPath (Join-Path $fixture "releases\download\v0.0.7\kurogane-cli-$hostTriple.zip.sha256") -Value (('0' * 64) + " *kurogane-cli-$hostTriple.zip")
New-Release '0.0.8' $hostTriple -Line '' -ExitCode 3
New-Release '0.0.9' $hostTriple -Line 'kurogane 1.2.3'
New-Release '0.1.0' $hostTriple -Nested
# A zip that is not one, with a checksum that matches it: extraction itself must fail.
$corrupt = Join-Path $fixture "releases\download\v0.1.1\kurogane-cli-$hostTriple.zip"
New-Item -ItemType Directory -Force -Path (Split-Path $corrupt) | Out-Null
[IO.File]::WriteAllBytes($corrupt, [byte[]](1..200))
Set-Content -LiteralPath "$corrupt.sha256" -Value (Get-FileHash -LiteralPath $corrupt -Algorithm SHA256).Hash.ToLowerInvariant() -NoNewline

# ----------------------------------------------------------------- runner ---

$caseEnv = 'KUROGANE_VERSION', 'KUROGANE_INSTALL_DIR', 'KUROGANE_NO_MODIFY_PATH', 'KUROGANE_ARCH',
    'KUROGANE_DOWNLOAD_URL', 'KUROGANE_TEST_ENV_KEY', 'FAKE_TRUNCATE', 'DL_LOG', 'GITHUB_PATH', 'LOCALAPPDATA'
$savedEnv = @{}
foreach ($n in $caseEnv) { $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }

$script:case = $null
function New-Case([string]$Name) {
    $dir = Join-Path $work "case.$Name"
    $script:case = [pscustomobject]@{
        Name = $Name
        Dir = $dir
        AppData = Join-Path $dir 'appdata'
        Log = Join-Path $dir 'dl.log'
        Key = "$regRoot\$Name"
        Bin = Join-Path $dir 'appdata\kurogane\bin'
        Output = ''
        Code = 0
    }
    New-Item -ItemType Directory -Force -Path $script:case.AppData | Out-Null
    Set-Content -LiteralPath $script:case.Log -Value $null
    New-Item -Force -Path $script:case.Key | Out-Null
}

function Invoke-Installer([hashtable]$Env = @{}, [string]$Mode = 'script', [string]$ScriptArgs = '', [string]$Policy = '') {
    $c = $script:case
    foreach ($n in $caseEnv) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    $env:LOCALAPPDATA = $c.AppData
    $env:DL_LOG = $c.Log
    $env:KUROGANE_DOWNLOAD_URL = 'https://fixture.invalid/releases'
    $env:KUROGANE_TEST_ENV_KEY = $c.Key
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k], 'Process') }
    try {
        if ($Policy) {
            # A policy that blocks .ps1 files blocks the runner too, so load it as a script block.
            $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
            $cmd = "& ([scriptblock]::Create([IO.File]::ReadAllText($(& $q $runner)))) -Installer $(& $q $installer) -Fixture $(& $q $fixture) -Mode $Mode"
            if ($ScriptArgs) { $cmd += " -ScriptArgs $(& $q $ScriptArgs)" }
            $argList = @('-NoProfile', '-ExecutionPolicy', $Policy, '-Command', $cmd)
        } else {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-Installer', $installer, '-Fixture', $fixture, '-Mode', $Mode)
            if ($ScriptArgs) { $argList += '-ScriptArgs'; $argList += $ScriptArgs }
        }
        $c.Output = (& $Shell @argList 2>&1 | Out-String)
        $c.Code = $LASTEXITCODE
    } finally {
        foreach ($n in $caseEnv) { [Environment]::SetEnvironmentVariable($n, $savedEnv[$n], 'Process') }
    }
}

function Check([string]$What, [scriptblock]$Condition) {
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $ok = $false }
    if ($ok) {
        $script:pass++
    } else {
        $script:fail++
        $script:failed += "  - $($script:case.Name): $What"
        Write-Host "FAIL [$($script:case.Name)] $What" -ForegroundColor Red
        ($script:case.Output -split "`n") | ForEach-Object { Write-Host "    | $_" }
    }
}

function Has([string]$Text) { $script:case.Output.Contains($Text) }
function ExeVersion([string]$Exe) { @(& $Exe --version)[0] }
function UserPath { (Get-Item -LiteralPath $script:case.Key).GetValue('Path', '', 'DoNotExpandEnvironmentNames') }
function UserPathKind { (Get-Item -LiteralPath $script:case.Key).GetValueKind('Path') }
function Leftovers { @(Get-ChildItem -Force -LiteralPath $script:case.Bin | Where-Object { $_.Name -ne 'kurogane.exe' }).Count }
function Exe { Join-Path $script:case.Bin 'kurogane.exe' }

# ------------------------------------------------------------------ cases ---

try {
    New-Case 'fresh'
    Invoke-Installer
    Check 'exit 0' { $case.Code -eq 0 }
    Check 'installed latest' { (ExeVersion (Exe)) -eq "kurogane $LatestVersion" }
    Check 'summary' { (Has "Kurogane $LatestVersion installed") -and (Has 'kurogane new my-app') -and (Has 'kurogane dev') }
    Check 'verified' { Has 'Verified sha256' }
    Check 'user PATH has bin dir' { (UserPath) -eq $case.Bin }
    Check 'user PATH is REG_EXPAND_SZ' { (UserPathKind) -eq 'ExpandString' }
    Check "native artifact ($hostTriple)" { (Get-Content $case.Log) -match [regex]::Escape("$hostTriple.zip") }
    Check 'basic parsing' { -not ((Get-Content $case.Log) -match 'basic=False') }
    Check 'no leftovers' { (Leftovers) -eq 0 }

    Invoke-Installer
    Check 'reinstall exit 0' { $case.Code -eq 0 -and (Has 'reinstalled') }
    Check 'PATH entry once' { (UserPath) -eq $case.Bin }

    New-Case 'path-preserved'
    Set-ItemProperty -LiteralPath $case.Key -Name Path -Value '%USERPROFILE%\tools;C:\other' -Type ExpandString
    Invoke-Installer
    Check 'prepends and keeps %VARS% unexpanded' { (UserPath) -eq "$($case.Bin);%USERPROFILE%\tools;C:\other" }
    Check 'kind preserved' { (UserPathKind) -eq 'ExpandString' }

    New-Case 'path-trailing-slash'
    Set-ItemProperty -LiteralPath $case.Key -Name Path -Value "C:\a;$($case.Bin)\" -Type ExpandString
    Invoke-Installer
    Check 'existing entry with trailing \ is recognised' { (UserPath) -eq "C:\a;$($case.Bin)\" }

    New-Case 'upgrade'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '0.0.5' }
    Check 'pinned' { (ExeVersion (Exe)) -eq 'kurogane 0.0.5' }
    Invoke-Installer -Env @{ KUROGANE_VERSION = "v$LatestVersion" }
    Check 'upgraded' { $case.Code -eq 0 -and (ExeVersion (Exe)) -eq "kurogane $LatestVersion" -and (Has "updated 0.0.5 -> $LatestVersion") }

    New-Case 'upgrade-while-running'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '0.0.5' }
    $held = Start-Process -FilePath (Exe) -ArgumentList '--hold' -PassThru -WindowStyle Hidden
    try {
        Invoke-Installer
        Check 'upgrade succeeds while old exe runs' { $case.Code -eq 0 -and (ExeVersion (Exe)) -eq "kurogane $LatestVersion" }
    } finally {
        Stop-Process -Id $held.Id -Force -ErrorAction SilentlyContinue
        $held.WaitForExit()
    }
    Invoke-Installer
    Check 'next install clears the .old file' { (Leftovers) -eq 0 }

    New-Case 'bad-checksum'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '0.0.5' }
    Invoke-Installer -Env @{ KUROGANE_VERSION = '0.0.7' }
    Check 'fails' { $case.Code -ne 0 -and (Has 'checksum mismatch') }
    Check 'old install intact' { (ExeVersion (Exe)) -eq 'kurogane 0.0.5' -and (Leftovers) -eq 0 }

    foreach ($policy in '', 'Restricted') {
        New-Case "corrupt-archive$(if ($policy) { "-$policy" })"
        Invoke-Installer -Env @{ KUROGANE_VERSION = '0.0.5' }
        Invoke-Installer -Env @{ KUROGANE_VERSION = '0.1.1' } -Mode iex -Policy $policy
        Check 'fails' { $case.Code -ne 0 -and (Has 'archive is corrupt') }
        Check 'old install intact' { (ExeVersion (Exe)) -eq 'kurogane 0.0.5' -and (Leftovers) -eq 0 }
    }

    New-Case 'interrupted'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '0.0.5' }
    Invoke-Installer -Env @{ FAKE_TRUNCATE = '1' }
    Check 'fails' { $case.Code -ne 0 -and (Has 'download failed') }
    Check 'old install intact' { (ExeVersion (Exe)) -eq 'kurogane 0.0.5' -and (Leftovers) -eq 0 }

    New-Case 'not-runnable'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '0.0.8' }
    Check 'fails before installing' { $case.Code -ne 0 -and (Has 'does not run on this machine') -and -not (Test-Path (Exe)) }

    New-Case 'wrong-version'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '0.0.9' }
    Check 'fails' { $case.Code -ne 0 -and (Has 'asked for 0.0.9') -and -not (Test-Path (Exe)) }

    New-Case 'missing-version'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '4.0.0' }
    Check 'explains' { $case.Code -ne 0 -and (Has "is '4.0.0' a published version") }

    New-Case 'bad-version-string'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '1;calc' }
    Check 'rejected' { $case.Code -ne 0 -and (Has 'invalid version') }

    New-Case 'arm64'
    Invoke-Installer -Env @{ KUROGANE_ARCH = 'ARM64' }
    Check 'aarch64 artifact' { $case.Code -eq 0 -and ((Get-Content $case.Log) -match 'aarch64-pc-windows-msvc\.zip') }

    New-Case 'unsupported-arch'
    Invoke-Installer -Env @{ KUROGANE_ARCH = 'x86' }
    Check 'rejected' { $case.Code -ne 0 -and (Has 'unsupported CPU architecture: x86') -and -not (Get-Content $case.Log) }

    New-Case 'http-refused'
    Invoke-Installer -Env @{ KUROGANE_DOWNLOAD_URL = 'http://fixture.invalid/releases' }
    Check 'rejected' { $case.Code -ne 0 -and (Has 'must be an https:// URL') }

    New-Case 'no-modify-path'
    Invoke-Installer -Env @{ KUROGANE_NO_MODIFY_PATH = '1' }
    Check 'PATH untouched' { $case.Code -eq 0 -and -not ((Get-Item -LiteralPath $case.Key).GetValueNames() -contains 'Path') -and (Has 'not on your user PATH') }

    New-Case 'custom-dir'
    $custom = Join-Path $case.Dir 'my tools\bin'
    Invoke-Installer -Env @{ KUROGANE_INSTALL_DIR = $custom }
    Check 'installed with spaces in path' { $case.Code -eq 0 -and (ExeVersion (Join-Path $custom 'kurogane.exe')) -eq "kurogane $LatestVersion" -and (UserPath) -eq $custom }

    New-Case 'relative-dir'
    Invoke-Installer -Env @{ KUROGANE_INSTALL_DIR = 'rel\bin' }
    Check 'rejected' { $case.Code -ne 0 -and (Has 'must be an absolute path') }

    New-Case 'semicolon-dir'
    Invoke-Installer -Env @{ KUROGANE_INSTALL_DIR = 'C:\a;b' }
    Check 'rejected' { $case.Code -ne 0 -and (Has "must not contain ';'") }

    New-Case 'nested-zip'
    Invoke-Installer -Env @{ KUROGANE_VERSION = '0.1.0' }
    Check 'finds exe in subdirectory' { $case.Code -eq 0 -and (ExeVersion (Exe)) -eq 'kurogane 0.1.0' }

    New-Case 'github-path'
    $gh = Join-Path $case.Dir 'github_path'
    Set-Content -LiteralPath $gh -Value $null
    Invoke-Installer -Env @{ GITHUB_PATH = $gh }
    Check 'appended' { $case.Code -eq 0 -and ((Get-Content $gh) -contains $case.Bin) }

    # The documented form. A failure must return control to the caller
    # instead of exiting the host (which would close the user's window).
    New-Case 'iex'
    Invoke-Installer -Mode iex
    Check 'irm | iex form installs' { $case.Code -eq 0 -and (ExeVersion (Exe)) -eq "kurogane $LatestVersion" }
    New-Case 'iex-restricted'
    Invoke-Installer -Mode iex -Policy Restricted
    Check 'irm | iex installs under the default Restricted policy' { $case.Code -eq 0 -and (ExeVersion (Exe)) -eq "kurogane $LatestVersion" }
    New-Case 'iex-failure'
    Invoke-Installer -Mode iex -Env @{ KUROGANE_ARCH = 'x86' }
    Check 'failure returns to caller' { $case.Code -ne 0 -and (Has 'runner: installer threw') -and (Has 'Kurogane was not installed') }

    New-Case 'scriptblock-args'
    Invoke-Installer -Mode scriptblock -ScriptArgs 'Version=0.0.5'
    Check 'parameters work' { $case.Code -eq 0 -and (ExeVersion (Exe)) -eq 'kurogane 0.0.5' }
} finally {
    Remove-Item -LiteralPath $regRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "install.ps1 under ${Shell}: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -ne 0) {
    Write-Host "failed checks:`n$($script:failed -join "`n")"
    exit 1
}
