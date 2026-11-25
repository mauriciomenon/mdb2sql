// NIVEL BASICO: SQLite temporario da conversao do Access
// Ao abrir um .mdb/.accdb o app grava UMA vez um SQLite em <temp>/mdb2sql-rust-tauri-svelte/<pid>-<nome>.sqlite e
// le dali. Ao fechar, abrir outro ou sair, a interface pergunta: salvar (move o arquivo para onde o usuario
// escolher) ou apagar. Nunca fica orfao: Drop apaga o que nao foi salvo, a saida do app apaga os deste processo
// e a abertura seguinte apaga os de processos que ja terminaram (o app caiu).

use std::fs::File;
use std::path::{Path, PathBuf};

// pasta do usuario (nunca o /tmp compartilhado): %TEMP% no Windows, $XDG_CACHE_HOME ou ~/.cache nos outros
pub fn temp_dir() -> PathBuf {
    let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from);
    let base = if cfg!(windows) {
        std::env::temp_dir()
    } else {
        var("XDG_CACHE_HOME").or_else(|| var("HOME").map(|h| h.join(".cache"))).unwrap_or_else(std::env::temp_dir)
    };
    base.join("mdb2sql-rust-tauri-svelte")
}

// prefixo dos temporarios deste processo
fn own_prefix() -> String {
    format!("{}-", std::process::id())
}

// NIVEL BASICO: Arquivo temporario novo e vazio "<pid>-<n>-<nome>" na pasta dos temporarios (criada se faltar)
// NIVEL TECNICO: create_new reserves the name atomically (no check-then-create); a name already taken (another
// test thread, a leftover) just moves to the next n. SQLite and the CSV writer open the empty file as new.
pub fn new_temp_path(name: &str) -> Result<PathBuf, String> {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);
    let dir = temp_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    loop {
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = dir.join(format!("{}{n}-{name}", own_prefix()));
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(_) => return Ok(path),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("{}: {e}", path.display())),
        }
    }
}

// NIVEL BASICO: Versao de um arquivo: caminho completo, tamanho e data de modificacao ("caminho|bytes|ns"); None se o
// arquivo nao existe ou nao da para ler. A interface guarda a chave do Access e a do SQLite salvo dele: enquanto as duas
// forem as mesmas, abrir o Access abre o SQLite salvo, sem converter de novo (como o Go)
// NIVEL TECNICO: Windows paths compare case-insensitively, so the path is lowercased there (same as Go's fileKey)
pub fn file_key(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok().filter(|m| m.is_file())?;
    let modified = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos();
    let full = path.canonicalize().ok()?.to_string_lossy().into_owned();
    let full = full.strip_prefix(r"\\?\").map(str::to_string).unwrap_or(full);
    let full = if cfg!(windows) { full.to_lowercase() } else { full };
    Some(format!("{full}|{}|{modified}", meta.len()))
}

// NIVEL BASICO: SQLite convertido ainda nao salvo; sumir com ele (drop) apaga o arquivo
pub struct Converted {
    path: PathBuf,
    // Windows: o arquivo fica aberto sem compartilhar a exclusao, entao a limpeza de outra instancia do app nao
    // consegue apagar um temporario em uso
    _guard: Option<File>,
}

impl Converted {
    // `path` ja gravado e fechado pelo rusqlite
    pub fn new(path: PathBuf) -> Self {
        let guard = lock(&path);
        Converted { path, _guard: guard }
    }

    #[cfg(test)] // o app nao le mais o arquivo convertido (a sessao usa o DuckDB da leitura); os testes conferem
    pub fn path(&self) -> &Path {
        &self.path
    }

    // NIVEL BASICO: Move o SQLite para `target` (substitui um arquivo existente: o dialogo de salvar ja perguntou)
    // Em erro o temporario continua valendo (o usuario pode tentar outra pasta)
    pub fn save(mut self, target: &Path) -> Result<(), (Self, String)> {
        self._guard = None; // fecha o arquivo antes de mover
        let moved = std::fs::rename(&self.path, target).or_else(|_| {
            // outro disco: copia e apaga o temporario (o copy so substitui o destino no fim)
            std::fs::copy(&self.path, target).and_then(|_| std::fs::remove_file(&self.path))
        });
        match moved {
            Ok(()) => Ok(()),
            Err(e) => {
                let message = format!("{}: {e}", target.display());
                self._guard = lock(&self.path);
                Err((self, message))
            }
        }
    }
}

impl Drop for Converted {
    fn drop(&mut self) {
        self._guard = None;
        let _ = std::fs::remove_file(&self.path); // ja salvo (movido): nao existe mais e nada acontece
    }
}

#[cfg(windows)]
fn lock(path: &Path) -> Option<File> {
    use std::os::windows::fs::OpenOptionsExt;
    // FILE_SHARE_READ: outros podem ler, ninguem apaga nem escreve enquanto este processo vive
    std::fs::OpenOptions::new().read(true).share_mode(0x1).open(path).ok()
}

#[cfg(not(windows))]
fn lock(_: &Path) -> Option<File> {
    None
}

// o processo do prefixo <pid>- ainda roda? (Windows: o arquivo travado ja impede a exclusao; ver lock)
#[cfg(unix)]
fn alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

#[cfg(not(unix))]
fn alive(_: u32) -> bool {
    false
}

// NIVEL BASICO: Na abertura do app: apaga os temporarios de processos que ja terminaram; devolve quantos apagou
pub fn clean_stale(dir: &Path) -> usize {
    let own = std::process::id();
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    let mut removed = 0;
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let pid = name.split_once('-').and_then(|(pid, _)| pid.parse::<u32>().ok());
        if pid.is_some_and(|pid| pid != own && !alive(pid)) && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    removed
}

// NIVEL BASICO: Na saida do app: apaga os temporarios deste processo (inclusive uma conversao interrompida)
pub fn remove_own(dir: &Path) {
    let prefix = own_prefix();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        if entry.file_name().to_string_lossy().starts_with(&prefix) {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}
