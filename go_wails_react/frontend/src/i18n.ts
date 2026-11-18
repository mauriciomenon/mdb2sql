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

export type T = (key: string, ...args: unknown[]) => string;
