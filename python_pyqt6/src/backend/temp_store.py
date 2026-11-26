# Pasta temporaria desta sessao do app para os SQLite convertidos do Access (<temp>/mdb2sql-python-pyqt6/<id>/):
# na pasta temporaria do usuario; se nao der para criar arquivo nela, na do sistema; por ultimo, na pasta do arquivo
# aberto. Apagada ao sair; a de uma sessao que caiu (trava sem processo vivo) e apagada na proxima abertura.
# !T: QLockFile writes the owner PID; tryLock() on another session's lock succeeds only when that process is gone

import os
import shutil
import uuid
from pathlib import Path
from typing import Iterable

from PyQt6.QtCore import QDir, QLockFile

NAME = "mdb2sql-python-pyqt6"


def temp_folders() -> list[Path]:
    """Pasta temporaria do usuario (Windows: GetTempPath / %TEMP%) e a do sistema, nesta ordem."""
    system = Path(os.environ.get("SystemRoot", r"C:\Windows"), "Temp") if os.name == "nt" else Path("/tmp")
    return list(dict.fromkeys([Path(QDir.tempPath()), system]))


def _lock(path: Path) -> QLockFile:
    lock = QLockFile(str(path))
    lock.setStaleLockTime(0)  # so o PID decide: uma sessao longa nunca vira "velha" pelo tempo
    return lock


class SessionDir:
    def __init__(self, base: Path) -> None:
        base.mkdir(parents=True, exist_ok=True)
        self.path = base / uuid.uuid4().hex[:12]
        self.lock = _lock(self.path.with_suffix(".lock"))
        if not self.lock.tryLock(0):
            raise OSError(f"lock {self.path}.lock: {self.lock.error()}")
        self.path.mkdir()

    def close(self) -> None:
        shutil.rmtree(self.path, ignore_errors=True)
        self.lock.unlock()  # apaga o .lock
        _remove_if_empty(self.path.parent)


def _remove_if_empty(base: Path) -> None:
    # sem nenhuma sessao (nenhuma outra janela do app): nada fica na pasta do arquivo aberto
    try:
        base.rmdir()
    except OSError:
        pass  # outra sessao ainda usa a pasta, ou ela nao existe


def open_session(folders: Iterable[Path]) -> SessionDir | None:
    """A sessao na primeira pasta em que der para criar arquivo; None se nenhuma deixar."""
    for folder in folders:
        try:
            return SessionDir(folder / NAME)
        except OSError:
            continue
    return None


def remove_stale(folder: Path) -> int:
    """Apaga de folder as sessoes que cairam; devolve quantos arquivos convertidos foram apagados."""
    removed = 0
    for lock_path in sorted((folder / NAME).glob("*.lock")):
        lock = _lock(lock_path)
        if not lock.tryLock(0):
            continue  # outra janela do app aberta: a pasta dela fica
        session = lock_path.with_suffix("")
        removed += sum(1 for _ in session.rglob("*.sqlite"))
        shutil.rmtree(session, ignore_errors=True)
        lock.unlock()
    _remove_if_empty(folder / NAME)
    return removed
