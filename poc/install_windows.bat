@echo off

echo Installing mdb2sql for Windows...

echo.
echo Installing Python dependencies...
python -m venv venv
call venv\Scripts\activate.bat
python -m pip install --upgrade pip
pip install -r requirements.txt

echo.
echo Downloading Jackcess JARs...
if not exist temp mkdir temp
curl -L -o temp\jackcess-4.0.5.jar https://sourceforge.net/projects/jackcess/files/jackcess/4.0.5/jackcess-4.0.5.jar/download
curl -L -o temp\commons-lang3-3.14.0.jar https://repo1.maven.org/maven2/org/apache/commons/commons-lang3/3.14.0/commons-lang3-3.14.0.jar
curl -L -o temp\commons-logging-1.3.0.jar https://repo1.maven.org/maven2/commons-logging/commons-logging/1.3.0/commons-logging-1.3.0.jar

echo.
echo Installation complete!
echo.
echo For ODBC support (convert_pyodbc.py):
echo   Download and install Microsoft Access Database Engine:
echo   https://www.microsoft.com/en-us/download/details.aspx?id=54920
echo.
echo For Jackcess support (convert_jackcess.py):
echo   Install Java JDK from https://adoptium.net/
echo.
echo Usage:
echo   venv\Scripts\activate
echo   python convert_pyodbc.py --input file.mdb --output database.duckdb
echo   python convert_jackcess.py --input file.mdb --output database.duckdb
