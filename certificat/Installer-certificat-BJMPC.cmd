@echo off
rem BJMPC Informatique - installe le certificat de confiance puis debloque les installateurs BJMPC de ce dossier.
rem   Installer-certificat-BJMPC.cmd           : installer
rem   Installer-certificat-BJMPC.cmd /retirer  : retirer le certificat
set "ARG="
if /i "%~1"=="/retirer" set "ARG=-Retirer"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Installer-certificat-BJMPC.ps1" %ARG%
