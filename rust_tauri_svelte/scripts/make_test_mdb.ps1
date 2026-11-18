# Gera tests\data\sample.mdb, o Access pequeno do teste automatico (cargo test le pelo mdbtools embutido).
# Precisa do Access Database Engine 64 bits (OLE DB e ODBC); so roda de novo se o arquivo tiver de mudar
# (ele fica versionado). Uso: pwsh -NoProfile -File scripts/make_test_mdb.ps1
$ErrorActionPreference = 'Stop'
$out = Join-Path (Split-Path $PSScriptRoot) 'tests\data\sample.mdb'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
Remove-Item -Force $out -ErrorAction Ignore

# Engine Type 5 = formato Access 2000-2003 (.mdb); o SQL do OLE DB e ANSI-92, o unico que aceita DECIMAL(p,s)
$catalog = New-Object -ComObject ADOX.Catalog
[void]$catalog.Create("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$out;Jet OLEDB:Engine Type=5")
$ado = $catalog.ActiveConnection
try {
    [void]$ado.Execute('CREATE TABLE [Sample Types] ([id] INTEGER, [tiny] BYTE, [small] SMALLINT, [price] CURRENCY, [exact] DECIMAL(18,4), [ratio] DOUBLE, [name] TEXT(50), [note] MEMO, [happened] DATETIME, [flag] BIT, [raw] LONGBINARY)')
    [void]$ado.Execute('CREATE TABLE [Empty] ([id] INTEGER, [label] TEXT(10))')
} finally {
    $ado.Close()
}

$conn = [System.Data.Odbc.OdbcConnection]::new("Driver={Microsoft Access Driver (*.mdb, *.accdb)};Dbq=$out;")
$conn.Open()
try {
    $insert = $conn.CreateCommand()
    $insert.CommandText = 'INSERT INTO [Sample Types] VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
    $rows = @(
        @(1, 255, -32768, [decimal]'1234567.8912', [decimal]'12345678901234.5678', 0.1, "Ação, ""aspas""", "linha 1`r`nlinha 2",
            [datetime]'2026-07-14 10:30:05', $true, [byte[]](0, 1, 254, 255)),
        @(2, $null, $null, $null, $null, $null, $null, $null, $null, $false, $null),
        @(3, 0, 7, [decimal]'-0.0001', [decimal]'-1.5', -2.5, '', 'x', [datetime]'1899-12-30', $false, [byte[]](42))
    )
    foreach ($row in $rows) {
        $insert.Parameters.Clear()
        foreach ($value in $row) {
            # sem $(...): ele desmontaria o byte[] num object[]
            if ($null -eq $value) { $value = [DBNull]::Value }
            [void]$insert.Parameters.AddWithValue('p', $value)
        }
        [void]$insert.ExecuteNonQuery()
    }
} finally {
    $conn.Close()
}
Get-Item $out | Select-Object FullName, Length
