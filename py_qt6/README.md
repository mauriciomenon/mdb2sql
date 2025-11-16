# PYTHON + PYQT6 IMPLEMENTATION

---

## STACK

- **Backend**: Python 3.11+ (rapid development, familiar)
- **Frontend**: PyQt6 (native, cross-platform GUI)
- **Database**: DuckDB (embedded analytics)
- **Distribution**: Nuitka or PyInstaller (standalone binary)

---

## PREREQUISITES

### System
- Python 3.11+ (`python3 --version`)
- Poetry 2.0+ (`poetry --version`)

### Platform Specific
- **macOS**: Xcode Command Line Tools (for Nuitka)
- **Linux**: build-essential, python3-dev
- **Windows**: Visual Studio Build Tools (for Nuitka)

---

## SETUP

```bash
# Install Poetry (if not installed)
curl -sSL https://install.python-poetry.org | python3 -

# Install dependencies
poetry install

# Activate virtual environment
poetry shell

# Run application
python src/main.py

# Or run directly with Poetry
poetry run python src/main.py

# Install build tools (optional)
poetry install --with build

# Build with Nuitka (fast binary)
poetry run python -m nuitka --standalone --onefile src/main.py

# Or PyInstaller (more compatible)
poetry run pyinstaller --onefile --windowed src/main.py
```

---

## PROJECT STRUCTURE

```
py_qt6/
├── src/
│   ├── main.py            # entry point, QApplication
│   ├── ui/                # PyQt6 widgets
│   │   ├── main_window.py
│   │   ├── search_panel.py
│   │   ├── result_table.py
│   │   └── diff_viewer.py
│   ├── backend/           # business logic
│   │   ├── db_manager.py
│   │   ├── search_engine.py
│   │   └── diff_engine.py
│   └── shared/
│       ├── types.py
│       └── constants.py
├── config/                # schemas, mappings
├── data/                  # converted DuckDB files
├── importacao/            # original MDB files
├── requirements.txt       # Python dependencies
└── venv/                  # virtual environment
```

---

## KEY CONCEPTS

### PyQt6 Basics
```python
from PyQt6.QtWidgets import QApplication, QMainWindow, QTableWidget

app = QApplication([])
window = QMainWindow()
table = QTableWidget(10, 5)  # 10 rows, 5 columns
window.setCentralWidget(table)
window.show()
app.exec()
```

### Signals and Slots
```python
# Signal: evento emitido por widget
search_button.clicked.connect(self.on_search)

# Slot: metodo que responde ao signal
def on_search(self):
    term = self.search_input.text()
    results = self.search_engine.search(term)
    self.display_results(results)
```

### DuckDB Python
```python
import duckdb

conn = duckdb.connect('data/202511_db1.duckdb', read_only=True)
result = conn.execute("SELECT * FROM table1 WHERE field LIKE ?", [f"%{term}%"])
df = result.df()  # pandas DataFrame
conn.close()
```

### Threading for Performance
```python
from PyQt6.QtCore import QThread, pyqtSignal

class SearchWorker(QThread):
    # Signal emitido quando busca termina
    finished = pyqtSignal(list)

    def run(self):
        results = expensive_search()
        self.finished.emit(results)

# UI nao congela durante busca
worker = SearchWorker()
worker.finished.connect(self.display_results)
worker.start()
```

---

## CURRENT STATUS

- [ ] Project structure created
- [ ] requirements.txt with dependencies
- [ ] Basic QMainWindow
- [ ] DuckDB connection manager
- [ ] Load last database
- [ ] Display table in QTableWidget

---

## LEARNING RESOURCES

### Python Basics
- List comprehensions: `[x for x in items if x > 10]`
- Context managers: `with open(file) as f:` (auto cleanup)
- Type hints: `def search(term: str) -> list[dict]:`
- Dataclasses: estruturas de dados simples

### PyQt6
- Layouts: QVBoxLayout, QHBoxLayout (organizar widgets)
- Models: QAbstractTableModel (dados para QTableView)
- Styles: QSS (CSS-like styling para widgets)

### DuckDB
- Relational API: `conn.table('mytable').filter(...).select(...)`
- Arrow integration: zero-copy para pandas/polars
- Extensions: FTS (full-text search), JSON

---

## DISTRIBUTION

### Nuitka (Recommended)
- Compila Python para C
- Binario rapido (near-native speed)
- Menor footprint
- Suporta plugins PyQt6

```bash
python -m nuitka \
  --standalone \
  --onefile \
  --enable-plugin=pyqt6 \
  --output-dir=build \
  src/main.py
```

### PyInstaller (Alternative)
- Bundler tradicional
- Mais compativel com bibliotecas complexas
- Binario maior

```bash
pyinstaller \
  --onefile \
  --windowed \
  --add-data "config:config" \
  src/main.py
```

---

**Next**: Create virtual environment and install dependencies
