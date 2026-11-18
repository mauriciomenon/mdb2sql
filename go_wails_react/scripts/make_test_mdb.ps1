# Gera backend\testdata\types.mdb, o .mdb pequeno dos testes (gerado aqui: os arquivos do mdbtestdata nao tem licenca).
# So Windows 64 bits com o Access Database Engine (ACE OLEDB). O arquivo gerado e versionado; rodar de novo so para
# mudar o conteudo: pwsh -NoProfile -File scripts\make_test_mdb.ps1
$ErrorActionPreference = 'Stop'
$out = Join-Path (Split-Path $PSScriptRoot) 'backend\testdata\types.mdb'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
Remove-Item $out -ErrorAction Ignore

# Engine Type 5 = Jet 4 (.mdb do Access 2000-2003), o formato que o mdbtools le melhor
$cs = "Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$out;Jet OLEDB:Engine Type=5"
$cat = New-Object -ComObject ADOX.Catalog
$cat.Create($cs) | Out-Null
$cn = $cat.ActiveConnection
$cn.Execute('CREATE TABLE [Tipos] ([ID] COUNTER PRIMARY KEY, [Flag] YESNO, [B] BYTE, [S] SHORT, [L] LONG, ' +
    '[Money] CURRENCY, [Dec] DECIMAL(10,2), [Sng] SINGLE, [Dbl] DOUBLE, [When] DATETIME, [Txt] TEXT(50), ' +
    '[Note] MEMO, [Bin] LONGBINARY)') | Out-Null
$cn.Execute('CREATE TABLE [Cidades e Regiões] ([Nome] TEXT(40), [Habitantes] LONG)') | Out-Null

$cols = '[Flag], [B], [S], [L], [Money], [Dec], [Sng], [Dbl], [When], [Txt], [Note]'
$cn.Execute("INSERT INTO [Tipos] ($cols) VALUES (TRUE, 200, -5, 123456, 1234567.8901, 0.10, 0.1, 0.1, " +
    "#2020-01-02 03:04:05#, 'Ação é ñ', 'linha 1' & Chr(13) & Chr(10) & 'linha 2')") | Out-Null
$cn.Execute('INSERT INTO [Tipos] ([Txt]) VALUES (NULL)') | Out-Null # tudo NULL (Flag: o Access grava Nao)
$cn.Execute("INSERT INTO [Tipos] ($cols) VALUES (FALSE, 0, 0, 0, 0, 0, 0, 0, #1899-12-30#, '', '')") | Out-Null
# binario pelo Recordset: o SQL do Jet nao tem literal binario
$rs = New-Object -ComObject ADODB.Recordset
$rs.Open('SELECT [ID], [Bin] FROM [Tipos] ORDER BY [ID]', $cn, 1, 3) # adOpenKeyset, adLockOptimistic
foreach ($bytes in @([byte[]](0xAA, 0xBB, 0x00)), $null, @([byte[]](0x01))) {
    if ($null -ne $bytes) { $rs.Fields.Item('Bin').AppendChunk([byte[]]$bytes); $rs.Update() }
    $rs.MoveNext()
}
$rs.Close()
$cn.Execute("INSERT INTO [Cidades e Regiões] VALUES ('São Paulo', 11451245)") | Out-Null
$cn.Execute("INSERT INTO [Cidades e Regiões] VALUES ('Foz do Iguaçu', NULL)") | Out-Null
$cn.Close()
Get-Item $out | Select-Object FullName, Length
