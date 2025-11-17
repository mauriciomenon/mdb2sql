# MDB2SQL - Setup Guide for Debian Trixie

**Target OS**: Debian Trixie (testing)
**Last Updated**: 2025-11-16

---

## PREREQUISITES

### Update System
```bash
sudo apt update
sudo apt upgrade -y
```

### Install Essential Build Tools
```bash
sudo apt install -y build-essential curl wget git pkg-config libssl-dev
```

---

## STACK-SPECIFIC SETUP

### GO + WAILS + REACT

#### Install Go 1.21+
```bash
# Download latest Go
wget https://go.dev/dl/go1.23.4.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.23.4.linux-amd64.tar.gz

# Add to PATH
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc
source ~/.bashrc
```

Verify:
```bash
go version  # Should show 1.21+
```

#### Install Node.js 20+ via nvm
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
source ~/.bashrc

nvm install 20
nvm use 20
```

Verify:
```bash
node --version  # Should show v20+
npm --version
```

#### Install Wails Dependencies
```bash
sudo apt install -y \
    libgtk-3-dev \
    libwebkit2gtk-4.0-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    patchelf
```

#### Install Wails CLI
```bash
go install github.com/wailsapp/wails/v2/cmd/wails@latest
```

Verify:
```bash
wails version  # Should show v2.11+
```

#### Build Go/Wails Implementation
```bash
cd go_wails_react
go mod tidy
cd frontend
npm install
cd ..
wails dev
```

**Expected**: Window opens with database viewer showing sample data.

---

### RUST + TAURI + SVELTE

#### Install Rust via rustup
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
```

Verify:
```bash
rustc --version  # Should show 1.70+
cargo --version
```

#### Install Node.js (if not already installed)
See Go/Wails section above.

#### Install Tauri Dependencies
```bash
sudo apt install -y \
    libwebkit2gtk-4.0-dev \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    patchelf \
    libssl-dev
```

#### Build Rust/Tauri Implementation
```bash
cd rust_tauri_svelte
cargo check  # Download deps and verify build
cd ui
npm install
cd ..
cargo tauri dev
```

**Expected**: Window opens with database viewer showing sample data.

---

### PYTHON + PYQT6

#### Install Python 3.11+ and Dev Packages
```bash
sudo apt install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev
```

Verify:
```bash
python3 --version  # Should show 3.11+
pip3 --version
```

#### Install PyQt6 System Dependencies
```bash
sudo apt install -y \
    libxcb-xinerama0 \
    libxcb-cursor0 \
    libegl1 \
    libxkbcommon-x11-0 \
    libdbus-1-3
```

#### Install Poetry (Python dependency manager)
```bash
curl -sSL https://install.python-poetry.org | python3 -
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Verify:
```bash
poetry --version
```

#### Build Python/PyQt6 Implementation
```bash
cd py_qt6
poetry install
poetry run python -m src.main
```

**Alternative without Poetry**:
```bash
cd py_qt6
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python -m src.main
```

**Expected**: Qt window opens with database viewer showing sample data.

---

## LOADING SAMPLE DATABASE

All implementations look for database at:
```
data/sample.duckdb
```

### Option 1: Use Environment Variable
```bash
export MDB2SQL_DB_PATH="/path/to/your/database.duckdb"
```

Add to `~/.bashrc` for persistence:
```bash
echo 'export MDB2SQL_DB_PATH="/path/to/your/database.duckdb"' >> ~/.bashrc
source ~/.bashrc
```

### Option 2: Copy Sample Database
```bash
# Assuming you have a converted DuckDB file
cp /path/to/sample.duckdb data/sample.duckdb
```

---

## COMMON ISSUES

### Wails: "webkit2gtk not found"
**Fix**: Install `libwebkit2gtk-4.0-dev` (see Wails dependencies)

### Tauri: "Failed to load module 'canberra-gtk-module'"
**Fix**: Install `libcanberra-gtk3-module`:
```bash
sudo apt install -y libcanberra-gtk3-module
```

### Python: "Qt platform plugin could not be initialized"
**Fix**: Install missing Qt platform dependencies:
```bash
sudo apt install -y qt6-base-dev libxcb-cursor0
```

### Go: "go: command not found" after install
**Fix**: Source bashrc or restart terminal:
```bash
source ~/.bashrc
```

### Rust: "linker 'cc' not found"
**Fix**: Install build-essential:
```bash
sudo apt install -y build-essential
```

---

## RUNNING TESTS

### Go/Wails
```bash
cd go_wails_react
go test ./...
```

### Rust/Tauri
```bash
cd rust_tauri_svelte
cargo test
```

### Python/PyQt6
```bash
cd py_qt6
poetry run pytest  # If tests implemented
```

---

## BUILDING FOR PRODUCTION

### Go/Wails
```bash
cd go_wails_react
wails build
# Output: build/bin/mdb2sql
```

### Rust/Tauri
```bash
cd rust_tauri_svelte
cargo tauri build
# Output: target/release/bundle/deb/mdb2sql_0.1.0_amd64.deb
```

### Python/PyQt6 (using PyInstaller)
```bash
cd py_qt6
poetry add --group dev pyinstaller
poetry run pyinstaller --onefile --windowed src/main.py
# Output: dist/main
```

---

## DEVELOPMENT WORKFLOW

1. Start implementation in dev mode
2. Make code changes
3. Hot reload updates UI automatically
4. Check console for errors
5. Test with sample database

**Dev Mode Commands**:
```bash
# Go/Wails
cd go_wails_react && wails dev

# Rust/Tauri
cd rust_tauri_svelte && cargo tauri dev

# Python/PyQt6
cd py_qt6 && poetry run python -m src.main
```

---

## PERFORMANCE NOTES FOR DEBIAN

- **GTK3 vs GTK4**: All implementations use GTK3 WebKit (better compatibility)
- **Wayland vs X11**: Both supported, Wayland may have better HiDPI
- **Package managers**: apt-get is faster than apt for scripting
- **Caching**: First cargo/go build is slow, subsequent builds are fast

---

## DEBIAN-SPECIFIC OPTIMIZATIONS

### Enable contrib and non-free repos (if needed)
```bash
echo 'deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware' | sudo tee /etc/apt/sources.list
sudo apt update
```

### Install ccache for faster rebuilds
```bash
sudo apt install -y ccache
echo 'export PATH="/usr/lib/ccache:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

---

**Setup complete. Choose your preferred stack and start development.**
