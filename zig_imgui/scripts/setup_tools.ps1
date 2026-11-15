# Baixa para .tools/ do subprojeto (fora do git) o compilador Zig fixado, para o build nao depender de um Zig global.
# Chamado por ..\build_w11_amd64.ps1; sozinho: pwsh -NoProfile -File scripts/setup_tools.ps1
# As outras dependencias (Dear ImGui, cimgui, zglfw, libduckdb) sao baixadas pelo proprio `zig build`,
# fixadas por hash em build.zig.zon.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Versao estavel fixada. Para trocar: copie "shasum" de x86_64-windows em https://ziglang.org/download/index.json
$ZigVersion = '0.17.1'
$ZigSha256 = 'b03f477a1943673e02aca0f570e8030dffd536ce1f45cbc4d3326ec31159562e'

$name = "zig-x86_64-windows-$ZigVersion"
$tools = Join-Path (Split-Path $PSScriptRoot) '.tools'
$zig = Join-Path $tools "$name\zig.exe"
if (Test-Path $zig) { "Zig $(& $zig version) ja esta em $tools\$name"; return }

New-Item -ItemType Directory -Force $tools | Out-Null
$zip = Join-Path $tools "$name.zip"
"Baixando $name.zip (cerca de 100 MB)..."
Invoke-WebRequest "https://ziglang.org/download/$ZigVersion/$name.zip" -OutFile $zip

# o arquivo baixado so e extraido depois de conferir o sha256 publicado
$got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($got -ne $ZigSha256) {
    Remove-Item $zip
    throw "sha256 de $name.zip nao confere: esperado $ZigSha256, veio $got"
}

# extrai em pasta propria e so depois move para o lugar (o zip tem uma pasta raiz com o mesmo nome)
$tmp = Join-Path $tools '_extract'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory $tmp | Out-Null
& "$env:SystemRoot\System32\tar.exe" -xf $zip -C $tmp
if ($LASTEXITCODE) { throw "falha ao extrair $zip ($LASTEXITCODE)" }
if (Test-Path "$tools\$name") { Remove-Item "$tools\$name" -Recurse -Force }
Move-Item "$tmp\$name" "$tools\$name"
Remove-Item $tmp, $zip -Recurse -Force
"Zig $(& $zig version) instalado em $tools\$name"
