# Varre o exe do PyInstaller (bootloader + cada arquivo embutido, descompactado) atras de dados da maquina de build
# !T: Entries are zlib-compressed inside the exe, so a plain byte search of the file would miss them
# Uso: python scripts/scan_exe.py <exe ou pasta> ...   (sai com 1 se achar caminho local; "gmail" so e listado)
# Uma pasta (app onedir, zip ou instalador extraidos) e varrida arquivo por arquivo.

import os
import re
import sys
from pathlib import Path

from PyInstaller.archive.readers import CArchiveReader

# pasta de usuario de quem fez o build (Users\nome, /home/nome); termos extras vem de MDB2SQL_SCAN_TERMS
# (separados por virgula), para nenhum dado pessoal ficar escrito no codigo
USER = re.escape(Path.home().name).encode()
EXTRA = [re.escape(t.strip()).encode() for t in os.environ.get("MDB2SQL_SCAN_TERMS", "").split(",") if t.strip()]
LOCAL = re.compile(b"|".join([rb"users[\\/]+" + USER + rb"\b", rb"/home/" + USER + rb"\b", *EXTRA]), re.IGNORECASE)
# "gmail" aparece em creditos de bibliotecas (stdlib, numpy): listado para conferencia, nao falha o build
CREDITS = re.compile(rb"gmail", re.IGNORECASE)


def scan(exe: Path) -> dict[re.Pattern[bytes], list[str]]:
    hits: dict[re.Pattern[bytes], set[str]] = {LOCAL: set(), CREDITS: set()}

    def check(name: str, data: bytes) -> None:
        # segunda passada sem os bytes NUL: pega as strings UTF-16 das DLLs do Windows
        for blob in (data, data.replace(b"\x00", b"")):
            for pattern, found in hits.items():
                for match in pattern.finditer(blob):
                    found.add(f"{name}: {blob[max(0, match.start() - 40) : match.end() + 40]!r}")

    if exe.is_dir():
        # pasta do app (onedir): cada arquivo; o exe dela tem o PYZ embutido, varrido abaixo
        for path in sorted(p for p in exe.rglob("*") if p.is_file()):
            check(str(path.relative_to(exe)), path.read_bytes())
            # mdb2sql.exe no Windows, mdb2sql (ELF, sem extensao) no Linux
            if path.parent == exe and path.stem == "mdb2sql" and path.suffix.lower() in ("", ".exe"):
                for pattern, found in scan(path).items():
                    hits[pattern].update(found)
        return {pattern: sorted(found) for pattern, found in hits.items()}

    archive = CArchiveReader(str(exe))
    first_entry = min(entry[0] for entry in archive.toc.values())
    check("<bootloader>", exe.read_bytes()[: archive._start_offset + first_entry])
    for name, entry in archive.toc.items():
        if entry[4] == "z":  # PYZ: modulos Python compilados
            pyz = archive.open_embedded_archive(name)
            for module in pyz.toc:
                check(f"{name}:{module}", pyz.extract(module, raw=True) or b"")
        else:
            check(name, archive.extract(name))
    return {pattern: sorted(found) for pattern, found in hits.items()}


if __name__ == "__main__":
    failed = False
    for target in map(Path, sys.argv[1:]):
        result = scan(target)
        for line in result[LOCAL]:
            print("LOCAL", line)
        for line in result[CREDITS]:
            print("terceiros", line)
        print(f"scan {target}: {len(result[LOCAL])} caminhos/dados locais, {len(result[CREDITS])} 'gmail' de terceiros")
        failed = failed or bool(result[LOCAL])
    sys.exit(1 if failed else 0)
