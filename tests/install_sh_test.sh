#!/bin/sh
# Hermetic tests for install.sh.
#
#   sh tests/install_sh_test.sh            # run the installer under sh
#   TEST_SHELL=dash sh tests/install_sh_test.sh
#
# Every case runs the real installer with `env -i` and a PATH made only of
# stubs (curl, wget, uname, sysctl, ...) and wrappers around the real tools the
# installer is allowed to use. Downloads resolve `https://fixture.invalid/...`
# into a local fixture release tree, so the download/verify/install code paths
# are exercised exactly as in production, without network.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
TEST_SHELL="${TEST_SHELL:-sh}"
TEST_SHELL_PATH="$(command -v "$TEST_SHELL")" || {
    echo "no such shell: $TEST_SHELL" >&2
    exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixture"
PASS=0
FAIL=0
FAILED=""

# ---------------------------------------------------------------- fixtures --

# make_release <version> <triple> [binary-body]
make_release() {
    _v="$1"
    _t="$2"
    _stage="$WORK/stage/$_v/$_t/kurogane-cli-$_t"
    mkdir -p "$_stage"
    printf '#!/bin/sh\n%s\n' "${3:-echo \"kurogane $_v\"}" >"$_stage/kurogane"
    chmod 755 "$_stage/kurogane"
    _out="$FIX/releases/download/v$_v"
    mkdir -p "$_out"
    (cd "$WORK/stage/$_v/$_t" && tar -czf "$_out/kurogane-cli-$_t.tar.gz" "kurogane-cli-$_t")
    (cd "$_out" && sha256 "kurogane-cli-$_t.tar.gz" >"kurogane-cli-$_t.tar.gz.sha256")
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s *%s\n' "$(sha256sum "$1" | awk '{print $1}')" "$1"
    else
        printf '%s *%s\n' "$(shasum -a 256 "$1" | awk '{print $1}')" "$1"
    fi
}

# The version the fixture's "latest" release reports.
LATEST=0.0.6
TRIPLES="x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-apple-darwin aarch64-apple-darwin"
for t in $TRIPLES; do
    make_release 0.0.5 "$t"
    make_release $LATEST "$t"
done
# "latest" points at $LATEST, like GitHub's /releases/latest/download redirect.
mkdir -p "$FIX/releases/latest"
cp -R "$FIX/releases/download/v$LATEST" "$FIX/releases/latest/download"

# 0.0.7: checksum file does not match the archive.
make_release 0.0.7 x86_64-unknown-linux-musl
printf '%064d *kurogane-cli-x86_64-unknown-linux-musl.tar.gz\n' 0 \
    >"$FIX/releases/download/v0.0.7/kurogane-cli-x86_64-unknown-linux-musl.tar.gz.sha256"
# 0.0.8: binary cannot run on this machine.
make_release 0.0.8 x86_64-unknown-linux-musl 'exit 126'
# 0.0.9: the tag says 0.0.9 but the binary reports something else.
make_release 0.0.9 x86_64-unknown-linux-musl 'echo "kurogane 1.2.3"'

# ------------------------------------------------------------------ stubs ---

TOOLS="$WORK/tools"
STUBS="$WORK/stubs"
mkdir -p "$TOOLS" "$STUBS"

# Wrap the real tools the installer may use, so PATH can exclude everything else.
for tool in mktemp tar gzip chmod mkdir mv cp rm awk grep cat tail head basename \
    sha256sum shasum openssl ldd tr sed sort wc dirname; do
    real="$(command -v "$tool" 2>/dev/null)" || continue
    printf '#!%s\nexec "%s" "$@"\n' "$TEST_SHELL_PATH" "$real" >"$TOOLS/$tool"
    chmod 755 "$TOOLS/$tool"
done

cat >"$STUBS/uname" <<EOF
#!$TEST_SHELL_PATH
case "\$1" in
    -s) echo "\${FAKE_UNAME_S:-Linux}" ;;
    -m) echo "\${FAKE_UNAME_M:-x86_64}" ;;
    -o) echo "\${FAKE_UNAME_O:-GNU/Linux}" ;;
    *) echo "\${FAKE_UNAME_S:-Linux}" ;;
esac
EOF

cat >"$STUBS/sysctl" <<EOF
#!$TEST_SHELL_PATH
[ -n "\${FAKE_ARM64:-}" ] && echo "hw.optional.arm64: \$FAKE_ARM64"
EOF

# Fake downloaders: map https://fixture.invalid/<path> -> \$FIX/<path>, log the
# invocation, and support a simulated interrupted transfer.
cat >"$STUBS/curl" <<EOF
#!$TEST_SHELL_PATH
echo "curl \$*" >>"\$DL_LOG"
out=""
url=""
proto=no
while [ \$# -gt 0 ]; do
    case "\$1" in
        --output) out="\$2"; shift ;;
        --proto) [ "\$2" = "=https" ] && proto=yes; shift ;;
        -*) ;;
        *) url="\$1" ;;
    esac
    shift
done
[ \$proto = yes ] || { echo "curl stub: missing --proto =https" >&2; exit 1; }
case "\$url" in https://fixture.invalid/*) ;; *) exit 6 ;; esac
src="$FIX/\${url#https://fixture.invalid/}"
[ -f "\$src" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
if [ -n "\${FAKE_TRUNCATE:-}" ]; then
    head -c 100 "\$src" >"\$out"
    echo "curl: (18) transfer closed with outstanding read data remaining" >&2
    exit 18
fi
cat "\$src" >"\$out"
EOF

cat >"$WORK/wget" <<EOF
#!$TEST_SHELL_PATH
[ "\$1" = --help ] && { echo "  --https-only   only follow secure HTTPS links"; exit 0; }
echo "wget \$*" >>"\$DL_LOG"
out=""
url=""
https=no
for a in "\$@"; do
    case "\$a" in
        --output-document=*) out="\${a#--output-document=}" ;;
        --https-only) https=yes ;;
        -*) ;;
        *) url="\$a" ;;
    esac
done
[ \$https = yes ] || exit 1
src="$FIX/\${url#https://fixture.invalid/}"
[ -f "\$src" ] || exit 8
cat "\$src" >"\$out"
EOF
chmod 755 "$STUBS"/* "$WORK/wget"

WGET_DIR="$WORK/wget-dir"
mkdir -p "$WGET_DIR"
cp "$WORK/wget" "$WGET_DIR/wget"
NOCURL="$WORK/stubs-nocurl"
mkdir -p "$NOCURL"
cp "$STUBS/uname" "$STUBS/sysctl" "$NOCURL/"

# Tool set without any sha256 implementation.
NOSHA="$WORK/tools-nosha"
mkdir -p "$NOSHA"
for f in "$TOOLS"/*; do
    case "$(basename "$f")" in sha256sum | shasum | openssl) ;; *) cp "$f" "$NOSHA/" ;; esac
done

# ----------------------------------------------------------------- runner ---

# new_case: fresh HOME and temp dir; sets CASE, H, OUT
new_case() {
    CASE="$WORK/case.$1"
    H="$CASE/home"
    mkdir -p "$H" "$CASE/tmp"
    OUT="$CASE/out"
    : >"$CASE/dl.log"
}

# run_installer [VAR=value ...] -- [installer args]
# Runs with stdin from /dev/null (non-interactive). Sets RC.
run_installer() {
    _path="$STUBS:$TOOLS"
    _envs=""
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        case "$1" in
            PATH=*) _path="${1#PATH=}" ;;
            *) _envs="$_envs $1" ;;
        esac
        shift
    done
    [ $# -gt 0 ] && shift
    # shellcheck disable=SC2086 # _envs is a list of VAR=value words without spaces
    env -i HOME="$H" TMPDIR="$CASE/tmp" PATH="$_path" DL_LOG="$CASE/dl.log" \
        KUROGANE_DOWNLOAD_URL=https://fixture.invalid/releases $_envs \
        "$TEST_SHELL_PATH" "$INSTALLER" "$@" </dev/null >"$OUT" 2>&1
    RC=$?
}

check() {
    if eval "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED="$FAILED
  - $1: $2"
        echo "FAIL [$1] $2 (installer exit status $RC)" >&2
        sed 's/^/    | /' "$OUT" >&2
    fi
}

has() { grep -qF -- "$1" "$OUT"; }
count() { grep -cxF -- "$2" "$1" 2>/dev/null || true; }
BIN() { echo "$H/.kurogane/bin/kurogane"; }
SRC_LINE() { echo ". \"$H/.kurogane/env\""; }
tmp_empty() { [ -z "$(ls -A "$CASE/tmp")" ]; }

# ------------------------------------------------------------------ cases ---

new_case fresh
run_installer --
check fresh '[ $RC -eq 0 ]'
check fresh '[ "$("$(BIN)" --version)" = "kurogane $LATEST" ]'
check fresh 'has "Kurogane $LATEST installed"'
check fresh 'has "kurogane new my-app"'
check fresh 'has "kurogane dev"'
check fresh 'has "verified sha256"'
check fresh '[ -f "$H/.kurogane/env" ]'
check fresh '[ "$(count "$H/.profile" "$(SRC_LINE)")" = 1 ]'
check fresh 'tmp_empty'
check fresh 'grep -q "x86_64-unknown-linux-musl.tar.gz" "$CASE/dl.log"'
check fresh 'grep -q -- "--tlsv1.2" "$CASE/dl.log"'
check fresh '[ -z "$(ls -A "$H/.kurogane/bin" | grep -v "^kurogane$")" ]'

# The generated env script really puts kurogane on PATH. (Not `command -v`:
# ksh93 quotes paths with spaces, see find_cmd in install.sh.)
check env-script '[ "$(env -i HOME="$H" PATH=/usr/bin:/bin "$TEST_SHELL_PATH" -c ". \"$H/.kurogane/env\"; kurogane --version")" = "kurogane $LATEST" ]'
check env-script '[ "$(env -i HOME="$H" PATH=/usr/bin:/bin "$TEST_SHELL_PATH" -c ". \"$H/.kurogane/env\"; . \"$H/.kurogane/env\"; echo \"\$PATH\"" | tr : "\n" | grep -cxF "$H/.kurogane/bin")" = 1 ]'

# Running again changes nothing but the binary.
printf 'export FOO=1' >>"$H/.bashrc" # no trailing newline
run_installer --
check reinstall '[ $RC -eq 0 ]'
check reinstall 'has "reinstalled"'
check reinstall '[ "$(count "$H/.profile" "$(SRC_LINE)")" = 1 ]'
check reinstall '[ "$(count "$H/.bashrc" "$(SRC_LINE)")" = 1 ]'
check reinstall '[ "$(count "$H/.bashrc" "export FOO=1")" = 1 ]'
run_installer --
check reinstall-twice '[ "$(count "$H/.bashrc" "$(SRC_LINE)")" = 1 ]'

new_case upgrade
run_installer -- --version 0.0.5
check upgrade-pinned '[ $RC -eq 0 ] && [ "$("$(BIN)" --version)" = "kurogane 0.0.5" ]'
check upgrade-pinned 'grep -q "download/v0.0.5/" "$CASE/dl.log"'
run_installer KUROGANE_VERSION=v$LATEST --
check upgrade '[ $RC -eq 0 ] && [ "$("$(BIN)" --version)" = "kurogane $LATEST" ]'
check upgrade 'has "updated 0.0.5 -> $LATEST"'

new_case bad-checksum
run_installer -- --version 0.0.5
run_installer -- --version 0.0.7
check bad-checksum '[ $RC -ne 0 ]'
check bad-checksum 'has "checksum mismatch"'
check bad-checksum '[ "$("$(BIN)" --version)" = "kurogane 0.0.5" ]'
check bad-checksum 'tmp_empty'

new_case interrupted
run_installer -- --version 0.0.5
run_installer FAKE_TRUNCATE=1 --
check interrupted '[ $RC -ne 0 ]'
check interrupted 'has "download failed"'
check interrupted '[ "$("$(BIN)" --version)" = "kurogane 0.0.5" ]'
check interrupted '[ -z "$(ls -A "$H/.kurogane/bin" | grep -v "^kurogane$")" ]'
check interrupted 'tmp_empty'

new_case not-runnable
run_installer -- --version 0.0.5
run_installer -- --version 0.0.8
check not-runnable '[ $RC -ne 0 ] && has "does not run on this machine"'
check not-runnable '[ "$("$(BIN)" --version)" = "kurogane 0.0.5" ]'

new_case wrong-version
run_installer -- --version 0.0.9
check wrong-version '[ $RC -ne 0 ] && has "asked for 0.0.9" && [ ! -e "$(BIN)" ]'

new_case missing-version
run_installer -- --version 4.0.0
check missing-version '[ $RC -ne 0 ] && has "is '"'"'4.0.0'"'"' a published version"'

new_case bad-version-string
run_installer -- --version '1;rm'
check bad-version-string '[ $RC -ne 0 ] && has "invalid version"'

new_case aarch64-linux
run_installer FAKE_UNAME_M=aarch64 --
check aarch64-linux '[ $RC -eq 0 ] && grep -q "aarch64-unknown-linux-musl" "$CASE/dl.log"'

new_case unsupported-arch
run_installer FAKE_UNAME_M=riscv64 --
check unsupported-arch '[ $RC -ne 0 ] && has "unsupported CPU architecture: riscv64"'
check unsupported-arch '[ ! -s "$CASE/dl.log" ]'

new_case unsupported-os
run_installer FAKE_UNAME_S=FreeBSD FAKE_UNAME_M=amd64 --
check unsupported-os '[ $RC -ne 0 ] && has "unsupported operating system: FreeBSD"'

new_case windows-shell
run_installer FAKE_UNAME_S=MINGW64_NT-10.0 --
check windows-shell '[ $RC -ne 0 ] && has "install.ps1"'

new_case android
run_installer FAKE_UNAME_O=Android FAKE_UNAME_M=aarch64 --
check android '[ $RC -ne 0 ] && has "Android is not supported"'

new_case macos-arm
run_installer FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64 --
check macos-arm '[ $RC -eq 0 ] && grep -q "aarch64-apple-darwin" "$CASE/dl.log"'

new_case macos-intel
run_installer FAKE_UNAME_S=Darwin FAKE_UNAME_M=x86_64 --
check macos-intel '[ $RC -eq 0 ] && grep -q "x86_64-apple-darwin" "$CASE/dl.log"'

new_case macos-rosetta
run_installer FAKE_UNAME_S=Darwin FAKE_UNAME_M=x86_64 FAKE_ARM64=1 --
check macos-rosetta '[ $RC -eq 0 ] && grep -q "aarch64-apple-darwin" "$CASE/dl.log"'

new_case wget-fallback
run_installer "PATH=$NOCURL:$WGET_DIR:$TOOLS" --
check wget-fallback '[ $RC -eq 0 ] && [ -x "$(BIN)" ]'
check wget-fallback 'grep -q "^wget --https-only --secure-protocol=TLSv1_2" "$CASE/dl.log"'

new_case no-downloader
run_installer "PATH=$NOCURL:$TOOLS" --
check no-downloader '[ $RC -ne 0 ] && has "need '"'"'curl'"'"' or '"'"'wget'"'"'"'

new_case no-sha-tool
run_installer "PATH=$STUBS:$NOSHA" --
check no-sha-tool '[ $RC -ne 0 ] && has "to verify the download" && [ ! -e "$(BIN)" ]'

new_case http-refused
run_installer KUROGANE_DOWNLOAD_URL=http://fixture.invalid/releases --
check http-refused '[ $RC -ne 0 ] && has "must be an https:// URL"'

new_case no-modify-path
run_installer -- --no-modify-path
check no-modify-path '[ $RC -eq 0 ] && [ ! -e "$H/.profile" ] && has "is not on PATH"'
new_case no-modify-path-env
run_installer KUROGANE_NO_MODIFY_PATH=1 --
check no-modify-path-env '[ $RC -eq 0 ] && [ ! -e "$H/.profile" ]'

new_case already-on-path
run_installer "PATH=$H/.kurogane/bin:$STUBS:$TOOLS" --
check already-on-path '[ $RC -eq 0 ] && [ ! -e "$H/.profile" ] && [ ! -e "$H/.kurogane/env" ]'

new_case custom-dir
run_installer -- --install-dir "$H/my tools/bin"
check custom-dir '[ $RC -eq 0 ] && [ -x "$H/my tools/bin/kurogane" ]'
check custom-dir 'grep -qF "$H/my tools/bin" "$H/.kurogane/env"'
check custom-dir '[ "$(env -i HOME="$H" PATH=/usr/bin:/bin "$TEST_SHELL_PATH" -c ". \"$H/.kurogane/env\"; kurogane --version")" = "kurogane $LATEST" ]'

# Another kurogane earlier on PATH is reported; the fresh install itself never is.
new_case shadowed
mkdir -p "$H/old bin"
printf '#!/bin/sh\necho kurogane 0.0.1\n' >"$H/old bin/kurogane"
chmod 755 "$H/old bin/kurogane"
run_installer "PATH=$H/old bin:$H/.kurogane/bin:$STUBS:$TOOLS" --
check shadowed '[ $RC -eq 0 ] && has "$H/old bin/kurogane'"'"' comes earlier on PATH"'
new_case not-shadowed
run_installer "PATH=$H/my tools/bin:$STUBS:$TOOLS" -- --install-dir "$H/my tools/bin"
check not-shadowed '[ $RC -eq 0 ] && [ -x "$H/my tools/bin/kurogane" ] && ! has "shadows this install"'

new_case relative-dir
run_installer -- --install-dir rel/bin
check relative-dir '[ $RC -ne 0 ] && has "must be an absolute path"'

new_case unsafe-dir
run_installer -- --install-dir '/tmp/$(id)'
check unsafe-dir '[ $RC -ne 0 ] && has "unsupported characters"'
run_installer -- --install-dir '/tmp/a\b'
check unsafe-dir-backslash '[ $RC -ne 0 ] && has "unsupported characters"'
run_installer -- --install-dir '/tmp/a"b'
check unsafe-dir-quote '[ $RC -ne 0 ] && has "unsupported characters"'

new_case zsh-fish
printf '#!/bin/sh\n' >"$CASE/zsh"
chmod 755 "$CASE/zsh"
mkdir -p "$H/.config/fish"
run_installer "PATH=$CASE:$STUBS:$TOOLS" --
check zsh-fish '[ $RC -eq 0 ] && [ "$(count "$H/.zshenv" "$(SRC_LINE)")" = 1 ]'
check zsh-fish 'grep -qF "set -gx PATH \"$H/.kurogane/bin\"" "$H/.config/fish/conf.d/kurogane.fish"'
check zsh-fish '[ ! -e "$H/.bashrc" ]'

new_case github-path
: >"$CASE/github_path"
run_installer "GITHUB_PATH=$CASE/github_path" --
check github-path '[ $RC -eq 0 ] && [ "$(cat "$CASE/github_path")" = "$H/.kurogane/bin" ]'

new_case nixos
mkdir -p "$CASE/sysroot/etc"
printf 'NAME=NixOS\nID=nixos\n' >"$CASE/sysroot/etc/os-release"
run_installer "KUROGANE_TEST_SYSROOT=$CASE/sysroot" --
check nixos '[ $RC -ne 0 ] && has "nix profile add github:0x48piraj/kurogane"'
check nixos '[ ! -e "$(BIN)" ] && [ ! -s "$CASE/dl.log" ]'
run_installer "KUROGANE_TEST_SYSROOT=$CASE/sysroot" -- --force-generic
check nixos-force '[ $RC -eq 0 ] && [ -x "$(BIN)" ]'

new_case nix-on-linux
mkdir -p "$CASE/sysroot/nix/store"
run_installer "KUROGANE_TEST_SYSROOT=$CASE/sysroot" --
check nix-on-linux '[ $RC -eq 0 ] && has "Nix detected" && [ -x "$(BIN)" ]'

new_case quiet
run_installer -- -q
check quiet '[ $RC -eq 0 ] && ! has "downloading" && has "installed"'

new_case unknown-flag
run_installer -- --frobnicate
check unknown-flag '[ $RC -ne 0 ] && has "unknown option: --frobnicate"'

new_case help
run_installer -- --help
check help '[ $RC -eq 0 ] && has "USAGE" && [ ! -s "$CASE/dl.log" ]'

# The documented form: piped into the shell, args after `sh -s --`.
run_piped() {
    env -i HOME="$H" TMPDIR="$CASE/tmp" PATH="$STUBS:$TOOLS" DL_LOG="$CASE/dl.log" \
        KUROGANE_DOWNLOAD_URL=https://fixture.invalid/releases \
        "$TEST_SHELL_PATH" -c "cat '$INSTALLER' | '$TEST_SHELL_PATH' -s -- $*" >"$OUT" 2>&1
    RC=$?
}
new_case pipe
run_piped --version 0.0.5 -y
check pipe '[ $RC -eq 0 ] && [ "$("$(BIN)" --version)" = "kurogane 0.0.5" ]'

# A truncated script must not run anything: main is the last line.
new_case truncated-script
head -c 2000 "$INSTALLER" >"$CASE/partial.sh"
env -i HOME="$H" TMPDIR="$CASE/tmp" PATH="$STUBS:$TOOLS" DL_LOG="$CASE/dl.log" \
    "$TEST_SHELL_PATH" "$CASE/partial.sh" </dev/null >"$OUT" 2>&1
check truncated-script '[ ! -s "$CASE/dl.log" ] && [ ! -e "$H/.kurogane" ]'

# ----------------------------------------------------------------- report ---

echo "install.sh under $TEST_SHELL_PATH: $PASS passed, $FAIL failed"
if [ $FAIL -ne 0 ]; then
    printf 'failed checks:%s\n' "$FAILED"
    exit 1
fi
