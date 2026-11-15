# mdb2sql 1.0.1

Data: 2026-11-15

## Arquivos desta release (Windows 11 x64)
| Arquivo | O que e |
|---|---|
| `mdb2sql-1.0.1-w11-amd64-pyqt.exe` | Python + PyQt6. Executavel unico (novo nesta versao). |
| `mdb2sql-1.0.1-w11-amd64-wails.exe` | Go + Wails + React. Executavel unico, DuckDB embutido. Precisa do WebView2 (ja vem no Windows 11). |
| `mdb2sql-1.0.1-w11-amd64-tauri-setup.exe` | Rust + Tauri 2 + Svelte, instalador NSIS. |
| `mdb2sql-1.0.1-w11-amd64-tauri.msi` | O mesmo app Tauri, instalador MSI. |
| `mdb2sql-1.0.1-w11-amd64-zig.zip` | Zig + Dear ImGui: `mdb2sql-zig.exe` + `duckdb.dll` (deixar os dois na mesma pasta). |
| `SHA256SUMS.txt` | sha256 de cada arquivo. |

## Novidades nos quatro apps
- Tela "Sobre": versao, para que serve, versoes reais de runtime (DuckDB, Qt/Go/Rust/Zig etc.), autor e endereco do codigo.
- Copiar valor (celula selecionada, Ctrl+C ou clique direito), Copiar linha (valores separados por TAB, cola certo no
  Excel) e Copiar linha com cabecalho. Valor com TAB, quebra de linha ou aspas vai entre aspas, como o Excel espera.
- Pesquisa nas linhas carregadas (todas as colunas) e filtro na lista de tabelas.
- Cada pasta de stack tem `setup_tools.ps1` (baixa para `.tools/` as ferramentas fixas, com sha256 conferido) e
  `build_windows.ps1` (gera o executavel sem caminhos da maquina de build). Ver o README de cada pasta.

## Por stack
- PyQt6: menu Edit com as acoes de copia; executavel unico com PyInstaller; a lista de tabelas segue a selecao feita por
  leitor de tela.
- Wails: "Sample data" mostra o nome real do arquivo aberto (antes mostrava sempre sample.duckdb); mensagens de erro
  longas quebram linha em vez de cortar; autor e copyright reais no executavel.
- Tauri: botao "Browse..." com seletor de arquivo nativo; datas e horas no formato `AAAA-MM-DD HH:MM:SS` (antes vinham
  em formato de depuracao), e inteiros sem sinal, HUGEINT e DECIMAL corrigidos; botao de tema Sistema/Claro/Escuro.
- Zig: consultas fora da thread da interface (a janela nao trava; botao Cancelar), seletor de arquivo nativo, exportar
  CSV, sem janela de console, tema claro/escuro (View > Theme), busca tambem no resultado de SQL.

## Removido
- Binario antigo de macOS e script de teste com caminhos locais que estavam no repositorio.

## Limitacoes conhecidas
- A pesquisa cobre as linhas carregadas (limite de linhas), nao a tabela inteira no banco.
- Nenhuma versao converte `.mdb`/`.accdb`; todas abrem bancos DuckDB ja convertidos.
- Zig: so Windows x64; exportar CSV exporta a grade mostrada (pagina de 100 linhas ou ate 10.000 no SQL).
- Wails: o executavel mostra campos de versao vazios nas propriedades do arquivo (aviso do linker do Wails).
- Alertas de dependencia sem correcao publicada: `glib` (Tauri 2 em Linux) e `deepmerge` (baixa severidade).
