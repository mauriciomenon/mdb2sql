#!/bin/bash
# Script para gerar PDFs de arquivos MD nas pastas temp e renomear para PascalCase
# !T: Converts markdown to PDF using pandoc and renames files to PascalCase convention

set -e

# Verifica se pandoc esta instalado
# !T: Check if pandoc is available for MD to PDF conversion
if ! command -v pandoc &> /dev/null; then
    echo "ERRO: pandoc nao encontrado. Instale com: brew install pandoc"
    echo "ERROR: pandoc not found. Install with: brew install pandoc"
    exit 1
fi

# Funcao para converter snake_case ou kebab-case para PascalCase
# !T: Converts snake_case/kebab-case to PascalCase using sed
to_pascal_case() {
    local input="$1"
    # Remove extensao .md
    local name="${input%.md}"

    # Converte para PascalCase
    # !T: sed replaces _ or - followed by letter with uppercase letter
    echo "$name" | sed -E 's/(^|[_-])([a-z])/\U\2/g'
}

# Array de diretorios temp
# !T: Find all temp directories excluding build artifacts
TEMP_DIRS=($(find /Users/menon/git/mdb2sql -path "*/temp" -type d 2>/dev/null | grep -v ".venv" | grep -v "target" | grep -v "node_modules"))

echo "=== Processando arquivos MD em pastas temp ==="
echo ""

# Contadores
total_files=0
renamed_files=0
pdf_files=0
errors=0

# Processa cada diretorio temp
for temp_dir in "${TEMP_DIRS[@]}"; do
    echo "Processando: $temp_dir"
    echo "---"

    # Encontra todos os arquivos .md no diretorio
    # !T: Process only .md files in current temp directory
    while IFS= read -r md_file; do
        if [[ -f "$md_file" ]]; then
            total_files=$((total_files + 1))

            # Extrai nome do arquivo sem caminho
            basename_file=$(basename "$md_file")
            dir_path=$(dirname "$md_file")

            echo "  Arquivo: $basename_file"

            # Converte para PascalCase
            # !T: Generate PascalCase filename
            pascal_name=$(to_pascal_case "$basename_file")
            new_md_file="$dir_path/${pascal_name}.md"

            # Renomeia se necessario
            # !T: Rename only if filename differs
            if [[ "$basename_file" != "${pascal_name}.md" ]]; then
                echo "    Renomeando: $basename_file -> ${pascal_name}.md"
                mv "$md_file" "$new_md_file"
                renamed_files=$((renamed_files + 1))
                md_file="$new_md_file"  # Atualiza referencia
            else
                echo "    Ja esta em PascalCase: ${pascal_name}.md"
            fi

            # Gera PDF usando pandoc
            # !T: pandoc converts MD to PDF with metadata and formatting
            pdf_file="$dir_path/${pascal_name}.pdf"

            echo "    Gerando PDF: ${pascal_name}.pdf"

            if pandoc "$md_file" -o "$pdf_file" \
                --pdf-engine=xelatex \
                -V geometry:margin=1in \
                -V documentclass=article \
                -V fontsize=11pt \
                --toc \
                --number-sections 2>/dev/null; then

                pdf_files=$((pdf_files + 1))
                echo "    ✓ PDF gerado com sucesso"
            else
                # Tenta metodo alternativo sem xelatex
                # !T: Fallback to default engine if xelatex fails
                echo "    ! xelatex falhou, tentando engine padrao..."

                if pandoc "$md_file" -o "$pdf_file" \
                    -V geometry:margin=1in \
                    --toc 2>/dev/null; then

                    pdf_files=$((pdf_files + 1))
                    echo "    ✓ PDF gerado com engine alternativo"
                else
                    echo "    ✗ ERRO ao gerar PDF"
                    errors=$((errors + 1))
                fi
            fi

            echo ""
        fi
    done < <(find "$temp_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null)

    echo ""
done

# Relatorio final
# !T: Summary statistics of operations performed
echo "==================================="
echo "RESUMO DA OPERACAO:"
echo "==================================="
echo "Arquivos MD encontrados: $total_files"
echo "Arquivos renomeados: $renamed_files"
echo "PDFs gerados: $pdf_files"
echo "Erros: $errors"
echo "==================================="

if [[ $errors -gt 0 ]]; then
    echo ""
    echo "NOTA: Se houver erros de PDF, instale dependencias:"
    echo "  macOS: brew install --cask mactex-no-gui"
    echo "  ou: brew install pandoc basictex"
    exit 1
fi

exit 0
