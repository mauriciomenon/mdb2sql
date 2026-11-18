# Pasta temporaria desta sessao do app para os SQLite convertidos do Access (<temp>/mdb2sql-python-pyqt6/<id>/).
# Apagada ao sair; a de uma sessao que caiu (trava sem processo vivo) e apagada na proxima abertura.
# !T: QLockFile writes the owner PID; tryLock() on another session's lock succeeds only when that process is gone

import shutil
import tempfile
import uuid
from pathlib import Path

from PyQt6.QtCore import QLockFile

BASE = Path(tempfile.gettempdir()) / "mdb2sql-python-pyqt6"


def _lock(path: Path) -> QLockFile:
    lock = QLockFile(str(path))
    lock.setStaleLockTime(0)  # so o PID decide: uma sessao longa nunca vira "velha" pelo tempo
    return lock


class SessionDir:
    def __init__(self, base: Path | None = None) -> None:
        base = base or BASE
        base.mkdir(parents=True, exist_ok=True)
        self.removed = [lock.with_suffix("") for lock in sorted(base.glob("*.lock")) if _remove_orphan(lock)]
        self.path = base / uuid.uuid4().hex[:12]
        self.lock = _lock(self.path.with_suffix(".lock"))
        if not self.lock.tryLock(0):
            raise RuntimeError(f"lock {self.path}.lock: {self.lock.error()}")
        self.path.mkdir()

    def close(self) -> None:
        shutil.rmtree(self.path, ignore_errors=True)
        self.lock.unlock()  # apaga o .lock


def _remove_orphan(lock_path: Path) -> bool:
    lock = _lock(lock_path)
    if not lock.tryLock(0):
        return False  # outra janela do app aberta: a pasta dela fica
    shutil.rmtree(lock_path.with_suffix(""), ignore_errors=True)
    lock.unlock()
    return True
