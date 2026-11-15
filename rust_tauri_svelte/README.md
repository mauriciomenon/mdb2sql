# MDB2SQL (Rust + Tauri + Svelte)

Visualizador de bancos DuckDB convertidos de Microsoft Access. Backend em Rust (crate `duckdb`, DuckDB embutido),
janela Tauri 2 (WebView2 no Windows) e interface Svelte 5.

Stack: Rust 1.99.1, tauri 2.12 (tauri-cli 2.12.4, tauri-plugin-dialog 2.8), crate duckdb 1.20000.2
(DuckDB 2.0.0 bundled), Svelte 5.57 + Vite 8.3. Versoes exatas: `rust-toolchain.toml`, `Cargo.lock` e
`pnpm-lock.yaml` (raiz do repositorio).

## Build

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1   # -> dist\w11\amd64\ (exe, instaladores NSIS e MSI)
```

Comandos, produtos, pastas de trabalho e limpeza: [README-BUILD.txt](README-BUILD.txt).
Use sempre esse comando (ou `cargo tauri build`): um `cargo build --release` puro gera um exe que procura o
servidor de desenvolvimento e abre uma janela vazia.

Testes: `cargo test` nesta pasta (backend, texto do About, versoes) e `pnpm --filter mdb2sql-ui test`
(`node --test`, sem dependencias: texto copiado da grade e busca). Desenvolvimento: `cargo tauri dev`.

## Grade de dados

- Clique seleciona uma celula. `Ctrl+C` copia o valor dela.
- Botao direito (ou a tecla de menu) abre o menu: Copy value, Copy row, Copy row with header. A linha vai
  separada por TAB; valores com TAB, quebra de linha ou aspas vao entre aspas, como o Excel espera.
- "Search loaded rows" filtra as linhas carregadas procurando em todas as colunas; "Filter tables" filtra a lista
  de tabelas. A busca vale para o que esta carregado (Row limit), nao para a tabela inteira no banco.

## Versao

A fonte unica e `version` em `Cargo.toml`. O `tauri.conf.json` nao tem `version` (o Tauri herda a do Cargo.toml),
o dialogo About le a mesma constante, e `ui/package.json` repete o numero; `cargo test` falha se eles divergirem.

## Ferramentas com versao fixa

| Ferramenta | Versao | Onde fica | Quem instala |
| --- | --- | --- | --- |
| Rust (rustc, cargo) | 1.99.1 | toolchain do rustup, escolhida por `rust-toolchain.toml` | `scripts/setup_tools.ps1` (`rustup toolchain install`) |
| tauri-cli | 2.12.4 | `.tools\bin\cargo-tauri.exe` (pasta ignorada pelo git) | `scripts/setup_tools.ps1` (`cargo install --root .tools ... --locked`) |
| Dependencias Rust | `Cargo.lock` | registry do cargo | cargo |
| Dependencias do frontend | `pnpm-lock.yaml` (raiz) | `node_modules` | `scripts/setup_tools.ps1` (`pnpm install --frozen-lockfile`) |

O `scripts/build_w11.ps1` usa `.tools\bin\cargo-tauri.exe` quando existe; sem ele cai no `cargo tauri` do sistema.
O Rust 1.100.0 saiu em 2026-11-09, ha menos de duas semanas, por isso o pino fica em 1.99.1.

## O que continua no sistema e por que

- **rustup**: e ele que le o `rust-toolchain.toml` e baixa o compilador fixado, com assinatura conferida. Uma copia
  do toolchain dentro de `.tools/` duplicaria centenas de MB sem ganho.
- **MSVC Build Tools (C++) + Windows SDK**: o linker `link.exe` e o compilador `cl.exe` que constroi o DuckDB
  embutido (C++). Sao instalados pelo Visual Studio Installer, tem licenca propria e varios GB; nao podem ser
  copiados para uma pasta do projeto.
- **Node.js + pnpm**: executam o Vite que gera `ui/dist`. O workspace pnpm e da raiz do repositorio e e
  compartilhado com o stack Go + Wails.
- **WebView2 Runtime**: componente do Windows 11, usado pelo app em execucao.
- **NSIS e WiX**: o tauri-cli baixa as versoes que ele mesmo fixa (e confere o hash) para
  `%LOCALAPPDATA%\tauri` na primeira vez que gera os instaladores.
