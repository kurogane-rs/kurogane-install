#!/bin/sh
# Kurogane installer for macOS and Linux.
#
#   curl --proto '=https' --tlsv1.2 -LsSf https://kurogane-rs.org/install.sh | sh
#
# Installs the prebuilt `kurogane` CLI into a per-user directory and adds it
# to PATH. Dependencies such as Rust, Chromium, and platform toolchains are
# installed or configured later by `kurogane` itself.
#
# The script only defines functions; `main` runs on the very last line, so a
# truncated download executes nothing.
#
# Options (after `sh -s --` when piped):
#   --version <v>        install a specific version (default: latest)
#   --install-dir <dir>  install the binary into <dir> (default: ~/.kurogane/bin)
#   --no-modify-path     do not touch shell startup files
#   --force-generic      install the generic Linux binary on NixOS anyway
#   -q, --quiet          only print errors and the final summary
#   -y, --yes            accepted for compatibility; the installer never prompts
#   -h, --help           show this help
#
# Environment: KUROGANE_VERSION, KUROGANE_INSTALL_DIR, KUROGANE_HOME,
# KUROGANE_NO_MODIFY_PATH=1, KUROGANE_DOWNLOAD_URL (release mirror, https only).

set -u

KUROGANE_REPO_URL="https://github.com/0x48piraj/kurogane"
KUROGANE_FLAKE="github:0x48piraj/kurogane"
KUROGANE_PACKAGE="kurogane-cli"

usage() {
    cat <<'EOF'
kurogane-install: install the Kurogane CLI

USAGE:
    curl --proto '=https' --tlsv1.2 -LsSf https://kurogane-rs.org/install.sh | sh -s -- [OPTIONS]

OPTIONS:
    --version <v>        install a specific version (default: latest)
    --install-dir <dir>  install the binary into <dir> (default: ~/.kurogane/bin)
    --no-modify-path     do not touch shell startup files
    --force-generic      install the generic Linux binary on NixOS anyway
    -q, --quiet          only print errors and the final summary
    -y, --yes            accepted for compatibility; the installer never prompts
    -h, --help           show this help

ENVIRONMENT:
    KUROGANE_VERSION, KUROGANE_INSTALL_DIR, KUROGANE_HOME,
    KUROGANE_NO_MODIFY_PATH=1, KUROGANE_DOWNLOAD_URL
EOF
}

main() {
    _version="${KUROGANE_VERSION:-latest}"
    _home="${KUROGANE_HOME:-${HOME:-}/.kurogane}"
    _bin_dir="${KUROGANE_INSTALL_DIR:-}"
    _modify_path=yes
    _force_generic=no
    _quiet=no

    case "${KUROGANE_NO_MODIFY_PATH:-}" in
        '' | 0 | false) ;;
        *) _modify_path=no ;;
    esac

    while [ $# -gt 0 ]; do
        case "$1" in
            --version)
                [ $# -ge 2 ] || die "--version needs a value"
                _version="$2"
                shift
                ;;
            --version=*) _version="${1#--version=}" ;;
            --install-dir)
                [ $# -ge 2 ] || die "--install-dir needs a value"
                _bin_dir="$2"
                shift
                ;;
            --install-dir=*) _bin_dir="${1#--install-dir=}" ;;
            --no-modify-path) _modify_path=no ;;
            --force-generic) _force_generic=yes ;;
            -q | --quiet) _quiet=yes ;;
            -y | --yes) ;;
            -h | --help)
                usage
                return 0
                ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    [ -n "${HOME:-}" ] || [ -n "${KUROGANE_HOME:-}" ] || die "HOME is not set; set KUROGANE_HOME or HOME"
    [ -n "$_bin_dir" ] || _bin_dir="$_home/bin"
    case "$_bin_dir" in
        /*) ;;
        *) die "install directory must be an absolute path: $_bin_dir" ;;
    esac
    check_safe_path "$_bin_dir"
    check_safe_path "$_home"

    _version="${_version#v}"
    case "$_version" in
        latest) ;;
        *[!0-9A-Za-z.+-]* | '') die "invalid version: $_version" ;;
    esac

    need_cmd uname
    need_cmd mktemp
    need_cmd tar
    need_cmd chmod
    need_cmd mkdir
    need_cmd mv
    need_cmd cp
    need_cmd rm

    detect_target || return 1
    _target="$RETVAL"

    _base_url="${KUROGANE_DOWNLOAD_URL:-$KUROGANE_REPO_URL/releases}"
    case "$_base_url" in
        https://*) ;;
        *) die "KUROGANE_DOWNLOAD_URL must be an https:// URL: $_base_url" ;;
    esac
    _base_url="${_base_url%/}"
    if [ "$_version" = latest ]; then
        _release_url="$_base_url/latest/download"
    else
        _release_url="$_base_url/download/v$_version"
    fi
    _archive="$KUROGANE_PACKAGE-$_target.tar.gz"

    _tmp="$(mktemp -d 2>/dev/null || mktemp -d -t kurogane)" || die "cannot create a temporary directory"
    [ -d "$_tmp" ] || die "cannot create a temporary directory"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [ "$_version" = latest ]; then
        say "downloading the latest Kurogane for $_target"
    else
        say "downloading Kurogane $_version for $_target"
    fi
    download "$_release_url/$_archive" "$_tmp/$_archive" ||
        die "download failed: $_release_url/$_archive
  (is '$_version' a published version? releases: $KUROGANE_REPO_URL/releases)"
    download "$_release_url/$_archive.sha256" "$_tmp/$_archive.sha256" ||
        die "download failed: $_release_url/$_archive.sha256"

    verify_sha256 "$_tmp/$_archive" "$_tmp/$_archive.sha256" || return 1

    mkdir "$_tmp/x" || die "cannot create extraction directory"
    tar -xzf "$_tmp/$_archive" -C "$_tmp/x" 2>/dev/null || die "the downloaded archive is corrupt"

    _new=""
    for _cand in "$_tmp/x/$KUROGANE_PACKAGE-$_target/kurogane" "$_tmp/x/kurogane"; do
        if [ -f "$_cand" ] && [ ! -L "$_cand" ]; then
            _new="$_cand"
            break
        fi
    done
    [ -n "$_new" ] || die "the archive does not contain a kurogane binary"
    chmod 755 "$_new"

    # Prove the binary runs on this machine before touching the existing install.
    _new_version="$("$_new" --version 2>/dev/null)" || die "the downloaded kurogane does not run on this machine
  (is the temporary directory '$_tmp' mounted noexec? set TMPDIR to another directory)"
    case "$_new_version" in
        kurogane\ *) _new_version="${_new_version#kurogane }" ;;
        *) die "the downloaded binary did not identify itself as kurogane" ;;
    esac
    if [ "$_version" != latest ] && [ "$_new_version" != "$_version" ]; then
        die "asked for $_version but the release contains $_new_version"
    fi

    _dest="$_bin_dir/kurogane"
    _old_version=""
    if [ -x "$_dest" ]; then
        _old_version="$("$_dest" --version 2>/dev/null)" || _old_version=""
        _old_version="${_old_version#kurogane }"
    fi

    mkdir -p "$_bin_dir" || die "cannot create $_bin_dir"
    _staged="$_bin_dir/.kurogane.new.$$"
    if ! cp "$_new" "$_staged" || ! chmod 755 "$_staged"; then
        rm -f "$_staged"
        die "cannot write to $_bin_dir"
    fi
    if ! mv -f "$_staged" "$_dest"; then
        rm -f "$_staged"
        die "cannot replace $_dest"
    fi

    _path_note=""
    if on_path "$_bin_dir"; then
        :
    elif [ "$_modify_path" = yes ]; then
        setup_path "$_home" "$_bin_dir"
        _path_note=configured
    else
        _path_note=skipped
    fi
    if [ -n "${GITHUB_PATH:-}" ] && [ -w "${GITHUB_PATH}" ]; then
        printf '%s\n' "$_bin_dir" >>"$GITHUB_PATH"
    fi

    summary
}

cleanup() {
    if [ -n "${_tmp:-}" ]; then
        rm -rf "$_tmp"
    fi
}

# Writes the summary of what happened and the next command to run.
summary() {
    printf '\n' >&2
    if [ -z "$_old_version" ]; then
        printf '%s\n' "$(bold "Kurogane $_new_version installed") to $_dest" >&2
    elif [ "$_old_version" = "$_new_version" ]; then
        printf '%s\n' "$(bold "Kurogane $_new_version reinstalled") at $_dest" >&2
    else
        printf '%s\n' "$(bold "Kurogane updated") $_old_version -> $_new_version at $_dest" >&2
    fi

    _shadow="$(command -v kurogane 2>/dev/null || true)"
    if [ -n "$_shadow" ] && [ "$_shadow" != "$_dest" ] && on_path "$_bin_dir"; then
        warn "'$_shadow' comes earlier on PATH and shadows this install;
  remove it (e.g. 'cargo uninstall kurogane-cli') or reorder PATH"
    fi

    case "$_path_note" in
        configured)
            printf '\n%s\n    . "%s/env"\n' "To use kurogane in this shell, run:" "$_home" >&2
            printf '%s\n' "(new shells pick it up automatically)" >&2
            ;;
        skipped)
            printf '\n%s\n    %s\n' "$_bin_dir is not on PATH. Add it yourself, e.g.:" "export PATH=\"$_bin_dir:\$PATH\"" >&2
            ;;
    esac

    if ! command -v cargo >/dev/null 2>&1 && [ ! -x "${CARGO_HOME:-${HOME:-}/.cargo}/bin/cargo" ]; then
        printf '\n%s\n' "Kurogane builds apps with Rust; 'kurogane doctor' shows what else your machine needs." >&2
    fi

    printf '\n%s\n    %s\n    %s\n    %s\n' "Create your first app:" "kurogane new my-app" "cd my-app" "kurogane dev" >&2
}

# Sets RETVAL to the release target triple for this machine, or explains why
# this machine should not use the generic installer.
detect_target() {
    _os="$(uname -s)"
    _arch="$(uname -m)"

    case "$_os" in
        Linux)
            if [ "$(uname -o 2>/dev/null || true)" = Android ]; then
                die "Android is not supported"
            fi
            if is_nixos && [ "$_force_generic" = no ]; then
                err "this is NixOS: prebuilt binaries and the Chromium runtime need Nix packaging here.
  Install Kurogane through its flake instead:

      nix profile add $KUROGANE_FLAKE

  (older Nix: 'nix profile install'; try it once: 'nix run $KUROGANE_FLAKE -- --help').
  Use --force-generic to install the generic binary anyway."
                return 1
            fi
            _os_part=unknown-linux-musl
            ;;
        Darwin)
            _os_part=apple-darwin
            # A shell running under Rosetta 2 reports x86_64; prefer the native build.
            if [ "$_arch" = x86_64 ] && sysctl hw.optional.arm64 2>/dev/null | grep -q ': 1'; then
                _arch=arm64
            fi
            ;;
        MINGW* | MSYS* | CYGWIN* | Windows_NT)
            die "on Windows, install with:
      powershell -c \"irm https://kurogane-rs.org/install.ps1|iex\""
            ;;
        *) die "unsupported operating system: $_os (Kurogane supports Linux, macOS and Windows)" ;;
    esac

    # The Linux binaries are static, so a 32-bit userland on a 64-bit kernel
    # still runs them; only the kernel architecture matters.
    case "$_arch" in
        x86_64 | amd64) _arch=x86_64 ;;
        aarch64 | arm64) _arch=aarch64 ;;
        *) die "unsupported CPU architecture: $_arch on $_os
  (Kurogane ships x86_64 and aarch64 binaries; see $KUROGANE_REPO_URL#install)" ;;
    esac

    if [ "$_os" = Linux ]; then
        if [ "$_force_generic" = no ] && has_nix; then
            say "Nix detected: '$KUROGANE_FLAKE' is also available as a Nix package"
        fi
        if ldd --version 2>&1 | grep -q musl; then
            warn "this system uses musl libc; the kurogane CLI runs, but the Chromium runtime it
  downloads needs glibc, so apps cannot run here"
        fi
    fi

    RETVAL="$_arch-$_os_part"
}

is_nixos() {
    _root="${KUROGANE_TEST_SYSROOT:-}"
    [ -e "$_root/etc/NIXOS" ] && return 0
    [ -r "$_root/etc/os-release" ] && grep -Eq '^ID="?nixos"?$' "$_root/etc/os-release"
}

has_nix() {
    command -v nix >/dev/null 2>&1 || [ -d "${KUROGANE_TEST_SYSROOT:-}/nix/store" ]
}

# download <url> <file>: HTTPS-only, TLS 1.2+, follows redirects, fails on
# HTTP errors. The destination is only ever inside the private temp dir.
download() {
    # Snap-confined curl cannot write to the temp dir; prefer wget then.
    _curl="$(command -v curl 2>/dev/null || true)"
    case "$_curl" in
        */snap/*) check_cmd wget && _curl="" ;;
    esac
    if [ -n "$_curl" ]; then
        curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
            --retry 3 --output "$2" "$1"
    elif check_cmd wget; then
        if wget --help 2>&1 | grep -q -- '--https-only'; then
            wget --https-only --secure-protocol=TLSv1_2 --quiet --output-document="$2" "$1"
        else
            # BusyBox wget has no protocol flags; the URL itself is https-only.
            wget -q -O "$2" "$1"
        fi
    else
        die "need 'curl' or 'wget' to download Kurogane"
    fi
}

# verify_sha256 <file> <checksum-file>: fails closed when no hashing tool exists.
verify_sha256() {
    _expected="$(awk 'NR == 1 { print tolower($1) }' "$2")"
    case "$_expected" in
        *[!0-9a-f]* | '') die "the published checksum file is malformed" ;;
    esac
    [ ${#_expected} -eq 64 ] || die "the published checksum file is malformed"

    if check_cmd sha256sum; then
        _actual="$(sha256sum "$1" | awk '{ print tolower($1) }')"
    elif check_cmd shasum; then
        _actual="$(shasum -a 256 "$1" | awk '{ print tolower($1) }')"
    elif check_cmd openssl; then
        _actual="$(openssl dgst -sha256 "$1" | awk '{ print tolower($NF) }')"
    else
        die "need 'sha256sum', 'shasum' or 'openssl' to verify the download"
    fi

    if [ "$_actual" != "$_expected" ]; then
        err "checksum mismatch for $(basename "$1")
  expected $_expected
  got      $_actual
  The download is corrupt or was tampered with; nothing was installed."
        return 1
    fi
    say "verified sha256 $_actual"
}

on_path() {
    case ":${PATH:-}:" in
        *:"$1":* | *:"$1/":*) return 0 ;;
        *) return 1 ;;
    esac
}

# setup_path <home> <bin_dir>: writes <home>/env and sources it from the
# startup files of every shell present. Idempotent.
setup_path() {
    mkdir -p "$1" || die "cannot create $1"
    _env="$1/env"
    cat >"$_env" <<EOF
# Added by the Kurogane installer: puts kurogane on PATH.
case ":\${PATH}:" in
    *:"$2":*) ;;
    *) export PATH="$2:\$PATH" ;;
esac
EOF
    _line=". \"$_env\""

    add_line "$HOME/.profile" "$_line" create
    for _rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login"; do
        [ -f "$_rc" ] && add_line "$_rc" "$_line"
    done
    if check_cmd zsh || case "${SHELL:-}" in *zsh) true ;; *) false ;; esac; then
        add_line "${ZDOTDIR:-$HOME}/.zshenv" "$_line" create
    fi
    _fish="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
    if check_cmd fish || [ -d "$_fish" ]; then
        mkdir -p "$_fish/conf.d" &&
            cat >"$_fish/conf.d/kurogane.fish" <<EOF
# Added by the Kurogane installer: puts kurogane on PATH.
if not contains "$2" \$PATH
    set -gx PATH "$2" \$PATH
end
EOF
    fi
}

# add_line <file> <line> [create]: appends <line> unless already present.
add_line() {
    if [ ! -f "$1" ]; then
        [ "${3:-}" = create ] || return 0
        : >"$1" || return 0
    fi
    grep -qxF "$2" "$1" 2>/dev/null && return 0
    if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
        printf '\n' >>"$1"
    fi
    printf '%s\n' "$2" >>"$1"
    say "added kurogane to PATH in $1"
}

# Paths end up inside generated shell code, so refuse characters that would
# need escaping there.
check_safe_path() {
    _nl='
'
    case "$1" in
        *[\"\`\$\\]* | *"$_nl"*) die "unsupported characters in path: $1" ;;
    esac
}

bold() {
    if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
        printf '\033[1m%s\033[0m' "$1"
    else
        printf '%s' "$1"
    fi
}

say() {
    [ "${_quiet:-no}" = yes ] || printf 'kurogane-install: %s\n' "$1" >&2
}

warn() {
    printf 'kurogane-install: warning: %s\n' "$1" >&2
}

err() {
    printf 'kurogane-install: error: %s\n' "$1" >&2
}

die() {
    err "$1"
    exit 1
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_cmd() {
    check_cmd "$1" || die "need '$1' (command not found)"
}

main "$@" || exit 1
