# kurogane-install

Installers and release pipeline with hermetic tests, multi-target builds, artifact attestations and automated GitHub Releases for the Kurogane CLI, kept outside the [core repository](https://github.com/0x48piraj/kurogane).

### Linux / macOS

```bash
curl --proto '=https' --tlsv1.2 -LsSf https://kurogane-rs.org/install.sh | sh
```

### Windows

```powershell
powershell -c "irm https://kurogane-rs.org/install.ps1|iex"
```

## How it works

The installers are hosted at [kurogane-rs.org](https://www.kurogane-rs.org/) and point to the latest Kurogane release.

### Installation

**Linux / macOS**

```bash
curl --proto '=https' --tlsv1.2 -LsSf https://kurogane-rs.org/install.sh | sh
```

**Windows**

```powershell
powershell -c "irm https://kurogane-rs.org/install.ps1|iex"
```

Stable releases become the latest release automatically.

### Uninstalling

```bash
kurogane self uninstall
```

Every install writes a receipt, `~/.kurogane/receipt.json` (or `$KUROGANE_HOME/receipt.json`) on Linux and macOS and `%LOCALAPPDATA%\kurogane\receipt.json` on Windows. It records the binary and the files and PATH entry the installer manages. The CLI reads it to know what is the installer's to remove, so its format is a contract between this repository and the CLI: `"schema": 1`, raised only for a change an older CLI would misread.

### Local tests

**Shell**

```sh
TEST_SHELL=dash sh tests/install_sh_test.sh
```

**PowerShell**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\install_ps1_test.ps1
```

**Round trip with a real CLI** (install it, then `kurogane self uninstall`; the shell version runs on Linux only)

```sh
KUROGANE_BIN=/path/to/kurogane sh tests/install_sh_test.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\install_ps1_test.ps1 -Kurogane C:\path\to\kurogane.exe
```
