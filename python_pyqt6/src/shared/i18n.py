# Textos da interface: um catalogo JSON por idioma (resources/i18n/<codigo>.json, mesmas chaves). Ingles e o padrao;
# Configuracoes > Idioma grava a escolha (QSettings "language") e vale na hora (MainWindow.retranslate).
# !T: tr("key", name=...) formats the text with str.format; a missing key raises KeyError (caught by the tests)

import json

from shared.bundle import resource

LANGUAGES = ("en", "pt_BR", "es")
DEFAULT = "en"
_catalog: dict[str, str] = {}
_language = ""


def catalog(language: str) -> dict[str, str]:
    return json.loads(resource(f"i18n/{language}.json").read_text(encoding="utf-8"))


def set_language(language: str) -> str:
    """Carrega o catalogo (idioma desconhecido: ingles); devolve o idioma em uso."""
    global _catalog, _language
    _language = language if language in LANGUAGES else DEFAULT
    _catalog = catalog(_language)
    return _language


def language() -> str:
    return _language


def tr(key: str, **values: object) -> str:
    if not _catalog:
        set_language(DEFAULT)
    text = _catalog[key]
    return text.format(**values) if values else text


def num(value: int) -> str:
    """Inteiro com separador de milhar do idioma: 36,754 (en) ou 36.754 (pt_BR, es)."""
    return f"{value:,}".replace(",", tr("number.thousands"))
