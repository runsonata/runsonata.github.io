# Installs Sonata (sn) from the GitHub releases on Windows.
#
#   irm https://sonata.5418.org/install.ps1 | iex
#
# Options, as environment variables (set them before piping into iex) or as
# parameters when the script is run as a file:
#   SONATA_VERSION / -Version       release to install, e.g. 0.1.92 (default: newest)
#   SONATA_INSTALL / -Dir           install location (default: ~\.sonata)
#   SONATA_NO_MODIFY_PATH=1 / -NoModifyPath   don't add <dir>\bin to the user PATH
#   SONATA_DEPS=yes / -Yes          install the Visual C++ runtime without asking, if it is missing
#   SONATA_DEPS=no / -NoDeps        never install it, only say that it is missing
#
# sn.exe needs the Visual C++ runtime. When it isn't installed, the script
# offers to install it (with winget, or Microsoft's installer).

param(
    [string]$Version = $env:SONATA_VERSION,
    [string]$Dir = $(if ($env:SONATA_INSTALL) { $env:SONATA_INSTALL } else { Join-Path $HOME '.sonata' }),
    [switch]$NoModifyPath = [bool]$env:SONATA_NO_MODIFY_PATH,
    [switch]$Yes,
    [switch]$NoDeps
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'runsonata/sonata'
$Api = "https://api.github.com/repos/$Repo"

# throw, not exit: under "irm | iex" exit would close the user's terminal.
function Fail($message) {
    throw "sonata install failed: $message"
}

$deps = if ($Yes) { 'yes' } elseif ($NoDeps) { 'no' } elseif ($env:SONATA_DEPS) { $env:SONATA_DEPS.ToLower() } else { 'ask' }
if ($deps -notin 'ask', 'yes', 'no') { Fail "SONATA_DEPS must be ask, yes or no (got '$deps')" }

# platform //////////////////////////////////////

# PROCESSOR_ARCHITEW6432 is set when this is a 32-bit PowerShell on 64-bit Windows.
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
# Asset names look like sonata-<version>-<platform>.zip. Releases from 1.0.0 use
# windows-x64 / windows-arm64; older ones used Windows-AMD64 / Windows-ARM64.
# Each entry is one architecture's suffixes (new first, then old, so -Version
# still works for old tags), in order of preference.
$candidates = switch ($arch) {
    'AMD64' { @(, @('-windows-x64.zip', '-Windows-AMD64.zip')) }
    'ARM64' { @(@('-windows-arm64.zip', '-Windows-ARM64.zip'),
                @('-windows-x64.zip', '-Windows-AMD64.zip')) }   # Windows on ARM runs x64 programs too
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

# The version in an asset name doesn't always match the tag (v0.1.92 shipped
# sonata-0.1.8-*), so match on the platform suffix only.
$asset = $null
foreach ($suffixes in $candidates) {
    foreach ($release in $releases) {
        $asset = $release.assets | Where-Object {
            $name = $_.name
            $suffixes | Where-Object { $name.EndsWith($_, [StringComparison]::Ordinal) }
        } | Select-Object -First 1
        if ($asset) { $tag = $release.tag_name; break }
    }
    if ($asset) { break }
}
if (-not $asset) {
    $looked = ($candidates | ForEach-Object { $_ }) -join ', '
    Fail "no release asset for Windows $arch (looked for: $looked)"
}
if ($arch -eq 'ARM64' -and $asset.name -match '(?i)x64|AMD64') {
    Write-Host '> No Windows ARM64 build; installing the x64 build instead'
}

# download and install //////////////////////////////////////////

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sonata-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    $zip = Join-Path $tmp $asset.name
    Write-Host "> Downloading $($asset.name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing

    $extracted = Join-Path $tmp 'x'
    Expand-Archive -Path $zip -DestinationPath $extracted -Force

    # The archive holds a single sonata-<version>-<platform>\ directory.
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

# libraries ////////////////////////////////////

# sn.exe and snrt.exe are built with MSVC against the shared C runtime, so
# they need the Visual C++ runtime. Windows shows a dialog, not an error, when
# a program misses a DLL, so look for the DLLs before running sn.
$vcArch = if ($asset.name -match '(?i)arm64') { 'arm64' } else { 'x64' }
$vcDlls = 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll'
# A 32-bit PowerShell sees SysWOW64 as System32; Sysnative is the real one.
$system32 = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Join-Path $env:SystemRoot 'Sysnative'
} else {
    Join-Path $env:SystemRoot 'System32'
}
function Get-MissingDlls {
    @($vcDlls | Where-Object { -not (Test-Path (Join-Path $system32 $_)) })
}

# Asks a yes/no question; $null when there is no one to ask.
function Confirm-Install($question) {
    if ($deps -eq 'yes') { return $true }
    if ($deps -eq 'no') { return $false }
    $nonInteractive = [Environment]::GetCommandLineArgs() | Where-Object { $_ -like '-NonI*' }
    if (-not [Environment]::UserInteractive -or $nonInteractive) { return $null }
    try {
        $reply = Read-Host "$question [Y/n]"
    } catch {
        return $null
    }
    return (-not $reply) -or ($reply -match '^[Yy]')
}

$wingetId = "Microsoft.VCRedist.2015+.$vcArch"
$redistUrl = "https://aka.ms/vc14/vc_redist.$vcArch.exe"
$depsNote = $null
$missing = Get-MissingDlls

if ($missing.Count -gt 0) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    $how = if ($winget) { "winget install -e --id $wingetId" } else { "download and run $redistUrl" }

    Write-Host ''
    Write-Host "> Sonata needs the Visual C++ runtime ($vcArch), which isn't installed (missing: $($missing -join ', '))."
    Write-Host "> It can be installed with: $how"
    $answer = Confirm-Install 'Install it now?'

    if ($answer) {
        try {
            if ($winget) {
                & winget install -e --id $wingetId --accept-package-agreements --accept-source-agreements
            } else {
                $redist = Join-Path ([IO.Path]::GetTempPath()) "vc_redist.$vcArch.exe"
                Write-Host "> Downloading $redistUrl"
                Invoke-WebRequest -Uri $redistUrl -OutFile $redist -UseBasicParsing
                # Asks for administrator rights (UAC). 3010 means a restart is
                # wanted, which sn doesn't need; 1638 that a newer one is installed.
                $process = Start-Process -FilePath $redist -ArgumentList '/install', '/passive', '/norestart' -Verb RunAs -Wait -PassThru
                if ($process.ExitCode -notin 0, 1638, 3010) {
                    Write-Warning "the Visual C++ installer exited with code $($process.ExitCode)"
                }
                Remove-Item -Path $redist -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "installing the Visual C++ runtime failed: $_"
        }
        $missing = Get-MissingDlls
    } elseif ($null -eq $answer) {
        Write-Host '> No one to ask; run the script with -Yes, or set SONATA_DEPS=yes, to install it.'
    }

    if ($missing.Count -gt 0) {
        $depsNote = "sn won't start until the Visual C++ runtime is installed: $how"
    }
}

$installed = $null
if (-not $depsNote) {
    $installed = & $sn --version 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -ne 0) { Fail 'installed sn.exe does not run' }
}

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
if ($depsNote) {
    Write-Host "Sonata $tag installed" -ForegroundColor Green
    Write-Host $depsNote
    if ($pathNote) { Write-Host $pathNote }
    return
}
Write-Host "Sonata $tag installed: $installed" -ForegroundColor Green
if ($pathNote) { Write-Host $pathNote }
Write-Host 'Run sn --help to get started.'
