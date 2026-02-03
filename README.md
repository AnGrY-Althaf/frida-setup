# Frida Auto Setup

Automated setup scripts for [Frida](https://frida.re/) on Windows and Linux. These scripts handle the entire setup process including Python installation, Frida tools, Android platform-tools, and frida-server deployment.

## Features

- **Automatic Python Installation** - Installs Python if not present
- **Python Environment Setup** (Linux) - Handles PATH, `~/.local/bin`, build dependencies, and pip issues
- **Multiple Install Methods** (Linux) - Tries `--user`, system-level, `--break-system-packages`, and venv fallback
- **Frida Tools Installation** - Installs `frida`, `frida-tools`, and `objection` via pip
- **Platform Tools Setup** - Downloads and configures Android platform-tools (adb)
- **Architecture Auto-Detection** - Automatically detects connected Android device architecture
- **Frida Server Deployment** - Downloads correct frida-server version and pushes to device
- **PATH Configuration** - Automatically adds required paths to your environment

## Supported Platforms

| Platform | Script | Status |
|----------|--------|--------|
| Windows 10/11 | `frida-setup.ps1` | ✅ |
| Linux (Debian/Ubuntu) | `frida-setup.sh` | ✅ |
| Linux (Fedora/RHEL) | `frida-setup.sh` | ✅ |
| Linux (Arch) | `frida-setup.sh` | ✅ |
| macOS | - | Coming Soon |

## Quick Start

### Windows

```powershell
# Clone the repository
git clone https://github.com/yourusername/frida-setup.git
cd frida-setup

# Run the script (recommended: Run as Administrator)
.\frida-setup.ps1
```

### Linux

```bash
# Clone the repository
git clone https://github.com/yourusername/frida-setup.git
cd frida-setup

# Make executable and run
chmod +x frida-setup.sh
./frida-setup.sh
```

## Usage

### Windows (PowerShell)

```powershell
# Auto-detect everything (device must be connected)
.\frida-setup.ps1

# Specify architecture manually
.\frida-setup.ps1 -AndroidArch "arm64"

# Custom Frida version
.\frida-setup.ps1 -FridaVersion "16.0.0" -FridaToolsVersion "12.0.0"

# Full custom setup
.\frida-setup.ps1 -FridaVersion "15.2.2" -FridaToolsVersion "10.4.1" -AndroidArch "x86_64"
```

**Parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-FridaVersion` | `15.2.2` | Frida version to install |
| `-FridaToolsVersion` | `10.4.1` | Frida-tools version to install |
| `-AndroidArch` | Auto-detect | Target architecture: `arm`, `arm64`, `x86`, `x86_64` |

### Linux (Bash)

```bash
# Auto-detect everything (device must be connected)
./frida-setup.sh

# Specify architecture manually
./frida-setup.sh -a arm64

# Custom Frida version
./frida-setup.sh -v 16.0.0 -t 12.0.0

# Full custom setup
./frida-setup.sh --frida-version 15.2.2 --tools-version 10.4.1 --arch x86_64

# Show help
./frida-setup.sh --help
```

**Options:**

| Option | Short | Default | Description |
|--------|-------|---------|-------------|
| `--frida-version` | `-v` | `15.2.2` | Frida version to install |
| `--tools-version` | `-t` | `10.4.1` | Frida-tools version to install |
| `--arch` | `-a` | Auto-detect | Target architecture |
| `--help` | `-h` | - | Show help message |

## Android Architecture Guide

| Architecture | Description | Common Devices |
|--------------|-------------|----------------|
| `arm64` | 64-bit ARM | Most modern phones (2016+) |
| `arm` | 32-bit ARM | Older phones, some budget devices |
| `x86_64` | 64-bit x86 | Android emulators, some tablets |
| `x86` | 32-bit x86 | Older emulators |

To manually check your device architecture:
```bash
adb shell getprop ro.product.cpu.abi
```

## What Gets Installed

### Windows

| Component | Location |
|-----------|----------|
| Python | Via winget/Microsoft Store |
| Frida tools | Python Scripts folder (added to PATH) |
| Platform Tools | `Documents\platform-tools` |
| 7-Zip (if needed) | Portable in TEMP or via winget |
| frida-server | Script directory |

### Linux

| Component | Location |
|-----------|----------|
| Python | System package manager |
| Frida tools | `~/.local/bin` (added to PATH) |
| Frida venv (fallback) | `~/.frida-venv` (if pip --user fails) |
| Platform Tools | `~/platform-tools` |
| frida-server | Script directory |

**Note:** On modern Linux distributions with PEP 668, the script may create a virtual environment at `~/.frida-venv` and auto-activate it in your shell configuration.

## Post-Installation

After running the script, you can:

### Test Frida Installation

```bash
# Check Frida version
frida --version

# List processes on connected device
frida-ps -U
```

### Start Frida Server

```bash
# Regular start
adb shell "/data/local/tmp/frida-server &"

# With root (if device is rooted)
adb shell "su -c /data/local/tmp/frida-server &"

# Check if running
adb shell "ps | grep frida"
```

### Use Objection

```bash
# Explore an app
objection -g com.example.app explore

# List activities
android hooking list activities
```

## Troubleshooting

### Windows: "Unrecognized archive format" with tar

Windows `tar.exe` doesn't support `.xz` files. The script automatically downloads 7-Zip portable to handle extraction.

### Windows: Python not found after installation

Open a **new** terminal/PowerShell window. The PATH changes only apply to new sessions.

### Linux: Permission denied

```bash
chmod +x frida-setup.sh
```

### Linux: "externally-managed-environment" error

Modern Linux distributions (Debian 12+, Ubuntu 23.04+, Fedora 38+) use PEP 668 which prevents pip from installing packages system-wide. The script handles this automatically by:

1. First trying `pip install --user`
2. Then trying `pip install --break-system-packages`
3. Finally falling back to a virtual environment at `~/.frida-venv`

If you still have issues:
```bash
# Manual venv setup
python3 -m venv ~/.frida-venv
source ~/.frida-venv/bin/activate
pip install frida frida-tools objection
```

### Linux: Frida command not found after installation

The script adds `~/.local/bin` to your PATH. Apply changes immediately:
```bash
# For bash
source ~/.bashrc

# For zsh
source ~/.zshrc

# Or just add to current session
export PATH="$HOME/.local/bin:$PATH"
```

### Linux: pip install fails with build errors

The script installs build dependencies automatically. If you still have issues:
```bash
# Debian/Ubuntu
sudo apt install python3-dev build-essential libffi-dev libssl-dev

# Fedora/RHEL
sudo dnf install python3-devel gcc libffi-devel openssl-devel

# Arch
sudo pacman -S base-devel python libffi openssl
```

### Device not detected

1. Enable USB debugging on your Android device
2. Connect via USB and accept the debugging prompt
3. Verify with: `adb devices`

### Frida server crashes

Make sure you downloaded the correct architecture. Check with:
```bash
adb shell getprop ro.product.cpu.abi
```

### SELinux blocking frida-server (Linux/Android)

```bash
adb shell "su -c setenforce 0"
```

## Requirements

### Windows
- Windows 10 or later
- PowerShell 5.1+
- USB debugging enabled on Android device

### Linux
- Any modern Linux distribution
- Bash shell
- `sudo` access (for package installation)
- USB debugging enabled on Android device

## Version Compatibility

| Frida Version | frida-tools Version | Notes |
|---------------|---------------------|-------|
| 15.2.2 | 10.4.1 | Default, stable |
| 16.x.x | 12.x.x | Latest features |

Check [Frida Releases](https://github.com/frida/frida/releases) for available versions.

## Security Note

Frida is a powerful dynamic instrumentation toolkit. Use it responsibly and only on devices/applications you own or have permission to test.

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Frida](https://frida.re/) - Dynamic instrumentation toolkit
- [Objection](https://github.com/sensepost/objection) - Runtime mobile exploration toolkit
- [Android Platform Tools](https://developer.android.com/studio/releases/platform-tools) - Google's ADB tools
