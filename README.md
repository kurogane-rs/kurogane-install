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

### Local tests

**Shell**

```sh
TEST_SHELL=dash sh tests/install_sh_test.sh
```

**PowerShell**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\install_ps1_test.ps1
```
