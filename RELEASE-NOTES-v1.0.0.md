# mdb2sql 1.0.0

Data: 2026-11-15

Visualizador de bancos DuckDB convertidos de Microsoft Access, em quatro implementacoes independentes. Todas abrem
um arquivo `.duckdb`, listam as tabelas e mostram os dados. Testadas com uma base real de 287 tabelas (a maior com
36.754 linhas), com capturas de tela da lista de tabelas e da grade de dados de cada uma.

## Arquivos desta release (Windows 11 x64)
| Arquivo | O que e |
|---|---|
| `mdb2sql-1.0.0-w11-amd64-wails.exe` | Go + Wails + React. Executavel unico, DuckDB embutido. Precisa do WebView2 (ja vem no Windows 11). |
| `mdb2sql-1.0.0-w11-amd64-tauri-setup.exe` | Rust + Tauri 2 + Svelte, instalador NSIS. |
| `mdb2sql-1.0.0-w11-amd64-tauri.msi` | O mesmo app Tauri, instalador MSI. |
| `mdb2sql-1.0.0-w11-amd64-zig.zip` | Zig + Dear ImGui: `mdb2sql-zig.exe` + `duckdb.dll` (deixar os dois na mesma pasta). |
| `SHA256SUMS.txt` | sha256 de cada arquivo. |
A versao PyQt6 roda a partir do codigo: `cd py_qt6 && uv run --python 3.12 python src/main.py [banco.duckdb]`.

## Novidades
- Interfaces novas nas quatro versoes: lista de tabelas com filtro, grade de dados, esquema, limite de linhas, tema
  claro/escuro.
- PyQt6: consultas fora da thread da interface, abre o banco passado na linha de comando ou em `MDB2SQL_DB_PATH`.
- Go + Wails: DuckDB 2.0 ligado estaticamente (sem DLL), abre qualquer banco pelo seletor de arquivos; corrigida a
  janela preta (chaves `frontend:install`/`frontend:build` do Wails v2) e a leitura de colunas booleanas do esquema.
- Rust + Tauri: migrado do Tauri 1 para o Tauri 2, icones reais, interface Svelte 5 refeita.
- Zig + Dear ImGui (novo): abre banco por argumento, `MDB2SQL_DB_PATH`, campo de caminho ou arrastar e soltar;
  dados paginados, busca, ordenacao, esquema e SQL livre.
- DuckDB 2.0 em todas: bancos gravados pelo DuckDB 2.0 nao abrem em versoes 1.x.

## Limitacoes conhecidas
- Nenhuma versao converte `.mdb`/`.accdb`; elas abrem bancos DuckDB ja convertidos.
- Tauri: sem seletor de arquivo nativo (o caminho e digitado); datas aparecem em formato de depuracao.
- Wails: o botao "Sample data" mostra `sample.duckdb` no status mesmo quando `MDB2SQL_DB_PATH` aponta para outro arquivo.
- Zig: so Windows x64, sem seletor de arquivo nativo, sem exportar CSV, consultas na thread da interface (SQL lento
  trava a janela) e abre uma janela de console junto.
- Alertas de dependencia sem correcao disponivel: `glib` (Tauri 2 ainda usa gtk-rs 0.18, so afeta Linux) e `deepmerge`
  (sem versao corrigida publicada), ambos de severidade baixa/media e fora do caminho de execucao no Windows.

## Como compilar
Veja `README.md`, `SetupWindows11.md` e `zig_imgui/README.md`. Resumo:
- Wails: `clean_go_wails.sh`, depois `GOTOOLCHAIN=go1.26.11 wails build -clean` com GCC UCRT no PATH.
- Tauri: `cd rust_tauri_svelte && cargo tauri build`.
- Zig: `cd zig_imgui && zig build -Doptimize=ReleaseSafe` (Zig 0.17.1).
