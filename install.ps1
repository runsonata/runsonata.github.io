# Installs Sonata (sn) on Windows.
#
#   irm https://sonata.5418.org/install.ps1 | iex
#
# sn.exe is a single file with no dependencies, so all this does is download it,
# verify it, and put it on your PATH.
#
# Options, as environment variables (set them before piping into iex) or as
# parameters when the script is run as a file:
#   SONATA_VERSION / -Version                 release to install, e.g. 2.0.0 (default: the latest)
#   SONATA_HOME / -Dir                        install location (default: ~\.sonata)
#   SONATA_NO_MODIFY_PATH=1 / -NoModifyPath   don't add <dir>\bin to the user PATH

param(
    [string]$Version = $env:SONATA_VERSION,
    [string]$Dir = $(if ($env:SONATA_HOME) { $env:SONATA_HOME } else { Join-Path $HOME '.sonata' }),
    [switch]$NoModifyPath = [bool]$env:SONATA_NO_MODIFY_PATH
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'runsonata/sonata'
# Where releases come from. Only meant to be changed for testing.
$DownloadUrl = if ($env:SONATA_DOWNLOAD_URL) { $env:SONATA_DOWNLOAD_URL } else { "https://github.com/$Repo/releases" }

# throw, not exit: under "irm | iex" exit would close the user's terminal.
function Fail($message) {
    throw "sonata install failed: $message"
}

# PROCESSOR_ARCHITEW6432 is set when this is a 32-bit PowerShell on 64-bit Windows.
$cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = switch ($cpu) {
    'AMD64' { 'x64' }
    'ARM64' { 'arm64' }
    default { Fail "unsupported architecture: $cpu" }
}

$platform = "windows-$arch"
$archive = "sonata-$platform.zip"

# Asset names have no version in them, so the latest release has a fixed URL: no
# GitHub API call, and so no rate limit to run into.
$base = if ($Version) { "$DownloadUrl/download/v$($Version.TrimStart('v'))" } else { "$DownloadUrl/latest/download" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sonata-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    $zip = Join-Path $tmp $archive
    $sums = Join-Path $tmp 'SHA256SUMS'

    Write-Host "> Downloading $archive"
    try {
        Invoke-WebRequest -Uri "$base/$archive" -OutFile $zip -UseBasicParsing
        Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sums -UseBasicParsing
    } catch {
        Fail "couldn't download from $base : $_"
    }

    $line = Get-Content $sums | Where-Object { ($_ -split '\s+')[1] -in $archive, "*$archive" } | Select-Object -First 1
    if (-not $line) { Fail "the release has no checksum for $archive" }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
    if ($actual -ne $expected) { Fail 'the download is corrupted (checksum mismatch); nothing was installed' }

    $extracted = Join-Path $tmp 'x'
    Expand-Archive -Path $zip -DestinationPath $extracted -Force

    $new = Join-Path $extracted "sonata-$platform\bin\sn.exe"
    if (-not (Test-Path $new)) { Fail 'unexpected archive layout: no bin\sn.exe' }

    # Run the new sn before it replaces anything, so a bad one can't break a good one.
    $installed = & $new --version 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -ne 0) { Fail "the downloaded sn.exe doesn't run on this system: $installed" }

    $bin = Join-Path $Dir 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    try {
        Copy-Item -Path $new -Destination (Join-Path $bin 'sn.exe') -Force
    } catch {
        Fail "couldn't write to $bin (is sn running?): $_"
    }
    Write-Host "> Installed to $bin\sn.exe"
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$pathNote = $null
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $bin)) {
    if ($NoModifyPath) {
        $pathNote = "Add $bin to your PATH to use sn."
    } else {
        $newPath = (@($userPath, $bin) | Where-Object { $_ }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path = "$bin;$env:Path"
        $pathNote = "Added $bin to your user PATH. Open a new terminal to use sn there."
    }
}

Write-Host ''
Write-Host "$installed installed." -ForegroundColor Green
if ($pathNote) { Write-Host $pathNote }
Write-Host 'Run sn --help to get started, or sn doctor to check your setup.'
