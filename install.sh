#!/bin/sh
# Installs Sonata (sn).
#
#   curl -fsSL https://sonata.5418.org/install.sh | sh
#
# sn is a single file with no dependencies, so all this does is download it,
# verify it, and put it on your PATH. It never asks for root and never installs
# anything else. For Windows, see install.ps1.
#
# Options (or the environment variable in brackets):
#   --version <version>   install this release, e.g. 2.0.0 (default: the latest) [SONATA_VERSION]
#   --dir <path>          install here, default ~/.sonata; sn goes in <dir>/bin   [SONATA_HOME]
#   --no-modify-path      don't add <dir>/bin to your PATH                        [SONATA_NO_MODIFY_PATH=1]
set -eu

REPO="runsonata/sonata"
# Where releases come from. Only meant to be changed for testing.
DOWNLOAD_URL="${SONATA_DOWNLOAD_URL:-https://github.com/$REPO/releases}"

version="${SONATA_VERSION:-}"
prefix="${SONATA_HOME:-$HOME/.sonata}"
modify_path=1
[ -n "${SONATA_NO_MODIFY_PATH:-}" ] && modify_path=0

if [ -t 1 ]; then
  bold=$(printf '\033[1m') red=$(printf '\033[31m') green=$(printf '\033[32m') dim=$(printf '\033[2m') reset=$(printf '\033[0m')
else
  bold="" red="" green="" dim="" reset=""
fi

info() { printf '%s>%s %s\n' "$dim" "$reset" "$*"; }
warn() { printf '%swarning:%s %s\n' "$red" "$reset" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)        [ $# -ge 2 ] || die "--version needs a value"; version="$2"; shift 2 ;;
    --version=*)      version="${1#*=}"; shift ;;
    --dir)            [ $# -ge 2 ] || die "--dir needs a value"; prefix="$2"; shift 2 ;;
    --dir=*)          prefix="${1#*=}"; shift ;;
    --no-modify-path) modify_path=0; shift ;;
    -h|--help)        sed -n '2,/^set -eu/p' "$0" 2>/dev/null | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown option: $1 (see --help)" ;;
  esac
done

# platform ////////////////////////////////////

case "$(uname -s)" in
  Linux)  os="linux" ;; # Android/Termux included: the linux builds are fully static
  Darwin) os="macos" ;;
  MINGW*|MSYS*|CYGWIN*)
    die "on Windows, run this in PowerShell: irm https://sonata.5418.org/install.ps1 | iex" ;;
  *)      die "unsupported system: $(uname -s)" ;;
esac

arch="$(uname -m)"
# A shell running under Rosetta reports x86_64 on Apple Silicon.
if [ "$os" = "macos" ] && [ "$arch" = "x86_64" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then
  arch="arm64"
fi
case "$arch" in
  x86_64|amd64)  arch="x64" ;;
  aarch64|arm64) arch="arm64" ;;
  *)             die "unsupported architecture: $arch" ;;
esac

platform="$os-$arch"
archive="sonata-$platform.tar.gz"

# Asset names have no version in them, so the latest release has a fixed URL:
# no GitHub API call, and so no rate limit to run into.
if [ -n "$version" ]; then
  base="$DOWNLOAD_URL/download/v${version#v}"
else
  base="$DOWNLOAD_URL/latest/download"
fi

# download ///////////////////////////////////

if command -v curl >/dev/null 2>&1; then
  download() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  download() { wget -qO "$2" "$1"; }
else
  die "curl or wget is required"
fi
command -v tar >/dev/null 2>&1 || die "tar is required"

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t sonata)"
trap 'rm -rf "$tmp"' EXIT

info "Downloading ${bold}$archive${reset}${version:+ ($version)}"
download "$base/$archive" "$tmp/$archive" || die "couldn't download $base/$archive"
download "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "couldn't download the checksums from $base"

# verify /////////////////////////////////////

expected="$(awk -v file="$archive" '$2 == file || $2 == "*" file { print $1 }' "$tmp/SHA256SUMS")"
[ -n "$expected" ] || die "the release has no checksum for $archive"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$archive" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$tmp/$archive" | awk '{ print $1 }')"
else
  actual=""
  warn "neither sha256sum nor shasum is installed, so the download can't be verified"
fi
if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
  die "the download is corrupted (checksum mismatch); nothing was installed"
fi

# install ////////////////////////////////////

tar -xzf "$tmp/$archive" -C "$tmp"
[ -f "$tmp/sonata-$platform/bin/sn" ] || die "unexpected archive layout: no bin/sn"

bin="$prefix/bin"
mkdir -p "$bin"

# Written next to the target and renamed over it: an interrupted install can't
# leave a half-written sn, and a running sn keeps working.
cp "$tmp/sonata-$platform/bin/sn" "$bin/.sn.new"
chmod 755 "$bin/.sn.new"

if [ "$os" = "macos" ] && command -v xattr >/dev/null 2>&1; then
  xattr -d com.apple.quarantine "$bin/.sn.new" 2>/dev/null || true
fi

# Run the new sn before it replaces anything, so a bad one can't break a good one.
if ! installed="$("$bin/.sn.new" --version 2>&1)"; then
  rm -f "$bin/.sn.new"
  die "the downloaded sn doesn't run on this system: $installed"
fi

mv -f "$bin/.sn.new" "$bin/sn"
info "Installed to ${bold}$bin/sn${reset}"

# PATH ///////////////////////////////////////

path_note=""

add_line() { # file line
  mkdir -p "$(dirname "$1")"
  if [ -f "$1" ] && grep -qF -- "$2" "$1"; then
    return 0
  fi
  printf '\n# sonata\n%s\n' "$2" >>"$1"
}

case ":$PATH:" in
  *":$bin:"*) ;;
  *)
    if [ "$modify_path" = 0 ]; then
      path_note="Add ${bold}$bin${reset} to your PATH to use sn."
    else
      # Keep $HOME literal in rc files when the path is under it.
      case "$bin" in
        "$HOME"/*) shown="\$HOME/${bin#"$HOME"/}" ;;
        *)         shown="$bin" ;;
      esac

      case "$(basename "${SHELL:-sh}")" in
        zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc"; add_line "$rc" "export PATH=\"$shown:\$PATH\"" ;;
        fish) rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/sonata.fish"; add_line "$rc" "fish_add_path \"$bin\"" ;;
        bash)
          rc="$HOME/.bashrc"
          # macOS Terminal starts login shells, which read .bash_profile instead.
          [ "$os" = "macos" ] && rc="$HOME/.bash_profile"
          add_line "$rc" "export PATH=\"$shown:\$PATH\"" ;;
        *)    rc="$HOME/.profile"; add_line "$rc" "export PATH=\"$shown:\$PATH\"" ;;
      esac
      path_note="Added to your PATH in ${bold}$rc${reset}. Restart your shell, or run:
    export PATH=\"$bin:\$PATH\""
    fi
    ;;
esac

echo
echo "${green}$installed installed.${reset}"
[ -z "$path_note" ] || echo "$path_note"
echo "Run ${bold}sn --help${reset} to get started, or ${bold}sn doctor${reset} to check your setup."
