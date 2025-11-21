# Guia Extensivo de Conceitos em Go + Wails + React

> [!info]
> Referencia longa (cerca de 20 pgs equivalentes) com fundamentos, praticas e padrões que precisam estar claros para evoluir o backend Go do MDB2SQL e a ponte com o frontend React via Wails.

## Sumario
- 01. Filosofia de Go e Pragmatismo
- 02. Modulos, Workspaces e Layout do Projeto
- 03. Tipos Basicos, Structs, Generics
- 04. Interfaces, Proprios e Contratos
- 05. Erros: Padrao, Wrapping e Sinalizacao
- 06. Goroutines, Scheduler e Backpressure
- 07. Channels, Select e Concorrencia Segura
- 08. Context: Cancelamento, Deadlines e Timeouts
- 09. Collections, Slices, Maps e Memory Model
- 10. Arquivos, IO, Streams e Bufio
- 11. DuckDB no Go (database/sql + go-duckdb)
- 12. Performance, Perfis e Benchmarks
- 13. Testes: unit, integration, golden tests
- 14. Estrutura do Backend Wails
- 15. Binding com Frontend React (runtime)
- 16. Serializacao, DTOs e Validacao
- 17. Build, Releases e Cross-Compilation
- 18. Observabilidade: Logs, Metrics, Traces
- 19. Seguranca, Config, Falhas e Resiliencia
- 20. Roteiro de Estudo e Snippets

## 01. Filosofia de Go e Pragmatismo
- Simplicidade sobre features complexas; prefere composicao a heranca.
- Executavel unico, rapida compilacao, foco em ferramentas embutidas (`go test`, `go fmt`, `go vet`).
- Padrao de diretorio claro com `go.mod` unico por implementacao.

## 02. Modulos, Workspaces e Layout do Projeto
- `go.mod` define nome do modulo (ex: `github.com/.../mdb2sql/go_wails_react`).
- Dependencies versionadas via `go.sum`; sem vendor por padrao.
- Estrutura ideal: `backend/` para servicos, `mdb2sql/` ou `app.go` para bindings, `frontend/` JS separado.
- Utilize `go env GOPATH` apenas quando necessario; mod mode eh default.

## 03. Tipos Basicos, Structs, Generics
- Tipos: `int`, `int64`, `string`, `[]byte`, `time.Time`.
- Structs com tags JSON para interoperar com frontend: `type Row struct { ID int ` + "`json:\"id\"`" + ` }`.
- Generics para utilidades internas (ex: `MapSlice[T, R]` para converter slices) mantendo API externa simples.
- Zero values significam estado inicial valido; construtores opcionais.

## 04. Interfaces, Proprios e Contratos
- Interfaces pequenas (ex: `type Logger interface { Info(msg string) }`).
- Implementacao implicita; sem palavra-chave `implements`.
- Prefira interfaces aceitas (consumidas) em vez de retornadas para facilitar testes.
- Use `io.Reader`, `io.Writer`, `context.Context` em APIs publicas.

## 05. Erros: Padrao, Wrapping e Sinalizacao
- `if err != nil { return err }` padrao; evite panics em fluxo normal.
- Wrapping com `%w` (fmt.Errorf) para checagem via `errors.Is/As`.
- Erros de dominio: `var ErrTableNotFound = errors.New("table not found")`.
- Logging do erro soh na borda, evitando logs duplicados.

## 06. Goroutines, Scheduler e Backpressure
- Goroutine eh leve; use para I/O paralelo (consultas, leitura de arquivos). Evite spam sem controle.
- Combine com WaitGroups para sincronizar finalizacao.
- Backpressure: limitar goroutines com semaforos (channel buffered) ou pools.
- Nunca acesse UI do React direto; apenas via bindings/emit.

## 07. Channels, Select e Concorrencia Segura
- Channels unbuffered para sincronizacao, buffered para filas.
- `select` para multiplexar eventos (dados, contexto cancelado, timeouts).
- Evitar usar channel como queue infinita; sempre prever fechamento.
- Padrao produtor/consumidor: produtor fecha channel apos enviar todos itens.

## 08. Context: Cancelamento, Deadlines e Timeouts
- Sempre primeiro parametro: `ctx context.Context` em funcoes publicas.
- Cancel com `context.WithCancel`/`WithTimeout`; propagar ate funcoes internas.
- Use `select { case <-ctx.Done(): return ctx.Err() }` em loops longos.
- No Wails, converta eventos/requests para contexts; respeitar cancelamento de UI.

## 09. Collections, Slices, Maps e Memory Model
- `append` pode realocar; cuidado ao compartilhar slices (usar `copy`).
- Maps nao sao thread-safe; proteger com mutex ou limitar ao uso em uma goroutine.
- Iterate com range; ordem de map e indefinida, nao depender.
- Use `sync.Map` apenas quando contencao for problema real e acesso paralelo for simples.

## 10. Arquivos, IO, Streams e Bufio
- Preferir `bufio.Scanner` para linhas e `bufio.Reader` para blocos.
- Use `os.MkdirAll` para garantir diretorios de data/logs.
- Sempre `defer file.Close()` apos abrir; lidar com permissao cross-platform.
- Paths construidos com `filepath.Join` para portabilidade.

## 11. DuckDB no Go (database/sql + go-duckdb)
- Importar driver: `_ "github.com/marcboeker/go-duckdb"`.
- Abrir conexao read-only: `sql.Open("duckdb", fmt.Sprintf("%s?access_mode=read_only", path))`.
- Preparar statements para queries repetitivas; usar parametro `?` evitando SQL injection.
- Scan em tipos fortemente tipados; para JSON use `json.RawMessage`.
- Conexoes nao sao thread-safe? `database/sql` gerencia pool, mas DuckDB e embutido: preferir 1 conexao por processo ou pool pequeno.

## 12. Performance, Perfis e Benchmarks
- `go test -bench . -benchmem` para medir funcoes criticas (diff, parsing).
- `pprof` integrado: `import _ "net/http/pprof"` para profiling em dev.
- Evitar alocacoes: reusar buffers, pre-alocar slices com `make([]T, 0, n)`.
- Usa `sync.Pool` com cuidado para objetos reciclaveis.

## 13. Testes: unit, integration, golden tests
- Estrutura sugerida: `backend/db_manager_test.go`, `backend/search_test.go`.
- Golden tests para JSON/SQL: snapshots em `testdata/` lidos via `os.ReadFile`.
- Use `testing.T.Helper()` em helpers para mensagens claras.
- Mocks com interfaces curtas; para DuckDB preferir instancias temporarias reais.

## 14. Estrutura do Backend Wails
- `App` struct em `app.go` segura estado de runtime, contexto e managers.
- Metodos exportados (Public) ficam disponiveis no frontend em `window.go.main.App.Method`.
- Inicializacao no `startup` hook; fechar recursos em `shutdown`.
- Data dir: preferir `runtime.UserConfigDir(app.ctx)` para arquivos mutaveis (logs, cache).

## 15. Binding com Frontend React (runtime)
- Chamada do JS: `const tables = await window.go.main.App.ListTables(path);`.
- Eventos: `runtime.EventsEmit(ctx, "db-loaded", payload)` para push pro frontend.
- Retornos devem ser JSON-serializaveis; use structs com tags `json` e tipos simples.
- Evite expor tipos internos complexos; converta antes de retornar.

## 16. Serializacao, DTOs e Validacao
- Use `encoding/json` padrao; evitar libs extras.
- Define DTOs para tabelas/colunas/diffs com `json` tags e valores default.
- Validar entradas (paths, nomes de tabelas) antes de montar SQL.
- Sanitizar strings de busca (escape wildcard) e limitar tam. de resultados.

## 17. Build, Releases e Cross-Compilation
- `wails build` gera binarios; `-clean` para rebuild completo.
- Cross-compilar: `wails build -platform windows/amd64` etc; garantir deps do OS presentes.
- Embalar assets do frontend via Vite build interno do Wails.
- Versao embedada via ldflags: `-X main.version=...`.

## 18. Observabilidade: Logs, Metrics, Traces
- Logging padrao com `log/slog` ou `zap` leve; niveis: info/debug/error.
- Estruturar logs com campos (table, db, duration_ms).
- Medir duracao de queries com `time.Since(start)`; incluir nos logs.
- Eventos de UI relevantes emitidos para React mostrando estado.

## 19. Seguranca, Config, Falhas e Resiliencia
- Nao concatenar SQL; sempre parametros.
- Nao confiar em paths vindos do frontend; normalizar e limitar a pasta data permitida.
- Recuperar de panics em goroutines com `defer` + `recover`, logar e sinalizar falha amigavel.
- Timeouts padrao para operacoes de disco/rede; degrade gracioso quando DuckDB ocupado.

## 20. Roteiro de Estudo e Snippets
- Ordem sugerida:
  1. Go Tour + Effective Go (2h)
  2. Erros, context e testing (2h)
  3. Goroutines/channels com exemplos de pipelines (3h)
  4. database/sql e duckdb (2h)
  5. Wails runtime + bindings (3h)
  6. Perfis com pprof (1h)
- Snippets uteis:
```go
// Timeout curto para query
ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
defer cancel()
rows, err := db.QueryContext(ctx, "SELECT * FROM tbl LIMIT 200")

// Pool de workers limitado
sem := make(chan struct{}, 4)
for _, job := range jobs {
    sem <- struct{}{}
    go func(job Job) {
        defer func() { <-sem }()
        process(job)
    }(job)
}
```

