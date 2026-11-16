; Instalador Windows da pasta do app (mdb2sql.exe + _internal) gerada pelo PyInstaller.
; Por usuario (sem admin): %LOCALAPPDATA%\Programs\<nome>, atalho no menu Iniciar, desinstalador em
; Configuracoes > Aplicativos. Gerado por scripts\package_w11.ps1:
;   makensis /DAPP_NAME=<nome visivel> /DAPP_SLUG=<slug> /DAPP_VERSION=<versao> /DAPP_DIR=<pasta do app>
;            /DOUT_FILE=<instalador.exe> installer.nsi
Unicode true
!define APP_EXE "mdb2sql.exe"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_SLUG}"

Name "${APP_NAME} ${APP_VERSION}"
OutFile "${OUT_FILE}"
; Recurso de versao do instalador (Propriedades > Detalhes)
VIProductVersion "${APP_VERSION}.0"
VIFileVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "FileDescription" "${APP_NAME} installer"
VIAddVersionKey "CompanyName" "Mauricio Menon"
VIAddVersionKey "LegalCopyright" "Mauricio Menon"
; icone do app no instalador e no desinstalador (o atalho usa o do mdb2sql.exe)
Icon "${__FILEDIR__}\..\src\resources\mdb2sql.ico"
UninstallIcon "${__FILEDIR__}\..\src\resources\mdb2sql.ico"
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
RequestExecutionLevel user
SetCompressor /SOLID lzma
Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section
  SetShellVarContext current
  ; atualizacao: nada do runtime anterior fica para tras
  RMDir /r "$INSTDIR\_internal"
  SetOutPath "$INSTDIR"
  File /r "${APP_DIR}\*.*"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Mauricio Menon"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$SMPROGRAMS\${APP_NAME}.lnk"
  ; so o que o instalador gravou: a pasta so some se ficar vazia
  Delete "$INSTDIR\${APP_EXE}"
  RMDir /r "$INSTDIR\_internal"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  ; copia do mdbtools que o app extrai ao abrir .mdb/.accdb sem ODBC
  RMDir /r "$LOCALAPPDATA\mdb2sql\python-pyqt6-${APP_VERSION}"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
SectionEnd
