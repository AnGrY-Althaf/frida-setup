#Requires -Version 5.1
<#
.SYNOPSIS
    Automated Frida Setup Script for Windows
.DESCRIPTION
    This script automatically:
    - Installs Python (via winget, Chocolatey, or Microsoft Store) if not present
    - Installs Frida, frida-tools, and objection via pip
    - Downloads Android platform-tools and adds to PATH
    - Auto-detects connected Android device architecture (arm, arm64, x86, x86_64)
    - Downloads the correct frida-server for the detected architecture
    - Installs 7-Zip portable if needed for .xz extraction
    - Pushes frida-server to connected Android device via adb
.NOTES
    Run this script in PowerShell as Administrator for best results.
    Administrator privileges allow system-wide Python installation.
#>

param(
    [string]$FridaVersion = "15.2.2",
    [string]$FridaToolsVersion = "10.4.1",
    [string]$AndroidArch = ""  # Auto-detect if empty. Options: arm, arm64, x86, x86_64
)

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Status { param($Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Success { param($Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Error { param($Message) Write-Host "[-] $Message" -ForegroundColor Red }
function Write-Warning { param($Message) Write-Host "[!] $Message" -ForegroundColor Yellow }

# ============================================
# Helper: Refresh current-session PATH from registry
# ============================================
function Refresh-EnvironmentPath {
    $machine = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = (@($machine, $user) | Where-Object { $_ }) -join ';'
    Write-Status "Session PATH refreshed from registry."
}

# ============================================
# Helper: Exact PATH token check
# Splits PATH on ';' and does a case-insensitive
# exact match (no substring false-positives).
# ============================================
function Test-PathContains {
    param([string]$PathString, [string]$Dir)
    if (-not $PathString) { return $false }
    $normalized = $Dir.TrimEnd('\')
    foreach ($token in ($PathString -split ';')) {
        if ($token.TrimEnd('\') -ieq $normalized) { return $true }
    }
    return $false
}

# ============================================
# Helper: Safely append a directory to a PATH
# string without leading/trailing semicolons.
# ============================================
function Add-ToPathString {
    param([string]$PathString, [string]$Dir)
    $tokens = @($PathString -split ';' | Where-Object { $_.Trim() -ne '' })
    $tokens += $Dir
    return $tokens -join ';'
}

# ============================================
# Helper: Persist User PATH to registry, verify
# the write, and broadcast WM_SETTINGCHANGE so
# all running processes pick up the change.
# ============================================
function Set-PersistentUserPath {
    param([string]$NewPath)

    Write-Status "Writing updated PATH to registry (HKCU\Environment)..."

    try {
        # Write to registry
        [Environment]::SetEnvironmentVariable('PATH', $NewPath, 'User')

        # Verify the write
        $written = [Environment]::GetEnvironmentVariable('PATH', 'User')
        if ($written -eq $NewPath) {
            Write-Success "Registry write verified successfully."
        } else {
            Write-Warning "Registry value differs from what was written - attempting direct registry write..."
            # Direct registry fallback
            $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            if ($regKey) {
                $regKey.SetValue('PATH', $NewPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                $regKey.Close()
                Write-Success "Direct registry write succeeded."
            }
        }
    } catch {
        Write-Warning "SetEnvironmentVariable failed: $_"
        Write-Status "Attempting direct registry write as fallback..."
        try {
            $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            if ($regKey) {
                $regKey.SetValue('PATH', $NewPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                $regKey.Close()
                Write-Success "Direct registry write succeeded."
            }
        } catch {
            Write-Warning "Direct registry write also failed: $_"
        }
    }

    # Broadcast WM_SETTINGCHANGE so Explorer + new terminals pick up the change immediately
    Write-Status "Broadcasting WM_SETTINGCHANGE to notify running processes..."
    try {
        if (-not ('WinEnv.Broadcaster' -as [type])) {
            Add-Type -Namespace WinEnv -Name Broadcaster -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        [WinEnv.Broadcaster]::SendMessageTimeout(
            [IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment',
            2, 5000, [ref]$result
        ) | Out-Null
        Write-Success "WM_SETTINGCHANGE broadcast sent — new terminals will see updated PATH."
    } catch {
        Write-Warning "WM_SETTINGCHANGE broadcast failed (non-critical): $_"
    }
}

# ============================================
# Helper Function: Broad Python Installation Finder
# Queries Windows Registry (HKLM + HKCU, 32/64-bit)
# then sweeps every common filesystem location.
# Returns List of @{ ExePath; Dir; ScriptsDir; Source }
# ============================================
function Find-AllPythonInstallations {
    $installs = [System.Collections.Generic.List[hashtable]]::new()
    $seenDirs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Inline helper — adds a python.exe candidate if it's Python 3 and not seen yet
    function Register-PythonExe {
        param([string]$ExePath, [string]$Source)
        if (-not $ExePath -or -not (Test-Path $ExePath -PathType Leaf)) { return }
        $dir = Split-Path $ExePath
        if (-not $seenDirs.Add($dir)) { return }   # .Add() returns $false if already present
        try {
            $v = & $ExePath --version 2>&1
            if ($v -match 'Python 3') {
                $script:installs.Add(@{
                    ExePath    = $ExePath
                    Dir        = $dir
                    ScriptsDir = (Join-Path $dir 'Scripts')
                    Source     = $Source
                })
            } else {
                $null = $seenDirs.Remove($dir)   # revert so a later python3.exe can try the same dir
            }
        } catch {}
    }

    # --------------------------------------------------
    # 1. Windows Registry (most authoritative)
    # --------------------------------------------------
    $regRoots = @(
        'HKLM:\SOFTWARE\Python\PythonCore',             # 64-bit installs
        'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore', # 32-bit on 64-bit OS
        'HKCU:\SOFTWARE\Python\PythonCore'              # per-user installs
    )
    foreach ($regRoot in $regRoots) {
        if (-not (Test-Path $regRoot)) { continue }
        foreach ($verKey in (Get-ChildItem $regRoot -ErrorAction SilentlyContinue)) {
            $ipPath = Join-Path $verKey.PSPath 'InstallPath'
            if (-not (Test-Path $ipPath)) { continue }
            $ip  = Get-ItemProperty $ipPath -ErrorAction SilentlyContinue
            $dir = $ip.'(default)'
            if (-not $dir -and $ip.ExecutablePath) { $dir = Split-Path $ip.ExecutablePath }
            if ($dir) {
                Register-PythonExe (Join-Path $dir 'python.exe')  "Registry: $regRoot"
                Register-PythonExe (Join-Path $dir 'python3.exe') "Registry: $regRoot"
            }
        }
    }

    # --------------------------------------------------
    # 2. Filesystem sweep
    # --------------------------------------------------
    # Use [Environment]::GetEnvironmentVariable for names with special chars like '(x86)'
    $progFiles   = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $progFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $appData      = [Environment]::GetEnvironmentVariable('APPDATA')
    $userProfile  = [Environment]::GetEnvironmentVariable('USERPROFILE')

    # Each entry: [rootDir, filter]   filter='' means check rootDir itself
    $locations = @(
        @($localAppData + '\Programs\Python',               'Python*'),   # Standard user installer
        @($progFiles    + '\Python',                        'Python*'),   # All-users (rare prefix)
        @($progFiles,                                       'Python*'),   # e.g. C:\Program Files\Python312
        @($progFilesX86,                                    'Python*'),   # 32-bit on 64-bit OS
        @('C:\',                                            'Python3*'),  # Old-style C:\Python312
        @('C:\',                                            'Python*'),   # Older C:\Python27 etc
        @($userProfile + '\scoop\apps\python\current',     ''),          # Scoop
        @($userProfile + '\scoop\apps\python3\current',    ''),          # Scoop (python3)
        @('C:\tools',                                       'python*'),   # Chocolatey
        @('C:\ProgramData\chocolatey\lib',                  'python*'),   # Chocolatey lib
        @($userProfile + '\anaconda3',                      ''),          # Anaconda
        @($userProfile + '\miniconda3',                     ''),          # Miniconda
        @($userProfile + '\mambaforge',                     ''),          # Mambaforge
        @('C:\ProgramData\Anaconda3',                       ''),          # System Anaconda
        @('C:\ProgramData\Miniconda3',                      ''),          # System Miniconda
        @($userProfile + '\.conda\envs',                   '*'),          # Conda envs
        @($userProfile + '\.pyenv\pyenv-win\versions',     '*'),          # pyenv-win
        @($appData     + '\Python',                         'Python*')    # Roaming pip --user
    )

    foreach ($loc in $locations) {
        $root   = $loc[0]
        $filter = $loc[1]
        if (-not $root -or -not (Test-Path $root)) { continue }

        if ($filter -eq '') {
            # root is itself a Python install directory
            Register-PythonExe (Join-Path $root 'python.exe')  "Filesystem: $root"
            Register-PythonExe (Join-Path $root 'python3.exe') "Filesystem: $root"
        } else {
            $subdirs = Get-ChildItem $root -Filter $filter -Directory -ErrorAction SilentlyContinue |
                       Sort-Object Name -Descending
            foreach ($sub in $subdirs) {
                Register-PythonExe (Join-Path $sub.FullName 'python.exe')  "Filesystem: $($sub.FullName)"
                Register-PythonExe (Join-Path $sub.FullName 'python3.exe') "Filesystem: $($sub.FullName)"
            }
        }
    }

    return $installs
}

# Configuration
$DocumentsFolder = [Environment]::GetFolderPath("MyDocuments")
$PlatformToolsPath = Join-Path $DocumentsFolder "platform-tools"
$CurrentFolder = $PSScriptRoot
if (-not $CurrentFolder) { $CurrentFolder = Get-Location }
$PlatformToolsURL = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
$PlatformToolsZip = Join-Path $env:TEMP "platform-tools.zip"
$7ZipPortablePath = Join-Path $env:TEMP "7za.exe"

# ============================================
# Helper Function: Get or Install 7-Zip
# ============================================
function Get-7ZipPath {
    # Check if 7-Zip is already installed
    $7zipLocations = @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe"
    )

    foreach ($loc in $7zipLocations) {
        if (Test-Path $loc) {
            return $loc
        }
    }

    # Check if 7za portable exists in temp
    if (Test-Path $7ZipPortablePath) {
        return $7ZipPortablePath
    }

    # Try to find 7z in PATH
    try {
        $cmd = Get-Command 7z -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    } catch { }

    return $null
}

function Install-7ZipPortable {
    Write-Status "Downloading 7-Zip portable for .xz extraction..."

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Download 7-Zip standalone console version (7zr.exe supports .xz)
        $7zrUrl = "https://github.com/ip7z/7zip/releases/download/24.08/7zr.exe"

        Invoke-WebRequest -Uri $7zrUrl -OutFile $7ZipPortablePath -UseBasicParsing
        if (Test-Path $7ZipPortablePath) {
            Write-Success "Downloaded 7-Zip portable"
            return $7ZipPortablePath
        }
    } catch {
        Write-Warning "Failed to download 7-Zip portable: $_"
    }

    return $null
}

# ============================================
# Helper Function: Detect Android Architecture
# ============================================
function Get-AndroidArchitecture {
    param([string]$AdbPath)

    try {
        $abi = & $AdbPath shell getprop ro.product.cpu.abi 2>&1
        $abi = $abi.Trim()

        Write-Status "Detected device ABI: $abi"

        # Map Android ABI to Frida architecture names
        switch -Regex ($abi) {
            "^arm64-v8a" { return "arm64" }
            "^armeabi-v7a" { return "arm" }
            "^armeabi" { return "arm" }
            "^x86_64" { return "x86_64" }
            "^x86" { return "x86" }
            default {
                Write-Warning "Unknown ABI: $abi, defaulting to arm64"
                return "arm64"
            }
        }
    } catch {
        Write-Warning "Could not detect device architecture: $_"
        return $null
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "       Frida Setup Script for Windows  " -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

# ============================================
# Step 1: Check and Install Python
# ============================================
Write-Status "Checking Python installation..."

function Find-Python {
    # 1. Try commands already in PATH (python3 first, then python, then py launcher)
    foreach ($cmd in @('python3', 'python', 'py')) {
        try {
            $v = & $cmd --version 2>&1
            if ($v -match 'Python 3') { return @{ Command = $cmd; Version = $v } }
        } catch { continue }
    }

    # 2. Broad registry + filesystem scan (handles any broken/missing PATH)
    Write-Status "Python not in PATH — running broad installation scan..."
    $all = Find-AllPythonInstallations
    if ($all.Count -gt 0) {
        # Pick the highest version (sort by exe directory name descending)
        $best = $all | Sort-Object { $_.Dir } -Descending | Select-Object -First 1
        if ($env:PATH -notlike "*$($best.Dir)*") {
            $env:PATH = "$($best.Dir);$env:PATH"
            Write-Status "Injected Python dir into session PATH: $($best.Dir) [$($best.Source)]"
        }
        $v = & $best.ExePath --version 2>&1
        return @{ Command = $best.ExePath; Version = $v }
    }

    return $null
}

function Install-Python {
    Write-Status "Python not found. Attempting to install Python..."

    # Method 1: Try winget (Windows Package Manager)
    $wingetAvailable = $false
    try {
        $wingetVersion = winget --version 2>&1
        if ($wingetVersion -match "\d+\.\d+") {
            $wingetAvailable = $true
        }
    } catch { }

    if ($wingetAvailable) {
        Write-Status "Installing Python via winget..."
        try {
            winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Python installed via winget!"
                # Refresh PATH
                $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
                return $true
            }
        } catch {
            Write-Warning "winget installation failed: $_"
        }
    }

    # Method 2: Try Chocolatey
    $chocoAvailable = $false
    try {
        $chocoVersion = choco --version 2>&1
        if ($chocoVersion -match "\d+\.\d+") {
            $chocoAvailable = $true
        }
    } catch { }

    if ($chocoAvailable) {
        Write-Status "Installing Python via Chocolatey..."
        try {
            choco install python -y
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Python installed via Chocolatey!"
                $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
                return $true
            }
        } catch {
            Write-Warning "Chocolatey installation failed: $_"
        }
    }

    # Method 3: Install from Microsoft Store using winget
    Write-Status "Installing Python from Microsoft Store..."

    if ($wingetAvailable) {
        try {
            # Install Python 3.12 from Microsoft Store using winget
            winget install "Python 3.12" --source msstore --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Python installed from Microsoft Store!"
                $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
                return $true
            }
        } catch {
            Write-Warning "Microsoft Store installation via winget failed: $_"
        }
    }

    # Method 4: Open Microsoft Store directly as fallback
    Write-Warning "Automatic installation failed. Opening Microsoft Store..."
    try {
        # Open Microsoft Store to Python 3.12 page
        Start-Process "ms-windows-store://pdp/?productid=9NCVDN91XZQP"
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "  Microsoft Store opened for Python    " -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Please install Python 3.12 from the Microsoft Store," -ForegroundColor White
        Write-Host "then run this script again." -ForegroundColor White
        Write-Host ""

        $waitForInstall = Read-Host "Press Enter after installing Python to continue, or 'q' to quit"
        if ($waitForInstall -eq 'q') {
            return $false
        }

        # Refresh PATH and check again
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")

        # Check if Python is now available
        $pythonCheck = Find-Python
        if ($pythonCheck) {
            return $true
        }

        return $false
    } catch {
        Write-Error "Failed to open Microsoft Store: $_"
        Write-Warning "Please install Python manually from Microsoft Store"
        Write-Warning "Search for 'Python 3.12' in Microsoft Store"
        return $false
    }
}

$pythonInfo = Find-Python

if (-not $pythonInfo) {
    $installed = Install-Python

    if ($installed) {
        # Refresh PATH from registry so newly added entries are visible, then scan again
        Write-Status "Refreshing PATH from registry after Python installation..."
        Refresh-EnvironmentPath
        Start-Sleep -Seconds 2
        $pythonInfo = Find-Python
    }

    if (-not $pythonInfo) {
        Write-Error "Python installation failed or Python not found in PATH!"
        Write-Warning "Please install Python manually from https://www.python.org/downloads/"
        Write-Warning "Make sure to check 'Add Python to PATH' during installation"
        Write-Warning "Then run this script again."
        exit 1
    }
}

$pythonCmd = $pythonInfo.Command
Write-Success "Found Python: $($pythonInfo.Version)"

# Get pip command
$pipCmd = $null
$pipPaths = @("pip", "pip3", "$pythonCmd -m pip")

foreach ($cmd in $pipPaths) {
    try {
        if ($cmd -match "-m pip") {
            $result = Invoke-Expression "$cmd --version" 2>&1
        } else {
            $result = & $cmd --version 2>&1
        }
        if ($result -match "pip \d+") {
            $pipCmd = $cmd
            Write-Success "Found pip: $result"
            break
        }
    } catch {
        continue
    }
}

if (-not $pipCmd) {
    Write-Error "pip is not installed!"
    Write-Warning "Installing pip..."
    & $pythonCmd -m ensurepip --upgrade
    $pipCmd = "$pythonCmd -m pip"
}

# ============================================
# Step 2: Install Frida, frida-tools, objection
# ============================================
Write-Status "Installing Frida v$FridaVersion, frida-tools v$FridaToolsVersion, and objection..."

try {
    if ($pipCmd -match "-m pip") {
        Invoke-Expression "$pipCmd install frida==$FridaVersion frida-tools==$FridaToolsVersion objection"
    } else {
        & $pipCmd install frida==$FridaVersion frida-tools==$FridaToolsVersion objection
    }
    Write-Success "Frida tools installed successfully!"
} catch {
    Write-Error "Failed to install Frida tools: $_"
    exit 1
}

# ============================================
# Step 3: Broad Python PATH Setup
# Finds every Python installation on the system
# and adds its root dir + Scripts dir to PATH.
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "   Step 3: Python PATH Configuration   " -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""
Write-Status "Scanning for all Python installations on this system..."

$allPythonInstalls = Find-AllPythonInstallations

# --- pip --user-base (may be outside install dir, e.g. on MS Store Python) ---
try {
    $userBase = & $pythonCmd -m site --user-base 2>$null
    if ($userBase) {
        $userScripts = Join-Path $userBase 'Scripts'
        if (Test-Path $userScripts) {
            Write-Status "[pip --user-base] Scripts dir: $userScripts"
            $allPythonInstalls.Add(@{
                ExePath    = $pythonCmd
                Dir        = $userBase
                ScriptsDir = $userScripts
                Source     = 'pip --user-base'
            })
        }
    }
} catch {}

# --- Microsoft Store Python (Scripts inside LocalCache, not the install root) ---
$msStorePkgs = Get-ChildItem "$env:LOCALAPPDATA\Packages" `
               -Filter 'PythonSoftwareFoundation.Python*' -Directory -ErrorAction SilentlyContinue
foreach ($pkg in $msStorePkgs) {
    $pattern  = Join-Path $pkg.FullName 'LocalCache\local-packages\Python*\Scripts'
    $resolved = Get-ChildItem $pattern -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($resolved) {
        Write-Status "[MS Store] Scripts dir: $($resolved.FullName)"
        $allPythonInstalls.Add(@{
            ExePath    = ''
            Dir        = $resolved.FullName
            ScriptsDir = $resolved.FullName
            Source     = "MS Store: $($pkg.Name)"
        })
    }
}

# --- Summary of discoveries ---
Write-Host ""
if ($allPythonInstalls.Count -eq 0) {
    Write-Warning "No Python installations found by broad scan."
    Write-Warning "PATH may need to be updated manually."
} else {
    Write-Success "Found $($allPythonInstalls.Count) Python installation(s):"
    foreach ($inst in $allPythonInstalls) {
        Write-Host "    Source : $($inst.Source)" -ForegroundColor Cyan
        Write-Host "    Dir    : $($inst.Dir)" -ForegroundColor White
        Write-Host "    Scripts: $($inst.ScriptsDir)" -ForegroundColor White
        Write-Host ""
    }
}

# --- Snapshot current PATH state ---
$machinePath     = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
$currentUserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if (-not $currentUserPath) { $currentUserPath = '' }

Write-Host "" 
Write-Host "--- Current PATH Snapshot ---" -ForegroundColor DarkCyan
Write-Host "Machine PATH entries:" -ForegroundColor DarkCyan
($machinePath -split ';' | Where-Object { $_ }) | ForEach-Object { Write-Host "  [M] $_" -ForegroundColor DarkGray }
Write-Host "User PATH entries:" -ForegroundColor DarkCyan
if ($currentUserPath) {
    ($currentUserPath -split ';' | Where-Object { $_ }) | ForEach-Object { Write-Host "  [U] $_" -ForegroundColor DarkGray }
} else {
    Write-Host "  [U] (empty)" -ForegroundColor DarkGray
}
Write-Host ""

$pathsAdded    = [System.Collections.Generic.List[string]]::new()
$pathsSkipped  = [System.Collections.Generic.List[string]]::new()

foreach ($inst in $allPythonInstalls) {
    Write-Status "Processing: $($inst.Source)"

    foreach ($candidate in @($inst.Dir, $inst.ScriptsDir)) {
        if (-not $candidate -or -not (Test-Path $candidate)) {
            if ($candidate) {
                Write-Host "    [SKIP] Does not exist: $candidate" -ForegroundColor DarkGray
            }
            continue
        }

        $inMachine = Test-PathContains -PathString $machinePath     -Dir $candidate
        $inUser    = Test-PathContains -PathString $currentUserPath  -Dir $candidate
        $inSession = Test-PathContains -PathString $env:PATH         -Dir $candidate

        # Always inject into the current session
        if (-not $inSession) {
            $env:PATH = "$candidate;$env:PATH"
            Write-Host "    [SESSION+] $candidate" -ForegroundColor Green
        } else {
            Write-Host "    [SESSION ] Already in session PATH: $candidate" -ForegroundColor DarkGray
        }

        if ($inMachine) {
            Write-Host "    [SKIP-M ] Already in Machine PATH: $candidate" -ForegroundColor DarkGray
            $pathsSkipped.Add($candidate) | Out-Null
        } elseif ($inUser) {
            Write-Host "    [SKIP-U ] Already in User PATH: $candidate" -ForegroundColor DarkGray
            $pathsSkipped.Add($candidate) | Out-Null
        } else {
            # Safe append: no leading/trailing semicolons
            $currentUserPath = Add-ToPathString -PathString $currentUserPath -Dir $candidate
            $pathsAdded.Add($candidate) | Out-Null
            Write-Host "    [ADD+   ] Queued for User PATH: $candidate" -ForegroundColor Yellow
        }
    }

    # Report Frida tools in this installation's Scripts dir
    if ($inst.ScriptsDir -and (Test-Path $inst.ScriptsDir)) {
        $fridaExe = Get-ChildItem $inst.ScriptsDir -Filter 'frida*' -ErrorAction SilentlyContinue
        if ($fridaExe) {
            Write-Success "    [FRIDA ] Found: $($fridaExe.Name -join ', ') in $($inst.ScriptsDir)"
        }
    }
    Write-Host ""
}

# --- Persist changes ---
Write-Host "--- PATH Update Summary ---" -ForegroundColor DarkCyan
Write-Host "  Paths already present (skipped): $($pathsSkipped.Count)" -ForegroundColor DarkGray
Write-Host "  New paths to persist           : $($pathsAdded.Count)" -ForegroundColor $(if ($pathsAdded.Count -gt 0) { 'Yellow' } else { 'DarkGray' })
Write-Host ""

if ($pathsAdded.Count -gt 0) {
    Write-Host "  Paths being added to User PATH:" -ForegroundColor Yellow
    foreach ($p in $pathsAdded) { Write-Host "    + $p" -ForegroundColor Yellow }
    Write-Host ""

    # Sanity-check PATH length (Windows hard limit is 32767 chars; warn above 4096)
    if ($currentUserPath.Length -gt 4096) {
        Write-Warning "User PATH is now $($currentUserPath.Length) chars. Consider cleaning up old entries."
    }

    Set-PersistentUserPath -NewPath $currentUserPath

    # Verify by reading back from registry
    Write-Host ""
    Write-Status "Verifying final User PATH entries in registry:"
    $finalPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    foreach ($p in $pathsAdded) {
        if (Test-PathContains -PathString $finalPath -Dir $p) {
            Write-Host "    [OK] $p" -ForegroundColor Green
        } else {
            Write-Host "    [MISSING] $p  <-- NOT found in registry after write!" -ForegroundColor Red
        }
    }
} else {
    Write-Success "All Python paths are already present in PATH. Nothing to persist."
}

Write-Host ""
# Final registry-level PATH refresh for this session
Refresh-EnvironmentPath

# ============================================
# Step 4: Download and Install Platform Tools
# ============================================
Write-Status "Checking Android Platform Tools..."

if (Test-Path $PlatformToolsPath) {
    $adbPath = Join-Path $PlatformToolsPath "adb.exe"
    if (Test-Path $adbPath) {
        Write-Success "Platform Tools already installed at: $PlatformToolsPath"
    } else {
        Write-Warning "Platform Tools folder exists but adb.exe not found. Re-downloading..."
        Remove-Item $PlatformToolsPath -Recurse -Force
    }
}

if (-not (Test-Path (Join-Path $PlatformToolsPath "adb.exe"))) {
    Write-Status "Downloading Android Platform Tools..."

    try {
        # Use TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Invoke-WebRequest -Uri $PlatformToolsURL -OutFile $PlatformToolsZip -UseBasicParsing
        Write-Success "Downloaded Platform Tools"

        Write-Status "Extracting Platform Tools to Documents folder..."
        Expand-Archive -Path $PlatformToolsZip -DestinationPath $DocumentsFolder -Force
        Remove-Item $PlatformToolsZip -Force
        Write-Success "Platform Tools extracted to: $PlatformToolsPath"
    } catch {
        Write-Error "Failed to download Platform Tools: $_"
        exit 1
    }
}

# Add Platform Tools to PATH
if (-not $currentUserPath.Contains($PlatformToolsPath)) {
    $currentUserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $newPath = $currentUserPath.TrimEnd(';') + ";$PlatformToolsPath"
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Write-Success "Added Platform Tools to USER PATH"
    $env:PATH = $env:PATH + ";$PlatformToolsPath"
} else {
    Write-Status "Platform Tools already in USER PATH"
}

# ============================================
# Step 5: Detect Device Architecture & Download Frida Server
# ============================================
$adbExe = Join-Path $PlatformToolsPath "adb.exe"
if (-not (Test-Path $adbExe)) {
    $adbExe = "adb"  # Try PATH
}

# Auto-detect architecture if not specified
if (-not $AndroidArch) {
    Write-Status "Detecting Android device architecture..."

    try {
        $devices = & $adbExe devices 2>&1
        $connectedDevices = $devices | Select-String -Pattern "device$" | Where-Object { $_ -notmatch "List" }

        if ($connectedDevices) {
            $detectedArch = Get-AndroidArchitecture -AdbPath $adbExe
            if ($detectedArch) {
                $AndroidArch = $detectedArch
                Write-Success "Detected architecture: $AndroidArch"
            } else {
                Write-Warning "Could not detect architecture, defaulting to arm64"
                $AndroidArch = "arm64"
            }
        } else {
            Write-Warning "No Android device connected. Please specify architecture manually."
            Write-Host ""
            Write-Host "Available architectures:" -ForegroundColor Yellow
            Write-Host "  1. arm64  (most modern phones)" -ForegroundColor White
            Write-Host "  2. arm    (older 32-bit phones)" -ForegroundColor White
            Write-Host "  3. x86_64 (emulators, some tablets)" -ForegroundColor White
            Write-Host "  4. x86    (older emulators)" -ForegroundColor White
            Write-Host ""

            $archChoice = Read-Host "Select architecture (1-4) or press Enter for arm64"
            switch ($archChoice) {
                "1" { $AndroidArch = "arm64" }
                "2" { $AndroidArch = "arm" }
                "3" { $AndroidArch = "x86_64" }
                "4" { $AndroidArch = "x86" }
                default { $AndroidArch = "arm64" }
            }
            Write-Status "Using architecture: $AndroidArch"
        }
    } catch {
        Write-Warning "Could not communicate with adb. Defaulting to arm64."
        $AndroidArch = "arm64"
    }
}

# Set Frida server variables based on detected/selected architecture
$FridaServerFile = "frida-server-$FridaVersion-android-$AndroidArch"
$FridaServerXZ = "$FridaServerFile.xz"
$FridaServerURL = "https://github.com/frida/frida/releases/download/$FridaVersion/$FridaServerXZ"

Write-Status "Downloading Frida Server v$FridaVersion for Android $AndroidArch..."

$fridaServerPath = Join-Path $CurrentFolder "frida-server"
$fridaServerXZPath = Join-Path $CurrentFolder $FridaServerXZ

if (Test-Path $fridaServerPath) {
    Write-Success "Frida Server already exists at: $fridaServerPath"
} else {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Write-Status "Downloading from: $FridaServerURL"
        Invoke-WebRequest -Uri $FridaServerURL -OutFile $fridaServerXZPath -UseBasicParsing
        Write-Success "Downloaded Frida Server"

        # Extract .xz file - Windows tar does NOT support .xz, must use 7-Zip
        Write-Status "Extracting Frida Server..."

        # Get or install 7-Zip
        $7zipPath = Get-7ZipPath

        if (-not $7zipPath) {
            # Try to install 7-Zip portable
            $7zipPath = Install-7ZipPortable
        }

        if (-not $7zipPath) {
            # Try to install via winget
            Write-Status "Trying to install 7-Zip via winget..."
            try {
                winget install 7zip.7zip --accept-package-agreements --accept-source-agreements 2>$null
                Start-Sleep -Seconds 2
                $7zipPath = Get-7ZipPath
            } catch { }
        }

        if ($7zipPath) {
            Write-Status "Using 7-Zip: $7zipPath"
            $extractResult = & $7zipPath x $fridaServerXZPath -o"$CurrentFolder" -y 2>&1
            if ($LASTEXITCODE -eq 0) {
                # Rename extracted file to frida-server
                $extractedFile = Join-Path $CurrentFolder $FridaServerFile
                if (Test-Path $extractedFile) {
                    Rename-Item $extractedFile "frida-server" -Force
                }
                Write-Success "Extracted Frida Server successfully"

                # Clean up .xz file
                Remove-Item $fridaServerXZPath -Force -ErrorAction SilentlyContinue
            } else {
                Write-Error "7-Zip extraction failed: $extractResult"
            }
        } else {
            Write-Error "Could not find or install 7-Zip!"
            Write-Host ""
            Write-Host "Please install 7-Zip manually:" -ForegroundColor Yellow
            Write-Host "  1. Download from https://www.7-zip.org/" -ForegroundColor White
            Write-Host "  2. Install it" -ForegroundColor White
            Write-Host "  3. Run this script again" -ForegroundColor White
            Write-Host ""
            Write-Host "Or manually extract:" -ForegroundColor Yellow
            Write-Host "  File: $fridaServerXZPath" -ForegroundColor White
            Write-Host "  Rename extracted file to: frida-server" -ForegroundColor White
        }

    } catch {
        Write-Error "Failed to download Frida Server: $_"
        exit 1
    }
}

# ============================================
# Step 6: Push Frida Server to Android Device
# ============================================
Write-Status "Checking for connected Android device..."

try {
    $devices = & $adbExe devices 2>&1
    $connectedDevices = $devices | Select-String -Pattern "device$" | Where-Object { $_ -notmatch "List" }

    if ($connectedDevices) {
        Write-Success "Found connected Android device(s)"

        if (Test-Path $fridaServerPath) {
            Write-Status "Pushing Frida Server to device..."
            & $adbExe push $fridaServerPath /data/local/tmp/frida-server

            Write-Status "Setting permissions..."
            & $adbExe shell "chmod 755 /data/local/tmp/frida-server"

            Write-Success "Frida Server pushed to /data/local/tmp/frida-server"

            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "           Setup Complete!              " -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "To start Frida Server on your device, run:" -ForegroundColor Yellow
            Write-Host "  adb shell `"/data/local/tmp/frida-server &`"" -ForegroundColor White
            Write-Host ""
            Write-Host "Or with root:" -ForegroundColor Yellow
            Write-Host "  adb shell `"su -c /data/local/tmp/frida-server &`"" -ForegroundColor White
            Write-Host ""

            $startServer = Read-Host "Do you want to start Frida Server now? (y/n)"
            if ($startServer -eq 'y' -or $startServer -eq 'Y') {
                Write-Status "Starting Frida Server..."

                # Kill any existing frida-server process
                & $adbExe shell "pkill -f frida-server" 2>$null

                # Start frida-server in background
                Start-Process -FilePath $adbExe -ArgumentList "shell", "/data/local/tmp/frida-server &" -NoNewWindow

                Start-Sleep -Seconds 2
                Write-Success "Frida Server started!"
                Write-Host ""
                Write-Host "Test with: frida-ps -U" -ForegroundColor Cyan
            }
        } else {
            Write-Warning "Frida Server file not found. Please extract it manually and run the script again."
        }
    } else {
        Write-Warning "No Android device connected!"
        Write-Warning "Please connect your device with USB debugging enabled and run:"
        Write-Host "  adb push frida-server /data/local/tmp/" -ForegroundColor White
        Write-Host "  adb shell `"chmod 755 /data/local/tmp/frida-server`"" -ForegroundColor White
        Write-Host "  adb shell `"/data/local/tmp/frida-server &`"" -ForegroundColor White
    }
} catch {
    Write-Warning "Could not communicate with adb: $_"
    Write-Warning "Make sure your device is connected with USB debugging enabled"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "            Installation Summary       " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Frida Version:      $FridaVersion" -ForegroundColor White
Write-Host "Device Architecture: $AndroidArch" -ForegroundColor White
Write-Host "Python Scripts:      Added to USER PATH" -ForegroundColor White
Write-Host "Platform Tools:      $PlatformToolsPath" -ForegroundColor White
Write-Host "Frida Server:        $fridaServerPath" -ForegroundColor White
Write-Host ""
Write-Warning "Remember to open a NEW terminal to use the updated PATH!"
Write-Host ""
