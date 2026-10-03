# Kurogane installer for Windows.
#
#   powershell -c "irm https://kurogane-rs.org/install.ps1|iex"
#
# Installs the prebuilt `kurogane` CLI into `%LOCALAPPDATA%\kurogane\bin` and
# adds it to the user PATH. Required dependencies are handled later by
# `kurogane`. Works with both Windows PowerShell 5.1 and PowerShell 7.
#
# `irm | iex` cannot pass arguments, so options come from the environment:
#   KUROGANE_VERSION         install a specific version (default: latest)
#   KUROGANE_INSTALL_DIR     install directory (default: %LOCALAPPDATA%\kurogane\bin)
#   KUROGANE_NO_MODIFY_PATH  set to 1 to leave PATH alone
#   KUROGANE_ARCH            x86_64 or aarch64, to override detection
#   KUROGANE_DOWNLOAD_URL    release mirror (https only)
# or as parameters when run as a script block:
#   & ([scriptblock]::Create((irm https://kurogane-rs.org/install.ps1))) -Version 0.0.6

param(
    [string]$Version = $env:KUROGANE_VERSION,
    [string]$InstallDir = $env:KUROGANE_INSTALL_DIR,
    [switch]$NoModifyPath,
    [string]$Arch = $env:KUROGANE_ARCH,
    [string]$DownloadUrl = $env:KUROGANE_DOWNLOAD_URL
)

function Install-Kurogane {
    param(
        [string]$Version,
        [string]$InstallDir,
        [bool]$NoModifyPath,
        [string]$Arch,
        [string]$DownloadUrl
    )

    $ErrorActionPreference = 'Stop'
    # The progress bar makes Invoke-WebRequest many times slower on 5.1.
    $ProgressPreference = 'SilentlyContinue'

    $repoUrl = 'https://github.com/0x48piraj/kurogane'
    $package = 'kurogane-cli'

    if (-not $Version) { $Version = 'latest' }
    $Version = $Version.TrimStart('v')
    if ($Version -ne 'latest' -and $Version -notmatch '^[0-9A-Za-z.+-]+$') {
        throw "invalid version: $Version"
    }
    if (-not $InstallDir) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; set KUROGANE_INSTALL_DIR' }
        $InstallDir = Join-Path $env:LOCALAPPDATA 'kurogane\bin'
    }
    if (-not [IO.Path]::IsPathRooted($InstallDir)) {
        throw "install directory must be an absolute path: $InstallDir"
    }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    if ($InstallDir.Contains(';')) { throw "install directory must not contain ';': $InstallDir" }

    $target = "$(Get-KuroganeArch $Arch)-pc-windows-msvc"

    if (-not $DownloadUrl) { $DownloadUrl = "$repoUrl/releases" }
    if (-not $DownloadUrl.StartsWith('https://')) {
        throw "KUROGANE_DOWNLOAD_URL must be an https:// URL: $DownloadUrl"
    }
    $DownloadUrl = $DownloadUrl.TrimEnd('/')
    if ($Version -eq 'latest') {
        $releaseUrl = "$DownloadUrl/latest/download"
        Write-Step "downloading the latest Kurogane for $target"
    } else {
        $releaseUrl = "$DownloadUrl/download/v$Version"
        Write-Step "downloading Kurogane $Version for $target"
    }
    $archive = "$package-$target.zip"

    # Windows PowerShell 5.1 may default to TLS 1.0; GitHub requires 1.2+.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kurogane-install-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $archivePath = Join-Path $tmp $archive
        $sumPath = "$archivePath.sha256"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$releaseUrl/$archive" -OutFile $archivePath
        } catch {
            throw "download failed: $releaseUrl/$archive`n  ($($_.Exception.Message))`n  is '$Version' a published version? releases: $repoUrl/releases"
        }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$releaseUrl/$archive.sha256" -OutFile $sumPath
        } catch {
            throw "download failed: $releaseUrl/$archive.sha256 ($($_.Exception.Message))"
        }

        $expected = ((Get-Content -LiteralPath $sumPath -TotalCount 1) -split '\s+')[0].ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'the published checksum file is malformed' }
        $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "checksum mismatch for $archive`n  expected $expected`n  got      $actual`n  The download is corrupt or was tampered with; nothing was installed."
        }
        Write-Step "verified sha256 $actual"

        $extracted = Join-Path $tmp 'x'
        try {
            Expand-Archive -LiteralPath $archivePath -DestinationPath $extracted
        } catch {
            throw 'the downloaded archive is corrupt'
        }
        $new = $null
        foreach ($candidate in @((Join-Path $extracted 'kurogane.exe'), (Join-Path $extracted "$package-$target\kurogane.exe"))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $new = $candidate; break }
        }
        if (-not $new) { throw 'the archive does not contain kurogane.exe' }

        # Prove the binary runs on this machine before touching the existing install.
        $newVersion = Get-KuroganeVersion $new
        if (-not $newVersion) { throw 'the downloaded kurogane.exe does not run on this machine' }
        if ($Version -ne 'latest' -and $newVersion -ne $Version) {
            throw "asked for $Version but the release contains $newVersion"
        }

        $dest = Join-Path $InstallDir 'kurogane.exe'
        $oldVersion = $null
        if (Test-Path -LiteralPath $dest -PathType Leaf) { $oldVersion = Get-KuroganeVersion $dest }

        Install-Binary $new $dest
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $pathNote = $null
    if (-not (Test-PathEntry $env:Path $InstallDir)) {
        # Make kurogane usable in this window right away, whatever happens below.
        $env:Path = "$InstallDir;$env:Path"
        if ($NoModifyPath) {
            $pathNote = 'skipped'
        } elseif (Add-UserPath $InstallDir) {
            $pathNote = 'configured'
        }
    }
    if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $InstallDir }

    Write-Host ''
    if (-not $oldVersion) {
        Write-Host "Kurogane $newVersion installed" -ForegroundColor Green -NoNewline
        Write-Host " to $dest"
    } elseif ($oldVersion -eq $newVersion) {
        Write-Host "Kurogane $newVersion reinstalled" -ForegroundColor Green -NoNewline
        Write-Host " at $dest"
    } else {
        Write-Host 'Kurogane updated' -ForegroundColor Green -NoNewline
        Write-Host " $oldVersion -> $newVersion at $dest"
    }

    $first = Get-Command kurogane -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($first -and $first.Source -ne $dest) {
        Write-Warn "'$($first.Source)' comes earlier on PATH and shadows this install;`n  remove it (e.g. 'cargo uninstall kurogane-cli') or reorder PATH"
    }
    if ($pathNote -eq 'configured') {
        Write-Host "Added $InstallDir to your user PATH (new terminals pick it up)."
    } elseif ($pathNote -eq 'skipped') {
        Write-Host "$InstallDir is not on your user PATH; add it to use kurogane in new terminals."
    }
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host "Kurogane builds apps with Rust; 'kurogane doctor' shows what else your machine needs."
    }
    Write-Host ''
    Write-Host 'Create your first app:'
    Write-Host '    kurogane new my-app'
    Write-Host '    cd my-app'
    Write-Host '    kurogane dev'
}

# Native machine architecture, not the architecture of this PowerShell
# process: x64 PowerShell under emulation on ARM64 still gets the ARM64 build.
function Get-KuroganeArch([string]$Override) {
    $raw = $Override
    if (-not $raw) {
        try {
            $raw = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
        } catch { $raw = $null }
    }
    if (-not $raw) { $raw = $env:PROCESSOR_ARCHITEW6432 }
    if (-not $raw) { $raw = $env:PROCESSOR_ARCHITECTURE }
    switch -regex ($raw) {
        '^(AMD64|x86_64|x64)$' { return 'x86_64' }
        '^(ARM64|aarch64)$' { return 'aarch64' }
        default { throw "unsupported CPU architecture: $raw (Kurogane ships x86_64 and aarch64 builds for Windows)" }
    }
}

function Get-KuroganeVersion([string]$Exe) {
    try {
        # Collect everything first: stopping the pipeline early (Select-Object
        # -First) kills the process and reports exit code -1.
        $out = @(& $Exe --version 2>$null)
    } catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0 -or $out.Count -lt 1 -or "$($out[0])" -notmatch '^kurogane (\S+)$') { return $null }
    return $Matches[1]
}

# Replaces $Dest with $Source. A running kurogane.exe cannot be overwritten
# but can be renamed, so the old binary is moved aside first and restored if
# the new one cannot be put in place.
function Install-Binary([string]$Source, [string]$Dest) {
    $dir = Split-Path -Parent $Dest
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $staged = Join-Path $dir ".kurogane.new.$PID.exe"
    $old = "$Dest.old"
    Copy-Item -LiteralPath $Source -Destination $staged -Force
    try {
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        $hadOld = Test-Path -LiteralPath $Dest
        if ($hadOld) { Move-Item -LiteralPath $Dest -Destination $old -Force }
        try {
            Move-Item -LiteralPath $staged -Destination $Dest -Force
        } catch {
            if ($hadOld) { Move-Item -LiteralPath $old -Destination $Dest -Force }
            throw "cannot replace ${Dest}: $($_.Exception.Message)"
        }
        # Still locked if the old kurogane is running; the next install retries.
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    } finally {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
    }
}

function Test-PathEntry([string]$PathValue, [string]$Dir) {
    foreach ($entry in ("$PathValue" -split ';')) {
        if ($entry -and $entry.TrimEnd('\') -ieq $Dir) { return $true }
    }
    return $false
}

# Prepends $Dir to the user PATH in the registry, preserving REG_EXPAND_SZ
# and unexpanded %VARIABLES% in existing entries, then tells running programs
# (Explorer, new terminals) that the environment changed.
function Add-UserPath([string]$Dir) {
    $keyPath = 'HKCU:\Environment'
    if ($env:KUROGANE_TEST_ENV_KEY) { $keyPath = $env:KUROGANE_TEST_ENV_KEY }
    $key = Get-Item -LiteralPath $keyPath
    $kind = 'ExpandString'
    $current = ''
    if ($key.GetValueNames() -contains 'Path') {
        $kind = $key.GetValueKind('Path')
        if ($kind -ne 'String' -and $kind -ne 'ExpandString') {
            Write-Warn "the user PATH is not a string value ($kind); add $Dir to PATH yourself"
            return $false
        }
        $current = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    }
    if (Test-PathEntry $current $Dir) { return $true }
    $updated = if ($current) { "$Dir;$current" } else { $Dir }
    Set-ItemProperty -LiteralPath $keyPath -Name Path -Value $updated -Type ExpandString
    if (-not $env:KUROGANE_TEST_ENV_KEY) {
        # Setting any user variable through .NET broadcasts WM_SETTINGCHANGE.
        $dummy = 'KUROGANE_INSTALLER_' + [Guid]::NewGuid().ToString('N')
        [Environment]::SetEnvironmentVariable($dummy, '1', 'User')
        [Environment]::SetEnvironmentVariable($dummy, $null, 'User')
    }
    return $true
}

function Write-Step([string]$Message) {
    Write-Host "kurogane-install: $Message"
}

function Write-Warn([string]$Message) {
    Write-Host "kurogane-install: warning: $Message" -ForegroundColor Yellow
}

try {
    Install-Kurogane -Version $Version -InstallDir $InstallDir -NoModifyPath ($NoModifyPath -or ($env:KUROGANE_NO_MODIFY_PATH -and $env:KUROGANE_NO_MODIFY_PATH -notin @('0', 'false'))) -Arch $Arch -DownloadUrl $DownloadUrl
} catch {
    Write-Host "kurogane-install: error: $($_.Exception.Message)" -ForegroundColor Red
    # Never `exit`: under `irm | iex` that would close the user's window.
    throw 'Kurogane was not installed.'
}
