#!/usr/bin/env bash
# Installs Sonata (sn) from the GitHub releases.
#
#   curl -fsSL https://sonata.5418.org/install.sh | bash
#
# THIS FILE IS NOT FOR WINDOWS!
# MacOS and any other posix os is safe to run this.
#
# Options (or the environment variable in brackets):
#   --version <tag>    release to install, e.g. 0.1.92 or v0.1.92 [SONATA_VERSION]
#                      default: the newest release, pre-releases included
#   --dir <path>       where to install                         [SONATA_INSTALL]
#                      default: ~/.sonata (sn is put in <dir>/bin)
#   --no-modify-path   don't add <dir>/bin to PATH              [SONATA_NO_MODIFY_PATH=1]
set -euo pipefail

REPO="runsonata/sonata"
API="https://api.github.com/repos/$REPO"

version="${SONATA_VERSION:-}"
prefix="${SONATA_INSTALL:-$HOME/.sonata}"
modify_path=1
[[ -n "${SONATA_NO_MODIFY_PATH:-}" ]] && modify_path=0

if [[ -t 1 ]]; then
  bold=$'\033[1m' red=$'\033[31m' green=$'\033[32m' dim=$'\033[2m' reset=$'\033[0m'
else
  bold="" red="" green="" dim="" reset=""
fi

info() { echo "${dim}>${reset} $*"; }
die()  { echo "${red}error:${reset} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Install Sonata (sn) from the GitHub releases.

usage: install.sh [--version <tag>] [--dir <path>] [--no-modify-path]

  --version <tag>    release to install, e.g. 0.1.92 (default: newest)  [SONATA_VERSION]
  --dir <path>       install location (default: ~/.sonata)             [SONATA_INSTALL]
  --no-modify-path   don't add <dir>/bin to PATH                       [SONATA_NO_MODIFY_PATH=1]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)        version="${2:?--version needs a value}"; shift 2 ;;
    --version=*)      version="${1#*=}"; shift ;;
    --dir)            prefix="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*)          prefix="${1#*=}"; shift ;;
    --no-modify-path) modify_path=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (see --help)" ;;
  esac
done

# platform ////////////////////////////////////

case "$(uname -s)" in
  Linux)                     os="Linux"   ext="tar.gz" ;;
  Darwin)                    os="Darwin"  ext="tar.gz" ;;
  MINGW*|MSYS*|CYGWIN*)      os="Windows" ext="zip" ;;
  *)                         die "unsupported OS: $(uname -s)" ;;
esac

arch="$(uname -m)"
# A shell running under Rosetta reports x86_64 on Apple Silicon.
if [[ "$os" == "Darwin" && "$arch" == "x86_64" ]] \
   && [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
  arch="arm64"
fi

# Asset names look like sonata-<version>-<platform>.<ext>. Releases from 1.0.0
# use lowercase platforms (linux-x64, macos-arm64, windows-x64); older ones used
# uname-style names (Linux-x86_64, Darwin-arm64, Windows-AMD64). Each list holds
# the new suffix first, then the old one, so --version still works for old tags.
# "fallback" is tried only when nothing in "suffixes" matches.
fallback=""
case "$os:$arch" in
  Linux:x86_64|Linux:amd64)       arch="x64"   suffixes="-linux-x64.$ext -Linux-x86_64.$ext" ;;
  Linux:aarch64|Linux:arm64)      arch="arm64" suffixes="-linux-arm64.$ext -Linux-aarch64.$ext" ;;
  Darwin:arm64|Darwin:aarch64)    arch="arm64" suffixes="-macos-arm64.$ext -Darwin-arm64.$ext" ;;
  Darwin:x86_64)                  arch="x64"   suffixes="-macos-x64.$ext -Darwin-x86_64.$ext" ;;
  Windows:x86_64|Windows:amd64)   arch="x64"   suffixes="-windows-x64.$ext -Windows-AMD64.$ext" ;;
  Windows:aarch64|Windows:arm64)  arch="arm64" suffixes="-windows-arm64.$ext -Windows-ARM64.$ext"
                                  # Windows on ARM runs x64 programs too.
                                  fallback="-windows-x64.$ext -Windows-AMD64.$ext" ;;
  *)                              die "unsupported architecture: $arch on $os" ;;
esac

# download helpers ///////////////////////////////////////

if command -v curl >/dev/null 2>&1; then
  fetch()    { curl -fsSL -H "Accept: application/vnd.github+json" "$1"; }
  download() { curl -fL --progress-bar -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch()    { wget -qO- --header="Accept: application/vnd.github+json" "$1"; }
  download() { wget -q --show-progress -O "$2" "$1"; }
else
  die "curl or wget is required"
fi

if [[ "$ext" == "zip" ]]; then
  command -v unzip >/dev/null 2>&1 || die "unzip is required"
else
  command -v tar >/dev/null 2>&1 || die "tar is required"
fi

# find the release asset /////////////////////////////////////

# The version in an asset name doesn't always match the tag (v0.1.92 shipped
# sonata-0.1.8-*), so match on the platform suffix only.
find_asset() { # find_asset <suffix>...; reads release JSON on stdin, prints the first matching URL
  local pattern="" s
  for s in "$@"; do
    pattern="${pattern:+$pattern|}${s//./\\.}\$"
  done
  grep -o '"browser_download_url": *"[^"]*"' \
    | sed 's/.*"\(https[^"]*\)"$/\1/' \
    | grep -E -- "$pattern" \
    | head -n 1 || true
}

if [[ -n "$version" ]]; then
  tag="v${version#v}"
  info "Looking up Sonata $tag"
  json="$(fetch "$API/releases/tags/$tag")" || die "release $tag not found"
else
  info "Looking up the latest Sonata release"
  # /releases/latest skips pre-releases, so read the list instead (newest first).
  json="$(fetch "$API/releases?per_page=20")" || die "couldn't reach the GitHub API"
fi

# shellcheck disable=SC2086 # the suffix lists are meant to split into words
url="$(find_asset $suffixes <<<"$json")"
if [[ -z "$url" && -n "$fallback" ]]; then
  url="$(find_asset $fallback <<<"$json")"
  [[ -n "$url" ]] && info "No $os $arch build; installing the x64 build instead"
fi
[[ -n "$url" ]] || die "no release asset for $os $arch (looked for: $suffixes${fallback:+ $fallback})"
tag="$(sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p' <<<"$url")"

# download and install //////////////////////////////////////

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t sonata)"
trap 'rm -rf "$tmp"' EXIT

info "Downloading ${bold}${url##*/}${reset}"
download "$url" "$tmp/archive.$ext"

mkdir -p "$tmp/x"
if [[ "$ext" == "zip" ]]; then
  unzip -q "$tmp/archive.$ext" -d "$tmp/x"
else
  tar -xzf "$tmp/archive.$ext" -C "$tmp/x"
fi

# The archive holds a single sonata-<version>-<platform>/ directory.
root="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$root" && -d "$root/bin" ]] || die "unexpected archive layout"

exe="sn"
[[ "$os" == "Windows" ]] && exe="sn.exe"
[[ -f "$root/bin/$exe" ]] || die "archive has no bin/$exe"

info "Installing to ${bold}$prefix${reset}"
mkdir -p "$prefix"
cp -R "$root"/. "$prefix"/
chmod +x "$prefix/bin/$exe"
[[ -f "$prefix/libexec/sonata/snrt" ]] && chmod +x "$prefix/libexec/sonata/snrt"

# Downloads made by a browser carry this on macOS; clear it in case the
# archive was fetched some other way before.
if [[ "$os" == "Darwin" ]] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$prefix/bin" "$prefix/libexec" 2>/dev/null || true
fi

"$prefix/bin/$exe" --version >/dev/null 2>&1 || die "installed $exe doesn't run"

# PATH ///////////////////////////////////////////////

bin="$prefix/bin"
path_note=""

add_line() { # file line
  mkdir -p "$(dirname "$1")"
  if [[ -f "$1" ]] && grep -qF -- "$2" "$1"; then
    return 1
  fi
  printf '\n# sonata\n%s\n' "$2" >>"$1"
}

if [[ ":$PATH:" == *":$bin:"* ]]; then
  :
elif (( modify_path == 0 )); then
  path_note="Add ${bold}$bin${reset} to your PATH to use sn."
else
  # Show $HOME literally in rc files when the path is under it.
  shown="$bin"
  [[ "$bin" == "$HOME"/* ]] && shown="\$HOME/${bin#"$HOME"/}"

  case "$(basename "${SHELL:-bash}")" in
    zsh)
      rc="${ZDOTDIR:-$HOME}/.zshrc"
      add_line "$rc" "export PATH=\"$shown:\$PATH\"" || true ;;
    fish)
      rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/sonata.fish"
      add_line "$rc" "fish_add_path \"$bin\"" || true ;;
    *)
      rc="$HOME/.bashrc"
      # macOS Terminal starts login shells, which read .bash_profile instead.
      [[ "$os" == "Darwin" ]] && rc="$HOME/.bash_profile"
      add_line "$rc" "export PATH=\"$shown:\$PATH\"" || true ;;
  esac
  path_note="$bin is on your PATH via ${bold}$rc${reset}. Restart your shell, or run:
    export PATH=\"$bin:\$PATH\""

  # Git Bash: also put it on the Windows user PATH so cmd/PowerShell see it.
  if [[ "$os" == "Windows" ]] && command -v cygpath >/dev/null 2>&1 \
     && command -v powershell.exe >/dev/null 2>&1; then
    winbin="$(cygpath -w "$bin")"
    powershell.exe -NoProfile -NonInteractive -Command "
      \$p = [Environment]::GetEnvironmentVariable('Path', 'User')
      if (-not ((\$p -split ';') -contains '$winbin')) {
        [Environment]::SetEnvironmentVariable('Path', ((@(\$p, '$winbin') | Where-Object { \$_ }) -join ';'), 'User')
      }" >/dev/null 2>&1 || true
  fi
fi

echo
echo "${green}Sonata ${tag:-} installed:${reset} $("$prefix/bin/$exe" --version 2>/dev/null | head -n 1)"
[[ -n "$path_note" ]] && echo "$path_note"
echo "Run ${bold}sn --help${reset} to get started."
