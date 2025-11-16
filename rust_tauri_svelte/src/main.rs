// NIVEL BASICO: Entry point do app Tauri
// Rust compila este codigo e cria a janela do app usando webview do sistema
// O frontend (Svelte) sera servido dentro desta janela

// NIVEL TECNICO: Prevent console window on Windows release builds
#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

use tauri::Manager;

// NIVEL BASICO: Este comando pode ser chamado do JavaScript/Svelte
// usando invoke('greet', { name: 'User' })
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! Welcome to MDB2SQL", name)
}

fn main() {
    // NIVEL BASICO: Builder pattern cria app Tauri
    // invoke_handler registra comandos disponiveis para frontend
    // run() inicia event loop (janela fica aberta ate fechar)

    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![greet])
        .setup(|app| {
            // NIVEL TECNICO: Setup hook, executa antes de mostrar janela
            #[cfg(debug_assertions)]
            {
                let window = app.get_window("main").unwrap();
                window.open_devtools();
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
