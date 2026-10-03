# Runs install.ps1 once, in this (fresh) process, with downloads served
# from a local fixture tree. Used by tests/install_ps1_test.ps1.
#
# Invoke-WebRequest is replaced by a function of the same name: PowerShell
# resolves functions before cmdlets, so the installer's real download,
# verify and install code runs unchanged against `https://fixture.invalid/`.
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$Fixture,
    [ValidateSet('script', 'iex', 'scriptblock')][string]$Mode = 'script',
    # Installer parameters as "Name=value,Name2=value2".
    [string]$ScriptArgs = ''
)

$params = @{}
foreach ($pair in ($ScriptArgs -split ',' | Where-Object { $_ })) {
    $name, $value = $pair -split '=', 2
    $params[$name] = $value
}

$global:KuroganeFixture = $Fixture

function global:Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    Add-Content -LiteralPath $env:DL_LOG -Value "GET $Uri basic=$UseBasicParsing"
    if (-not $Uri.StartsWith('https://fixture.invalid/')) { throw "stub: refusing $Uri" }
    $src = Join-Path $global:KuroganeFixture ($Uri.Substring('https://fixture.invalid/'.Length) -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw 'The remote server returned an error: (404) Not Found.' }
    if ($env:FAKE_TRUNCATE) {
        $bytes = [IO.File]::ReadAllBytes($src)
        [IO.File]::WriteAllBytes($OutFile, $bytes[0..([Math]::Min(99, $bytes.Length - 1))])
        throw 'The underlying connection was closed: An unexpected error occurred on a receive.'
    }
    Copy-Item -LiteralPath $src -Destination $OutFile
}

try {
    switch ($Mode) {
        'script' { & $Installer @params }
        'iex' { Get-Content -Raw -LiteralPath $Installer | Invoke-Expression }
        'scriptblock' { & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $Installer))) @params }
    }
} catch {
    Write-Host "runner: installer threw: $($_.Exception.Message)"
    exit 1
}
exit 0
