@echo off
cd /d "%~dp0"
set "BJMPC_SELFTEST=PREVIEW"
set "BJMPC_PAGE=summary"
set "BJMPC_DEMO=1"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0BJMPC-Toolbox.ps1" > "%~dp0Apercu_sortie.txt" 2>&1
