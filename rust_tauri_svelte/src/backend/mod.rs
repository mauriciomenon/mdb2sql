// NIVEL BASICO: Modulo backend do Rust
// db_manager: banco aberto; access e sqlite_io: leitura (e gravacao SQLite); converted: SQLite temporario do
// Access; export: exportacao

pub mod access;
pub mod converted;
pub mod db_manager;
pub mod export;
pub mod sqlite_io;
#[cfg(test)]
mod tests;
