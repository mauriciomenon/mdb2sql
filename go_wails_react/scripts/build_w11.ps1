# So o build (sem testes nem dist/): build\bin\mdb2sql.exe e o instalador NSIS, sem caminhos locais embutidos.
# Comando oficial: ..\build_w11_amd64.ps1 (ver README-BUILD.txt).
. (Join-Path $PSScriptRoot 'env_w11.ps1')

# Vite escreve em frontend/dist/<plataforma>-<arch>; um frontend/dist/index.html antigo seria embutido no lugar da UI nova
Remove-Item -Recurse -Force frontend\dist -ErrorAction Ignore

# Arquivos embutidos no exe (go:embed backend/embedded): mdbtools (leitor Access reserva) e a extensao sqlite do DuckDB
$embedded = Join-Path $Root 'backend\embedded'
Get-ChildItem $embedded -Exclude '.gitkeep' | Remove-Item -Force
$mdbtools = Get-ChildItem (Join-Path $tools 'mdbtools') -Directory -Filter 'mdbtools-*' -ErrorAction Ignore | Select-Object -First 1
$extension = Join-Path $tools 'duckdb-ext\sqlite_scanner.duckdb_extension.gz'
if (-not $mdbtools -or -not (Test-Path $extension)) { throw 'mdbtools ou a extensao sqlite faltando em .tools; rode scripts\setup_tools.ps1' }
foreach ($f in 'mdb-tables.exe', 'mdb-schema.exe', 'mdb-export.exe', 'COPYING', 'COPYING.LIB', 'VERSION.txt') {
    Copy-Item (Join-Path $mdbtools.FullName $f) $embedded
}
Copy-Item $extension $embedded

# Numero do build = commits ate HEAD (pasta de cache por build); commit completo e data = hoje, mostrados em
# Ajuda > Sobre (padrao 18b: "Versao 1.3.0 - commit <40 digitos> - <AAAA-MM-DD>")
$buildNumber = git rev-list --count HEAD
if ($LASTEXITCODE) { throw 'git rev-list falhou' }
$buildCommit = git rev-parse HEAD
if ($LASTEXITCODE) { throw 'git rev-parse falhou' }
$buildDate = Get-Date -Format 'yyyy-MM-dd'
"build $buildNumber, commit $buildCommit ($buildDate)"

# -trimpath tira do exe os caminhos da maquina de build (pasta do usuario, cache de modulos); -nsis gera o instalador
wails build -clean -trimpath -nsis -ldflags "-X main.buildNumber=$buildNumber -X main.buildCommit=$buildCommit -X main.buildDate=$buildDate"
if ($LASTEXITCODE) { throw "wails build falhou ($LASTEXITCODE)" }
Get-Item build\bin\mdb2sql.exe, build\bin\mdb2sql-amd64-installer.exe | Select-Object Name, Length, LastWriteTime
