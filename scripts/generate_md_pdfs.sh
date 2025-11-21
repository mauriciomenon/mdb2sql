#!/bin/bash
# Script para gerar PDFs de arquivos MD nas pastas temp e raiz do projeto
# !T: Converts markdown to PDF using pandoc, processes all MD files in project

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Verifica se pandoc esta instalado
# !T: Check if pandoc is available for MD to PDF conversion
if ! command -v pandoc &> /dev/null; then
    echo "ERRO: pandoc nao encontrado. Instale com:"
    echo "  macOS: brew install pandoc"
    echo "  Debian/Ubuntu: sudo apt-get install pandoc texlive-xelatex"
    echo "  Windows: winget install Pandoc.Pandoc && winget install MiKTeX.MiKTeX"
    echo ""
    echo "ERROR: pandoc not found. Install with the commands above."
    exit 1
fi

# Array de arquivos MD para processar
# !T: Find all relevant MD files excluding build artifacts and venv
MD_FILES=(
    "$PROJECT_ROOT/README.md"
    "$PROJECT_ROOT/ProjectSpec.md"
    "$PROJECT_ROOT/SetupWindows.md"
    "$PROJECT_ROOT/SetupWindows11.md"
    "$PROJECT_ROOT/SetupDebian.md"
    "$PROJECT_ROOT/SetupSummary.md"
    "$PROJECT_ROOT/temp/ConversaInicial20251116.md"
    "$PROJECT_ROOT/temp/AnaliseMdbEstrutura.md"
    "$PROJECT_ROOT/temp/Diario20251116.md"
    "$PROJECT_ROOT/temp/ErrosEProblemasPoc.md"
    "$PROJECT_ROOT/docs/Tauri2Setup.md"
    "$PROJECT_ROOT/go_wails_react/temp/GoConceptsGuide.md"
    "$PROJECT_ROOT/go_wails_react/temp/UIDesignGuidelines.md"
    "$PROJECT_ROOT/py_qt6/temp/PythonConceptsGuide.md"
    "$PROJECT_ROOT/rust_tauri_svelte/temp/RustConceptsGuide.md"
)

echo "=== Gerando PDFs de arquivos MD ==="
echo ""

# Contadores
total_files=0
pdf_files=0
errors=0

# Processa cada arquivo MD
for md_file in "${MD_FILES[@]}"; do
    if [[ -f "$md_file" ]]; then
        total_files=$((total_files + 1))

        # Extrai nome do arquivo sem caminho
        basename_file=$(basename "$md_file")
        dir_path=$(dirname "$md_file")

        echo "  Arquivo: $basename_file"

        # Remove extensao .md e gera nome do PDF
        # !T: Generate PDF filename with same base name
        file_base="${basename_file%.md}"
        pdf_file="$dir_path/${file_base}.pdf"

        echo "    Gerando PDF: ${file_base}.pdf"

        # Gera PDF usando pandoc
        # !T: pandoc converts MD to PDF with metadata and formatting
PREFERRED_ENGINE=""
if command -v xelatex &> /dev/null; then
    PREFERRED_ENGINE="xelatex"
elif command -v tectonic &> /dev/null; then
    PREFERRED_ENGINE="tectonic"
fi

COMMON_FLAGS=( -s ${PREFERRED_ENGINE:+--pdf-engine=$PREFERRED_ENGINE} -V geometry:margin=1in -V documentclass=article -V fontsize=11pt --toc --number-sections --highlight-style=tango )

if pandoc "$md_file" -o "$pdf_file" "${COMMON_FLAGS[@]}" 2>/dev/null; then

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
    else
        echo "  ! Arquivo nao encontrado: $md_file"
        errors=$((errors + 1))
        echo ""
    fi
done

# Relatorio final
# !T: Summary statistics of operations performed
echo "==================================="
echo "RESUMO DA OPERACAO:"
echo "==================================="
echo "Arquivos MD processados: $total_files"
echo "PDFs gerados: $pdf_files"
echo "Erros: $errors"
echo "==================================="

if [[ $errors -gt 0 ]]; then
    echo ""
    echo "NOTA: Se houver erros de PDF, instale dependencias:"
    echo "  macOS: brew install --cask mactex-no-gui"
    echo "  ou: brew install pandoc basictex"
    echo "  Debian/Ubuntu: sudo apt-get install texlive-xelatex"
    exit 1
fi

exit 0
