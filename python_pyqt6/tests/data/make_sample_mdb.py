# Gera tests/data/sample.mdb (Access 2000, Jet 4) pelo driver ODBC do Access do Windows. Dado inventado, sem
# licenca de terceiros: cobre os tipos que a conversao para SQLite precisa preservar (inteiro, decimal exato,
# Double, texto com acento/aspas/quebra de linha, data, booleano, binario, NULL x texto vazio, nomes com espaco).
# Uso (so quando o conteudo mudar; o .mdb fica versionado): uv run python tests/data/make_sample_mdb.py

import ctypes
from decimal import Decimal as D  # texto seria lido com a virgula decimal do Windows pt-BR
import sys
from pathlib import Path

import pyodbc

DRIVER = "Microsoft Access Driver (*.mdb, *.accdb)"
OUT = Path(__file__).with_name("sample.mdb")

ROWS = [
    (1, "U9A", "EXCITACIÓN TENSIÓN DE CAMPO", 2316.0, D("18.0000"), 7, 200, True, "2026-07-14 10:11:12", b"\x00\x01\xff", "a"),
    (2, "U18A", 'linha 1\nlinha 2, "aspas"', 1.5, D("12.3456"), -3, 0, False, "1999-12-31 23:59:59", None, None),
    (3, "", None, None, None, None, None, False, None, b"", ""),
    (4, None, "ação ñandú", -0.001, D("-1.0000"), 32767, 255, True, "2000-02-29 00:00:00", b"\x10", "x y"),
]


def main() -> int:
    if sys.platform != "win32":
        raise SystemExit("precisa do driver ODBC do Access (Windows)")
    OUT.unlink(missing_ok=True)
    # ODBC_ADD_DSN = 1; CREATE_DB com .mdb = arquivo Access 2000 (Jet 4), lido pelo mdbtools e pelo ODBC
    attributes = ctypes.create_unicode_buffer(f'CREATE_DB="{OUT}" General\0\0')  # lista terminada em \0\0
    ok = ctypes.windll.ODBCCP32.SQLConfigDataSourceW(None, 1, DRIVER, attributes)
    if not ok:
        raise SystemExit("SQLConfigDataSource falhou")
    conn = pyodbc.connect(f"Driver={{{DRIVER}}};DBQ={OUT};", autocommit=True)
    cur = conn.cursor()
    cur.execute(
        "CREATE TABLE points (id LONG, sigla TEXT(10), descr MEMO, valor DOUBLE, preco CURRENCY, qtd SHORT,"
        " octet BYTE, ativo BIT, quando DATETIME, bin LONGBINARY, [nome com espaco] TEXT(20))"
    )
    for row in ROWS:
        cur.execute("INSERT INTO points VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", row)
    cur.execute("CREATE TABLE [empty table] (code LONG, label TEXT(10))")
    conn.close()
    print(f"{OUT} ({OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
