// NIVEL BASICO: Modulo backend do Rust
// db_manager: banco aberto; access e sqlite_io: leitura (e gravacao SQLite); converted: SQLite temporario do
// Access; display: X11/Wayland no Linux; export: gravacao (Salvar e Exportar); save_dialog: caixa de salvar com
// varios tipos; terms: pesquisa de termos

pub mod access;
pub mod converted;
pub mod db_manager;
pub mod display;
pub mod export;
pub mod save_dialog;
pub mod sqlite_io;
pub mod terms;
#[cfg(test)]
mod tests;
