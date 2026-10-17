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
#   --yes, -y          install missing libraries without asking [SONATA_DEPS=yes]
#   --no-deps          never install libraries, only say which  [SONATA_DEPS=no]
#
# sn loads a few libraries from the system (libsodium, ImageMagick for
# @sonata/image, the Visual C++ runtime on Windows). The script looks for the
# ones the downloaded build needs and this machine lacks, and offers to install
# them with the system's package manager (apt, dnf, yum, zypper, pacman,
# Homebrew or winget).
set -euo pipefail

REPO="runsonata/sonata"
API="https://api.github.com/repos/$REPO"

version="${SONATA_VERSION:-}"
prefix="${SONATA_INSTALL:-$HOME/.sonata}"
modify_path=1
[[ -n "${SONATA_NO_MODIFY_PATH:-}" ]] && modify_path=0
deps="${SONATA_DEPS:-ask}" # ask | yes | no

if [[ -t 1 ]]; then
  bold=$'\033[1m' red=$'\033[31m' green=$'\033[32m' dim=$'\033[2m' reset=$'\033[0m'
else
  bold="" red="" green="" dim="" reset=""
fi

info() { echo "${dim}>${reset} $*"; }
warn() { echo "${red}warning:${reset} $*" >&2; }
die()  { echo "${red}error:${reset} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Install Sonata (sn) from the GitHub releases.

usage: install.sh [--version <tag>] [--dir <path>] [--no-modify-path] [--yes | --no-deps]

  --version <tag>    release to install, e.g. 0.1.92 (default: newest)  [SONATA_VERSION]
  --dir <path>       install location (default: ~/.sonata)             [SONATA_INSTALL]
  --no-modify-path   don't add <dir>/bin to PATH                       [SONATA_NO_MODIFY_PATH=1]
  --yes, -y          install missing libraries without asking          [SONATA_DEPS=yes]
  --no-deps          never install libraries, only say which           [SONATA_DEPS=no]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)        version="${2:?--version needs a value}"; shift 2 ;;
    --version=*)      version="${1#*=}"; shift ;;
    --dir)            prefix="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*)          prefix="${1#*=}"; shift ;;
    --no-modify-path) modify_path=0; shift ;;
    -y|--yes)         deps="yes"; shift ;;
    --no-deps)        deps="no"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (see --help)" ;;
  esac
done
case "$deps" in
  ask|yes|no) ;;
  *) die "SONATA_DEPS must be ask, yes or no (got '$deps')" ;;
esac

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

# libraries ///////////////////////////////////////

# The libraries the binaries need that aren't on this machine, one per line:
# sonames on Linux, Homebrew paths on macOS, DLL names on Windows.
missing_libs() { # missing_libs <binary>...
  local f lib sys32
  case "$os" in
    Linux)
      command -v ldd >/dev/null 2>&1 || return 0
      for f in "$@"; do
        if [[ -f "$f" ]]; then ldd "$f" 2>/dev/null || true; fi
      done | awk '/=> not found/ { print $1 }' | sort -u
      ;;
    Darwin)
      # Mach-O load commands hold absolute paths, and only Homebrew's can be
      # missing (/usr/lib and /System are part of macOS). otool needs the Xcode
      # command line tools, so read the paths straight out of the binaries.
      for f in "$@"; do
        if [[ -f "$f" ]]; then
          grep -aoE '/(opt/homebrew|usr/local)/[A-Za-z0-9_.+@/-]+\.dylib' "$f" || true
        fi
      done | sort -u | while IFS= read -r lib; do
        if [[ ! -e "$lib" ]]; then echo "$lib"; fi
      done
      ;;
    Windows)
      # MSVC builds need the Visual C++ runtime; everything else ships with Windows.
      command -v cygpath >/dev/null 2>&1 || return 0
      sys32="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32"
      for lib in vcruntime140.dll vcruntime140_1.dll msvcp140.dll; do
        if [[ ! -f "$sys32/$lib" ]]; then echo "$lib"; fi
      done
      ;;
  esac
}

# The Linux package that provides a soname, for one package manager.
linux_package() { # linux_package <manager> <soname>
  local soname="$2" name ver base candidate
  case "$1" in
    dnf|yum|zypper)
      # RPM packages declare the sonames they provide, so the package manager
      # can find the right one itself. Every Sonata build is 64-bit.
      echo "$soname()(64bit)"
      ;;
    pacman)
      case "$soname" in
        libsodium.*)            echo libsodium ;;
        libMagick*)             echo imagemagick ;;
        libzstd.*)              echo zstd ;;
        libssl.*|libcrypto.*)   echo openssl ;;
        libz.*)                 echo zlib ;;
        libstdc++.*|libgcc_s.*) echo gcc-libs ;;
        *)                      return 1 ;;
      esac
      ;;
    apt-get)
      case "$soname" in
        libz.so.*)      echo zlib1g; return ;;
        libgcc_s.so.*)  echo libgcc-s1; return ;;
        libcrypto.so.*) soname="libssl.so.${soname#libcrypto.so.}" ;;
      esac
      # Debian names runtime packages after the soname: libsodium.so.23 is in
      # libsodium23, and libMagickWand-6.Q16.so.7 in libmagickwand-6.q16-7 (a
      # hyphen when the name ends in a digit). Since the 64-bit time_t
      # transition some have a "t64" suffix, so ask apt which one exists.
      name="$(tr '[:upper:]' '[:lower:]' <<<"${soname%%.so.*}")"
      ver="${soname#*.so.}"
      ver="${ver%%.*}"
      [[ "$name" == *[0-9] ]] && name="$name-"
      base="$name$ver"
      for candidate in "$base" "${base}t64"; do
        if apt-cache show --no-all-versions "$candidate" 2>/dev/null | grep -q '^Package:'; then
          echo "$candidate"
          return
        fi
      done
      echo "$base" # the package lists may be empty; apt-get update comes first anyway
      ;;
    *)
      return 1
      ;;
  esac
}

# Runs a command as root: directly, or through sudo or doas.
as_root() {
  if [[ "$(id -u)" == 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  elif command -v doas >/dev/null 2>&1; then
    doas "$@"
  else
    echo "this needs root, and neither sudo nor doas is installed" >&2
    return 1
  fi
}

# Asks a yes/no question on the terminal. The script itself usually arrives
# through a pipe, so stdin is no good for answers. Returns 2 without a terminal.
confirm() { # confirm <question>
  local reply
  case "$deps" in
    yes) return 0 ;;
    no)  return 1 ;;
  esac
  ( exec </dev/tty ) 2>/dev/null || return 2
  printf '%s [Y/n] ' "$1" >/dev/tty
  read -r reply </dev/tty || reply="n"
  [[ -z "$reply" || "$reply" == [Yy]* ]]
}

deps_note="" # set when libraries are still missing at the end

setup_libraries() { # setup_libraries <binary>...
  local missing lib pkg manager="" packages="" unknown="" shown="" root="" vcarch="x64"
  missing="$(missing_libs "$@")"
  [[ -n "$missing" ]] || return 0

  [[ "$(id -u)" == 0 ]] || root="sudo "
  case "$os" in
    Linux)
      for manager in apt-get dnf yum zypper pacman ""; do
        [[ -n "$manager" ]] && command -v "$manager" >/dev/null 2>&1 && break
      done
      while IFS= read -r lib; do
        if pkg="$(linux_package "$manager" "$lib")"; then
          packages="$packages $pkg"
        else
          unknown="$unknown $lib"
        fi
      done <<<"$missing"
      ;;
    Darwin)
      manager="brew"
      while IFS= read -r lib; do
        # /opt/homebrew/opt/<formula>/lib/... or /opt/homebrew/Cellar/<formula>/<version>/lib/...
        pkg="$(sed -nE 's#^/(opt/homebrew|usr/local)/(opt|Cellar)/([^/]+)/.*#\3#p' <<<"$lib")"
        if [[ -n "$pkg" ]]; then
          packages="$packages $pkg"
        else
          unknown="$unknown $lib"
        fi
      done <<<"$missing"
      ;;
    Windows)
      [[ "${url##*/}" == *[Aa][Rr][Mm]64* ]] && vcarch="arm64"
      manager="vcredist"
      command -v winget >/dev/null 2>&1 && manager="winget"
      packages=" Microsoft.VCRedist.2015+.$vcarch"
      ;;
  esac
  packages="$(tr ' ' '\n' <<<"$packages" | sed '/^$/d' | sort -u | tr '\n' ' ')"
  packages="${packages% }"

  case "$manager" in
    apt-get)  shown="${root}apt-get update && ${root}apt-get install -y $packages" ;;
    dnf|yum)  shown="$root$manager install -y $packages" ;;
    zypper)   shown="${root}zypper install $packages" ;;
    pacman)   shown="${root}pacman -S --needed $packages" ;;
    brew)     shown="brew install $packages" ;;
    winget)   shown="winget install -e --id $packages" ;;
    vcredist) shown="download and run https://aka.ms/vc14/vc_redist.$vcarch.exe" ;;
  esac
  # Quote the RPM soname capabilities, which have parentheses.
  shown="$(sed -E "s/([^ ]+\\(\\)\\(64bit\\))/'\\1'/g" <<<"$shown")"

  echo
  info "Sonata needs libraries this system doesn't have:"
  while IFS= read -r lib; do echo "    $lib"; done <<<"$missing"

  if [[ -z "$packages" ]]; then
    deps_note="Install the packages that provide:${unknown}"
    return 0
  fi
  if [[ "$manager" == "brew" ]] && ! command -v brew >/dev/null 2>&1; then
    deps_note="Install Homebrew (https://brew.sh), then run: ${bold}$shown${reset}"
    return 0
  fi
  [[ -n "$unknown" ]] && warn "no package found for:$unknown"
  info "They can be installed with: ${bold}$shown${reset}"

  local answer=0
  confirm "Install them now?" || answer=$?
  if (( answer != 0 )); then
    (( answer == 2 )) && info "No terminal to ask on; rerun with --yes to install them."
    deps_note="Install the libraries Sonata needs with: ${bold}$shown${reset}"
    return 0
  fi

  # The package managers mustn't read from stdin: under "curl | bash" that is
  # the rest of this script.
  local status=0
  case "$manager" in
    apt-get)
      # shellcheck disable=SC2086 # the package list is meant to split into words
      { as_root apt-get update && as_root apt-get install -y $packages; } </dev/null || status=$? ;;
    dnf|yum)
      # shellcheck disable=SC2086
      as_root "$manager" install -y $packages </dev/null || status=$? ;;
    zypper)
      # shellcheck disable=SC2086
      as_root zypper --non-interactive install $packages </dev/null || status=$? ;;
    pacman)
      # shellcheck disable=SC2086
      as_root pacman -S --needed --noconfirm $packages </dev/null || status=$? ;;
    brew)
      # shellcheck disable=SC2086
      brew install $packages </dev/null || status=$? ;;
    winget)
      winget install -e --id "$packages" --accept-package-agreements --accept-source-agreements </dev/null || status=$? ;;
    vcredist)
      # Asks for administrator rights itself (UAC).
      { download "https://aka.ms/vc14/vc_redist.$vcarch.exe" "$tmp/vc_redist.exe" \
          && "$tmp/vc_redist.exe" /install /passive /norestart; } </dev/null || status=$? ;;
  esac
  # 3010: the Visual C++ installer wants a restart, which sn doesn't need.
  if (( status != 0 && status != 3010 )); then
    warn "installing the libraries failed"
  fi

  missing="$(missing_libs "$@")"
  if [[ -n "$missing" ]]; then
    deps_note="These libraries are still missing: $(tr '\n' ' ' <<<"$missing")
Install them with: ${bold}$shown${reset}"
  fi
}

snrt="$prefix/libexec/sonata/snrt"
[[ "$os" == "Windows" ]] && snrt="$snrt.exe"
setup_libraries "$prefix/bin/$exe" "$snrt"

if ! "$prefix/bin/$exe" --version >/dev/null 2>&1; then
  # Missing libraries are explained at the end; the rest of the install
  # (PATH) is still worth doing.
  [[ -n "$deps_note" ]] || die "installed $exe doesn't run"
fi

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
if [[ -n "$deps_note" ]] && ! "$prefix/bin/$exe" --version >/dev/null 2>&1; then
  echo "${green}Sonata ${tag:-} installed${reset}, but sn won't start until its libraries are."
  echo "$deps_note"
  [[ -n "$path_note" ]] && echo "$path_note"
  exit 0
fi
echo "${green}Sonata ${tag:-} installed:${reset} $("$prefix/bin/$exe" --version 2>/dev/null | head -n 1)"
[[ -n "$deps_note" ]] && echo "$deps_note"
[[ -n "$path_note" ]] && echo "$path_note"
echo "Run ${bold}sn --help${reset} to get started."
