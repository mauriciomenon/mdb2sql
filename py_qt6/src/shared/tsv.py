# Texto separado por TAB para a area de transferencia (cola em colunas no Excel/LibreOffice)
# !T: A value with TAB, line break or quote goes inside double quotes, with inner quotes doubled


def tsv_field(value: object) -> str:
    text = "" if value is None else str(value)
    if any(char in text for char in '\t\n\r"'):
        return '"' + text.replace('"', '""') + '"'
    return text


def rows_to_tsv(rows: list[list[object]], header: list[str] | None = None) -> str:
    lines = ([header] if header is not None else []) + rows
    return "\n".join("\t".join(tsv_field(value) for value in line) for line in lines)
