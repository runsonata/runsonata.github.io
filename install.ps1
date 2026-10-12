# Installs Sonata (sn) from the GitHub releases on Windows.
#
#   irm https://sonata.5418.org/install.ps1 | iex
#
# Options, as environment variables (set them before piping into iex) or as
# parameters when the script is run as a file:
#   SONATA_VERSION / -Version       release to install, e.g. 0.1.92 (default: newest)
#   SONATA_INSTALL / -Dir           install location (default: ~\.sonata)
#   SONATA_NO_MODIFY_PATH=1 / -NoModifyPath   don't add <dir>\bin to the user PATH

param(
    [string]$Version = $env:SONATA_VERSION,
    [string]$Dir = $(if ($env:SONATA_INSTALL) { $env:SONATA_INSTALL } else { Join-Path $HOME '.sonata' }),
    [switch]$NoModifyPath = [bool]$env:SONATA_NO_MODIFY_PATH
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'runsonata/sonata'
$Api = "https://api.github.com/repos/$Repo"

# throw, not exit: under `irm | iex` exit would close the user's terminal.
function Fail($message) {
    throw "sonata install failed: $message"
}

# platform //////////////////////////////////////

# PROCESSOR_ARCHITEW6432 is set when this is a 32-bit PowerShell on 64-bit Windows.
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arches = switch ($arch) {
    'AMD64' { @('AMD64') }
    'ARM64' { @('ARM64', 'AMD64') }   # Windows on ARM runs x64 programs too
    default { Fail "unsupported architecture: $arch" }
}

# find the release asset //////////////////////////////

$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'sonata-installer' }

try {
    if ($Version) {
        $tag = 'v' + $Version.TrimStart('v')
        Write-Host "> Looking up Sonata $tag"
        $releases = @(Invoke-RestMethod -Uri "$Api/releases/tags/$tag" -Headers $headers)
    } else {
        Write-Host '> Looking up the latest Sonata release'
        # /releases/latest skips pre-releases, so read the list instead (newest first).
        $releases = @(Invoke-RestMethod -Uri "$Api/releases?per_page=20" -Headers $headers)
    }
} catch {
    if ($Version) { Fail "release $tag not found" } else { Fail "couldn't reach the GitHub API: $_" }
}

# Asset names look like sonata-<cmake version>-Windows-<arch>.zip; the CMake
# version doesn't always match the tag, so match on the suffix only.
$asset = $null
foreach ($a in $arches) {
    foreach ($release in $releases) {
        $asset = $release.assets | Where-Object { $_.name -like "*-Windows-$a.zip" } | Select-Object -First 1
        if ($asset) { $tag = $release.tag_name; break }
    }
    if ($asset) { break }
}
if (-not $asset) { Fail "no release asset for Windows $arch" }

# download and install //////////////////////////////////////////

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sonata-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    $zip = Join-Path $tmp $asset.name
    Write-Host "> Downloading $($asset.name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing

    $extracted = Join-Path $tmp 'x'
    Expand-Archive -Path $zip -DestinationPath $extracted -Force

    # The archive holds a single sonata-<version>-Windows-<arch>\ directory.
    $root = Get-ChildItem -Path $extracted -Directory | Select-Object -First 1
    if (-not $root -or -not (Test-Path (Join-Path $root.FullName 'bin\sn.exe'))) {
        Fail 'unexpected archive layout (no bin\sn.exe)'
    }

    Write-Host "> Installing to $Dir"
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    try {
        Copy-Item -Path (Join-Path $root.FullName '*') -Destination $Dir -Recurse -Force
    } catch {
        Fail "couldn't write to $Dir (is sn running?): $_"
    }
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$bin = Join-Path $Dir 'bin'
$sn = Join-Path $bin 'sn.exe'
$installed = & $sn --version 2>$null | Select-Object -First 1
if ($LASTEXITCODE -ne 0) { Fail 'installed sn.exe does not run' }

# PATH ////////////////////////////////////

$pathNote = $null
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = ($userPath -split ';') -contains $bin

if (-not $onPath) {
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
Write-Host "Sonata $tag installed: $installed" -ForegroundColor Green
if ($pathNote) { Write-Host $pathNote }
Write-Host 'Run sn --help to get started.'
