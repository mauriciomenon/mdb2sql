// NIVEL BASICO: Caixa de salvar nativa de Arquivo > Salvar e Salvar como: varios tipos de arquivo numa ordem fixa
// (SQLite, DuckDB, Excel), ja marcado o do arquivo aberto. Devolve o caminho escolhido e o tipo marcado (posicao em
// `types`); None = cancelada. A confirmacao de substituir um arquivo que ja existe e a da propria caixa.
//
// NIVEL TECNICO: the dialog plugin (rfd) cannot preselect a file type, so on Windows the dialog is the system one
// called directly (GetSaveFileNameW, which takes the index of the selected type). The other systems use the plugin.

use std::path::{Path, PathBuf};

// types = [(nome do tipo, extensao sem ponto)]; path = pasta + nome sugerido
pub fn pick<R: tauri::Runtime>(
    window: &tauri::WebviewWindow<R>,
    title: &str,
    path: &Path,
    types: &[(String, String)],
    selected: usize,
) -> Option<(PathBuf, usize)> {
    if types.is_empty() {
        return None;
    }
    let selected = selected.min(types.len() - 1);
    #[cfg(windows)]
    {
        let owner = window.hwnd().map_or(0, |handle| handle.0 as isize);
        native(owner, title, path, types, selected)
    }
    #[cfg(not(windows))]
    {
        plugin(window, title, path, types, selected)
    }
}

#[cfg(windows)]
fn native(owner: isize, title: &str, path: &Path, types: &[(String, String)], selected: usize) -> Option<(PathBuf, usize)> {
    use std::ffi::{OsStr, OsString};
    use std::os::windows::ffi::{OsStrExt, OsStringExt};

    // OPENFILENAMEW de commdlg.h (a mesma desde o Windows 2000)
    #[repr(C)]
    struct OpenFileName {
        size: u32,
        owner: isize,
        instance: isize,
        filter: *const u16,
        custom_filter: *mut u16,
        max_custom_filter: u32,
        filter_index: u32,
        file: *mut u16,
        max_file: u32,
        file_title: *mut u16,
        max_file_title: u32,
        initial_dir: *const u16,
        title: *const u16,
        flags: u32,
        file_offset: u16,
        file_extension: u16,
        default_ext: *const u16,
        custom_data: isize,
        hook: usize,
        template_name: *const u16,
        reserved_ptr: *mut std::ffi::c_void,
        reserved: u32,
        flags_ex: u32,
    }
    #[link(name = "comdlg32")]
    unsafe extern "system" {
        fn GetSaveFileNameW(options: *mut OpenFileName) -> i32;
    }
    #[link(name = "ole32")]
    unsafe extern "system" {
        fn CoInitializeEx(reserved: *mut std::ffi::c_void, flags: u32) -> i32;
        fn CoUninitialize();
    }
    // a caixa roda na thread do comando (async): a parte de shell dela quer COM de apartamento nessa thread
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const OVERWRITE_PROMPT: u32 = 0x2;
    const HIDE_READ_ONLY: u32 = 0x4;
    const NO_CHANGE_DIR: u32 = 0x8;
    const PATH_MUST_EXIST: u32 = 0x800;
    const EXPLORER: u32 = 0x80000;

    let wide = |text: &OsStr| text.encode_wide().chain([0]).collect::<Vec<u16>>();
    // "nome (*.ext)\0*.ext\0" de cada tipo e um \0 no fim
    let mut filter: Vec<u16> = Vec::new();
    for (name, ext) in types {
        filter.extend(wide(OsStr::new(&format!("{name} (*.{ext})"))));
        filter.extend(wide(OsStr::new(&format!("*.{ext}"))));
    }
    filter.push(0);
    // pasta que nao existe mais (a ultima usada): a caixa nem abriria; fica so o nome e o Windows escolhe a pasta
    let start = match path.parent() {
        Some(dir) if dir.is_dir() => path.as_os_str(),
        _ => path.file_name().unwrap_or_default(),
    };
    let mut file = wide(start);
    file.resize(file.len().max(32_768), 0);
    let title = wide(OsStr::new(title));
    // com extensao padrao a caixa completa o nome digitado sem extensao com a do tipo marcado
    let default_ext = wide(OsStr::new(&types[selected].1));
    let mut options = OpenFileName {
        size: std::mem::size_of::<OpenFileName>() as u32,
        owner,
        instance: 0,
        filter: filter.as_ptr(),
        custom_filter: std::ptr::null_mut(),
        max_custom_filter: 0,
        filter_index: selected as u32 + 1,
        file: file.as_mut_ptr(),
        max_file: file.len() as u32,
        file_title: std::ptr::null_mut(),
        max_file_title: 0,
        initial_dir: std::ptr::null(),
        title: title.as_ptr(),
        flags: OVERWRITE_PROMPT | HIDE_READ_ONLY | NO_CHANGE_DIR | PATH_MUST_EXIST | EXPLORER,
        file_offset: 0,
        file_extension: 0,
        default_ext: default_ext.as_ptr(),
        custom_data: 0,
        hook: 0,
        template_name: std::ptr::null(),
        reserved_ptr: std::ptr::null_mut(),
        reserved: 0,
        flags_ex: 0,
    };
    // S_OK ou S_FALSE (ja iniciado): cada um pede o seu CoUninitialize; RPC_E_CHANGED_MODE (outro modo) nao
    let com = unsafe { CoInitializeEx(std::ptr::null_mut(), COINIT_APARTMENTTHREADED) } >= 0;
    let picked = unsafe { GetSaveFileNameW(&mut options) };
    if com {
        unsafe { CoUninitialize() };
    }
    if picked == 0 {
        return None;
    }
    let end = file.iter().position(|&unit| unit == 0).unwrap_or(file.len());
    let index = (options.filter_index as usize).clamp(1, types.len()) - 1;
    Some((PathBuf::from(OsString::from_wide(&file[..end])), index))
}

// shortcut: the plugin dialog has no "selected type", so the type of the open file goes first in the list; call the
// GTK dialog directly (as on Windows) if the fixed order matters there too
#[cfg_attr(windows, allow(dead_code))]
fn plugin<R: tauri::Runtime>(
    window: &tauri::WebviewWindow<R>,
    title: &str,
    path: &Path,
    types: &[(String, String)],
    selected: usize,
) -> Option<(PathBuf, usize)> {
    use tauri_plugin_dialog::DialogExt;
    let mut dialog = window.dialog().file().set_parent(window).set_title(title);
    if let Some(dir) = path.parent().filter(|dir| dir.is_dir()) {
        dialog = dialog.set_directory(dir);
    }
    if let Some(name) = path.file_name() {
        dialog = dialog.set_file_name(name.to_string_lossy());
    }
    for i in std::iter::once(selected).chain((0..types.len()).filter(|i| *i != selected)) {
        dialog = dialog.add_filter(&types[i].0, &[types[i].1.as_str()]);
    }
    let picked = dialog.blocking_save_file()?.into_path().ok()?;
    // o tipo sai da extensao do arquivo escolhido (a interface confere); sem extensao conhecida vale o marcado
    Some((picked, selected))
}
