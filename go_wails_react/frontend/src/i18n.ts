// Textos da interface: os mesmos catalogos JSON do Go (../../i18n), um por idioma, mesmas chaves
// !T: English is the default and the fallback for a missing key

import en from '../../i18n/en.json';
import ptBR from '../../i18n/pt-BR.json';
import es from '../../i18n/es.json';

export type Lang = 'en' | 'pt-BR' | 'es';
export const LANGS: Lang[] = ['en', 'pt-BR', 'es'];
export const CATALOGS: Record<Lang, Record<string, string>> = { en, 'pt-BR': ptBR, es };

// text of key in lang with {0}, {1}... replaced by args
export function translate(lang: Lang, key: string, ...args: unknown[]): string {
  let s = CATALOGS[lang]?.[key] ?? CATALOGS.en[key] ?? key;
  args.forEach((a, i) => {
    s = s.split(`{${i}}`).join(String(a));
  });
  return s;
}

// a text with a count: key.one when n is 1 and the catalogs have it ("1 tabela"), else key ("2 tabelas", "0 tabelas")
export function translateN(lang: Lang, key: string, n: number, ...args: unknown[]): string {
  const one = `${key}.one`;
  return translate(lang, n === 1 && (one in CATALOGS[lang] || one in CATALOGS.en) ? one : key, ...args);
}

export type T = (key: string, ...args: unknown[]) => string;
export type TN = (key: string, n: number, ...args: unknown[]) => string;
