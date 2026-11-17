; Instalador NSIS do MDB2SQL (Zig + Dear ImGui). Gerado por scripts\package_w11.ps1:
;   makensis /DVERSION=<versao> /DAPPDIR=<pasta do app> /DOUTFILE=<instalador.exe> scripts\installer.nsi
; Instala por usuario (sem administrador) em %LOCALAPPDATA%\Programs\mdb2sql-zig-imgui, com atalho no Menu Iniciar
; e desinstalador em Configuracoes > Aplicativos.
Unicode true
ManifestDPIAware true
SetCompressor /SOLID lzma
RequestExecutionLevel user

!include "MUI2.nsh"

!define APPNAME "MDB2SQL (Zig + Dear ImGui)"
!define SLUG "mdb2sql-zig-imgui"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${SLUG}"

Name "${APPNAME} ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${SLUG}"
InstallDirRegKey HKCU "${UNINST_KEY}" "InstallLocation"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${APPNAME} installer"
VIAddVersionKey "LegalCopyright" "Mauricio Menon"

!define MUI_ABORTWARNING
!define MUI_ICON "..\assets\mdb2sql.ico"
!define MUI_UNICON "..\assets\mdb2sql.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\mdb2sql-zig.exe"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "PortugueseBR"

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "${APPDIR}\*.*"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\mdb2sql-zig.exe" "" "$INSTDIR\mdb2sql-zig.exe" 0
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "Mauricio Menon"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\mdb2sql-zig.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  RMDir /r "$INSTDIR\mdbtools"
  Delete "$INSTDIR\mdb2sql-zig.exe"
  Delete "$INSTDIR\duckdb.dll"
  Delete "$INSTDIR\sqlite_scanner.duckdb_extension"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "${UNINST_KEY}"
SectionEnd
