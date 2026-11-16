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

// "<base>.<ext>"; se esse for o proprio arquivo aberto, "<base> (export).<ext>" para nao sugerir sobrescreve-lo
export function suggestedName(base, ext, openedPath) {
  const clean = safeFileName(base);
  const name = `${clean}.${ext}`;
  return baseName(openedPath).toLowerCase() === name.toLowerCase() ? `${clean} (export).${ext}` : name;
}
