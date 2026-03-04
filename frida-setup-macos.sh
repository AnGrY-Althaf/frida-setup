#!/bin/bash
#
# Frida Setup Script for macOS
#
# This script automatically:
# - Installs Homebrew if not present
# - Installs Python3 and pip if not present (via Homebrew)
# - Sets up Python environment (PATH, ~/Library/Python/x.y/bin, build dependencies)
# - Installs Frida, frida-tools, and objection via pip
# - Handles pip installation issues (--user, --break-system-packages, venv fallback)
# - Downloads Android platform-tools (macOS version) and adds to PATH
# - Auto-detects connected Android device architecture (arm, arm64, x86, x86_64)
# - Downloads the correct frida-server for the detected architecture
# - Pushes frida-server to connected Android device via adb
#
# Usage: ./frida-setup-macos.sh [OPTIONS]
#   -v, --frida-version    Frida version (default: 15.2.2)
#   -t, --tools-version    Frida-tools version (default: 10.4.1)
#   -a, --arch             Android architecture (auto-detect if not specified)
#   -h, --help             Show this help message
#

set -e

# Default versions
FRIDA_VERSION="15.2.2"
FRIDA_TOOLS_VERSION="10.4.1"
ANDROID_ARCH=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Output functions
status()  { echo -e "${CYAN}[*]${NC} $1"; }
success() { echo -e "${GREEN}[+]${NC} $1"; }
error()   { echo -e "${RED}[-]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_TOOLS_PATH="$HOME/platform-tools"
PLATFORM_TOOLS_URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--frida-version)
            FRIDA_VERSION="$2"
            shift 2
            ;;
        -t|--tools-version)
            FRIDA_TOOLS_VERSION="$2"
            shift 2
            ;;
        -a|--arch)
            ANDROID_ARCH="$2"
            shift 2
            ;;
        -h|--help)
            echo "Frida Setup Script for macOS"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -v, --frida-version    Frida version (default: 15.2.2)"
            echo "  -t, --tools-version    Frida-tools version (default: 10.4.1)"
            echo "  -a, --arch             Android architecture: arm, arm64, x86, x86_64"
            echo "                         (auto-detects if not specified)"
            echo "  -h, --help             Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                           # Auto-detect everything"
            echo "  $0 -a arm64                  # Specify architecture"
            echo "  $0 -v 16.0.0 -a arm64        # Specify version and arch"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo ""
echo -e "${MAGENTA}========================================${NC}"
echo -e "${MAGENTA}       Frida Setup Script for macOS    ${NC}"
echo -e "${MAGENTA}========================================${NC}"
echo ""

# ============================================
# Helper Function: Detect shell RC file
# ============================================
get_shell_rc() {
    if [[ "$SHELL" == *"zsh"* ]] || [ -f "$HOME/.zshrc" ]; then
        echo "$HOME/.zshrc"
    elif [ -f "$HOME/.bash_profile" ]; then
        echo "$HOME/.bash_profile"
    elif [ -f "$HOME/.bashrc" ]; then
        echo "$HOME/.bashrc"
    else
        echo "$HOME/.zshrc"   # macOS Catalina+ default is zsh
    fi
}

SHELL_RC="$(get_shell_rc)"

# ============================================
# Helper Function: Install Homebrew
# ============================================
install_homebrew() {
    status "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH for Apple Silicon Macs
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        if ! grep -q "homebrew" "$SHELL_RC" 2>/dev/null; then
            echo "" >> "$SHELL_RC"
            echo "# Homebrew (Apple Silicon)" >> "$SHELL_RC"
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$SHELL_RC"
            success "Added Homebrew to $SHELL_RC"
        fi
    fi
}

# ============================================
# Helper Function: Setup Python Environment
# ============================================
setup_python_environment() {
    status "Setting up Python environment..."

    # Determine Python user lib path on macOS
    PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
    MACOS_PYTHON_BIN="$HOME/Library/Python/$PYTHON_VER/bin"

    # Create it if needed
    if [ ! -d "$MACOS_PYTHON_BIN" ]; then
        mkdir -p "$MACOS_PYTHON_BIN"
    fi

    # Write PATH entries to shell RC once
    if ! grep -q "# Frida Python Environment" "$SHELL_RC" 2>/dev/null; then
        status "Adding Python environment to $SHELL_RC..."
        cat >> "$SHELL_RC" << 'PYENVBLOCK'

# ============================================
# Frida Python Environment
# ============================================

# Add macOS user Python bin to PATH (pip --user installs)
_MACOS_PY_BIN="$HOME/Library/Python/$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)/bin"
if [ -d "$_MACOS_PY_BIN" ]; then
    case ":$PATH:" in
        *":$_MACOS_PY_BIN:"*) ;;
        *) export PATH="$_MACOS_PY_BIN:$PATH" ;;
    esac
fi
unset _MACOS_PY_BIN

# Add platform-tools to PATH
if [ -d "$HOME/platform-tools" ]; then
    case ":$PATH:" in
        *":$HOME/platform-tools:"*) ;;
        *) export PATH="$HOME/platform-tools:$PATH" ;;
    esac
fi
PYENVBLOCK
        success "Python environment added to $SHELL_RC"
    else
        status "Python environment already configured in $SHELL_RC"
    fi

    # Apply to current session
    export PATH="$MACOS_PYTHON_BIN:$PATH"

    # Upgrade pip
    status "Upgrading pip..."
    python3 -m pip install --user --upgrade pip 2>/dev/null || true

    success "Python environment setup complete"
}

# ============================================
# Helper Function: Verify Frida installation
# ============================================
verify_frida_installation() {
    status "Verifying Frida installation..."

    PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
    MACOS_PYTHON_BIN="$HOME/Library/Python/$PYTHON_VER/bin"
    export PATH="$MACOS_PYTHON_BIN:$PATH"

    if command -v frida &> /dev/null; then
        local frida_ver
        frida_ver=$(frida --version 2>/dev/null)
        success "Frida installed: $frida_ver"
        return 0
    fi

    # Try common locations
    local frida_locations=(
        "$MACOS_PYTHON_BIN/frida"
        "/usr/local/bin/frida"
        "/opt/homebrew/bin/frida"
    )

    for loc in "${frida_locations[@]}"; do
        if [ -x "$loc" ]; then
            success "Found frida at: $loc"
            return 0
        fi
    done

    warning "Frida command not found in PATH"
    warning "You may need to restart your terminal or run: source $SHELL_RC"
    return 1
}

# ============================================
# Helper Function: Detect Android Architecture
# ============================================
get_android_architecture() {
    local adb_path=$1
    local abi
    abi=$("$adb_path" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n')

    if [ -z "$abi" ]; then
        return 1
    fi

    status "Detected device ABI: $abi"

    case "$abi" in
        arm64-v8a*)   echo "arm64" ;;
        armeabi-v7a*|armeabi*) echo "arm" ;;
        x86_64*)      echo "x86_64" ;;
        x86*)         echo "x86" ;;
        *)
            warning "Unknown ABI: $abi, defaulting to arm64"
            echo "arm64"
            ;;
    esac
}

# ============================================
# Step 1: Check and Install Homebrew
# ============================================
status "Checking Homebrew..."

if command -v brew &> /dev/null; then
    success "Homebrew is already installed: $(brew --version | head -1)"
else
    warning "Homebrew not found. Installing..."
    install_homebrew
    if ! command -v brew &> /dev/null; then
        error "Homebrew installation failed! Please install manually from https://brew.sh"
        exit 1
    fi
    success "Homebrew installed successfully"
fi

# ============================================
# Step 2: Check and Install Python
# ============================================
status "Checking Python installation..."

PYTHON_CMD=""
for cmd in python3 python; do
    if command -v "$cmd" &> /dev/null; then
        version=$("$cmd" --version 2>&1)
        if [[ "$version" == *"Python 3"* ]]; then
            PYTHON_CMD="$cmd"
            success "Found Python: $version"
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    warning "Python 3 not found. Installing via Homebrew..."
    brew install python
    for cmd in python3 python; do
        if command -v "$cmd" &> /dev/null; then
            version=$("$cmd" --version 2>&1)
            if [[ "$version" == *"Python 3"* ]]; then
                PYTHON_CMD="$cmd"
                success "Python installed: $version"
                break
            fi
        fi
    done

    if [ -z "$PYTHON_CMD" ]; then
        error "Python installation failed!"
        exit 1
    fi
fi

# Check for pip
status "Checking pip installation..."
PIP_CMD=""
for cmd in pip3 pip; do
    if command -v "$cmd" &> /dev/null; then
        PIP_CMD="$cmd"
        success "Found pip: $($cmd --version 2>&1)"
        break
    fi
done

if [ -z "$PIP_CMD" ]; then
    if $PYTHON_CMD -m pip --version &> /dev/null 2>&1; then
        PIP_CMD="$PYTHON_CMD -m pip"
        success "Using pip via python -m pip"
    else
        warning "pip not found. Installing..."
        $PYTHON_CMD -m ensurepip --upgrade 2>/dev/null || brew install python  # python from brew ships pip
        PIP_CMD="$PYTHON_CMD -m pip"
    fi
fi

# ============================================
# Step 2.5: Setup Python Environment
# ============================================
setup_python_environment

# ============================================
# Step 3: Install Frida, frida-tools, objection
# ============================================
status "Installing Frida v$FRIDA_VERSION, frida-tools v$FRIDA_TOOLS_VERSION, and objection..."

INSTALL_SUCCESS=false

# Method 1: pip install --user (preferred, no sudo)
status "Attempting user-level installation..."
if $PIP_CMD install --user frida==$FRIDA_VERSION frida-tools==$FRIDA_TOOLS_VERSION objection 2>/dev/null; then
    INSTALL_SUCCESS=true
    success "Frida tools installed (user-level)!"
fi

# Method 2: pip install --break-system-packages (for newer pip / macOS System Python)
if [ "$INSTALL_SUCCESS" = false ]; then
    status "Trying with --break-system-packages flag..."
    if $PIP_CMD install --user --break-system-packages frida==$FRIDA_VERSION frida-tools==$FRIDA_TOOLS_VERSION objection 2>/dev/null; then
        INSTALL_SUCCESS=true
        success "Frida tools installed (--break-system-packages)!"
    fi
fi

# Method 3: system-level (may need sudo)
if [ "$INSTALL_SUCCESS" = false ]; then
    status "Trying system-level installation..."
    if $PIP_CMD install frida==$FRIDA_VERSION frida-tools==$FRIDA_TOOLS_VERSION objection 2>/dev/null; then
        INSTALL_SUCCESS=true
        success "Frida tools installed (system-level)!"
    fi
fi

# Method 4: Install via Homebrew pipx / virtual environment fallback
if [ "$INSTALL_SUCCESS" = false ]; then
    warning "Standard pip installation failed. Falling back to virtual environment..."

    VENV_PATH="$HOME/.frida-venv"

    if [ -d "$VENV_PATH" ]; then
        rm -rf "$VENV_PATH"
    fi

    $PYTHON_CMD -m venv "$VENV_PATH"

    if [ -f "$VENV_PATH/bin/activate" ]; then
        # shellcheck disable=SC1091
        source "$VENV_PATH/bin/activate"

        pip install --upgrade pip
        if pip install frida==$FRIDA_VERSION frida-tools==$FRIDA_TOOLS_VERSION objection; then
            INSTALL_SUCCESS=true
            success "Frida tools installed in virtual environment: $VENV_PATH"

            # Add venv activation to shell RC
            if ! grep -q "frida-venv" "$SHELL_RC" 2>/dev/null; then
                cat >> "$SHELL_RC" << VENVBLOCK

# Frida Virtual Environment (auto-activate)
if [ -f "$VENV_PATH/bin/activate" ]; then
    source "$VENV_PATH/bin/activate"
fi
VENVBLOCK
                warning "Virtual environment will auto-activate. Restart terminal or run: source $SHELL_RC"
            fi

            # Create symlinks in ~/Library/Python/<ver>/bin
            PYTHON_VER=$($PYTHON_CMD -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            MACOS_PYTHON_BIN="$HOME/Library/Python/$PYTHON_VER/bin"
            mkdir -p "$MACOS_PYTHON_BIN"
            for tool in frida frida-ps frida-trace frida-ls-devices frida-kill frida-discover objection; do
                if [ -f "$VENV_PATH/bin/$tool" ]; then
                    ln -sf "$VENV_PATH/bin/$tool" "$MACOS_PYTHON_BIN/$tool" 2>/dev/null || true
                fi
            done
            success "Created symlinks in $MACOS_PYTHON_BIN"
        fi
    fi
fi

if [ "$INSTALL_SUCCESS" = false ]; then
    error "Failed to install Frida tools after all attempts!"
    error "Please try manually: pip install --user frida frida-tools objection"
    exit 1
fi

# Verify installation
verify_frida_installation

# ============================================
# Step 4: Add Python bin to PATH
# ============================================
status "Checking Python user bin PATH..."

PYTHON_VER=$($PYTHON_CMD -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
MACOS_PYTHON_BIN="$HOME/Library/Python/$PYTHON_VER/bin"

if [ -d "$MACOS_PYTHON_BIN" ]; then
    if ls "$MACOS_PYTHON_BIN"/frida* &> /dev/null 2>&1; then
        success "Found Frida tools in: $MACOS_PYTHON_BIN"

        if [[ ":$PATH:" != *":$MACOS_PYTHON_BIN:"* ]]; then
            export PATH="$MACOS_PYTHON_BIN:$PATH"
            if ! grep -q "$MACOS_PYTHON_BIN" "$SHELL_RC" 2>/dev/null; then
                echo "" >> "$SHELL_RC"
                echo "# Added by Frida setup script" >> "$SHELL_RC"
                echo "export PATH=\"\$PATH:$MACOS_PYTHON_BIN\"" >> "$SHELL_RC"
                success "Added $MACOS_PYTHON_BIN to $SHELL_RC"
            fi
        else
            status "Python bin already in PATH"
        fi
    fi
fi

# ============================================
# Step 5: Download and Install Platform Tools
# ============================================
status "Checking Android Platform Tools..."

ADB_EXE=""
if [ -d "$PLATFORM_TOOLS_PATH" ] && [ -f "$PLATFORM_TOOLS_PATH/adb" ]; then
    success "Platform Tools already installed at: $PLATFORM_TOOLS_PATH"
    ADB_EXE="$PLATFORM_TOOLS_PATH/adb"
elif command -v adb &> /dev/null; then
    success "Found adb in PATH"
    ADB_EXE="adb"
else
    status "Downloading Android Platform Tools (macOS)..."

    # Ensure unzip and curl are available (both are standard on macOS)
    if ! command -v unzip &> /dev/null; then
        brew install unzip
    fi

    TEMP_ZIP="/tmp/platform-tools.zip"
    curl -L -o "$TEMP_ZIP" "$PLATFORM_TOOLS_URL"

    if [ -f "$TEMP_ZIP" ]; then
        success "Downloaded Platform Tools"
        status "Extracting Platform Tools..."
        unzip -q -o "$TEMP_ZIP" -d "$HOME"
        rm -f "$TEMP_ZIP"
        success "Platform Tools extracted to: $PLATFORM_TOOLS_PATH"
        ADB_EXE="$PLATFORM_TOOLS_PATH/adb"
        chmod +x "$ADB_EXE"
    else
        error "Failed to download Platform Tools"
        exit 1
    fi
fi

# Add Platform Tools to PATH
if [ -d "$PLATFORM_TOOLS_PATH" ]; then
    if [[ ":$PATH:" != *":$PLATFORM_TOOLS_PATH:"* ]]; then
        export PATH="$PATH:$PLATFORM_TOOLS_PATH"

        if ! grep -q "$PLATFORM_TOOLS_PATH" "$SHELL_RC" 2>/dev/null; then
            echo "" >> "$SHELL_RC"
            echo "# Added by Frida setup script - Android Platform Tools" >> "$SHELL_RC"
            echo "export PATH=\"\$PATH:$PLATFORM_TOOLS_PATH\"" >> "$SHELL_RC"
            success "Added Platform Tools to $SHELL_RC"
        fi
    else
        status "Platform Tools already in PATH"
    fi
fi

# ============================================
# Step 6: Remove macOS Quarantine from adb
# ============================================
# macOS Gatekeeper quarantines downloaded binaries; remove the attribute so adb runs without popup
status "Removing Gatekeeper quarantine from Platform Tools..."
if [ -d "$PLATFORM_TOOLS_PATH" ]; then
    xattr -cr "$PLATFORM_TOOLS_PATH" 2>/dev/null || true
    success "Quarantine removed from Platform Tools"
fi

# ============================================
# Step 7: Detect Device Architecture & Download Frida Server
# ============================================

# Auto-detect architecture if not specified
if [ -z "$ANDROID_ARCH" ]; then
    status "Detecting Android device architecture..."

    "$ADB_EXE" start-server 2>/dev/null || true

    devices=$("$ADB_EXE" devices 2>/dev/null | grep -w "device" | grep -v "List")

    if [ -n "$devices" ]; then
        ANDROID_ARCH=$(get_android_architecture "$ADB_EXE")
        if [ -n "$ANDROID_ARCH" ]; then
            success "Detected architecture: $ANDROID_ARCH"
        else
            warning "Could not detect architecture, defaulting to arm64"
            ANDROID_ARCH="arm64"
        fi
    else
        warning "No Android device connected. Please specify architecture manually."
        echo ""
        echo -e "${YELLOW}Available architectures:${NC}"
        echo "  1. arm64  (most modern phones)"
        echo "  2. arm    (older 32-bit phones)"
        echo "  3. x86_64 (emulators, some tablets)"
        echo "  4. x86    (older emulators)"
        echo ""
        read -r -p "Select architecture (1-4) or press Enter for arm64: " arch_choice

        case "$arch_choice" in
            1) ANDROID_ARCH="arm64" ;;
            2) ANDROID_ARCH="arm" ;;
            3) ANDROID_ARCH="x86_64" ;;
            4) ANDROID_ARCH="x86" ;;
            *) ANDROID_ARCH="arm64" ;;
        esac
        status "Using architecture: $ANDROID_ARCH"
    fi
fi

# Set Frida server variables
FRIDA_SERVER_FILE="frida-server-$FRIDA_VERSION-android-$ANDROID_ARCH"
FRIDA_SERVER_XZ="$FRIDA_SERVER_FILE.xz"
FRIDA_SERVER_URL="https://github.com/frida/frida/releases/download/$FRIDA_VERSION/$FRIDA_SERVER_XZ"
FRIDA_SERVER_PATH="$SCRIPT_DIR/frida-server"

status "Downloading Frida Server v$FRIDA_VERSION for Android $ANDROID_ARCH..."

if [ -f "$FRIDA_SERVER_PATH" ]; then
    success "Frida Server already exists at: $FRIDA_SERVER_PATH"
else
    # Ensure xz is available (macOS ships without xz; install via brew)
    if ! command -v xz &> /dev/null; then
        status "Installing xz via Homebrew..."
        brew install xz
    fi

    FRIDA_SERVER_XZ_PATH="$SCRIPT_DIR/$FRIDA_SERVER_XZ"

    status "Downloading from: $FRIDA_SERVER_URL"
    curl -L -o "$FRIDA_SERVER_XZ_PATH" "$FRIDA_SERVER_URL"

    if [ -f "$FRIDA_SERVER_XZ_PATH" ]; then
        success "Downloaded Frida Server"
        status "Extracting Frida Server..."

        if command -v xz &> /dev/null; then
            xz -d -k "$FRIDA_SERVER_XZ_PATH"
            mv "$SCRIPT_DIR/$FRIDA_SERVER_FILE" "$FRIDA_SERVER_PATH"
        else
            error "Could not extract .xz file. Please install xz: brew install xz"
            exit 1
        fi

        if [ -f "$FRIDA_SERVER_PATH" ]; then
            success "Extracted Frida Server successfully"
            rm -f "$FRIDA_SERVER_XZ_PATH"
        fi
    else
        error "Failed to download Frida Server"
        exit 1
    fi
fi

# ============================================
# Step 8: Push Frida Server to Android Device
# ============================================
status "Checking for connected Android device..."

devices=$("$ADB_EXE" devices 2>/dev/null | grep -w "device" | grep -v "List")

if [ -n "$devices" ]; then
    success "Found connected Android device(s)"

    if [ -f "$FRIDA_SERVER_PATH" ]; then
        status "Pushing Frida Server to device..."
        "$ADB_EXE" push "$FRIDA_SERVER_PATH" /data/local/tmp/frida-server

        status "Setting permissions..."
        "$ADB_EXE" shell "chmod 755 /data/local/tmp/frida-server"

        success "Frida Server pushed to /data/local/tmp/frida-server"

        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}           Setup Complete!              ${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        echo -e "${YELLOW}To start Frida Server on your device, run:${NC}"
        echo "  adb shell \"/data/local/tmp/frida-server &\""
        echo ""
        echo -e "${YELLOW}Or with root:${NC}"
        echo "  adb shell \"su -c /data/local/tmp/frida-server &\""
        echo ""

        read -r -p "Do you want to start Frida Server now? (y/n): " start_server
        if [[ "$start_server" == "y" || "$start_server" == "Y" ]]; then
            status "Starting Frida Server..."
            "$ADB_EXE" shell "pkill -f frida-server" 2>/dev/null || true
            "$ADB_EXE" shell "/data/local/tmp/frida-server &" &
            sleep 2
            success "Frida Server started!"
            echo ""
            echo -e "${CYAN}Test with: frida-ps -U${NC}"
        fi
    else
        warning "Frida Server file not found. Please run the script again."
    fi
else
    warning "No Android device connected!"
    warning "Please connect your device with USB debugging enabled and run:"
    echo "  adb push frida-server /data/local/tmp/"
    echo "  adb shell \"chmod 755 /data/local/tmp/frida-server\""
    echo "  adb shell \"/data/local/tmp/frida-server &\""
fi

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}            Installation Summary       ${NC}"
echo -e "${CYAN}========================================${NC}"
echo "Frida Version:       $FRIDA_VERSION"
echo "Device Architecture: $ANDROID_ARCH"
echo "Python bin:          Added to PATH ($MACOS_PYTHON_BIN)"
echo "Platform Tools:      $PLATFORM_TOOLS_PATH"
echo "Frida Server:        $FRIDA_SERVER_PATH"
echo ""
warning "Remember to source your shell rc file or open a NEW terminal!"
echo -e "${CYAN}  source $SHELL_RC${NC}"
echo ""
