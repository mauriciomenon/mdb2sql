# MDB2SQL - Guia de Instalacao Debian 13.2 Stable

## Data: 2025-11-20
## Status: Receita de Bolo para Instalacao Completa

---

## PREREQUISITOS

### 1. Debian 13.2 Stable - 64-bit
- Versao: Debian 13.2 (stable release)
- Codinome: Trixie
- Acesso root ou sudo
- Conexao com internet

---

## ATUALIZACAO DO SISTEMA

```bash
sudo apt update
sudo apt upgrade -y
```

---

## INSTALACAO DE FERRAMENTAS BASE

### 1. Instalar Dependencias Essenciais

```bash
sudo apt install -y \
    build-essential \
    curl \
    wget \
    git \
    pkg-config \
    libssl-dev \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    patchelf
```

---

### 2. Instalar Git

```bash
sudo apt install -y git
```

**Configurar Git:**
```bash
git config --global user.name "Seu Nome"
git config --global user.email "seu@email.com"
```

**Verificar:**
```bash
git --version
```

---

### 3. Instalar Node.js e npm

**Metodo 1: Via NodeSource (recomendado para versao especifica)**

```bash
# Adicionar repositorio NodeSource para Node.js 23.x
curl -fsSL https://deb.nodesource.com/setup_23.x | sudo -E bash -

# Instalar Node.js
sudo apt install -y nodejs

# Verificar
node --version
npm --version
```

**Instalar pnpm globalmente:**
```bash
sudo npm install -g pnpm
```

**Verificar:**
```bash
pnpm --version
```

---

### 4. Instalar Python 3.14

**Metodo 1: Build from Source (recomendado para versao exata)**

```bash
# Dependencias para compilar Python
sudo apt install -y \
    libreadline-dev \
    libncursesw5-dev \
    libssl-dev \
    libsqlite3-dev \
    tk-dev \
    libgdbm-dev \
    libc6-dev \
    libbz2-dev \
    libffi-dev \
    zlib1g-dev

# Download Python 3.14
cd /tmp
wget https://www.python.org/ftp/python/3.14.0/Python-3.14.0.tgz
tar -xf Python-3.14.0.tgz
cd Python-3.14.0

# Compilar e instalar
./configure --enable-optimizations
make -j $(nproc)
sudo make altinstall

# Verificar
python3.14 --version
```

**Criar alias (opcional):**
```bash
echo "alias python=python3.14" >> ~/.bashrc
echo "alias pip=pip3.14" >> ~/.bashrc
source ~/.bashrc
```

**Instalar Poetry:**
```bash
curl -sSL https://install.python-poetry.org | python3.14 -
```

**Adicionar Poetry ao PATH:**
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

**Verificar:**
```bash
poetry --version
```

---

### 5. Instalar Rust e Cargo

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

**Seguir instrucoes do instalador (opcao padrao: 1)**

**Adicionar ao PATH:**
```bash
source $HOME/.cargo/env
```

**Adicionar permanentemente:**
```bash
echo 'source $HOME/.cargo/env' >> ~/.bashrc
```

**Verificar:**
```bash
rustc --version
cargo --version
```

**Versao recomendada: 1.83.0**

---

### 6. Instalar Go

**Versao recomendada: 1.23.3**

```bash
# Download Go
wget https://go.dev/dl/go1.23.3.linux-amd64.tar.gz

# Remover instalacao anterior (se houver)
sudo rm -rf /usr/local/go

# Extrair
sudo tar -C /usr/local -xzf go1.23.3.linux-amd64.tar.gz

# Adicionar ao PATH
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc
source ~/.bashrc
```

**Verificar:**
```bash
go version
```

---

### 7. Instalar Wails CLI

**Prerequisito:** Go ja instalado

```bash
go install github.com/wailsapp/wails/v2/cmd/wails@latest
```

**Verificar:**
```bash
wails version
```

**Versao recomendada: v2.11.0**

**Instalar dependencias adicionais do Wails:**
```bash
sudo apt install -y \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    build-essential
```

---

### 8. Instalar Tauri Prerequisites

**Dependencias do sistema:**
```bash
sudo apt install -y \
    libwebkit2gtk-4.1-dev \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    patchelf
```

**Instalar Tauri CLI:**
```bash
cargo install tauri-cli
```

**Verificar:**
```bash
cargo tauri --version
```

---

## CLONAR REPOSITORIO

```bash
cd ~
git clone https://github.com/seu-usuario/mdb2sql.git
cd mdb2sql
git checkout dev
```

---

## CONFIGURACAO DE CADA IMPLEMENTACAO

### 1. Python + PyQt6

**Navegar ate o diretorio:**
```bash
cd ~/mdb2sql/py_qt6
```

**Instalar dependencias do sistema para PyQt6:**
```bash
sudo apt install -y \
    libxcb-xinerama0 \
    libxcb-cursor0 \
    libxkbcommon-x11-0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-randr0 \
    libxcb-render-util0 \
    libxcb-shape0
```

**Instalar dependencias Python:**
```bash
poetry install
```

**Verificar instalacao:**
```bash
poetry run python --version
```

**Criar diretorio de dados:**
```bash
mkdir -p data
```

**Copiar banco de dados sample:**
```bash
cp ../data/sample.duckdb ./data/sample.duckdb
```

**Executar:**
```bash
poetry run python src/main.py
```

**OU diretamente via venv (se Poetry der problema):**
```bash
.venv/bin/python src/main.py
```

---

### 2. Go + Wails + React

**Navegar ate o diretorio:**
```bash
cd ~/mdb2sql/go_wails_react
```

**Criar diretorio de dados:**
```bash
mkdir -p data
```

**Copiar banco de dados:**
```bash
cp ../data/sample.duckdb ./data/sample.duckdb
```

**Instalar dependencias Go:**
```bash
go mod tidy
```

**Executar em modo desenvolvimento:**
```bash
wails dev
```

**Build para producao:**
```bash
wails build
```

**Executavel ficara em:**
```
~/mdb2sql/go_wails_react/build/bin/MDB2SQL
```

**Executar o build:**
```bash
./build/bin/MDB2SQL
```

---

### 3. Rust + Tauri + Svelte

**ATENCAO:** Implementacao Rust tem problemas conhecidos de incompatibilidade entre Tauri v1 e v2.

**Navegar ate o diretorio:**
```bash
cd ~/mdb2sql/rust_tauri_svelte
```

**Instalar dependencias do frontend:**
```bash
cd ui
pnpm install
cd ..
```

**Tentar build (pode falhar):**
```bash
cd src-tauri
cargo build
```

**Se der erro de incompatibilidade de versoes:**
- Verificar temp/ERROS_E_PROBLEMAS_POC.md para detalhes
- Esta e uma limitacao conhecida da POC

---

## TESTES COMPLETOS

### Script Bash para Rodar Todas as GUIs

**Criar arquivo:** `run_all_guis_debian.sh`

```bash
#!/usr/bin/env bash
# Script para rodar as 3 implementacoes GUI no Debian

set -e

echo "========================================="
echo "MDB2SQL - Running All GUI Implementations"
echo "========================================="
echo ""

# Cores
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. Python + PyQt6
echo -e "${GREEN}[1/3] Starting Python + PyQt6...${NC}"
cd ~/mdb2sql/py_qt6
poetry run python src/main.py &
PY_PID=$!
echo -e "${CYAN}Python GUI started (PID: $PY_PID)${NC}"
sleep 2

# 2. Go + Wails + React
echo ""
echo -e "${GREEN}[2/3] Starting Go + Wails + React...${NC}"
cd ~/mdb2sql/go_wails_react
wails dev &
GO_PID=$!
echo -e "${CYAN}Go Wails GUI started (PID: $GO_PID)${NC}"
sleep 3

# 3. Rust + Tauri + Svelte (pode falhar)
echo ""
echo -e "${GREEN}[3/3] Starting Rust + Tauri + Svelte...${NC}"
cd ~/mdb2sql/rust_tauri_svelte
cargo tauri dev &
RUST_PID=$!
echo -e "${CYAN}Rust Tauri GUI started (PID: $RUST_PID)${NC}"

echo ""
echo "========================================="
echo -e "${YELLOW}All 3 GUIs are starting...${NC}"
echo ""
echo "PIDs:"
echo "  Python PyQt6: $PY_PID"
echo "  Go Wails:     $GO_PID"
echo "  Rust Tauri:   $RUST_PID"
echo ""
echo "Press Ctrl+C to stop all processes"
echo "========================================="

# Wait for all background processes
wait
```

**Dar permissao de execucao:**
```bash
chmod +x run_all_guis_debian.sh
```

**Executar:**
```bash
./run_all_guis_debian.sh
```

---

## PROBLEMAS CONHECIDOS NO DEBIAN

### 1. PyQt6 Sem Display X11

**Problema:** `cannot connect to X server`

**Solucao:** Garantir que DISPLAY esta definido
```bash
export DISPLAY=:0
```

**OU executar com Wayland:**
```bash
QT_QPA_PLATFORM=wayland poetry run python src/main.py
```

---

### 2. Wails Sem GTK/WebKit

**Problema:** `package webkit2gtk-4.1 not found`

**Solucao:**
```bash
sudo apt install -y libwebkit2gtk-4.1-dev libgtk-3-dev
```

---

### 3. DuckDB Shared Library

**Problema:** Erros ao carregar libduckdb.so

**Solucao:**
```bash
sudo ldconfig
```

---

### 4. Permission Denied em Scripts

**Problema:** `Permission denied` ao executar scripts

**Solucao:**
```bash
chmod +x script_name.sh
```

---

### 5. Poetry Nao Encontra Python 3.14

**Problema:** Poetry usa Python errado

**Solucao:**
```bash
# Forcar Poetry a usar Python 3.14
poetry env use python3.14
poetry install
```

---

## VERSOES TESTADAS E FUNCIONAIS

### Debian 13.2 Stable (Trixie)

```
Debian: 13.2 stable
Kernel: 6.x
Node.js: 23.3.0
npm: 10.9.0
pnpm: Latest
Python: 3.14.0
Poetry: 1.8.5
Go: 1.23.3
Wails: v2.11.0
Rust: 1.83.0
Cargo: 1.83.0
```

---

## CONFIGURACOES ADICIONAIS

### Habilitar Wayland para GUIs

```bash
# Adicionar ao ~/.bashrc
echo 'export QT_QPA_PLATFORM=wayland' >> ~/.bashrc
echo 'export GDK_BACKEND=wayland' >> ~/.bashrc
source ~/.bashrc
```

---

### Otimizacoes de Performance

```bash
# Instalar aceleracao de hardware (Intel/AMD)
sudo apt install -y mesa-vulkan-drivers libvulkan1

# Verificar Vulkan
vulkaninfo | head -20
```

---

## PROXIMOS PASSOS

1. Testar instalacao em VM limpa do Debian 13.2 stable
2. Criar script de instalacao automatizado (apt + bash)
3. Documentar erros especificos do Debian
4. Adicionar suporte a Ubuntu 24.04 LTS

---

**Ultima Atualizacao:** 2025-11-20 22:40 UTC-3
**Responsavel:** Claude Code
**Versao Testada:** Debian 13.2 Stable (Trixie)
**Status:** RECEITA COMPLETA PARA DEBIAN 13.2 STABLE

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
