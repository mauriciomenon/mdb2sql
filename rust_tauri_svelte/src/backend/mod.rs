// NIVEL BASICO: Modulo backend do Rust
// db_manager: banco aberto; access e sqlite_io: leitura (e gravacao SQLite); export: exportacao

pub mod access;
pub mod db_manager;
pub mod export;
pub mod sqlite_io;
#[cfg(test)]
mod tests;
