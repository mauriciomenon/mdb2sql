# Gera testdata\mdb2sql_test.mdb (Access 2000, Jet 4), o .mdb pequeno versionado que os testes leem com o mdbtools.
# So para refazer o arquivo: precisa do Windows com o "Microsoft Access Database Engine" 64 bits (ACE OLEDB).
# Os testes (src\access.zig) conferem exatamente estes valores: mudou aqui, muda la.
# Uso: pwsh -NoProfile -File scripts\make_test_mdb.ps1
$ErrorActionPreference = 'Stop'
$out = Join-Path (Split-Path $PSScriptRoot) 'testdata\mdb2sql_test.mdb'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
Remove-Item $out -ErrorAction Ignore

$conn = "Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$out"
$cat = New-Object -ComObject ADOX.Catalog
$null = $cat.Create("$conn;Jet OLEDB:Engine Type=5")
$cat.ActiveConnection.Close()

$db = New-Object -ComObject ADODB.Connection
$db.Open($conn)
try {
    $sql = @(
        'CREATE TABLE [Tipos] (id LONG, nome TEXT(50), valor DECIMAL(10,2), preco CURRENCY, razao DOUBLE, ' +
        'quando DATETIME, ativo BIT, pequeno BYTE, curto SHORT, nota MEMO, dados LONGBINARY)'
        "INSERT INTO [Tipos] VALUES (1, 'Ação', 1234.56, 19.99, 0.5, #2026-07-14 10:30:00#, True, 255, -7, 'linha 1', 0x00FF10)"
        "INSERT INTO [Tipos] VALUES (2, 'it''s ""q""', -0.01, 0, 2316, #1999-12-31#, False, 0, 32000, '', NULL)"
        'INSERT INTO [Tipos] (id) VALUES (3)'
        'CREATE TABLE [Medições de campo] ([Ponto nº] LONG, [Descrição] TEXT(80))'
        "INSERT INTO [Medições de campo] VALUES (10, 'TENSÃO DE CAMPO')"
        "INSERT INTO [Medições de campo] VALUES (20, NULL)"
        'CREATE TABLE [Vazia] (x LONG)'
    )
    foreach ($s in $sql) { $null = $db.Execute($s) }
} finally { $db.Close() }
"$out ($((Get-Item $out).Length) bytes)"
