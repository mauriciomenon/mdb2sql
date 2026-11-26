// NIVEL BASICO: SQLite temporario da conversao do Access
// Ao abrir um .mdb/.accdb o app grava UMA vez um SQLite em <temp>/mdb2sql-rust-tauri-svelte/<pid>-<nome>.sqlite.
// Arquivo > Salvar copia esse arquivo para onde o usuario escolher; fechar, abrir outro ou reabrir apaga o que nao
// foi salvo, e so ao sair do programa a interface pergunta. Nunca fica orfao: Drop apaga o que nao foi salvo, a
// saida do app apaga os deste processo e a abertura seguinte apaga os de processos que ja terminaram (o app caiu).

use std::fs::File;
use std::path::{Path, PathBuf};

// subpasta propria desta versao dentro de cada pasta possivel
const FOLDER: &str = "mdb2sql-rust-tauri-svelte";

// NIVEL BASICO: Pastas possiveis do temporario, na ordem de uso: a temporaria do usuario (%TEMP% no Windows,
// $XDG_CACHE_HOME ou ~/.cache nos outros), a do sistema (%SystemRoot%\Temp, /tmp) e, por ultimo, a pasta do arquivo
// original (`beside`)
pub fn temp_dirs(beside: Option<&Path>) -> Vec<PathBuf> {
    let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from);
    let (user, system) = if cfg!(windows) {
        (std::env::temp_dir(), var("SystemRoot").map(|root| root.join("Temp")))
    } else {
        let cache = var("XDG_CACHE_HOME").or_else(|| var("HOME").map(|h| h.join(".cache")));
        (cache.unwrap_or_else(std::env::temp_dir), Some(PathBuf::from("/tmp")))
    };
    [Some(user), system, beside.map(Path::to_path_buf)].into_iter().flatten().map(|dir| dir.join(FOLDER)).collect()
}

// prefixo dos temporarios deste processo
fn own_prefix() -> String {
    format!("{}-", std::process::id())
}

// NIVEL BASICO: Arquivo temporario novo e vazio "<pid>-<n>-<nome>" na primeira pasta de temp_dirs em que der para
// criar arquivo (a pasta e criada se faltar). `beside`: pasta do arquivo original, a ultima tentativa
pub fn new_temp_path(name: &str, beside: Option<&Path>) -> Result<PathBuf, String> {
    new_temp_in(&temp_dirs(beside), name)
}

// NIVEL TECNICO: create_new reserves the name atomically (no check-then-create); a name already taken (another
// test thread, a leftover) just moves to the next n. SQLite and the CSV writer open the empty file as new.
// A folder that cannot be created or written sends the file to the next one; the error is that of the last folder.
pub(crate) fn new_temp_in(dirs: &[PathBuf], name: &str) -> Result<PathBuf, String> {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);
    let mut failed = String::from("no temporary folder");
    'dirs: for dir in dirs {
        if let Err(e) = std::fs::create_dir_all(dir) {
            failed = format!("{}: {e}", dir.display());
            continue;
        }
        loop {
            let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = dir.join(format!("{}{n}-{name}", own_prefix()));
            match std::fs::OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(_) => return Ok(path),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => {
                    failed = format!("{}: {e}", path.display());
                    continue 'dirs;
                }
            }
        }
    }
    Err(failed)
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

    // a sessao le o DuckDB da conversao, nao este arquivo: o caminho serve para copiar (Salvar) e recusar como destino
    pub fn path(&self) -> &Path {
        &self.path
    }

    // NIVEL BASICO: Pasta do temporario quando ele ficou ao lado do arquivo original (as duas pastas temporarias
    // falharam); a interface guarda para limpar as sobras ali na proxima abertura do app
    pub fn beside(&self) -> Option<&Path> {
        self.path.parent().filter(|dir| !temp_dirs(None).iter().any(|temp| temp == dir))
    }
}

impl Drop for Converted {
    fn drop(&mut self) {
        self._guard = None;
        let _ = std::fs::remove_file(&self.path);
        // ao lado do original nao fica nem a subpasta vazia (remove_dir so apaga pasta vazia)
        if let Some(dir) = self.beside() {
            let _ = std::fs::remove_dir(dir);
        }
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

// NIVEL BASICO: Na abertura do app: apaga as sobras nas pastas temporarias e nas pastas ao lado de arquivos originais
// que a interface guardou (`beside`; so vale pasta com o nome da subpasta do app, e vazia ela some). Devolve quantos
// arquivos apagou (linha do Log)
pub fn clean_all(beside: &[String]) -> usize {
    let mut removed: usize = temp_dirs(None).iter().map(|dir| clean_stale(dir)).sum();
    for dir in beside.iter().map(Path::new).filter(|dir| dir.file_name().is_some_and(|name| name == FOLDER)) {
        removed += clean_stale(dir);
        let _ = std::fs::remove_dir(dir);
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
