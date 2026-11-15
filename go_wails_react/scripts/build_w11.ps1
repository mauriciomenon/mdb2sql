# So o build (sem testes nem dist/): build\bin\mdb2sql.exe sem caminhos locais embutidos.
# Comando oficial: ..\build_w11_amd64.ps1 (ver README-BUILD.txt).
. (Join-Path $PSScriptRoot 'env_w11.ps1')

# Vite escreve em frontend/dist/<plataforma>-<arch>; um frontend/dist/index.html antigo seria embutido no lugar da UI nova
Remove-Item -Recurse -Force frontend\dist -ErrorAction Ignore

# -trimpath tira do exe os caminhos da maquina de build (pasta do usuario, cache de modulos)
wails build -clean -trimpath
if ($LASTEXITCODE) { throw "wails build falhou ($LASTEXITCODE)" }
Get-Item build\bin\mdb2sql.exe | Select-Object Name, Length, LastWriteTime
