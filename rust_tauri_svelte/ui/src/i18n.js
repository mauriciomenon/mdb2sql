// NIVEL BASICO: Idiomas da interface: um catalogo por idioma (i18n/<codigo>.js, mesmas chaves) e t(chave, valores)
// NIVEL TECNICO: plain module so `node --test` can check the catalogs without a browser
import en from './i18n/en.js';
import es from './i18n/es.js';
import ptBR from './i18n/pt-BR.js';

// [codigo, nome no proprio idioma]; o primeiro e o padrao
export const LANGS = [
  ['en', 'English'],
  ['pt-BR', 'Português (Brasil)'],
  ['es', 'Español'],
];
export const CATALOGS = { en, 'pt-BR': ptBR, es };

// NIVEL BASICO: Funcao de traducao do idioma; chave sem texto cai no ingles e, sem ingles, na propria chave.
// {nome} no texto vira values.nome
export function translator(lang) {
  const catalog = CATALOGS[lang] ?? en;
  return (key, values = {}) =>
    (catalog[key] ?? en[key] ?? key).replace(/\{(\w+)\}/g, (all, name) => (name in values ? String(values[name]) : all));
}

// NIVEL BASICO: Mensagem do backend com [[chave]] vira a frase do catalogo; o resto (detalhe tecnico) fica igual
export function describe(t, message) {
  return String(message).replace(/\[\[([\w.]+)\]\]/g, (_, key) => t(key));
}
