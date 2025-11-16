#!/bin/bash

echo "Installing mdb2sql for macOS..."

if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew not found. Install from https://brew.sh"
    exit 1
fi

echo "Installing mdbtools..."
brew install mdbtools

echo "Installing Java (for Jackcess)..."
brew install openjdk

echo "Creating Python virtual environment..."
python3 -m venv venv
source venv/bin/activate

echo "Installing Python dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

echo "Downloading Jackcess JARs..."
mkdir -p temp
curl -L -o temp/jackcess-4.0.5.jar https://sourceforge.net/projects/jackcess/files/jackcess/4.0.5/jackcess-4.0.5.jar/download
curl -L -o temp/commons-lang3-3.14.0.jar https://repo1.maven.org/maven2/org/apache/commons/commons-lang3/3.14.0/commons-lang3-3.14.0.jar
curl -L -o temp/commons-logging-1.3.0.jar https://repo1.maven.org/maven2/commons-logging/commons-logging/1.3.0/commons-logging-1.3.0.jar

echo ""
echo "Installation complete!"
echo ""
echo "Usage:"
echo "  source venv/bin/activate"
echo "  python convert_mdbtools.py --input file.mdb --output database.duckdb"
echo "  python convert_jackcess.py --input file.mdb --output database.duckdb"
