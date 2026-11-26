// NIVEL BASICO: Caminhos dos dialogos de salvar, sem interface (testado com node --test)
// Pasta padrao = pasta do arquivo aberto; sem arquivo aberto, a ultima pasta usada.

function lastSeparator(path) {
  return Math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'));
}

// pasta de um caminho de arquivo ('' se nao tem pasta)
export function dirOf(path) {
  const i = lastSeparator(path || '');
  return i > 0 ? path.slice(0, i) : '';
}

export function baseName(path) {
  return (path || '').slice(lastSeparator(path || '') + 1);
}

// nome sem a extensao
export function stem(path) {
  const name = baseName(path);
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(0, dot) : name;
}

export function defaultSaveDir(openedPath, lastDir) {
  return dirOf(openedPath) || lastDir || '';
}

// junta pasta e nome com o separador que a pasta ja usa
export function joinPath(dir, name) {
  if (!dir) return name;
  const sep = dir.includes('/') && !dir.includes('\\') ? '/' : '\\';
  return dir.endsWith(sep) ? dir + name : dir + sep + name;
}

// caracteres que o Windows nao aceita em nome de arquivo viram "_"
export function safeFileName(text) {
  return (text || '').replace(/[<>:"/\\|?*\x00-\x1f]/g, '_').trim() || 'export';
}

// NIVEL BASICO: SQLite salvo de cada Access, entre execucoes: { [chave do Access]: { dest, destKey } }, chaves de
// file_key no backend ("caminho|bytes|data"). Entrada deste Access, ou null
export function savedEntry(list, accessKey) {
  const entry = accessKey ? list?.[accessKey] : null;
  return entry?.dest && entry.destKey ? entry : null;
}

// lista nova com o SQLite salvo deste Access: a versao antiga do mesmo Access (mesmo caminho) sai; ficam as `max` mais
// recentes
export function withSaved(list, accessKey, dest, destKey, max) {
  const samePath = accessKey.slice(0, accessKey.indexOf('|') + 1);
  const kept = Object.entries(list ?? {}).filter(([key]) => !key.startsWith(samePath));
  return Object.fromEntries([...kept, [accessKey, { dest, destKey }]].slice(-max));
}

// extensao em minusculas, sem o ponto ('' se nao tem)
export function extOf(path) {
  const name = baseName(path);
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
}

// "<base>.<ext>"; se esse for o proprio arquivo aberto, o nome passa por copyName ("<base> (copia)" no idioma da tela)
// para nao sugerir gravar por cima dele
export function suggestedName(base, ext, openedPath, copyName = (name) => name) {
  const clean = safeFileName(base);
  const name = `${clean}.${ext}`;
  return baseName(openedPath).toLowerCase() === name.toLowerCase() ? `${copyName(clean)}.${ext}` : name;
}

// NIVEL BASICO: Arquivo > Salvar: tipos na ordem do app; o do arquivo aberto ja vem marcado (Access e SQLite: SQLite;
// DuckDB: DuckDB)
export const SAVE_FORMATS = ['sqlite', 'duckdb', 'xlsx'];

// tipo e caminho que a caixa de salvar devolveu: vale a extensao digitada se for de um dos tipos; senao o tipo marcado
// na caixa, e o caminho ganha a extensao dele
export function savedFormat(path, index) {
  const typed = extOf(path);
  if (SAVE_FORMATS.includes(typed)) return { path, format: typed };
  const format = SAVE_FORMATS[index] ?? SAVE_FORMATS[0];
  return { path: `${path}.${format}`, format };
}
